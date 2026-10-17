import Foundation

/// Sign-in cookies from whichever browser a source belongs to.
enum SessionImport {
    static func read(from source: BrowserImportSource) throws -> ChromeCookieBatch {
        switch source.format {
        case .chromium: return try ChromeSessionImport.read(from: source)
        case .firefox: return try FirefoxSessionImport.read(from: source)
        case .safari: return try SafariSessionImport.read(from: source)
        }
    }
}

/// Firefox keeps cookies unencrypted in cookies.sqlite, so no Keychain is involved; the same
/// consent still comes first. Container, partitioned and private-origin cookies stay behind.
enum FirefoxSessionImport {
    static func read(from source: BrowserImportSource, now: Date = Date()) throws -> ChromeCookieBatch {
        guard source.format == .firefox, let url = source.cookiesURL else {
            throw BrowserImportError.unreadable("This Firefox profile has no cookies database.")
        }
        let database = try BrowserSQLite(url)
        let columns = Set(try database.query("PRAGMA table_info(moz_cookies);").compactMap { $0["name"] as? String })
        var selected = ["host", "name", "value", "path", "expiry", "isSecure", "isHttpOnly"]
        guard Set(selected).isSubset(of: columns) else { throw BrowserImportError.invalidFormat("This Firefox cookie schema is not supported.") }
        selected += ["sameSite", "rawSameSite", "originAttributes", "lastAccessed"].filter(columns.contains)
        let order = columns.contains("lastAccessed") ? "ORDER BY lastAccessed DESC, host, name, path" : "ORDER BY host, name, path"
        let total = (try database.query("SELECT COUNT(*) AS total FROM moz_cookies;").first?["total"] as? NSNumber)?.intValue ?? 0
        let rows = try database.query("SELECT \(selected.joined(separator: ",")) FROM moz_cookies \(order) LIMIT 5000;")
        return try ChromeSessionImport.batch(rows: rows.map(chromeRow), total: total, browser: "Firefox", now: now)
    }

    /// One moz_cookies row in Chrome's shape. Firefox has no host-binding or port metadata to
    /// carry; an unset or None SameSite becomes Lax, as for Chrome's unspecified cookies.
    static func chromeRow(_ row: [String: Any]) -> [String: Any]? {
        if let attributes = row["originAttributes"] as? String, !attributes.isEmpty { return nil }
        func int(_ key: String) -> Int { (row[key] as? NSNumber)?.intValue ?? 0 }
        var expiry = (row["expiry"] as? NSNumber)?.doubleValue ?? 0
        if expiry > 100_000_000_000 { expiry /= 1000 }  // newer Firefox stores milliseconds
        let sameSite = row["rawSameSite"] != nil ? int("rawSameSite") : int("sameSite")
        return ["host_key": row["host"] as? String ?? "", "name": row["name"] as? String ?? "",
                "value": row["value"] as? String ?? "", "path": row["path"] as? String ?? "",
                "is_secure": int("isSecure"), "is_httponly": int("isHttpOnly"),
                "samesite": [1: 1, 2: 2][sameSite] ?? -1,
                "is_persistent": 1, "has_expires": 1, "expires_utc": ChromeSessionImport.chromeTime(expiry)]
    }
}

/// Safari keeps cookies in Cookies.binarycookies inside its protected container. Reading it may
/// need Full Disk Access; Facet asks macOS and never works around a refusal.
enum SafariSessionImport {
    struct Record {
        var domain: String, name: String, path: String, value: String
        var secure: Bool, httpOnly: Bool
        var expires: Date, created: Date

        /// Safari records no SameSite here, so it is treated as unspecified (Lax). It writes only
        /// persistent cookies to disk.
        var chromeRow: [String: Any] {
            ["host_key": domain, "name": name, "value": value, "path": path,
             "is_secure": secure ? 1 : 0, "is_httponly": httpOnly ? 1 : 0, "samesite": -1,
             "is_persistent": 1, "has_expires": 1, "expires_utc": ChromeSessionImport.chromeTime(expires.timeIntervalSince1970)]
        }
    }

