import Foundation
import AppKit
import WebKit
import CommonCrypto
import CryptoKit
import SQLite3
import Network

extension PolishTests {
    // Independently generated with OpenSSL PBKDF2-HMAC-SHA1 (fixture-only / saltysalt / 1003).
    static let cookieKey = Data([0x6a,0xfb,0x14,0xd2,0x55,0x19,0x85,0xfb,0xf5,0x1f,0x1c,0x1a,0xcf,0x57,0x8f,0x8a])

    static func encryptedFixture(_ value: String, host: String = ".fixture.test", version: Int = 24) throws -> Data {
        var plain = version >= 24 ? Data(SHA256.hash(data: Data(host.utf8))) : Data()
        plain.append(Data(value.utf8))
        var out = Data(count: plain.count + kCCBlockSizeAES128)
        let capacity = out.count
        var count = 0
        let iv = Data(repeating: 0x20, count: 16)
        let result = out.withUnsafeMutableBytes { output in
            plain.withUnsafeBytes { input in
                cookieKey.withUnsafeBytes { key in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, cookieKey.count, ivBytes.baseAddress, input.baseAddress, plain.count,
                                output.baseAddress, capacity, &count)
                    }
                }
            }
        }
        guard result == kCCSuccess else { throw NSError(domain: "Fixture encryption", code: Int(result)) }
        return Data("v10".utf8) + out.prefix(count)
    }

    static func cookieRow(_ name: String = "sid", now: Date = Date()) -> [String: Any] {
        ["host_key": ".fixture.test", "name": name, "value": "fixture-only", "encrypted_value": Data(), "path": "/",
         "expires_utc": NSNumber(value: Int64((now.addingTimeInterval(86400).timeIntervalSince1970 + 11_644_473_600) * 1_000_000)),
         "is_secure": 1, "is_httponly": 1, "samesite": 1, "is_persistent": 1, "has_expires": 1,
         "top_frame_site_key": "", "source_scheme": 2, "source_port": 443]
    }

    static func expectCookieRejected(_ row: [String: Any], _ message: String) {
        do { _ = try ChromeSessionImport.makeCookie(row: row, value: "fixture-only", now: Date()); expect(false, message) }
        catch { expect(true, message) }
    }

    static func chromeSessions(_ root: URL) throws {
        let key = try ChromeSessionImport.deriveKey(password: Data("fixture-only".utf8))
        expect(key == cookieKey, "Chrome PBKDF2 matches independent OpenSSL vector")
        let modernOrder = ChromeSessionImport.cookieOrderClause(columns: Set(["host_key", "name", "path", "expires_utc", "creation_utc", "last_update_utc", "last_access_utc"]))
        expect(modernOrder == "ORDER BY last_access_utc DESC, last_update_utc DESC, creation_utc DESC, expires_utc DESC, host_key ASC, name ASC, path ASC",
               "bounded cookie import prefers recent records deterministically")
        let legacyOrder = ChromeSessionImport.cookieOrderClause(columns: Set(["host_key", "name", "path", "expires_utc"]))
        expect(legacyOrder == "ORDER BY expires_utc DESC, host_key ASC, name ASC, path ASC",
               "bounded cookie import has deterministic legacy fallback")
        for version in [23, 24, 30] {
            let encrypted = try encryptedFixture("session-token", version: version)
            let decoded = try ChromeSessionImport.decrypt(encrypted, host: ".fixture.test", version: version, key: key)
            expect(decoded == "session-token", "Chrome v10 decrypt, schema \(version)")
        }
        let encrypted = try encryptedFixture("session-token")
        for (data, host, wrongKey) in [(encrypted, ".wrong.test", key), (Data("v20".utf8) + encrypted.dropFirst(3), ".fixture.test", key), (Data("v10broken".utf8), ".fixture.test", key), (encrypted, ".fixture.test", Data(repeating: 0, count: 16))] {
            do { _ = try ChromeSessionImport.decrypt(data, host: host, version: 24, key: wrongKey); expect(false, "reject invalid crypto or host binding") }
            catch { expect(true, "reject invalid crypto or host binding") }
        }
        let now = Date()
        let row = cookieRow(now: now)
        let cookie = try ChromeSessionImport.makeCookie(row: row, value: "session-token", now: now)
        expect(cookie.isSecure && cookie.isHTTPOnly && cookie.path == "/" && cookie.domain == ".fixture.test", "cookie scope, Secure, HttpOnly preserved")
        expect(cookie.sameSitePolicy?.rawValue.lowercased() == "lax", "SameSite Lax preserved")
        expect(abs((cookie.expiresDate?.timeIntervalSince1970 ?? 0) - now.addingTimeInterval(86400).timeIntervalSince1970) < 1, "Chrome cookie expiry converted")
        for sameSite in [-1, 0, 1, 2] {
            var variation = row; variation["samesite"] = sameSite
            let converted = try ChromeSessionImport.makeCookie(row: variation, value: "session-token", now: now)
            expect(ChromeSessionImport.sameSite(converted) == [-1:"lax", 0:"none", 1:"lax", 2:"strict"][sameSite], "SameSite mode \(sameSite) represented")
        }
        var session = row; session["is_persistent"] = 0; session["has_expires"] = 0; session["expires_utc"] = 0
        let sessionCookie = try ChromeSessionImport.makeCookie(row: session, value: "session-token", now: now)
        expect(sessionCookie.expiresDate == nil && sessionCookie.isSessionOnly, "session cookie remains session-only")
        var hostOnly = row; hostOnly["host_key"] = "fixture.test"; hostOnly["name"] = "__Host-sid"
        let hostCookie = try ChromeSessionImport.makeCookie(row: hostOnly, value: "session-token", now: now)
        expect(hostCookie.domain == "fixture.test", "host-only scope preserved")
        for (field, value, message) in [
            ("top_frame_site_key", "https://top.test" as Any, "partitioned cookies are not flattened"),
            ("is_partitioned", 1 as Any, "legacy partition flag rejected"),
            ("source_port", 8443 as Any, "nonstandard port binding not weakened"),
            ("source_port", 80 as Any, "HTTPS cookie bound to port 80 not widened"),
            ("source_scheme", 1 as Any, "HTTP origin binding not widened"),
            ("source_scheme", 99 as Any, "unknown scheme rejected"),
            ("expires_utc", 1 as Any, "expired cookie excluded"),
            ("host_key", ".com" as Any, "invalid broad domain excluded"),
            ("host_key", "x.test/evil" as Any, "malformed host excluded"),
            ("name", "a\u{0}b" as Any, "control characters excluded"),
            ("name", "__Host-sid" as Any, "invalid domain-scoped Host prefix excluded"),
            ("samesite", 99 as Any, "unknown SameSite not silently weakened")
        ] {
            var bad = row; bad[field] = value; expectCookieRejected(bad, message)
        }
        var stronger = row; stronger["is_secure"] = 0
        let strongerCookie = try ChromeSessionImport.makeCookie(row: stronger, value: "token", now: now)
        expect(strongerCookie.isSecure, "HTTPS source binding stays secure even if original Secure flag is absent")

        let profile = root.appendingPathComponent("Chrome/Default")
        let network = profile.appendingPathComponent("Network")
        try FileManager.default.createDirectory(at: network, withIntermediateDirectories: true)
        let dbURL = network.appendingPathComponent("Cookies")
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { fatalError("fixture cookie database") }
        defer { sqlite3_close(db) }
        try sql(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE meta(key TEXT,value TEXT); INSERT INTO meta VALUES('version','24'); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,expires_utc INTEGER,is_secure INTEGER,is_httponly INTEGER,samesite INTEGER,is_persistent INTEGER,has_expires INTEGER,top_frame_site_key TEXT,source_scheme INTEGER,source_port INTEGER);")
        func insert(_ row: [String: Any]) throws {
            let keys = row.keys.sorted()
            let values = keys.map { key -> String in
                if let data = row[key] as? Data { return "X'" + data.map { String(format: "%02x", $0) }.joined() + "'" }
                if let string = row[key] as? String { return "'" + string.replacingOccurrences(of: "'", with: "''") + "'" }
                return String(describing: row[key]!)
            }
            try sql(db, "INSERT INTO cookies(\(keys.joined(separator: ","))) VALUES(\(values.joined(separator: ",")));")
        }
        var encryptedRow = row; encryptedRow["encrypted_value"] = encrypted; encryptedRow["value"] = "must-not-be-used"
        try insert(encryptedRow)
        var second = encryptedRow; second["name"] = "sid2"; try insert(second)
        var unsupported = encryptedRow; unsupported["name"] = "unsupported"; unsupported["encrypted_value"] = Data("v20".utf8) + encrypted.dropFirst(3); try insert(unsupported)
        var partitioned = encryptedRow; partitioned["name"] = "partitioned"; partitioned["top_frame_site_key"] = "https://top.test"; try insert(partitioned)
        let source = BrowserImportService.shared.customChromiumSource(profileURL: profile)!
        expect(source.hasSessions && !source.hasBookmarks && !source.hasHistory, "cookie-only Chrome profile selectable")
        expect(source.cookiesURL == dbURL, "Network/Cookies location detected")
        let before = try Data(contentsOf: dbURL), beforeWAL = try Data(contentsOf: URL(fileURLWithPath: dbURL.path + "-wal"))
        var keyReads = 0
        let batch = try ChromeSessionImport.read(from: source, passwordProvider: { keyReads += 1; return Data("fixture-only".utf8) })
        expect(keyReads == 1 && batch.cookies.count == 2 && batch.skipped == 2, "one authorized key lookup, unsupported/partitioned rows skipped")
        expect(batch.cookies.allSatisfy { $0.value == "session-token" }, "encrypted cookie takes precedence over plaintext field")
        let after = try Data(contentsOf: dbURL), afterWAL = try Data(contentsOf: URL(fileURLWithPath: dbURL.path + "-wal"))
        expect(before == after && beforeWAL == afterWAL, "cookie database and WAL remain unmodified")
        expect(!batch.warnings.joined().contains("session-token"), "cookie values absent from diagnostics")
        do {
            _ = try ChromeSessionImport.read(from: source, passwordProvider: { throw BrowserImportError.unreadable("Permission denied") })
            expect(false, "Keychain denial must not fall back")
        } catch { expect(error.localizedDescription == "Permission denied", "Keychain denial stops decryption without fallback") }
        try sql(db, "DELETE FROM cookies;")
        var plaintext = row; plaintext["value"] = "plain-fixture"; try insert(plaintext)
        let plainBatch = try ChromeSessionImport.read(from: source, passwordProvider: { keyReads += 1; return Data() })
        expect(plainBatch.cookies.first?.value == "plain-fixture" && keyReads == 1, "plaintext-only profile never requests Keychain")
        try sql(db, "DELETE FROM cookies;")
        try insert(unsupported)
        do { _ = try ChromeSessionImport.read(from: source, passwordProvider: { keyReads += 1; return Data() }); expect(false, "unsupported-only import must fail") }
        catch { expect(error.localizedDescription.contains("unsupported encryption") && keyReads == 1, "unsupported-only import fails without requesting Keychain") }
        let other = BrowserImportSource(id: "other", browserName: "Brave", profileName: "Default", profileURL: profile, format: .chromium, bookmarksURL: nil, historyURL: nil)
        expect(!other.hasSessions, "other Chromium profiles cannot use Chrome's key")
    }

    /// A loopback-only mock site verifies actual authenticated navigation, not just cookie enumeration.
    static func cookieAuthenticatedNavigation(_ dataStore: WKWebsiteDataStore) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        var port: NWEndpoint.Port?
        var sawCookie = false
        var connections: [NWConnection] = []
        listener.stateUpdateHandler = { state in if case .ready = state { port = listener.port } }
        listener.newConnectionHandler = { connection in
            connections.append(connection)
            connection.start(queue: .main)
            var received = Data()
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
                    if let data { received.append(data) }
                    guard received.count <= 16_384, error == nil else { connection.cancel(); return }
                    let text = String(data: received, encoding: .utf8) ?? ""
                    guard text.contains("\r\n\r\n") else { if !complete { receive() }; return }
                    sawCookie = text.components(separatedBy: "\r\n").contains { $0.lowercased().hasPrefix("cookie:") && $0.contains("fixture_auth=synthetic-login") }
                    let title = sawCookie ? "Signed in without login" : "Login required"
                    let body = "<!doctype html><title>\(title)</title><p>\(title)</p>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            receive()
        }
        listener.start(queue: .main)
        defer { connections.forEach { $0.cancel() }; listener.cancel() }
        guard wait("loopback authentication fixture ready", until: { port != nil }), let port else { return }
        var row = cookieRow("fixture_auth")
        row["host_key"] = "127.0.0.1"; row["is_secure"] = 0; row["source_scheme"] = 0; row["source_port"] = -1
        let cookie = try ChromeSessionImport.makeCookie(row: row, value: "synthetic-login", now: Date())
        expect(!cookie.isSecure && cookie.isHTTPOnly, "legacy HTTP cookie attributes preserved")
        var installed = false
        ChromeSessionImport.install([cookie], into: dataStore.httpCookieStore) { installed = $0.imported == 1 }
        guard wait("loopback session cookie installed", until: { installed }) else { return }
        let config = WKWebViewConfiguration(); config.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port.rawValue)/account")!))
        wait("imported cookie authenticates local page without login", seconds: 15, until: { webView.title == "Signed in without login" })
        expect(sawCookie, "WebKit sends migrated authentication cookie on navigation")
        webView.stopLoading()
    }

    static func sessionImportConsentUI(_ root: URL) {
        // The fixture now contains only unsupported v20 data, so even an accidental import
        // cannot reach Keychain. Profile discovery is injected and never scans real data.
        let profile = root.appendingPathComponent("Chrome/Default")
        let chrome = BrowserImportSource(id: "fixture", browserName: "Google Chrome", profileName: "Fixture", profileURL: profile, format: .chromium, bookmarksURL: nil, historyURL: nil)
        let other = BrowserImportSource(id: "other", browserName: "Brave", profileName: "Fixture", profileURL: profile, format: .chromium, bookmarksURL: nil, historyURL: nil)
        let controller = SettingsWindowController(importSourceProvider: { [chrome, other] })
        controller.selectImportPane(); controller.showWindow(nil)
        defer { controller.close() }
        guard let tabs = controller.window?.contentViewController as? NSTabViewController,
              let pane = tabs.children.first(where: { $0.title == "Import" }) else { expect(false, "Import pane registered"); return }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(pane.view)
        guard let sessions = views.compactMap({ $0 as? NSButton }).first(where: { $0.title.lowercased().contains("sign-in sessions") }),
              let button = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Import Selected Data" }),
              let popup = views.compactMap({ $0 as? NSPopUpButton }).first else { expect(false, "session import controls registered"); return }
        expect(sessions.state == .off && sessions.isEnabled && !button.isEnabled, "Chrome sessions are off by default, including cookie-only profiles")
        sessions.state = .on; NSApp.sendAction(sessions.action!, to: sessions.target, from: sessions)
        expect(button.isEnabled, "explicit opt-in enables session-only import")
        popup.selectItem(at: 1); NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        expect(sessions.state == .off && !sessions.isEnabled && !button.isEnabled, "switching to another browser clears session consent")
        popup.selectItem(at: 0); NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        sessions.state = .on; NSApp.sendAction(sessions.action!, to: sessions.target, from: sessions)
        controller.refresh()
        expect(sessions.state == .off && !button.isEnabled, "refresh requires fresh session opt-in")
        sessions.state = .on; NSApp.sendAction(sessions.action!, to: sessions.target, from: sessions)
        var sawConsent = false
        DispatchQueue.main.async {
            if let modal = NSApp.modalWindow {
                sawConsent = descendants(modal.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("account sign-in tokens") }
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
            } else { NSApp.abortModal() }
        }
        NSApp.sendAction(button.action!, to: button.target, from: button)
        expect(sawConsent, "sensitive import requires a detailed consent dialog")
        expect(sessions.state == .off && sessions.isEnabled && !button.isEnabled, "Cancel exits before import and clears consent")
    }

    static func cookieStoreRoundTrip() throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let store = dataStore.httpCookieStore
        var rows: [[String: Any]] = []
        for sameSite in [-1, 0, 1, 2] {
            var row = cookieRow("sid-\(sameSite)"); row["samesite"] = sameSite; rows.append(row)
        }
        var session = cookieRow("session"); session["is_persistent"] = 0; session["has_expires"] = 0; session["expires_utc"] = 0; rows.append(session)
        var host = cookieRow("__Host-sid"); host["host_key"] = "fixture.test"; rows.append(host)
        let cookies = try rows.map { try ChromeSessionImport.makeCookie(row: $0, value: "synthetic-login", now: Date()) }
        var first: ChromeCookieInstallResult?
        ChromeSessionImport.install(cookies, into: store) { first = $0 }
        wait("synthetic cookies installed in nonpersistent WebKit store", seconds: 15, until: { first != nil })
        expect(first?.imported == cookies.count && first?.rejected == 0, "WebKit preserves security attributes for imported cookies")
        var second: ChromeCookieInstallResult?
        ChromeSessionImport.install(cookies, into: store) { second = $0 }
        wait("repeat cookie import completes", until: { second != nil })
        expect(second?.imported == 0 && second?.preserved == cookies.count, "existing Facet cookies preserved on reimport")
        let alternate = try rows.map { try ChromeSessionImport.makeCookie(row: $0, value: "different-account", now: Date()) }
        var third: ChromeCookieInstallResult?
        ChromeSessionImport.install(alternate, into: store) { third = $0 }
        wait("conflicting account import completes", until: { third != nil })
        var fetched: [HTTPCookie]?
        store.getAllCookies { fetched = $0 }
        wait("verify existing account cookies", until: { fetched != nil })
        expect(fetched?.allSatisfy { $0.value == "synthetic-login" } == true, "session import cannot overwrite existing account tokens")
        try cookieAuthenticatedNavigation(dataStore)
        _ = dataStore // Retain the isolated store until every asynchronous check completes.
    }
}
