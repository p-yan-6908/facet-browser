import Foundation
import Security
import LocalAuthentication
import CommonCrypto
import CryptoKit
import WebKit

struct ChromeCookieBatch {
    let cookies: [HTTPCookie]
    let skipped: Int
    let warnings: [String]
}

struct ChromeCookieInstallResult {
    var imported = 0
    var preserved = 0
    var rejected = 0
    var sites = Set<String>()
}

/// Deliberately narrow adapter, not a password extractor. Secrets remain in memory until
/// handed to WebKit's normal cookie store. Never log rows, values, keys, or raw crypto errors.
/// Covers every Chromium browser whose Keychain item Facet knows; Firefox and Safari rows are
/// converted to the same shape and share the validation below.
enum ChromeSessionImport {
    enum Skipped: Error { case unsupportedEncryption, invalidCookie, expired, partitioned, boundOrigin }

    static func label(_ reason: Skipped) -> String {
        switch reason {
        case .unsupportedEncryption: return "unsupported encryption"
        case .invalidCookie: return "invalid, unverifiable, or unrepresentable cookies"
        case .expired: return "expired cookies"
        case .partitioned: return "partitioned or container cookies"
        case .boundOrigin: return "origin-bound or conflicting cookies"
        }
    }

    static func cookieDatabase(in profile: URL) -> URL? {
        ["Network/Cookies", "Cookies"].map { profile.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func chromeSafeStoragePassword() throws -> Data {
        try safeStoragePassword(keyring: "Chrome", browser: "Chrome")
    }

    /// Called only after explicit session-import consent. Let macOS authorize access; never
    /// change the source item's ACL, create a replacement key, or bypass a denied prompt. Each
    /// Chromium browser keeps its own item, "<Name> Safe Storage"; only that one is requested.
    static func safeStoragePassword(keyring: String, browser: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = "Allow Facet to import the \(browser) sign-in sessions you selected."
        defer { context.invalidate() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(keyring) Safe Storage",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        guard result == errSecSuccess, let password = item as? Data, !password.isEmpty else {
            throw BrowserImportError.unreadable("\(browser) sign-in sessions could not be unlocked. macOS Keychain access was denied or \(keyring) Safe Storage is unavailable. No protection was bypassed; you may need to sign in again in Facet.")
        }
        return password
    }

    static func deriveKey(password: Data) throws -> Data {
        let salt = Array("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let result = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { secret in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        secret.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        guard result == kCCSuccess else { throw Skipped.invalidCookie }
        return key
    }

    static func decrypt(_ encrypted: Data, host: String, version: Int, key: Data) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)) else { throw Skipped.unsupportedEncryption }
        let ciphertext = encrypted.dropFirst(3)
        guard key.count == kCCKeySizeAES128, !ciphertext.isEmpty,
              ciphertext.count % kCCBlockSizeAES128 == 0, ciphertext.count <= 16_384 else { throw Skipped.invalidCookie }
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        var written = 0
        let capacity = plaintext.count
        let result = plaintext.withUnsafeMutableBytes { output in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, ciphertext.count, output.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard result == kCCSuccess else { throw Skipped.invalidCookie }
        let decoded = plaintext.prefix(written)
        let value: Data.SubSequence
        if version >= 24 {
            let digest = Data(SHA256.hash(data: Data(host.utf8)))
            guard decoded.count >= digest.count, decoded.prefix(digest.count) == digest else { throw Skipped.invalidCookie }
            value = decoded.dropFirst(digest.count)
        } else { value = decoded }
        guard let string = String(data: value, encoding: .utf8) else { throw Skipped.invalidCookie }
        return string
    }

    static func read(from source: BrowserImportSource,
                     passwordProvider: (() throws -> Data)? = nil,
                     now: Date = Date()) throws -> ChromeCookieBatch {
        guard source.format == .chromium, let keyring = source.sessionKeyring, let url = source.cookiesURL else {
            throw BrowserImportError.unreadable("Choose a Chrome, Brave, Edge, Arc, Vivaldi, Opera or Chromium profile containing a Cookies database. Other Chromium browsers' encrypted sign-in data is not supported.")
        }
        let browser = source.browserName
        let provide = passwordProvider ?? { try safeStoragePassword(keyring: keyring, browser: browser) }
        let database = try BrowserSQLite(url)
        let meta = try database.query("SELECT value FROM meta WHERE key = 'version';")
        let version = (meta.first?["value"] as? String).flatMap(Int.init) ?? (meta.first?["value"] as? NSNumber)?.intValue ?? 0
        guard version > 0 else { throw BrowserImportError.invalidFormat("\(browser) cookie schema version is missing.") }
        let columns = Set(try database.query("PRAGMA table_info(cookies);").compactMap { $0["name"] as? String })
        var required = ["host_key", "name", "value", "encrypted_value", "path", "expires_utc", "is_secure", "is_httponly", "samesite", "is_persistent", "has_expires"]
        if version >= 24 { required += ["top_frame_site_key", "source_scheme", "source_port"] }
        guard Set(required).isSubset(of: columns) else { throw BrowserImportError.invalidFormat("This \(browser) cookie schema is not supported.") }
        var selected = required
        for column in ["top_frame_site_key", "is_partitioned", "source_scheme", "source_port"] where columns.contains(column) && !selected.contains(column) { selected.append(column) }
        let total = (try database.query("SELECT COUNT(*) AS total FROM cookies;").first?["total"] as? NSNumber)?.intValue ?? 0
        // A large Chrome profile can have far more than 5,000 cookies. Without ORDER BY,
        // SQLite may return an arbitrary subset, which can omit the user's current sessions.
        // Prefer Chrome's recency columns when present, with stable scope/name tie-breakers.
        let order = cookieOrderClause(columns: columns)
        let rows = try database.query("SELECT \(selected.joined(separator: ",")) FROM cookies \(order) LIMIT 5000;")
        var cookies: [HTTPCookie] = []
        var skipped = max(0, total - rows.count)
        var reasons: [String: Int] = [:]
        var key: Data?
        defer { if key != nil { key!.resetBytes(in: 0..<key!.count) } }
        var identities = Set<String>()
        for row in rows.prefix(5000) {
            do {
                // Validate scope and lifetime before requesting any secret.
                _ = try makeCookie(row: row, value: "validation", now: now)
                let encrypted: Data
                if let bytes = row["encrypted_value"] as? Data { encrypted = bytes }
                else if (row["encrypted_value"] as? String) == "" { encrypted = Data() }
                else { throw Skipped.invalidCookie }
                let value: String
                if encrypted.isEmpty {
                    guard let plain = row["value"] as? String else { throw Skipped.invalidCookie }
                    value = plain
                } else {
                    guard encrypted.starts(with: Data("v10".utf8)) else { throw Skipped.unsupportedEncryption }
                    if key == nil {
                        var password = try provide()
                        defer { password.resetBytes(in: 0..<password.count) }
                        key = try deriveKey(password: password)
                    }
                    value = try decrypt(encrypted, host: row["host_key"] as? String ?? "", version: version, key: key!)
                }
                let cookie = try makeCookie(row: row, value: value, now: now)
                guard identities.insert(identity(cookie)).inserted else { throw Skipped.boundOrigin }
                cookies.append(cookie)
            } catch let reason as Skipped {
                skipped += 1
                reasons[label(reason), default: 0] += 1
            }
            // Keychain failures intentionally escape: denying access never triggers a fallback key.
        }
        var warnings = reasons.sorted { $0.key < $1.key }.map { "Skipped \($0.value) \($0.key)." }
        if total > 5000 { warnings.append("Only the 5,000 most recently relevant cookie records were considered; the remaining \(total - 5000) were skipped.") }
        guard !cookies.isEmpty else {
            throw BrowserImportError.unreadable("No transferable sign-in cookies were found in \(browser). " + warnings.joined(separator: " "))
        }
        return ChromeCookieBatch(cookies: cookies, skipped: skipped, warnings: warnings)
    }

    /// Validates plaintext rows already converted to Chrome's shape (Firefox, Safari). A nil row
    /// is a container or partitioned cookie the source keeps apart, which Facet cannot represent.
    static func batch(rows: [[String: Any]?], total: Int, browser: String, unreadable: Int = 0,
                      now: Date = Date()) throws -> ChromeCookieBatch {
        var cookies: [HTTPCookie] = [], identities = Set<String>(), reasons: [String: Int] = [:]
        var skipped = max(0, total - rows.count) + unreadable
        for row in rows {
            do {
                guard let row else { throw Skipped.partitioned }
                guard let value = row["value"] as? String else { throw Skipped.invalidCookie }
                let cookie = try makeCookie(row: row, value: value, now: now)
                guard identities.insert(identity(cookie)).inserted else { throw Skipped.boundOrigin }
                cookies.append(cookie)
            } catch let reason as Skipped {
                skipped += 1
                reasons[label(reason), default: 0] += 1
            }
        }
        var warnings = reasons.sorted { $0.key < $1.key }.map { "Skipped \($0.value) \($0.key)." }
        if unreadable > 0 { warnings.append("Skipped \(unreadable) unreadable cookie records.") }
        if total > rows.count { warnings.append("Only the \(rows.count) most recently used cookie records were considered; the remaining \(total - rows.count) were skipped.") }
        guard !cookies.isEmpty else {
            throw BrowserImportError.unreadable("No transferable sign-in cookies were found in \(browser). " + warnings.joined(separator: " "))
        }
        return ChromeCookieBatch(cookies: cookies, skipped: skipped, warnings: warnings)
    }

    /// A cookie expiry in Unix seconds, as Chrome's microseconds since 1601.
    static func chromeTime(_ unixSeconds: Double) -> NSNumber {
        NSNumber(value: (unixSeconds + 11_644_473_600) * 1_000_000)
    }

    /// Deterministic, recency-biased ordering for the bounded cookie import. Chrome schemas
    /// vary, so use the strongest available activity timestamp and always add stable ties.
    static func cookieOrderClause(columns: Set<String>) -> String {
        let preferred = ["last_access_utc", "last_update_utc", "creation_utc", "expires_utc"]
        let available = preferred.filter { columns.contains($0) }
        let recency = available.map { "\($0) DESC" }
        return "ORDER BY " + (recency + ["host_key ASC", "name ASC", "path ASC"]).joined(separator: ", ")
    }

    static func makeCookie(row: [String: Any], value: String, now: Date) throws -> HTTPCookie {
        func integer(_ field: String) -> Int { (row[field] as? NSNumber)?.intValue ?? 0 }
        guard (row["top_frame_site_key"] as? String ?? "").isEmpty, integer("is_partitioned") == 0 else { throw Skipped.partitioned }
        guard let domain = row["host_key"] as? String, let name = row["name"] as? String,
              let path = row["path"] as? String, path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              !name.isEmpty, name.utf8.count <= 1024, value.utf8.count <= 8192,
              !name.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value >= 0x7f }),
              !name.contains(where: { $0.isWhitespace || "()<>@,;:\\\"/[]?={}".contains($0) }),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || $0 == ";" }) else { throw Skipped.invalidCookie }
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || "/\\:@?#".contains($0) }),
              !host.hasPrefix("."), host.contains("."), !host.hasSuffix("."),
              let origin = URL(string: "https://" + host), origin.host?.lowercased() == host.lowercased() else { throw Skipped.invalidCookie }
        let sourceScheme = integer("source_scheme")
        // WebKit has no source-port field. Only conventional HTTPS origins or legacy
        // unbound cookies are candidates; engine-specific port-keyed policy cannot be cloned.
        let port = (row["source_port"] as? NSNumber)?.intValue ?? -1
        guard (port == -1 || (sourceScheme == 2 ? port == 443 : [80, 443].contains(port))), sourceScheme != 1 else { throw Skipped.boundOrigin }
        guard [0, 2].contains(sourceScheme) else { throw Skipped.invalidCookie }
        let secure = integer("is_secure") != 0 || sourceScheme == 2 // Never weaken HTTPS source binding.
        if name.hasPrefix("__Secure-") && !secure { throw Skipped.invalidCookie }
        if name.hasPrefix("__Host-") && (!secure || domain.hasPrefix(".") || path != "/") { throw Skipped.invalidCookie }
        let persistent = integer("is_persistent") != 0
        var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: name, .value: value,
            .originURL: URL(string: (secure ? "https://" : "http://") + host)!]
        // Foundation treats Secure and Discard as presence flags, even for the string "FALSE".
        if secure { properties[.secure] = "TRUE" }
        // Any Discard property makes Foundation discard the expiry.
        if !persistent { properties[.discard] = "TRUE" }
        if persistent {
            guard integer("has_expires") != 0, let micros = row["expires_utc"] as? NSNumber else { throw Skipped.invalidCookie }
            let seconds = micros.doubleValue / 1_000_000 - 11_644_473_600
            guard seconds.isFinite else { throw Skipped.invalidCookie }
            let expires = Date(timeIntervalSince1970: seconds)
            guard expires > now else { throw Skipped.expired }
            properties[.expires] = expires
        }
        if integer("is_httponly") != 0 { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch integer("samesite") {
        case -1: properties[.sameSitePolicy] = "Lax" // Chrome's default is Lax; nil means None in WebKit.
        case 0: guard secure else { throw Skipped.invalidCookie }; properties[.sameSitePolicy] = "None"
        case 1: properties[.sameSitePolicy] = "Lax"
        case 2: properties[.sameSitePolicy] = "Strict"
        default: throw Skipped.invalidCookie
        }
        guard let cookie = HTTPCookie(properties: properties), cookie.isSecure == secure,
              cookie.isHTTPOnly == (integer("is_httponly") != 0),
              cookie.domain == domain, cookie.path == path, cookie.value == value,
              cookie.isSessionOnly == !persistent,
              sameSite(cookie) == ((properties[.sameSitePolicy] as? String)?.lowercased() ?? "none") else { throw Skipped.invalidCookie }
        return cookie
    }

    /// Foundation exposes explicit None as nil; WebKit maps nil to None, not default Lax.
    static func sameSite(_ cookie: HTTPCookie) -> String { cookie.sameSitePolicy?.rawValue.lowercased() ?? "none" }

    /// Ignore the leading dot for conflict detection so host-only and domain cookies cannot
    /// unexpectedly switch an already signed-in Facet account.
    static func identity(_ cookie: HTTPCookie) -> String {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return [domain.lowercased(), cookie.path, cookie.name].joined(separator: "\u{0}")
    }

    static func install(_ cookies: [HTTPCookie], into store: WKHTTPCookieStore,
                        completion: @escaping (ChromeCookieInstallResult) -> Void) {
        precondition(Thread.isMainThread)
        store.getAllCookies { existing in
            let protected = Set(existing.map(identity))
            var result = ChromeCookieInstallResult()
            func next(_ start: Int) {
                var index = start
                while index < cookies.count && protected.contains(identity(cookies[index])) {
                    result.preserved += 1; index += 1
                }
                guard index < cookies.count else { completion(result); return }
                let cookie = cookies[index]
                store.setCookie(cookie) {
                    store.getAllCookies { current in
                        let stored = current.first { identity($0) == identity(cookie) }
                        let matches = stored.map {
                            $0.value == cookie.value && $0.domain == cookie.domain && $0.path == cookie.path &&
                            $0.isSecure == cookie.isSecure && $0.isHTTPOnly == cookie.isHTTPOnly &&
                            sameSite($0) == sameSite(cookie) && $0.isSessionOnly == cookie.isSessionOnly &&
                            ($0.expiresDate == nil) == (cookie.expiresDate == nil) &&
                            abs(($0.expiresDate?.timeIntervalSince1970 ?? 0) - (cookie.expiresDate?.timeIntervalSince1970 ?? 0)) < 1
                        } ?? false
                        if matches {
                            result.imported += 1; result.sites.insert(cookie.domain); next(index + 1)
                        } else {
                            result.rejected += 1
                            if let stored, stored.value == cookie.value { store.delete(stored) { next(index + 1) } }
                            else { next(index + 1) }
                        }
                    }
                }
            }
            next(0)
        }
    }
}
