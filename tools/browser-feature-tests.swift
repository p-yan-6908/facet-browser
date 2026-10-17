import AppKit
import Network
import WebKit

/// Loopback-only HTTP fixture. Each route returns a full response, or nil to drop the
/// connection without answering (a network failure, from the browser's point of view).
final class LoopbackServer {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private(set) var port: UInt16?
    private(set) var requests: [String] = []
    var route: (String) -> Data?

    init(route: @escaping (String) -> Data?) throws {
        self.route = route
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = self?.listener.port?.rawValue }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: .main)
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        var received = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data { received.append(data) }
                guard error == nil, received.count < 65_536 else { connection.cancel(); return }
                let text = String(decoding: received, as: UTF8.self)
                guard text.contains("\r\n\r\n") else { if !complete { receive() }; return }
                self.requests.append(text)
                guard let response = self.route(text) else { connection.cancel(); return }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        receive()
    }

    static func response(_ status: String, _ headers: [String: String], _ body: Data) -> Data {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    static func html(_ body: String, status: String = "200 OK", headers: [String: String] = [:]) -> Data {
        response(status, headers.merging(["Content-Type": "text/html; charset=utf-8"]) { a, _ in a }, Data(body.utf8))
    }

    func stop() { connections.forEach { $0.cancel() }; listener.cancel() }
}

