import AppKit
import WebKit
import SQLite3

/// A TabDelegate that records the login a page submitted.
private final class LoginCatcher: TabDelegate {
    var captured: (username: String, password: String, url: URL)?
    func tab(_ tab: Tab, didSubmitLogin username: String, password: String, on url: URL) {
        captured = (username, password, url)
    }
    func tabDidChangeState(_ tab: Tab) {}
    func tab(_ tab: Tab, openNewTabWith url: URL?, configuration: WKWebViewConfiguration?, activate: Bool) -> Tab? { nil }
    func tabRequestsClose(_ tab: Tab) {}
    func tabStatus(_ tab: Tab, message: String?) {}
}

extension PolishTests {
    /// The password store, its save/update decisions, and the Chromium password importer.
    static func passwords(_ root: URL) throws {
        let store = PasswordStore.shared
        store.installTestBackend()

        // Host keying mirrors site settings: www is shared, other subdomains are their own site.
        expect(PasswordStore.key(for: URL(string: "https://www.Example.com/login")) == "example.com", "www is stripped and lowercased")
        expect(PasswordStore.key(for: URL(string: "https://m.example.com/")) == "m.example.com", "other subdomains are their own site")

        let site = URL(string: "https://www.example.com/login")!
        expect(store.save(url: site, username: "ada", password: "hunter2"), "a login saves")
        expect(store.isSaved(url: URL(string: "https://example.com/account"), username: "ada"), "a saved login matches across www")
        expect(store.password(for: URL(string: "https://example.com/"), username: "ada") == "hunter2", "the password reads back")
        expect(!store.save(url: URL(string: "https://example.com/"), username: "x", password: ""), "an empty password is not saved")

        expect(store.decision(url: site, username: "ada", password: "hunter2") == .ignore, "an unchanged login is ignored")
        expect(store.decision(url: site, username: "ada", password: "newpass") == .update, "a changed password offers update")
        expect(store.decision(url: site, username: "grace", password: "p") == .save, "a new username offers save")
        expect(store.decision(url: site, username: "", password: "p") == .ignore, "a blank username is ignored")
        expect(store.decision(url: URL(string: "about:blank"), username: "a", password: "p") == .ignore, "a non-web page is ignored")

        store.save(url: site, username: "grace", password: "second")
        let logins = store.logins(for: URL(string: "https://example.com/"))
        expect(logins.count == 2 && logins.first?.username == "grace", "logins list newest first")
        expect(store.allLogins().allSatisfy { $0.password.isEmpty }, "the manager list carries no passwords")

        // Importing is idempotent and keeps the newer copy.
        let old = Date(timeIntervalSince1970: 1_000), recent = Date(timeIntervalSince1970: 2_000)
        expect(store.saveImported(host: "imported.test", username: "u", password: "a", updated: old), "a new imported login saves")
        expect(!store.saveImported(host: "imported.test", username: "u", password: "a", updated: old), "the same imported login again is a no-op")
        expect(store.saveImported(host: "imported.test", username: "u", password: "b", updated: recent)
               && store.password(for: URL(string: "https://imported.test"), username: "u") == "b", "a newer imported password wins")
        store.remove(host: "imported.test", username: "u")
        expect(!store.isSaved(url: URL(string: "https://imported.test"), username: "u"), "a login can be removed")

        // "Never for this site" is remembered.
        SiteSettings.shared.setSavePasswordSuppressed(true, for: site)
        expect(SiteSettings.shared.isSavePasswordSuppressed(for: URL(string: "https://example.com/x")), "never-save is remembered across www")
        SiteSettings.shared.setSavePasswordSuppressed(false, for: site)
        expect(!SiteSettings.shared.isSavePasswordSuppressed(for: site), "never-save can be cleared")

        try chromiumPasswordImport(root)
    }