    static func cookieFiles() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
                home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")]
    }

    static func read(from source: BrowserImportSource, files: [URL] = cookieFiles(), now: Date = Date()) throws -> ChromeCookieBatch {
        guard source.format == .safari else { throw BrowserImportError.unreadable("Choose Safari to import Safari sign-ins.") }
        guard let data = files.lazy.compactMap({ try? Data(contentsOf: $0) }).first else {
            throw BrowserImportError.unreadable("Safari's cookies could not be read. macOS may require Full Disk Access for Facet (System Settings \u{2192} Privacy & Security \u{2192} Full Disk Access). Nothing was bypassed.")
        }
        let (records, unreadable) = try parse(data)
        let recent = records.sorted { $0.created > $1.created }.prefix(5000)
        return try ChromeSessionImport.batch(rows: recent.map(\.chromeRow), total: records.count, browser: "Safari",
                                             unreadable: unreadable, now: now)
    }

    /// Cookies.binarycookies: "cook", a big-endian page count and page sizes, then pages of
    /// little-endian records whose strings sit at offsets inside each record. Every offset is
    /// bounds-checked; a damaged record is counted and skipped, a damaged file is refused.
    static func parse(_ data: Data) throws -> (records: [Record], unreadable: Int) {
        let bytes = [UInt8](data)
        let invalid = BrowserImportError.invalidFormat("Safari's cookie file is not in a format Facet understands.")
        func be32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return Int(bytes[o]) << 24 | Int(bytes[o + 1]) << 16 | Int(bytes[o + 2]) << 8 | Int(bytes[o + 3])
        }
        func le32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        func double(_ o: Int) -> Double? {
            guard o >= 0, o + 8 <= bytes.count else { return nil }
            let bits = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[o + $1]) << (8 * UInt64($1)) }
            return Double(bitPattern: bits)
        }
        func string(_ o: Int, end: Int) -> String? {
            guard o >= 0, o < end, let zero = bytes[o..<end].firstIndex(of: 0) else { return nil }
            return String(decoding: bytes[o..<zero], as: UTF8.self)
        }
        guard bytes.count >= 8, Array(bytes[0..<4]) == Array("cook".utf8), let pages = be32(4), pages <= 65_536 else { throw invalid }
        var offset = 8 + pages * 4
        var records: [Record] = [], unreadable = 0
        for p in 0..<pages {
            guard let size = be32(8 + p * 4), size >= 12, offset + size <= bytes.count, let count = le32(offset + 4),
                  count <= 65_536, 8 + count * 4 <= size else { throw invalid }
            let page = offset, end = offset + size
            for c in 0..<count {
                guard let relative = le32(page + 8 + c * 4), let length = le32(page + relative), length >= 56,
                      page + relative + length <= end else { unreadable += 1; continue }
                let start = page + relative, recordEnd = start + length
                guard let flags = le32(start + 8), let d = le32(start + 16), let n = le32(start + 20),
                      let pa = le32(start + 24), let v = le32(start + 28),
                      let expires = double(start + 40), let created = double(start + 48), expires.isFinite, created.isFinite,
                      let domain = string(start + d, end: recordEnd), let name = string(start + n, end: recordEnd),
                      let path = string(start + pa, end: recordEnd), let value = string(start + v, end: recordEnd) else { unreadable += 1; continue }
                records.append(Record(domain: domain, name: name, path: path, value: value,
                                      secure: flags & 1 != 0, httpOnly: flags & 4 != 0,
                                      expires: Date(timeIntervalSinceReferenceDate: expires),
                                      created: Date(timeIntervalSinceReferenceDate: created)))
            }
            offset = end
        }
        return (records, unreadable)
    }
}
