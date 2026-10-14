import Foundation

@main
struct ChromeCompatVerify {
    static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fail("usage: chrome-compat-verify <profile>") }
        let profile = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        Config.supportDir = FileManager.default.temporaryDirectory.appendingPathComponent("facet-chrome-compat-store-\(UUID())")
        try FileManager.default.createDirectory(at: Config.supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: Config.supportDir) }

        let history = profile.appendingPathComponent("History")
        let source = BrowserImportSource(id: "compat", browserName: "Google Chrome", profileName: "Disposable", profileURL: profile,
                                         format: .chromium, bookmarksURL: nil,
                                         historyURL: FileManager.default.fileExists(atPath: history.path) ? history : nil)

        guard source.hasHistory else { fail("Chrome did not create a History database") }
        let (_, entries, warnings) = try BrowserImportService.shared.readData(from: source, bookmarks: false, history: true)
        guard entries.contains(where: { $0.url.contains("127.0.0.1") }) else {
            fail("Facet could not read the disposable Chrome navigation from History")
        }

        guard let cookiesURL = source.cookiesURL else { fail("Chrome did not create a Cookies database") }
        let db = try BrowserSQLite(cookiesURL)
        let versionRows = try db.query("SELECT value FROM meta WHERE key='version';")
        let version = (versionRows.first?["value"] as? String).flatMap(Int.init)
            ?? (versionRows.first?["value"] as? NSNumber)?.intValue ?? 0
        guard version > 0 else { fail("Chrome Cookies database has no schema version") }

        let columns = Set(try db.query("PRAGMA table_info(cookies);").compactMap { $0["name"] as? String })
        var required = ["host_key", "name", "value", "encrypted_value", "path", "expires_utc",
                        "is_secure", "is_httponly", "samesite", "is_persistent", "has_expires"]
        if version >= 24 { required += ["top_frame_site_key", "source_scheme", "source_port"] }
        let missing = Set(required).subtracting(columns)
        guard missing.isEmpty else { fail("current Chrome cookie schema is missing fields Facet expects: \(missing.sorted())") }

        let rows = try db.query("SELECT host_key,name,value,encrypted_value FROM cookies WHERE name='facet_fixture' LIMIT 1;")
        guard let row = rows.first else { fail("Chrome did not persist the disposable test cookie") }
        let encrypted = row["encrypted_value"] as? Data ?? Data()
        let plain = row["value"] as? String ?? ""
        let prefix = String(data: encrypted.prefix(3), encoding: .utf8) ?? "binary"

        // This smoke test deliberately does not touch Chrome Safe Storage. Production
        // decryption is covered by deterministic synthetic crypto fixtures. Here we
        // assert that current real Chrome still stores either plaintext or the v10
        // prefix that Facet's macOS importer implements.
        if !encrypted.isEmpty && prefix != "v10" {
            fail("current Chrome uses unsupported cookie encryption prefix \(prefix)")
        }

        if ProcessInfo.processInfo.environment["FACET_ALLOW_CHROME_KEYCHAIN_TEST"] == "YES" {
            guard !encrypted.isEmpty else { fail("interactive Keychain check expected an encrypted fixture cookie") }
            var password = try ChromeSessionImport.chromeSafeStoragePassword()
            defer { password.resetBytes(in: 0..<password.count) }
            var key = try ChromeSessionImport.deriveKey(password: password)
            defer { key.resetBytes(in: 0..<key.count) }
            let host = row["host_key"] as? String ?? ""
            let decrypted = try ChromeSessionImport.decrypt(encrypted, host: host, version: version, key: key)
            guard decrypted == "fixture-session-value" else { fail("Chrome Safe Storage unlocked the fixture but the decrypted value did not match") }
            print("  interactive Keychain decrypt: PASS (value not printed)")
        }

        print("PASS: disposable Chrome profile compatible")
        print("  cookie schema: \(version)")
        print("  cookie storage: \(encrypted.isEmpty ? "plaintext" : prefix)")
        print("  required cookie columns: present")
        print("  history entries read: \(entries.count)")
        if !warnings.isEmpty { print("  history warnings: \(warnings.joined(separator: " | "))") }
        if !plain.isEmpty { print("  plaintext cookie field present (value intentionally not printed)") }
    }
}
