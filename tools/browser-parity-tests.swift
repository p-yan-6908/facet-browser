import AppKit
import WebKit

extension PolishTests {
    /// Chrome-parity logic that needs no live page.
    static func browserParity() {
        // Recently closed: newest last, capped, removable by id.
        let closed = RecentlyClosed()
        for n in 0..<30 { closed.add(tab: SavedTab(url: "https://t\(n).test/", title: "T\(n)", interactionState: nil), from: nil) }
        expect(closed.items.count == closed.limit && closed.items.first?.title == "T5", "recently closed keeps the newest 25")
        closed.add(window: SavedWindow(tabs: [SavedTab(url: "https://a.test/", title: "A", interactionState: nil),
                                             SavedTab(url: "https://b.test/", title: "", interactionState: nil)],
                                       activeIndex: 1, frame: nil))
        expect(closed.items.last?.title == "Window: A and 1 more", "closed windows are titled by their first tab")
        if case .window(let w)? = closed.popLast()?.entry { expect(w.activeIndex == 1, "closed windows keep their selected tab") }
        else { expect(false, "\u{2318}\u{21E7}T pops the most recent entry first") }
        let middle = closed.items[3]
        expect(closed.remove(id: middle.id)?.title == "T9" && !closed.items.contains { $0.id == middle.id },
               "History \u{2192} Recently Closed reopens a chosen entry")

        // Tearing a tab off the strip.
        expect(!TabStripView.isDetached(NSPoint(x: 10, y: 20), stripHeight: 36), "a drag along the strip reorders")
        expect(TabStripView.isDetached(NSPoint(x: 10, y: 36 + 40), stripHeight: 36)
               && TabStripView.isDetached(NSPoint(x: 10, y: -40), stripHeight: 36), "a drag well off the strip tears the tab off")

        // Paste and Go, on a private pasteboard so the real clipboard is untouched.
        expect(URLField.pasteAndGoTitle(for: "example.com/path") == "Paste and Go", "addresses paste and go")
        expect(URLField.pasteAndGoTitle(for: "best pizza near me") == "Paste and Search", "other text pastes and searches")
        let field = URLField()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("https://exam\nple.com/a", forType: .string)
        field.pasteboard = board
        var went: String?
        field.onPasteAndGo = { went = $0 }
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let built = field.textView(NSTextView(), menu: menu, for: click, at: 0)
        let item = built?.items[2] as? ClosureMenuItem
        expect(item?.title == "Paste and Go", "Paste and Go sits right after Paste")
        if let item { _ = item.target?.perform(item.action, with: item) }
        expect(went == "https://example.com/a", "Paste and Go joins an address split across lines")

        // Site information.
        let site = SiteSettings(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("facet-pageinfo-\(UUID()).json"))
        site.setPermission("camera", for: "Meet.test", allowed: true)
        site.setPermission("open:zoommtg", for: "meet.test", allowed: false)
        site.setPermission("camera", for: "other.test", allowed: false)
        let remembered = site.rememberedPermissions(for: "meet.test")
        expect(remembered.map(\.kind) == ["camera", "open:zoommtg"] && remembered.first?.allowed == true, "page info lists one site's permissions")
        site.clearPermission("camera", for: "meet.test")
        expect(site.permission("camera", for: "meet.test") == nil && site.permission("camera", for: "other.test") == false,
               "a permission can be reset to Ask for one site")
        expect(PageInfoController.permissionName("open:zoommtg") == "Open zoommtg: links", "permission kinds read naturally")
        expect(PageInfoController.security(for: URL(string: "https://a.test/"), onlySecureContent: true).title == "Connection is secure"
               && PageInfoController.security(for: URL(string: "https://a.test/"), onlySecureContent: false).title.contains("not secure")
               && PageInfoController.security(for: URL(string: "http://a.test/"), onlySecureContent: false).title == "Connection is not secure",
               "page info describes the connection like Chrome")
        expect(SiteData.belongs("bbc.co.uk", to: "www.bbc.co.uk") && SiteData.belongs("bbc.co.uk", to: "bbc.co.uk")
               && !SiteData.belongs("bbc.co.uk", to: "notbbc.co.uk"), "site data matches the site and its subdomains only")
    }