extension PolishTests {
    /// Pure logic behind the Chrome-parity features. No WebKit, no network.
    static func browserFeatures(_ root: URL) throws {
        // Downloads policy and filename safety.
        expect(!Tab.shouldDownload(canShowMIMEType: true, contentDisposition: nil), "renderable responses display")
        expect(Tab.shouldDownload(canShowMIMEType: false, contentDisposition: nil), "unrenderable responses download")
        expect(Tab.shouldDownload(canShowMIMEType: true, contentDisposition: " Attachment; filename=x.txt"), "attachment disposition downloads")
        expect(!Tab.shouldDownload(canShowMIMEType: true, contentDisposition: "inline"), "inline disposition displays")
        for (raw, check) in [("../../etc/passwd", "traversal"), (".hidden", "dotfile"), ("a:b", "colon"), ("", "empty")] {
            let s = Downloads.sanitizedFilename(raw)
            expect(!s.contains("/") && !s.contains(":") && !s.hasPrefix(".") && !s.isEmpty, "download filename sanitized: \(check)")
        }
        expect(Downloads.sanitizedFilename(String(repeating: "x", count: 400) + ".zip").hasSuffix(".zip"), "long filenames keep their extension")

        // Error pages.
        expect(Tab.isBenignNavigationError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)), "cancelled loads are not errors")
        expect(Tab.isBenignNavigationError(NSError(domain: "WebKitErrorDomain", code: 102)), "download interruptions are not errors")
        expect(!Tab.isBenignNavigationError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)), "DNS failures are errors")
        let html = Tab.errorPageHTML(heading: "<script>alert(1)</script>", message: "<img src=x onerror=alert(2)>",
                                     detail: "d", retryURL: "https://x.test/</script><script>alert(3)</script>")
        expect(html.components(separatedBy: "<script>").count == 2 && !html.contains("<img"), "error page escapes site-controlled text")

        // Per-site settings.
        let settingsURL = root.appendingPathComponent("site-settings-test.json")
        let site = SiteSettings(fileURL: settingsURL)
        site.setZoom(1.5, for: URL(string: "https://www.Example.com/a"))
        expect(site.zoom(for: URL(string: "https://example.com/b")) == 1.5, "zoom is shared by www and bare host")
        site.setPermission("camera", for: "Meet.Test", allowed: true)
        site.setBlockingDisabled(true, for: URL(string: "https://www.News.test/story"))
        site.flush()
        let reloaded = SiteSettings(fileURL: settingsURL)
        expect(reloaded.zoom(for: URL(string: "https://example.com/")) == 1.5 && reloaded.permission("camera", for: "meet.test") == true,
               "site settings persist")
        expect(reloaded.isBlockingDisabled(for: URL(string: "https://m.news.test/")) && reloaded.sitesWithoutBlocking == ["news.test"],
               "blocking exceptions persist and cover subdomains")
        expect(!reloaded.isBlockingDisabled(for: URL(string: "https://othernews.test/")), "blocking exceptions match whole domains only")
        reloaded.setBlockingDisabled(false, for: URL(string: "https://news.test/"))
        expect(reloaded.sitesWithoutBlocking.isEmpty, "blocking exceptions can be removed")

        // Blocklists accept plain domains, paths, and hosts-file lines.
        let parsed = ContentBlocker.parseDomains("""
        # comment
        ads.example
        0.0.0.0 tracker.example  # trailing comment
        127.0.0.1 localhost
        0.0.0.0 one.example\ttwo.example
        ADS.example
        cdn.example/path.js
        192.168.1.1 router.lan
        """)
        expect(parsed == ["ads.example", "tracker.example", "one.example", "two.example", "cdn.example/path.js"],
               "blocklist parses plain and hosts-file lines")
        reloaded.setZoom(1.0, for: URL(string: "https://example.com/"))
        expect(reloaded.zoom(for: URL(string: "https://example.com/")) == nil, "100% zoom is not stored")

        // Favicons are bounded to one 32px bitmap whatever the site serves.
        let big = NSImage(size: NSSize(width: 512, height: 512))
        big.lockFocus(); NSColor.systemRed.setFill(); NSRect(x: 0, y: 0, width: 512, height: 512).fill(); big.unlockFocus()
        let rep = FaviconStore.downsample(big)
        expect(rep?.pixelsWide == 32 && rep?.pixelsHigh == 32 && rep?.size == NSSize(width: 16, height: 16), "favicons are downsampled to 32px")
        if let tiff = big.tiffRepresentation {
            let stored = FaviconStore.shared.store(tiff, forHost: "icon.test", persist: true)
            expect(stored?.representations.first?.pixelsWide == 32, "stored favicon keeps only the small bitmap")
            expect(FaviconStore.shared.icon(forHost: "ICON.test") != nil, "favicon lookup is case-insensitive")
        }

        // Omnibox ranking and inline completion.
        let now = Date()
        Store.shared.importHistory([
            HistoryEntry(url: "https://github.com/", title: "GitHub", visits: 6, lastVisit: now),
            HistoryEntry(url: "https://github.com/trending", title: "Trending repositories", visits: 3, lastVisit: now),
            HistoryEntry(url: "https://gist.github.com/", title: "Gist", visits: 1, lastVisit: now),
            HistoryEntry(url: "https://www.wikipedia.org/", title: "Wikipedia", visits: 4, lastVisit: now),
        ])
        expect(Omnibox.inlineCompletion(for: "gi") == "github.com", "inline completion picks the frequent host")
        expect(Omnibox.inlineCompletion(for: "GI") == "GIthub.com", "inline completion keeps typed characters")
        expect(Omnibox.inlineCompletion(for: "github.com/t") == "github.com/trending", "inline completion extends into paths")
        expect(Omnibox.inlineCompletion(for: "wiki") == "wikipedia.org", "inline completion ignores www.")
        expect(Omnibox.inlineCompletion(for: "g") == nil && Omnibox.inlineCompletion(for: "gi hub") == nil, "no completion for one letter or phrases")
        expect(Omnibox.inlineCompletion(for: "gis") == nil, "single visits never autocomplete")

        let completed = Omnibox.suggestions(for: "gi", completion: "github.com", openTabs: [])
        expect(completed.first?.fillText == "github.com" && completed.first?.title == "GitHub", "completed address is the default row")
        expect(completed.dropFirst().first?.kind == .search, "search stays one arrow away")
        let search = Omnibox.suggestions(for: "weather today", completion: nil, openTabs: [])
        expect(search.first?.kind == .search && search.first?.url?.host == "www.google.com", "phrases default to search")
        expect(Omnibox.suggestions(for: "example.org", completion: nil, openTabs: []).first?.kind == .url, "addresses default to navigation")
        let tabRows = Omnibox.suggestions(for: "trend", completion: nil,
                                          openTabs: [(id: UUID(), title: "Trending repositories", url: URL(string: "https://github.com/trending")!)])
        expect(tabRows.contains { $0.kind == .openTab }, "open tabs are offered as Switch to Tab")
        expect(tabRows.filter { $0.detail == "github.com/trending" }.count == 1, "an open tab is not repeated as history")
        expect(Config.shared.searchEngineName == "Google" && Config.shared.isSearchQuery("two words") && !Config.shared.isSearchQuery("example.com"),
               "search engine name and query detection")

        // History and bookmark editing.
        Store.shared.removeHistory(urls: ["https://gist.github.com/"])
        expect(!Store.shared.history.contains { $0.url == "https://gist.github.com/" }, "single history entries can be deleted")
        Store.shared.importHistory([HistoryEntry(url: "https://old.test/", title: "Old", visits: 1, lastVisit: now.addingTimeInterval(-90 * 86_400))])
        Store.shared.clearHistory(since: now.addingTimeInterval(-3_600))
        expect(Store.shared.history.contains { $0.url == "https://old.test/" } && !Store.shared.history.contains { $0.url == "https://github.com/" },
               "clear history honours the time range")
        var bookmarkNotes = 0
        let token = NotificationCenter.default.addObserver(forName: .facetBookmarksChanged, object: nil, queue: nil) { _ in bookmarkNotes += 1 }
        let mark = URL(string: "https://bookmark.test/")!
        _ = Store.shared.toggleBookmark(url: mark, title: "Before")
        Store.shared.renameBookmark(url: mark.absoluteString, title: "After")
        expect(Store.shared.bookmarks.first { $0.url == mark.absoluteString }?.title == "After", "bookmarks can be renamed")
        Store.shared.removeBookmarks(urls: [mark.absoluteString])
        expect(!Store.shared.isBookmarked(mark) && bookmarkNotes == 3, "bookmark changes notify the bookmarks bar")
        NotificationCenter.default.removeObserver(token)

        // Pinned tabs survive a restart.
        Store.shared.saveSession(windows: [SavedWindow(tabs: [SavedTab(url: "https://pin.test/", title: "Pin", interactionState: nil, pinned: true),
                                                             SavedTab(url: "https://plain.test/", title: "Plain", interactionState: nil)],
                                                       activeIndex: 0, frame: nil)], selectedWindow: 0)
        let session = Store.shared.loadSessionWindows()
        expect(session.windows.first?.tabs.map(\.pinned) == [true, false], "pinned state round-trips through the session file")

        // Assistant plumbing.
        expect(BrowserAgentService.tools.contains { ($0["name"] as? String) == "go_back" } && BrowserAgentService.requiresApproval("go_back"),
               "go_back is registered and needs approval")
        let original: [[String: Any]] = [["role": "user", "content": "hi"],
                                         ["role": "user", "content": [["type": "tool_result", "tool_use_id": "1", "content": "x"]]]]
        let marked = BrowserAgentService.withCacheBreakpoint(original)
        let lastBlock = (marked.last?["content"] as? [[String: Any]])?.last
        expect(lastBlock?["cache_control"] != nil && (original.last?["content"] as? [[String: Any]])?.last?["cache_control"] == nil,
               "prompt-cache breakpoint marks only the outgoing copy")
        let textMarked = BrowserAgentService.withCacheBreakpoint([["role": "user", "content": "plain"]])
        expect(((textMarked.first?["content"] as? [[String: Any]])?.first?["text"] as? String) == "plain", "string content becomes a cacheable text block")
        let md = AgentSidebarView.renderMarkdown("**bold** and [docs](https://example.com) and `code`", font: .systemFont(ofSize: 12))
        let boldFont = md.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        expect(boldFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "assistant replies render bold")
        expect(md.string == "bold and docs and code" && md.attribute(.link, at: md.string.distance(of: "docs"), effectiveRange: nil) != nil,
               "assistant replies render links")
        let decoded = try JSONDecoder().decode(AgentElement.self, from: Data(#"{"ref":"e1","role":"combobox","name":"Fruit","value":"a","href":null,"disabled":false,"options":["Apple","Banana"]}"#.utf8))
        expect(decoded.options == ["Apple", "Banana"], "select options reach the model")
    }

    /// Real WebKit against a loopback server: downloads, sign-in prompts, error recovery,
    /// the isolated page bridge, per-site zoom, select filling, and crash handling.
    /// Real WebKit: a site exception and the global switch both stop blocking on the next load.
    static func blockingWebKit(_ root: URL) throws {
        _ = NSApplication.shared
        let server = try LoopbackServer { request in
            let line = request.components(separatedBy: "\r\n").first ?? ""
            if line.contains(" /probe.js ") {
                return LoopbackServer.response("200 OK", ["Content-Type": "text/javascript"], Data("document.title = 'probe ran'".utf8))
            }
            return LoopbackServer.html("<title>waiting</title><script src=\"/probe.js\"></script>")
        }
        defer { server.stop() }
        guard wait("blocking fixture server ready", until: { server.port != nil }), let port = server.port else { return }
        let page = URL(string: "http://127.0.0.1:\(port)/")!
        try "# fixture\n127.0.0.1/probe.js\n".write(to: root.appendingPathComponent("blocked-domains.txt"), atomically: true, encoding: .utf8)
        Config.shared.blockAdsAndTrackers = true
        defer { Config.shared.blockAdsAndTrackers = false; SiteSettings.shared.setBlockingDisabled(false, for: page) }
        func compile(_ message: String) -> Bool {
            var done = false
            ContentBlocker.load { _ in done = true }
            return wait(message, seconds: 20, until: { done }) && ContentBlocker.ruleList != nil
        }
        guard compile("fixture blocklist compiles") else { return }
        let tab = Tab(url: nil, isPrivate: true, delegate: nil)
        let wv = tab.ensureLoaded()
        wv.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        defer { tab.hibernate() }
        var loads = 0
        func titleAfterLoad() -> String? {
            loads += 1
            let url = URL(string: "http://127.0.0.1:\(port)/?n=\(loads)")!
            ContentBlocker.install(in: wv.configuration.userContentController)
            wv.load(URLRequest(url: url))
            wait("fixture page \(loads) loads", seconds: 10, until: { wv.url == url && !wv.isLoading && wv.title?.isEmpty == false })
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            return wv.title
        }
        expect(titleAfterLoad() == "waiting", "blocklist path rule blocks the probe script")

        SiteSettings.shared.setBlockingDisabled(true, for: page)
        guard compile("blocklist recompiles with a site exception") else { return }
        expect(titleAfterLoad() == "probe ran", "a site exception lets that site's requests through")

        SiteSettings.shared.setBlockingDisabled(false, for: page)
        guard compile("blocklist recompiles without the exception") else { return }
        expect(titleAfterLoad() == "waiting", "removing the exception blocks again")

        Config.shared.blockAdsAndTrackers = false
        expect(titleAfterLoad() == "probe ran", "switching blocking off really stops blocking")

        var remaining = -1
        wait("earlier blocklist compilations are removed", until: {
            WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { ids in
                remaining = (ids ?? []).filter { $0.hasPrefix("facet-block-") }.count
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            return remaining == 1
        })
    }

    static func browserFeaturesWebKit(_ root: URL) throws {
        _ = NSApplication.shared
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        Downloads.shared.folderOverride = downloads
        var flakyFails = true
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let server = try LoopbackServer { request in
            let line = request.components(separatedBy: "\r\n").first ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            switch path {
            case "/file.bin":
                return LoopbackServer.response("200 OK", ["Content-Type": "application/octet-stream"], payload)
            case "/attach":
                return LoopbackServer.response("200 OK", ["Content-Type": "text/plain", "Content-Disposition": "attachment; filename=\"report.txt\""], Data("report".utf8))
            case "/secret":
                let good = "Authorization: Basic " + Data("user:pass".utf8).base64EncodedString()
                if request.components(separatedBy: "\r\n").contains(where: { $0.caseInsensitiveCompare(good) == .orderedSame }) {
                    return LoopbackServer.html("<title>Authorized</title>ok")
                }
                return LoopbackServer.html("<title>Denied</title>no", status: "401 Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"Fixture\""])
            case "/flaky":
                return flakyFails ? nil : LoopbackServer.html("<title>Recovered</title>back")
            default:
                return LoopbackServer.html("""
                <title>Feature page</title><a id=l href="/target">link</a>
                <select id=s><option value=a>Apple</option><option value=b>Banana</option></select><p>needle</p>
                """)
            }
        }
        defer { server.stop(); Downloads.shared.folderOverride = nil }
        guard wait("feature fixture server ready", until: { server.port != nil }), let port = server.port else { return }
        let base = "http://127.0.0.1:\(port)"
        func makeTab(_ path: String) -> Tab {
            let tab = Tab(url: URL(string: base + path), isPrivate: true, delegate: nil)
            tab.ensureLoaded().frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            return tab
        }

        // A file response becomes a download instead of an error page.
        let fileTab = makeTab("/file.bin")
        let fileURL = downloads.appendingPathComponent("file.bin")
        wait("binary response downloads to disk", seconds: 15, until: {
            Downloads.shared.items.contains { $0.filename == "file.bin" && $0.state == .finished }
        })
        expect((try? Data(contentsOf: fileURL)) == payload, "downloaded bytes are intact")
        expect(fileTab.errorURL == nil && !(fileTab.title.contains("open")), "downloads never show an error page")
        let quarantine = (try? fileURL.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
        expect(quarantine?.isEmpty == false, "downloads are quarantined for Gatekeeper")
        fileTab.hibernate()

        let attachTab = makeTab("/attach")
        wait("attachment disposition downloads", seconds: 15, until: {
            Downloads.shared.items.contains { $0.filename == "report.txt" && $0.state == .finished }
        })
        expect(Downloads.shared.recent.contains { $0.lastPathComponent == "report.txt" }, "finished downloads are listed")
        attachTab.hibernate()

        // HTTP authentication: cancelling shows the site's 401 page; signing in works.
        var prompts = 0
        Tab.credentialPrompt = { space, _, _, completion in
            prompts += 1
            expect(space.host == "127.0.0.1" && space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic, "auth prompt names the protection space")
            completion(nil)
        }
        let denied = makeTab("/secret")
        wait("cancelled sign-in shows the 401 page", seconds: 15, until: { denied.title == "Denied" })
        denied.hibernate()
        WebKitEnv.discardPrivateStore()
        Tab.credentialPrompt = { _, _, _, completion in
            prompts += 1
            completion(URLCredential(user: "user", password: "pass", persistence: .none))
        }
        let authorized = makeTab("/secret")
        wait("basic auth sign-in loads the page", seconds: 15, until: { authorized.title == "Authorized" })
        expect(prompts >= 2, "each challenge asks the user")
        authorized.hibernate()
        WebKitEnv.discardPrivateStore()

        // A failed load shows Facet's error page, and Reload retries the real address.
        let flaky = makeTab("/flaky")
        wait("network failure shows an error page", seconds: 20, until: { flaky.errorURL != nil && !flaky.isLoading })
        expect(flaky.title.contains("127.0.0.1"), "error page names the host that failed")
        expect(flaky.errorURL?.path == "/flaky" && flaky.url?.path == "/flaky", "error page keeps the failed address")
        flakyFails = false
        flaky.reload()
        wait("reload from the error page retries the site", seconds: 15, until: { flaky.title == "Recovered" })
        expect(flaky.errorURL == nil, "recovering clears the error state")
        flaky.hibernate()

        // Page bridge: hover and right-click details arrive from the isolated world only.
        SiteSettings.shared.setZoom(1.25, for: URL(string: base + "/"))
        let page = makeTab("/page")
        guard let view = page.webView,
              wait("feature page loaded", seconds: 15, until: { page.title == "Feature page" && !page.isLoading }) else { return }
        expect(abs(page.pageZoom - 1.25) < 0.001, "per-site zoom is applied when the page commits")
        SiteSettings.shared.setZoom(1, for: URL(string: base + "/"))
        var pageWorld: Any?
        view.evaluateJavaScript("typeof (window.webkit && webkit.messageHandlers && webkit.messageHandlers.facetPage)") { r, _ in pageWorld = r }
        wait("page world probed", until: { pageWorld != nil })
        expect(pageWorld as? String == "undefined", "page scripts cannot reach the bridge handler")
        view.evaluateJavaScript("document.getElementById('l').dispatchEvent(new MouseEvent('mouseover', {bubbles: true}))") { _, _ in }
        wait("hovered link reported", until: { page.hoveredLink?.path == "/target" })
        view.evaluateJavaScript("document.getElementById('l').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, cancelable: true}))") { _, _ in }
        wait("context-menu target reported", until: { page.pageContext?.link?.path == "/target" })
        let menu = NSMenu()
        for (title, id) in [("Open Link in New Window", "WKMenuItemIdentifierOpenLinkInNewWindow"),
                            ("Download Linked File", "WKMenuItemIdentifierDownloadLinkedFile"), ("Copy Link", "WKMenuItemIdentifierCopyLink")] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
        }
        page.customizeContextMenu(menu)
        let titles = menu.items.map(\.title)
        expect(titles.prefix(2) == ["Open Link in New Tab", "Open Link in New Window"], "links open in new tabs from the context menu")
        expect(!titles.contains("Open Link in Private Window") && !titles.contains { $0.contains("Assistant") },
               "private tabs offer no private-window or assistant items")
        expect(menu.items.first { $0.title == "Download Linked File" } is ClosureMenuItem && titles.contains("Copy Link"),
               "downloads go through Facet; other WebKit items are kept")

        // The assistant can choose a <select> option by its visible text.
        var snapshot: AgentPageSnapshot?
        page.captureAgentSnapshot { if case .success(let s) = $0 { snapshot = s } }
        wait("snapshot with select captured", seconds: 15, until: { snapshot != nil })
        if let select = snapshot?.elements.first(where: { $0.options?.contains("Banana") == true }) {
            var filled: Result<String, Error>?
            page.agentFill(ref: select.ref, text: "banana") { filled = $0 }
            wait("select filled", until: { filled != nil })
            var value: Any?
            view.evaluateJavaScript("document.getElementById('s').value") { r, _ in value = r }
            wait("select value read", until: { value != nil })
            expect(value as? String == "b", "agent fill picks a select option by text")
        } else {
            expect(false, "snapshot lists select options")
        }

        // A background renderer killed by the system stays asleep instead of reloading.
        // SIGKILL is what jetsam does; WebKit's own kill SPI deliberately skips the delegate.
        if let pid = view.value(forKey: "_webProcessIdentifier") as? Int32, pid > 0 {
            kill(pid, SIGKILL)
            wait("crashed background tab goes to sleep", seconds: 10, until: { page.isHibernated })
            expect(page.url?.path == "/page", "crashed tab keeps its address for later")
        } else {
            print("SKIP: web content process id unavailable")
        }
        page.hibernate()
        Tab.credentialPrompt = { _, _, _, completion in completion(nil) }

        // Tab ordering in a real window controller.
        let c = BrowserWindowController(isPrivate: true)
        let a = c.newTab()
        let b = c.newTab(url: nil, activate: false, opener: a)
        let d = c.newTab(url: nil, activate: false, opener: a)
        let e = c.newTab()
        expect(c.tabs.map(\.id) == [a, b, d, e].map(\.id), "link-opened tabs land after their opener, in order")
        c.selectTab(index: 0)
        c.setPinned(true, for: e)
        expect(c.tabs.first === e && c.activeTab === a, "pinning moves a tab to the front and keeps the selection")
        c.tabStripDidRequestMove(from: 0, to: 2)
        c.tabStripDidRequestMove(from: 3, to: 0)
        expect(c.tabs.map(\.id) == [e, a, b, d].map(\.id), "pinned and unpinned tabs cannot swap sections")
        c.selectTab(index: 3)
        c.closeActiveTab()
        expect(c.activeTab === a, "closing a page's last child returns to its opener")
        c.window?.close()
    }
}

private extension String {
    func distance(of needle: String) -> Int {
        guard let r = range(of: needle) else { return 0 }
        return utf16.distance(from: startIndex, to: r.lowerBound)
    }
}
