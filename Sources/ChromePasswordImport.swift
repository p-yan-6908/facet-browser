import Foundation

struct ImportedLogin {
    let host: String
    let username: String
    let password: String
    let updated: Date
}

struct PasswordImportBatch {
    let logins: [ImportedLogin]
    let skipped: Int
    let warnings: [String]
}

/// Reads saved passwords from a Chromium browser's `Login Data` database. Same narrow,
/// read-only approach as the cookie importer: the Safe Storage key decrypts each value in
/// memory and nothing is written or logged. Firefox (NSS key database) and Safari (iCloud
/// Keychain) keep passwords where a third-party browser cannot read them, so only Chromium
/// is supported here.
enum ChromePasswordImport {
    private enum Skipped: Error { case unsupportedEncryption, empty, invalid }

    static func loginDatabase(in profile: URL) -> URL? {
        let url = profile.appendingPathComponent("Login Data")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func read(from source: BrowserImportSource, passwordProvider: (() throws -> Data)? = nil) throws -> PasswordImportBatch {
        guard source.format == .chromium, let keyring = source.sessionKeyring, let url = source.loginDataURL else {
            throw BrowserImportError.unreadable("Saved passwords can be imported only from a Chromium browser (Chrome, Brave, Edge, Arc, Vivaldi, Opera or Chromium) with a Login Data file.")
        }
        let browser = source.browserName
        let provide = passwordProvider ?? { try ChromeSessionImport.safeStoragePassword(keyring: keyring, browser: browser) }
        let database = try BrowserSQLite(url)
        let columns = Set(try database.query("PRAGMA table_info(logins);").compactMap { $0["name"] as? String })
        guard ["origin_url", "username_value", "password_value"].allSatisfy(columns.contains) else {
            throw BrowserImportError.invalidFormat("This \(browser) password schema is not supported.")
        }
        let dateColumn: String? = ["date_last_used", "date_password_modified", "date_created"].first { columns.contains($0) }
        let blacklist: String = columns.contains("blacklisted_by_user") ? "WHERE blacklisted_by_user = 0 " : ""
        let order: String = dateColumn.map { "ORDER BY \($0) DESC" } ?? ""
        var select: [String] = ["origin_url", "username_value", "password_value"]
        if let dateColumn { select.append(dateColumn) }
        let countRows = try database.query("SELECT COUNT(*) AS t FROM logins \(blacklist);")
        let total: Int = (countRows.first?["t"] as? NSNumber)?.intValue ?? 0
        let columnList = select.joined(separator: ",")
        let rows = try database.query("SELECT \(columnList) FROM logins \(blacklist)\(order) LIMIT 5000;")
        var logins: [ImportedLogin] = []
        var skipped = max(0, total - rows.count)
        var reasons: [String: Int] = [:]
        var key: Data?
        defer { if key != nil { key!.resetBytes(in: 0..<key!.count) } }
        var seen = Set<String>()
        for row in rows.prefix(5000) {
            do {
                guard let origin = row["origin_url"] as? String, let host = URL(string: origin)?.host,
                      let scheme = URL(string: origin)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw Skipped.invalid }
                let username = row["username_value"] as? String ?? ""
                guard let encrypted = row["password_value"] as? Data, !encrypted.isEmpty else { throw Skipped.empty }
                guard encrypted.starts(with: Data("v10".utf8)) else { throw Skipped.unsupportedEncryption }
                if key == nil {
                    var password = try provide()
                    defer { password.resetBytes(in: 0..<password.count) }
                    key = try ChromeSessionImport.deriveKey(password: password)
                }
                // Passwords, unlike schema-24 cookies, carry no host-hash prefix: version 0 keeps the whole value.
                let value = try ChromeSessionImport.decrypt(encrypted, host: "", version: 0, key: key!)
                guard !value.isEmpty else { throw Skipped.empty }
                guard seen.insert("\(host)\n\(username)").inserted else { throw Skipped.invalid }
                let micros = dateColumn.flatMap { (row[$0] as? NSNumber)?.doubleValue } ?? 0
                let updated = micros > 0 ? Date(timeIntervalSince1970: micros / 1_000_000 - 11_644_473_600) : Date(timeIntervalSince1970: 0)
                logins.append(ImportedLogin(host: host, username: username, password: value, updated: updated))
            } catch let reason as Skipped {
                skipped += 1
                let label: String
                switch reason {
                case .unsupportedEncryption: label = "passwords with unsupported (app-bound) encryption"
                case .empty: label = "empty or never-saved entries"
                case .invalid: label = "invalid or duplicate entries"
                }
                reasons[label, default: 0] += 1
            }
            // A Keychain denial escapes, exactly as for cookies: no fallback key is tried.
        }
        var warnings = reasons.sorted { $0.key < $1.key }.map { "Skipped \($0.value) \($0.key)." }
        if total > 5000 { warnings.append("Only the 5,000 most recent passwords were considered.") }
        guard !logins.isEmpty else {
            throw BrowserImportError.unreadable("No importable saved passwords were found in \(browser). " + warnings.joined(separator: " "))
        }
        return PasswordImportBatch(logins: logins, skipped: skipped, warnings: warnings)
    }
}