    /// Real windows, tabs and WebKit processes.
    static func browserParityWebKit() throws {
        _ = NSApplication.shared
        let server = try LoopbackServer { request in
            let path = (request.components(separatedBy: "\r\n").first ?? "").split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            return LoopbackServer.html("<title>Page \(path)</title><p>\(String(repeating: "memory ", count: 2000))</p>")
        }
        defer { server.stop() }
        guard wait("parity fixture server ready", until: { server.port != nil }), let port = server.port else { return }
        func page(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

        // Task Manager: live tabs report their process memory; sleeping tabs report none.
        let c = BrowserWindowController(isPrivate: true)
        let front = c.newTab(url: page("/front"))
        let back = c.newTab(url: page("/back"), activate: false)
        back.ensureLoaded().frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        wait("task manager pages load", seconds: 15, until: {
            front.webView?.isLoading == false && back.webView?.isLoading == false && back.title == "Page /back"
        })
        let pid = back.webProcessID
        expect((pid ?? 0) > 0 && MemoryMonitor.footprint(of: pid ?? 0) > 0, "each live tab has a measurable WebKit process")
        expect(back.hoverDescription.hasPrefix("Page /back\n127.0.0.1 \u{00B7} ") && !back.hoverDescription.hasSuffix("\u{00B7} "),
               "tab hover text shows the site and its memory")
        var rows = TaskManager.rows(windows: [c], sample: MemoryMonitor.sample())
        let backRow = rows.first { $0.tab === back }
        expect(rows.first?.kind == .browser && rows.last?.kind == .helpers && (backRow?.bytes ?? 0) > 0,
               "task manager lists the browser, each tab with its memory, and shared helpers")
        expect(backRow?.status == "Background" && backRow.map(TaskManager.canSleep) == true, "background tabs can be put to sleep")
        let manager = TaskManagerWindowController()
        manager.windowsProvider = { [c] }
        manager.reload()
        expect(manager.table.numberOfRows == manager.rows.count && manager.rows.count == 4, "task manager table shows every row")
        if let i = manager.rows.firstIndex(where: { $0.tab === back }) {
            manager.table.selectRowIndexes([i], byExtendingSelection: false)
            manager.sleepSelected()
        }
        expect(back.isHibernated && back.webProcessID == nil, "Sleep Tab frees the tab's process")
        rows = TaskManager.rows(windows: [c], sample: MemoryMonitor.sample())
        let sleeping = rows.first { $0.tab === back }
        expect(sleeping?.bytes == nil && sleeping?.status == "Asleep", "sleeping tabs show no memory")
        manager.close()

        // Search Tabs ranks by title and address, most recently used first, without waking tabs.
        front.title = "Hacker News"; front.url = URL(string: "https://news.ycombinator.com/")
        back.title = "GitHub Trending"; back.url = URL(string: "https://github.com/trending")
        let third = c.newTab(url: URL(string: "https://forums.swift.org/"), activate: false)
        third.title = "Swift Forums"
        front.lastActive = Date(timeIntervalSinceNow: -30); back.lastActive = Date(timeIntervalSinceNow: -60); third.lastActive = Date()
        expect(TabSearch.rank("hack", in: [c]).first?.tab === front, "tab search matches title prefixes")
        expect(TabSearch.rank("git trend", in: [c]).map(\.tab) == [back], "every word must match")
        expect(TabSearch.rank("", in: [c]).map(\.tab) == [third, front, back], "an empty search lists tabs by recent use")
        expect(TabSearch.rank("swift.org", in: [c]).first?.tab === third && TabSearch.rank("zzz", in: [c]).isEmpty, "addresses match too")
        let search = TabSearchController { [c] }
        search.field.stringValue = "github"
        _ = search.view
        search.refresh()
        var finished = false
        search.onFinish = { finished = true }
        search.choose(0)
        expect(c.activeTab === back && finished, "choosing a result switches to that tab")
        expect(!third.hasEverLoaded, "searching never wakes a sleeping tab")

        // Site information for a plain-HTTP page, with a remembered permission.
        SiteSettings.shared.setPermission("microphone", for: "127.0.0.1", allowed: true)
        defer { SiteSettings.shared.clearPermission("microphone", for: "127.0.0.1") }
        let info = Tab(url: page("/info"), isPrivate: true, delegate: nil)
        info.ensureLoaded().frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        wait("page info fixture loads", seconds: 10, until: { info.webView?.isLoading == false && info.title == "Page /info" })
        let infoView = PageInfoController(tab: info, browser: c).view
        func texts(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts) }
        func controls(_ v: NSView) -> [NSControl] { ((v as? NSControl).map { [$0] } ?? []) + v.subviews.flatMap(controls) }
        let shown = texts(infoView)
        expect(shown.contains("Connection is not secure") && shown.contains("Microphone"), "page info shows the connection and remembered permissions")
        expect(controls(infoView).contains { ($0 as? NSButton)?.title.hasPrefix("Clear Cookies") == true }, "page info offers to clear the site's data")
        info.hibernate()

        // Clearing one site's data leaves other sites alone.
        let store = WKWebsiteDataStore.nonPersistent()
        var set = 0
        for domain in ["a.test", "sub.b.test"] {
            let cookie = HTTPCookie(properties: [.domain: domain, .path: "/", .name: "sid", .value: "1",
                                                 .expires: Date(timeIntervalSinceNow: 3600)])!
            store.httpCookieStore.setCookie(cookie) { set += 1 }
        }
        wait("site data fixture cookies set", until: { set == 2 })
        var removed = -1
        SiteData.clear(host: "www.a.test", in: store) { removed = $0 }
        wait("site data cleared", seconds: 10, until: { removed >= 0 })
        var left: [HTTPCookie]?
        store.httpCookieStore.getAllCookies { left = $0 }
        wait("remaining cookies listed", until: { left != nil })
        expect(removed == 1 && left?.map(\.domain) == ["sub.b.test"], "clearing a site's data keeps other sites' cookies")

        // Dragging a tab onto another window's strip moves it there, live.
        let other = BrowserWindowController(isPrivate: true)
        let resident = other.newTab(url: page("/resident"))
        c.showWindow(nil); other.showWindow(nil)
        if let w = c.window, let o = other.window {
            w.setFrame(NSRect(x: 40, y: 80, width: 700, height: 500), display: true)
            o.setFrame(NSRect(x: 780, y: 80, width: 700, height: 500), display: true)
        }
        if let strip = other.tabStripScreenFrame {
            expect(other.tabStripIndex(atScreenPoint: NSPoint(x: strip.minX + 2, y: strip.midY)) == 0, "dropping at the strip's start inserts first")
            let liveView = back.webView
            c.moveTab(back, toScreenPoint: NSPoint(x: strip.maxX - 60, y: strip.midY))
            expect(other.tabs.contains { $0 === back } && !c.tabs.contains { $0 === back } && other.tabs.first === resident,
                   "a tab dropped on another window's strip moves there")
            expect(back.webView != nil && back.webView === liveView, "a moved tab keeps its live page")
        } else {
            expect(false, "window tab strip has a screen frame")
        }
        expect(c.tabStripIndex(atScreenPoint: NSPoint(x: 5000, y: 5000)) == nil, "points off the window are not a drop target")

        // Closed tabs and windows come back from Recently Closed.
        RecentlyClosed.shared.removeAll()
        let normal = BrowserWindowController(isPrivate: false)
        _ = normal.newTab(url: URL(string: "about:blank#one"))
        let two = normal.newTab(url: URL(string: "about:blank#two"), activate: false)
        normal.closeTab(index: normal.tabs.firstIndex { $0 === two }!)
        let closedTab = RecentlyClosed.shared.items.last
        if case .tab(let saved)? = closedTab?.entry {
            expect(saved.url == "about:blank#two" && closedTab?.window === normal, "closing a tab records it with its window")
            normal.reopen(saved)
            expect(normal.tabs.count == 2 && normal.activeTab?.url?.absoluteString == "about:blank#two", "a closed tab reopens in place")
        } else { expect(false, "closing a tab records it") }
        normal.window?.close()
        let closedWindow = RecentlyClosed.shared.items.last
        if case .window(let w)? = closedWindow?.entry { expect(w.tabs.count == 2, "closing a window records all its tabs") }
        else { expect(false, "closing a window records it") }
        let app = AppDelegate()
        if let closedWindow, let item = RecentlyClosed.shared.remove(id: closedWindow.id) {
            app.reopen(item)
            let reopened = app.allControllers.last
            expect(reopened?.tabs.map { $0.url?.absoluteString } == ["about:blank#one", "about:blank#two"], "a closed window reopens with its tabs")
            reopened?.window?.close()
        }
        let privateBefore = RecentlyClosed.shared.items.count
        c.closeTab(index: 0)
        expect(RecentlyClosed.shared.items.count == privateBefore, "private tabs are never recorded")
        RecentlyClosed.shared.removeAll()
        c.window?.close(); other.window?.close()
    }
}
