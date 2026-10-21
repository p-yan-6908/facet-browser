import AppKit
import SQLite3

extension PolishTests {
    /// Sign-ins from every browser Facet detects, from synthetic profiles only.
    static func otherBrowserSessions(_ root: URL) throws {
        // Each Chromium browser has its own Keychain item; a hand-picked folder is recognised by path.
        func chromium(_ name: String, _ path: String) -> BrowserImportSource {
            BrowserImportSource(id: name, browserName: name, profileName: "Default", profileURL: URL(fileURLWithPath: path),
                                format: .chromium, bookmarksURL: nil, historyURL: nil)
        }
        let keyrings = ["Google Chrome": "Chrome", "Brave": "Brave", "Microsoft Edge": "Microsoft Edge", "Arc": "Arc",
                        "Vivaldi": "Vivaldi", "Opera": "Opera", "Chromium": "Chromium"]
        expect(keyrings.allSatisfy { chromium($0.key, "/tmp/x").sessionKeyring == $0.value }, "each Chromium browser maps to its Keychain item")
        expect(chromium("Default", "/Users/a/Library/Application Support/BraveSoftware/Brave-Browser/Default").sessionKeyring == "Brave"
               && chromium("Profile 1", "/Users/a/Library/Application Support/Microsoft Edge/Profile 1").sessionKeyring == "Microsoft Edge"
               && chromium("Aside", "/tmp/Aside/Default").sessionKeyring == nil, "hand-picked profile folders are recognised by location")
        do {
            _ = try ChromeSessionImport.safeStoragePassword(keyring: "FacetFixtureMissing", browser: "Fixture")
            expect(false, "a missing Keychain item must fail")
        } catch {
            expect(error.localizedDescription.contains("FacetFixtureMissing Safe Storage") && error.localizedDescription.contains("Fixture sign-in"),
                   "Keychain errors name the browser's own Safe Storage item")
        }

        // A Brave profile decrypts with Brave's key through the same validated path as Chrome.
        let brave = root.appendingPathComponent("BraveSoftware/Brave-Browser/Default")
        try FileManager.default.createDirectory(at: brave.appendingPathComponent("Network"), withIntermediateDirectories: true)
        var bdb: OpaquePointer?; sqlite3_open(brave.appendingPathComponent("Network/Cookies").path, &bdb); defer { sqlite3_close(bdb) }
        try sql(bdb, "CREATE TABLE meta(key TEXT,value TEXT); INSERT INTO meta VALUES('version','24'); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,expires_utc INTEGER,is_secure INTEGER,is_httponly INTEGER,samesite INTEGER,is_persistent INTEGER,has_expires INTEGER,top_frame_site_key TEXT,source_scheme INTEGER,source_port INTEGER);")
        let encrypted = try encryptedFixture("brave-session")
        let expires = Int64((Date().addingTimeInterval(86_400).timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        try sql(bdb, "INSERT INTO cookies VALUES('.fixture.test','sid','',X'\(encrypted.map { String(format: "%02x", $0) }.joined())','/',\(expires),1,1,1,1,1,'',2,443);")
        let braveSource = BrowserImportService.shared.customChromiumSource(profileURL: brave)!
        var keyReads = 0
        let braveBatch = try ChromeSessionImport.read(from: braveSource, passwordProvider: { keyReads += 1; return Data("fixture-only".utf8) })
        expect(braveSource.sessionKeyring == "Brave" && braveSource.hasSessions && keyReads == 1 && braveBatch.cookies.first?.value == "brave-session",
               "Brave sign-ins import with Brave's key")

        // Firefox: plaintext rows, seconds or milliseconds, containers left behind.
        let firefox = root.appendingPathComponent("FirefoxProfile")
        try FileManager.default.createDirectory(at: firefox, withIntermediateDirectories: true)
        var fdb: OpaquePointer?; sqlite3_open(firefox.appendingPathComponent("cookies.sqlite").path, &fdb); defer { sqlite3_close(fdb) }
        let soon = Int(Date().addingTimeInterval(86_400).timeIntervalSince1970), past = Int(Date().addingTimeInterval(-86_400).timeIntervalSince1970)
        try sql(fdb, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE moz_cookies(id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT, value TEXT, host TEXT, path TEXT,
              expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER, isSecure INTEGER, isHttpOnly INTEGER, inBrowserElement INTEGER DEFAULT 0,
              sameSite INTEGER DEFAULT 0, rawSameSite INTEGER DEFAULT 0, schemeMap INTEGER DEFAULT 0);
            INSERT INTO moz_cookies(originAttributes,name,value,host,path,expiry,lastAccessed,isSecure,isHttpOnly,sameSite,rawSameSite) VALUES
              ('','sid','ff-session','.firefox.test','/',\(soon),5,1,1,2,2),
              ('','pref','dark','www.firefox.test','/',\(soon),4,0,0,0,0),
              ('','ms','new-format','ms.firefox.test','/',\(Int64(soon) * 1000),3,1,0,1,1),
              ('^userContextId=2','work','container','.firefox.test','/',\(soon),2,1,1,0,0),
              ('','old','gone','.firefox.test','/',\(past),1,1,1,0,0);
            """)
        let ff = BrowserImportSource(id: "ff-sessions", browserName: "Firefox", profileName: "Fixture", profileURL: firefox,
                                     format: .firefox, bookmarksURL: nil, historyURL: nil)
        expect(ff.hasSessions && ff.sessionKeyring == nil, "Firefox profiles with cookies offer sign-ins without Keychain")
        let ffBatch = try SessionImport.read(from: ff)
        let byName = Dictionary(uniqueKeysWithValues: ffBatch.cookies.map { ($0.name, $0) })
        expect(Set(byName.keys) == ["sid", "pref", "ms"] && ffBatch.skipped == 2, "Firefox cookies import; container and expired ones are skipped")
        expect(byName["sid"]?.isHTTPOnly == true && byName["sid"]?.isSecure == true && ChromeSessionImport.sameSite(byName["sid"]!) == "strict",
               "Firefox security flags and SameSite carry over")
        expect(ChromeSessionImport.sameSite(byName["pref"]!) == "lax", "an unset Firefox SameSite becomes Lax")
        expect(abs((byName["ms"]?.expiresDate?.timeIntervalSince1970 ?? 0) - Double(soon)) < 2, "millisecond expiries are understood")
        expect(ffBatch.warnings.contains { $0.contains("container") } && !ffBatch.warnings.joined().contains("ff-session"),
               "Firefox warnings explain skips without values")

        // Safari: Cookies.binarycookies, built byte by byte.
        func record(_ domain: String, _ name: String, _ value: String, flags: UInt32, expires: Date) -> [UInt8] {
            func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
            func dbl(_ d: Double) -> [UInt8] { (0..<8).map { UInt8((d.bitPattern >> (8 * UInt64($0))) & 0xff) } }
            let strings = [domain, name, "/", value].map { Array($0.utf8) + [0] }
            var offsets: [UInt32] = [], at: UInt32 = 56
            for s in strings { offsets.append(at); at += UInt32(s.count) }
            var r = le(at) + le(0) + le(flags) + le(0) + offsets.flatMap(le) + [UInt8](repeating: 0, count: 8)
            r += dbl(expires.timeIntervalSinceReferenceDate) + dbl(Date().timeIntervalSinceReferenceDate)
            return r + strings.flatMap { $0 }
        }
        let records = [record(".safari.test", "sid", "safari-session", flags: 5, expires: Date().addingTimeInterval(86_400)),
                       record("www.safari.test", "theme", "light", flags: 0, expires: Date().addingTimeInterval(86_400)),
                       record(".safari.test", "old", "gone", flags: 1, expires: Date().addingTimeInterval(-86_400)),
                       [10, 0, 0, 0] + [UInt8](repeating: 0, count: 6)]
        var page: [UInt8] = [0, 0, 1, 0] + [UInt8(records.count), 0, 0, 0]
        var offset = 8 + records.count * 4 + 4
        for r in records { page += (0..<4).map { UInt8((offset >> (8 * $0)) & 0xff) }; offset += r.count }
        page += [0, 0, 0, 0] + records.flatMap { $0 }
        let size = page.count
        var file = Array("cook".utf8) + [0, 0, 0, 1]
        file += [UInt8(size >> 24 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)]
        file += page + [UInt8](repeating: 0, count: 8)
        let cookieFile = root.appendingPathComponent("Cookies.binarycookies")
        try Data(file).write(to: cookieFile)
        let safari = BrowserImportSource(id: "safari-sessions", browserName: "Safari", profileName: "Default", profileURL: root,
                                         format: .safari, bookmarksURL: nil, historyURL: nil)
        expect(safari.hasSessions && safari.cookiesURL == nil, "Safari offers sign-ins without touching its container during detection")
        let sBatch = try SafariSessionImport.read(from: safari, files: [root.appendingPathComponent("missing"), cookieFile])
        let safariNames = Set(sBatch.cookies.map(\.name))
        expect(safariNames == ["sid", "theme"] && sBatch.cookies.first { $0.name == "sid" }.map { $0.isSecure && $0.isHTTPOnly } == true,
               "Safari cookies import with their flags")
        expect(sBatch.skipped == 2 && sBatch.warnings.contains("Skipped 1 unreadable cookie records."), "damaged and expired Safari records are skipped")
        do { _ = try SafariSessionImport.parse(Data("nope".utf8)); expect(false, "a non-cookie file is refused") }
        catch { expect(true, "a non-cookie file is refused") }
        do { _ = try SafariSessionImport.read(from: safari, files: [root.appendingPathComponent("missing")]); expect(false, "unreadable Safari cookies fail") }
        catch { expect(error.localizedDescription.contains("Full Disk Access"), "unreadable Safari cookies point to Full Disk Access") }

        // The first-launch offer: when to show it and which profile to suggest.
        expect(ImportOffer.shouldOffer(alreadyOffered: false, hasData: false, environment: [:]), "a fresh profile gets the offer")
        expect(!ImportOffer.shouldOffer(alreadyOffered: true, hasData: false, environment: [:])
               && !ImportOffer.shouldOffer(alreadyOffered: false, hasData: true, environment: [:])
               && !ImportOffer.shouldOffer(alreadyOffered: false, hasData: false, environment: ["FACET_PROFILE_DIR": "/tmp/p"]),
               "the offer is shown once, to empty profiles, and never to throwaway profiles")
        expect(ImportOffer.shouldOffer(alreadyOffered: true, hasData: true, environment: ["FACET_SHOW_IMPORT_OFFER": "1"]), "the offer can be shown on request")
        let chromeA = chromium("Google Chrome", "/tmp/a"), chromeB = chromium("Google Chrome", "/tmp/b")
        let used: [String: Date] = ["/tmp/a": Date(timeIntervalSince1970: 1), "/tmp/b": Date(timeIntervalSince1970: 2), firefox.path: Date(timeIntervalSince1970: 3)]
        let candidates = [chromeA, chromeB, ff]
        let lastUsed: (BrowserImportSource) -> Date? = { used[$0.profileURL.path] }
        expect(ImportOffer.suggested(candidates, defaultBrowser: "com.google.Chrome", lastUsed: lastUsed)?.profileURL.path == "/tmp/b",
               "the default browser's most recent profile is suggested")
        expect(ImportOffer.suggested(candidates, defaultBrowser: nil, lastUsed: lastUsed)?.browserName == "Firefox"
               && ImportOffer.suggested(candidates, defaultBrowser: "com.apple.Safari", lastUsed: lastUsed)?.browserName == "Firefox",
               "otherwise the most recently used profile is suggested")
        expect(ImportOffer.permissionNote(for: braveSource).contains("Brave Safe Storage") && ImportOffer.permissionNote(for: safari).contains("Full Disk Access"),
               "consent text names the permission macOS will ask for")
    }

    /// The first-launch sheet's choices.
    static func importOfferUI(_ root: URL) {
        _ = NSApplication.shared
        let profile = root.appendingPathComponent("BraveSoftware/Brave-Browser/Default")
        try? Data("{}".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        let brave = BrowserImportSource(id: "offer-brave", browserName: "Brave", profileName: "Default", profileURL: profile, format: .chromium,
                                        bookmarksURL: profile.appendingPathComponent("Bookmarks"), historyURL: nil)
        let firefox = BrowserImportSource(id: "offer-ff", browserName: "Firefox", profileName: "Fixture", profileURL: root.appendingPathComponent("FirefoxProfile"),
                                          format: .firefox, bookmarksURL: nil, historyURL: nil)
        let offer = ImportOfferController(sources: [brave, firefox], suggested: firefox)
        _ = offer.view
        expect(offer.selectedSource?.id == "offer-ff" && offer.bookmarks.state == .off && !offer.bookmarks.isEnabled && offer.signIns.state == .on,
               "the suggested browser is preselected with what it has")
        offer.sourcePopup.selectItem(at: 0)
        offer.sourceChanged()
        expect(offer.bookmarks.state == .on && offer.history.state == .off && !offer.history.isEnabled && offer.signIns.state == .on,
               "switching browsers updates what can be brought over")
        expect(offer.signInNote.stringValue.contains("Brave Safe Storage") && offer.signInNote.stringValue.contains("Passwords are not copied"),
               "the sign-in option explains what is copied and what macOS will ask")
        var chosen: ImportChoice?, finished = false
        offer.onImport = { chosen = $0 }
        offer.onFinish = { finished = true }
        offer.signIns.state = .off
        offer.importPressed()
        expect(finished && chosen?.source.id == "offer-brave" && chosen?.bookmarks == true && chosen?.signIns == false,
               "Import passes exactly what was ticked")
    }
}