    static func chromiumPasswordImport(_ root: URL) throws {
        let profile = root.appendingPathComponent("Google/Chrome/Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(profile.appendingPathComponent("Login Data").path, &db) == SQLITE_OK else { fatalError("login db") }
        defer { sqlite3_close(db) }
        try sql(db, "CREATE TABLE logins(origin_url TEXT, username_value TEXT, password_value BLOB, date_last_used INTEGER, blacklisted_by_user INTEGER);")
        func insert(_ origin: String, _ user: String, _ blob: Data, blacklisted: Int = 0, used: Int64 = 13_344_473_600_000_000) throws {
            let hex = blob.map { String(format: "%02x", $0) }.joined()
            try sql(db, "INSERT INTO logins VALUES('\(origin)','\(user)',X'\(hex)',\(used),\(blacklisted));")
        }
        // Passwords carry no host-hash prefix, so encrypt with version 0.
        try insert("https://site.test/login", "ada", try encryptedFixture("s3cret", version: 0))
        try insert("https://blocked.test/", "", Data(), blacklisted: 1)                       // blacklisted + empty
        try insert("https://empty.test/", "bob", Data())                                       // never saved
        try insert("https://app.test/", "carol", Data("v20".utf8) + Data(repeating: 9, count: 16))  // app-bound, unsupported
        try insert("ftp://ignore.test/", "dave", try encryptedFixture("x", version: 0))         // non-web origin

        let source = BrowserImportService.shared.customChromiumSource(profileURL: profile)!
        expect(source.hasPasswords && source.loginDataURL != nil, "a Chromium profile with a Login Data file offers passwords")
        var keyReads = 0
        let batch = try ChromePasswordImport.read(from: source, passwordProvider: { keyReads += 1; return Data("fixture-only".utf8) })
        expect(keyReads == 1 && batch.logins.count == 1, "one key read; only the valid login is returned")
        expect(batch.logins.first?.host == "site.test" && batch.logins.first?.username == "ada" && batch.logins.first?.password == "s3cret",
               "the saved password decrypts")
        expect(batch.skipped == 3 && !batch.warnings.joined().contains("s3cret"), "unsupported, empty and non-web entries are skipped without leaking values")

        let brave = BrowserImportSource(id: "b", browserName: "Brave", profileName: "Default",
                                        profileURL: profile, format: .chromium, bookmarksURL: nil, historyURL: nil)
        expect(brave.hasPasswords, "Brave offers password import too")
        let unknown = BrowserImportSource(id: "u", browserName: "Mystery", profileName: "Default",
                                          profileURL: root.appendingPathComponent("Mystery"), format: .chromium, bookmarksURL: nil, historyURL: nil)
        expect(!unknown.hasPasswords, "a browser with an unknown key cannot import passwords")
    }

    /// Real WebKit: a login page is autofilled from the store, and a submit is captured.
    static func passwordAutofillWebKit() throws {
        _ = NSApplication.shared
        PasswordStore.shared.installTestBackend()
        let server = try LoopbackServer { _ in
            LoopbackServer.html("""
            <title>Login</title>
            <form id=f onsubmit="return false">
              <input id=u type=text autocomplete=username>
              <input id=p type=password>
              <button id=go type=submit>Sign in</button>
            </form>
            """)
        }
        defer { server.stop() }
        guard wait("login fixture server ready", until: { server.port != nil }), let port = server.port else { return }
        let url = URL(string: "http://127.0.0.1:\(port)/login")!
        PasswordStore.shared.save(url: url, username: "ada", password: "hunter2")

        let catcher = LoginCatcher()
        let tab = Tab(url: url, isPrivate: false, delegate: catcher)
        let wv = tab.ensureLoaded()
        wv.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        defer { tab.hibernate() }
        wait("login page loads", seconds: 15, until: { wv.url?.path == "/login" && wv.isLoading == false && wv.title == "Login" })
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        func fieldValues(_ then: @escaping (String, String) -> Void) {
            wv.evaluateJavaScript("document.getElementById('u').value + '\\n' + document.getElementById('p').value") { result, _ in
                let parts = (result as? String ?? "").split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                then(String(parts.first ?? ""), parts.count > 1 ? String(parts[1]) : "")
            }
        }
        var filledUser = "", filledPass = "", done = false
        fieldValues { u, p in filledUser = u; filledPass = p; done = true }
        wait("autofill read back", until: { done })
        expect(filledUser == "ada" && filledPass == "hunter2", "a saved login is autofilled into the page's form")

        // A submit with changed values is captured by the isolated bridge.
        var submitted = false
        wv.evaluateJavaScript("""
        document.getElementById('u').value='grace';
        document.getElementById('p').value='newpass';
        document.getElementById('f').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));
        true
        """) { _, _ in submitted = true }
        wait("submit dispatched", until: { submitted })
        wait("login captured", seconds: 5, until: { catcher.captured != nil })
        expect(catcher.captured?.username == "grace" && catcher.captured?.password == "newpass", "a submitted login is captured from the isolated world")
        expect(PasswordStore.shared.decision(url: url, username: "grace", password: "newpass") == .save, "the captured login would be offered for saving")
    }
}
