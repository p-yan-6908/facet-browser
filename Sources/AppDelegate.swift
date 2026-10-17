import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    static var shared: AppDelegate?

    private var controllers: [BrowserWindowController] = []
    /// URLs can arrive from LaunchServices before the first window exists (clicking a
    /// link while Facet is closed), so hold them until the window is up.
    private var isReady = false
    private var pendingURLs: [URL] = []
    private let bookmarksMenu = NSMenu(title: "Bookmarks")
    private let historyMenu = NSMenu(title: "History")
    private var settingsWindowController: SettingsWindowController?
    private var libraryWindowController: LibraryWindowController?

    var allControllers: [BrowserWindowController] { controllers }

    var front: BrowserWindowController? {
        if let w = NSApp.keyWindow?.windowController as? BrowserWindowController { return w }
        if let w = NSApp.mainWindow?.windowController as? BrowserWindowController { return w }
        return controllers.last
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        MemoryBudgetController.shared.start()

        // Compile the blocklist before the first web view exists: content rules are
        // attached at configuration time, so getting this in first avoids a reload.
        ContentBlocker.load { [weak self] _ in
            self?.openInitialWindow()
        }
    }

    private func openInitialWindow() {
        var restoredControllers: [BrowserWindowController] = []
        var selectedRestored: BrowserWindowController?
        if Config.shared.restoreSessionOnLaunch {
            let saved = Store.shared.loadSessionWindows()
            for (index, state) in saved.windows.enumerated() {
                let c = makeWindow(show: false, offset: false)
                c.restore(saved: state.tabs, activeIndex: state.activeIndex)
                if let frame = state.frame { c.window?.setFrame(frame, display: false) }
                c.showWindow(nil)
                restoredControllers.append(c)
                let sleeping = max(0, state.tabs.count - 1)
                if sleeping > 0 { c.showStatus("Restored \(state.tabs.count) tabs, \(sleeping) asleep") }
                if index == (saved.selectedWindow ?? saved.windows.count - 1) { selectedRestored = c }
                else { c.window?.orderBack(nil) }
            }
            (selectedRestored ?? restoredControllers.last)?.window?.makeKeyAndOrderFront(nil)
        }

        let c = selectedRestored ?? restoredControllers.last ?? makeWindow()
        if !pendingURLs.isEmpty {
            let firstNew = c.tabs.count
            for u in pendingURLs { _ = c.newTab(url: u, activate: false) }
            pendingURLs.removeAll(); c.selectTab(index: firstNew)
        } else if restoredControllers.isEmpty && c.tabs.isEmpty { c.newTab() }
        isReady = true
        rebuildBookmarksMenu()
    }

    @discardableResult
    private func makeWindow(isPrivate: Bool = false, show: Bool = true, offset: Bool = true) -> BrowserWindowController {
        let c = BrowserWindowController(isPrivate: isPrivate)
        controllers.append(c)
        MemoryBudgetController.shared.register(c)
        if show { c.showWindow(nil); c.window?.makeKeyAndOrderFront(nil) }
        if offset, controllers.count > 1, let w = c.window {
            w.setFrameOrigin(NSPoint(x: w.frame.origin.x + 24, y: w.frame.origin.y - 24))
        }
        return c
    }

    /// A new, visible browser window (used for Move Tab to New Window and link menus).
    func makeBrowserWindow(isPrivate: Bool) -> BrowserWindowController {
        makeWindow(isPrivate: isPrivate)
    }

    func openInNewWindow(_ url: URL, isPrivate: Bool) {
        makeWindow(isPrivate: isPrivate).newTab(url: url)
    }

    /// Opens a URL from outside a browser window (History, Bookmarks), in a normal window.
    func openInFrontWindow(_ url: URL, activate: Bool) {
        let target = controllers.last { !$0.isPrivateWindow && $0.window?.isVisible == true } ?? makeWindow()
        let tab = target.newTab(url: url, activate: activate)
        if !activate { tab.ensureLoaded() }
        target.window?.makeKeyAndOrderFront(nil)
    }

    func windowClosed(_ controller: BrowserWindowController) {
        MemoryBudgetController.shared.unregister(controller)
        controllers.removeAll { $0 === controller }
        // Private browsing data lives exactly as long as some private window does.
        if controller.isPrivateWindow && !controllers.contains(where: \.isPrivateWindow) {
            WebKitEnv.discardPrivateStore()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveApplicationSession()
        Store.shared.flush()
        SiteSettings.shared.flush()
        return .terminateNow
    }

    func saveApplicationSession() {
        let normal = controllers.filter { !$0.isPrivateWindow }
        // Each window saves itself as it closes. With none left, quitting keeps that last
        // session to restore, as Chrome and Safari do, instead of overwriting it with nothing.
        guard !normal.isEmpty else { return }
        let snapshots = normal.compactMap { $0.sessionSnapshot() }
        let selected = front.flatMap { current in normal.firstIndex(where: { $0 === current }) }
        Store.shared.saveSession(windows: snapshots, selectedWindow: selected)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { makeWindow().newTab() }
        return true
    }

    /// Links opened from other apps (and from being the default browser). OAuth callback
    /// URLs are consumed before normal browser routing so authorization codes never become tabs.
    func application(_ application: NSApplication, open urls: [URL]) {
        let browserURLs = urls.filter { !AgentOAuthManager.shared.handleCallback($0) }
        guard !browserURLs.isEmpty else { return }
        guard isReady else { pendingURLs.append(contentsOf: browserURLs); return }
        let c = front ?? makeWindow()
        for u in browserURLs { c.newTab(url: u) }
        c.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu actions

    @objc func newTab() { (front ?? makeWindow()).newTab() }
    @objc func newWindow() { makeWindow().newTab() }
    @objc func newPrivateWindow() { makeWindow(isPrivate: true).newTab() }
    @objc func closeTab() { front?.closeActiveTab() }
    @objc func reopenClosedTab() { front?.reopenClosedTab() }
    @objc func focusAddressBar() { front?.focusURLField() }
    @objc func reload() { front?.reload() }
    @objc func hardReload() { front?.hardReload() }
    @objc func printPage() { front?.printPage() }
    @objc func savePageAs() { front?.savePageAs() }
    @objc func exportPDF() { front?.exportPDF() }
    @objc func showWebInspector() { front?.showWebInspector() }
    @objc func useSelectionForFind() { front?.useSelectionForFind() }
    @objc func showDownloads() {
        if let front { front.toggleDownloadsPopover() } else { Downloads.shared.revealFolder() }
    }

    @objc func toggleBookmarksBar() {
        Config.shared.showBookmarksBar.toggle()
        Config.shared.save()
        controllers.forEach { $0.chromeLayoutDidChange() }
    }

    @objc func showHistory() { showLibrary(.history) }
    @objc func showBookmarksManager() { showLibrary(.bookmarks) }

    private func showLibrary(_ mode: LibraryWindowController.Mode) {
        if libraryWindowController == nil { libraryWindowController = LibraryWindowController() }
        libraryWindowController?.show(mode)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Tab menu: each acts on the front window's current tab.
    @objc func togglePinTab() {
        guard let c = front, let tab = c.activeTab else { return }
        c.setPinned(!tab.isPinned, for: tab)
    }
    @objc func toggleMuteTab() { front?.activeTab?.isMuted.toggle() }
    @objc func duplicateTab() {
        guard let c = front, let tab = c.activeTab else { return }
        c.duplicate(tab)
    }
    @objc func moveTabToNewWindow() {
        guard let c = front, let tab = c.activeTab else { return }
        c.moveTabToNewWindow(tab)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let tab = front?.activeTab
        switch item.action {
        case #selector(toggleBookmarksBar):
            item.state = Config.shared.showBookmarksBar ? .on : .off
        case #selector(togglePinTab):
            item.title = tab?.isPinned == true ? "Unpin Tab" : "Pin Tab"
            return tab != nil
        case #selector(toggleMuteTab):
            item.title = tab?.isMuted == true ? "Unmute Tab" : "Mute Tab"
            return tab != nil
        case #selector(duplicateTab):
            return tab?.url != nil
        case #selector(moveTabToNewWindow):
            return (front?.tabs.count ?? 0) > 1
        case #selector(printPage), #selector(savePageAs), #selector(exportPDF), #selector(useSelectionForFind):
            return tab?.webView != nil
        case #selector(showWebInspector):
            return tab?.webView != nil && Config.shared.enableDeveloperTools
        default:
            break
        }
        return true
    }
    @objc func stopLoading() { front?.stopLoading() }
    @objc func goBack() { front?.goBack() }
    @objc func goForward() { front?.goForward() }
    @objc func find() { front?.showFindBar() }
    @objc func findNext() { front?.findNext() }
    @objc func findPrevious() { front?.findPrevious() }
    @objc func bookmark() { front?.toggleBookmark() }
    @objc func zoomIn() { front?.zoomIn() }
    @objc func zoomOut() { front?.zoomOut() }
    @objc func zoomReset() { front?.zoomReset() }
    @objc func sleepBackgroundTabs() { front?.hibernateBackgroundTabsNow() }
    @objc func nextTab() { front?.selectRelativeTab(1) }
    @objc func previousTab() { front?.selectRelativeTab(-1) }
    @objc func openDownloadsFolder() { Downloads.shared.revealFolder() }

    @objc func showAgent() {
        guard Config.shared.agentActive else { front?.showStatus("Assistant is disabled in Settings"); return }
        guard let front else { return }
        front.toggleAgentSidebar()
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard let c = front else { return }
        let n = sender.tag
        c.selectTab(index: n == 9 ? max(0, c.tabs.count - 1) : n)
    }

    @objc func openSettings() {
        if settingsWindowController == nil { settingsWindowController = SettingsWindowController() }
        settingsWindowController?.refresh()
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openImportSettings() {
        if settingsWindowController == nil { settingsWindowController = SettingsWindowController() }
        settingsWindowController?.refresh()
        settingsWindowController?.selectImportPane()
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func settingsDidChange() {
        MemoryBudgetController.shared.settingsDidChange()
        controllers.forEach { $0.settingsDidChange() }
        if Config.shared.memoryBudgetMB > 0 { MemoryBudgetController.shared.enforceBudget(reason: "settings changed") }
    }

    func contentBlockingSettingDidChange() {
        let apply = { [weak self] in self?.controllers.forEach { $0.contentBlockingSettingDidChange() } }
        if Config.shared.blockAdsAndTrackers { ContentBlocker.load { _ in apply() } }
        else { apply() }
    }

    /// Turns blocking back on, or off, for one site, then reloads that site's pages.
    func setBlocking(enabled: Bool, forSiteOf url: URL?) {
        guard let host = SiteSettings.key(for: url) else { return }
        SiteSettings.shared.setBlockingDisabled(!enabled, for: url)
        ContentBlocker.load { [weak self] _ in
            self?.controllers.forEach { $0.contentRulesDidChange(reloadingSiteOf: url) }
            self?.front?.showStatus(enabled ? "Blocking on for \(host)" : "Blocking off for \(host)")
        }
    }

    func browserDataWasImported() {
        rebuildBookmarksMenu()
        rebuildHistoryMenu()
        controllers.forEach { $0.showStatus("Browser data imported") }
    }

    @objc func openBlocklist() {
        if let u = ContentBlocker.domainListURL() { NSWorkspace.shared.open(u) }
    }

    @objc func openBookmark(_ sender: NSMenuItem) {
        guard let u = URL(string: sender.representedObject as? String ?? "") else { return }
        (front ?? makeWindow()).newTab(url: u)
    }

    @objc func clearHistory() {
        let a = NSAlert()
        a.messageText = "Clear browsing history?"
        a.informativeText = "Bookmarks and cookies are kept."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Store.shared.clearHistory()
        rebuildHistoryMenu()
        front?.showStatus("History cleared")
    }

    /// Chrome's Clear Browsing Data: a time range plus what to remove. Bookmarks, saved
    /// sessions, and private windows are never touched.
    @objc func clearBrowsingData() {
        let alert = NSAlert()
        alert.messageText = "Clear Browsing Data"
        alert.informativeText = "Bookmarks and open tabs are kept. Private windows are not affected."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 128))
        let rangeLabel = NSTextField(labelWithString: "Time range:")
        rangeLabel.frame = NSRect(x: 0, y: 104, width: 80, height: 18)
        let range = NSPopUpButton(frame: NSRect(x: 82, y: 98, width: 200, height: 26))
        let ranges: [(String, TimeInterval?)] = [("Last hour", 3_600), ("Last 24 hours", 86_400),
                                                 ("Last 7 days", 604_800), ("Last 4 weeks", 2_419_200), ("All time", nil)]
        range.addItems(withTitles: ranges.map(\.0))
        range.selectItem(at: 1)
        func check(_ title: String, _ y: CGFloat, on: Bool) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.frame = NSRect(x: 0, y: y, width: 300, height: 20)
            b.state = on ? .on : .off
            return b
        }
        let history = check("Browsing history", 72, on: true)
        let cookies = check("Cookies and other site data (signs you out)", 48, on: true)
        let cache = check("Cached images and files", 24, on: true)
        let site = check("Site settings (zoom levels and permissions)", 0, on: false)
        [rangeLabel, range, history, cookies, cache, site].forEach { box.addSubview($0) }
        alert.accessoryView = box
        alert.addButton(withTitle: "Clear Data")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let window = ranges[range.indexOfSelectedItem].1
        let since = window.map { Date().addingTimeInterval(-$0) } ?? .distantPast
        if history.state == .on {
            if window == nil { Store.shared.clearHistory(); FaviconStore.shared.clearAll() }
            else { Store.shared.clearHistory(since: since) }
            rebuildHistoryMenu()
        }
        if site.state == .on { SiteSettings.shared.resetAll() }
        let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                       WKWebsiteDataTypeOfflineWebApplicationCache, WKWebsiteDataTypeFetchCache]
        var types = Set<String>()
        if cookies.state == .on { types.formUnion(WKWebsiteDataStore.allWebsiteDataTypes().subtracting(cacheTypes)) }
        if cache.state == .on { types.formUnion(cacheTypes); URLCache.shared.removeAllCachedResponses() }
        guard !types.isEmpty else { front?.showStatus("Browsing data cleared"); return }
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: since) { [weak self] in
            self?.front?.showStatus("Browsing data cleared")
        }
    }

    @objc func clearWebsiteData() {
        let a = NSAlert()
        a.messageText = "Clear cookies and cached data?"
        a.informativeText = "You will be signed out of websites."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            URLCache.shared.removeAllCachedResponses()
            self?.front?.showStatus("Website data cleared")
        }
    }

    @objc func makeDefaultBrowser() {
        guard let me = Bundle.main.bundleURL as URL? else { return }
        NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "http") { [weak self] err in
            DispatchQueue.main.async {
                if let err {
                    self?.front?.showStatus("Couldn\u{2019}t set default: \(err.localizedDescription)")
                } else {
                    NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "https") { _ in }
                    self?.front?.showStatus("Facet is now the default browser")
                }
            }
        }
    }

    @objc func showAbout() {
        let s = MemoryMonitor.sample()
        let a = NSAlert()
        a.messageText = "Facet"
        a.informativeText = """
        A minimal browser on the system WebKit engine.

        Right now: \(s.display) across \(s.helperCount + 1) process\(s.helperCount == 0 ? "" : "es").
        Blocking \(ContentBlocker.ruleCount) ad and tracker rules.
        Background tabs sleep after \(Int(Config.shared.hibernateAfterMinutes)) min.
        Memory target: \(Config.shared.memoryBudgetMB == 0 ? "off" : "\(Config.shared.memoryBudgetMB) MB").
        """
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: - Menu construction

    func rebuildBookmarksMenu() {
        bookmarksMenu.removeAllItems()
        let add = NSMenuItem(title: "Bookmark This Page", action: #selector(bookmark), keyEquivalent: "d")
        add.target = self
        bookmarksMenu.addItem(add)
        let manager = NSMenuItem(title: "Bookmark Manager", action: #selector(showBookmarksManager), keyEquivalent: "b")
        manager.keyEquivalentModifierMask = [.command, .option]
        manager.target = self
        bookmarksMenu.addItem(manager)
        let bar = NSMenuItem(title: "Always Show Bookmarks Bar", action: #selector(toggleBookmarksBar), keyEquivalent: "")
        bar.target = self
        bookmarksMenu.addItem(bar)
        bookmarksMenu.addItem(.separator())
        if Store.shared.bookmarks.isEmpty {
            let empty = NSMenuItem(title: "No Bookmarks", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            bookmarksMenu.addItem(empty)
        }
        for b in Store.shared.bookmarks {
            let title = b.title.isEmpty ? Store.displayForm(b.url) : b.title
            let item = NSMenuItem(title: String(title.prefix(60)), action: #selector(openBookmark(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = b.url
            bookmarksMenu.addItem(item)
        }
    }

    func rebuildHistoryMenu() {
        historyMenu.removeAllItems()
        func add(_ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            historyMenu.addItem(i)
        }
        add("Back", #selector(goBack), "[")
        add("Forward", #selector(goForward), "]")
        historyMenu.addItem(.separator())
        add("Show All History", #selector(showHistory), "y")
        add("Reopen Closed Tab", #selector(reopenClosedTab), "t", [.command, .shift])
        historyMenu.addItem(.separator())
        for e in Store.shared.recentHistory(limit: 15) {
            let title = e.title.isEmpty ? Store.displayForm(e.url) : e.title
            let item = NSMenuItem(title: String(title.prefix(60)), action: #selector(openBookmark(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = e.url
            historyMenu.addItem(item)
        }
        historyMenu.addItem(.separator())
        add("Clear Browsing Data\u{2026}", #selector(clearBrowsingData), "\u{8}", [.command, .shift])
    }

    private func buildMenu() {
        let main = NSMenu()

        func menu(_ title: String) -> (NSMenuItem, NSMenu) {
            let item = NSMenuItem()
            let m = NSMenu(title: title)
            item.submenu = m
            main.addItem(item)
            return (item, m)
        }
        func add(_ m: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            i.tag = tag
            m.addItem(i)
        }

        // App menu
        let (_, app) = menu("Facet")
        add(app, "About Facet", #selector(showAbout), target: self)
        app.addItem(.separator())
        add(app, "Settings\u{2026}", #selector(openSettings), ",", target: self)
        add(app, "Edit Blocklist\u{2026}", #selector(openBlocklist), target: self)
        add(app, "Make Facet the Default Browser", #selector(makeDefaultBrowser), target: self)
        app.addItem(.separator())
        add(app, "Hide Facet", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit Facet", #selector(NSApplication.terminate(_:)), "q")

        // File
        let (_, file) = menu("File")
        add(file, "New Tab", #selector(newTab), "t", target: self)
        add(file, "New Window", #selector(newWindow), "n", target: self)
        add(file, "New Private Window", #selector(newPrivateWindow), "n", [.command, .shift], target: self)
        file.addItem(.separator())
        add(file, "Open Location\u{2026}", #selector(focusAddressBar), "l", target: self)
        add(file, "Import Browser Data\u{2026}", #selector(openImportSettings), target: self)
        file.addItem(.separator())
        add(file, "Close Tab", #selector(closeTab), "w", target: self)
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        file.addItem(.separator())
        add(file, "Save Page As\u{2026}", #selector(savePageAs), "s", target: self)
        add(file, "Export as PDF\u{2026}", #selector(exportPDF), target: self)
        add(file, "Print\u{2026}", #selector(printPage), "p", target: self)
        file.addItem(.separator())
        add(file, "Downloads", #selector(showDownloads), "j", [.command, .shift], target: self)
        add(file, "Open Downloads Folder", #selector(openDownloadsFolder), "l", [.command, .option], target: self)

        // Edit  (standard responder selectors: required for text editing inside pages)
        let (_, edit) = menu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Find\u{2026}", #selector(find), "f", target: self)
        add(edit, "Find Next", #selector(findNext), "g", target: self)
        add(edit, "Find Previous", #selector(findPrevious), "g", [.command, .shift], target: self)
        add(edit, "Use Selection for Find", #selector(useSelectionForFind), "e", target: self)

        // View
        let (_, view) = menu("View")
        add(view, "Always Show Bookmarks Bar", #selector(toggleBookmarksBar), "b", [.command, .shift], target: self)
        view.addItem(.separator())
        add(view, "Reload Page", #selector(reload), "r", target: self)
        add(view, "Force Reload Page", #selector(hardReload), "r", [.command, .shift], target: self)
        add(view, "Stop", #selector(stopLoading), ".", target: self)
        view.addItem(.separator())
        add(view, "Actual Size", #selector(zoomReset), "0", target: self)
        add(view, "Zoom In", #selector(zoomIn), "+", target: self)
        add(view, "Zoom Out", #selector(zoomOut), "-", target: self)
        view.addItem(.separator())
        add(view, "Sleep Background Tabs Now", #selector(sleepBackgroundTabs), "h", [.command, .shift], target: self)
        view.addItem(.separator())
        if Config.agentFeatureAvailable {
            add(view, "AI Agent\u{2026}", #selector(showAgent), "k", [.command, .shift], target: self)
        }
        add(view, "Web Inspector", #selector(showWebInspector), "i", [.command, .option], target: self)
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        // History
        let (historyItem, _) = menu("History")
        historyItem.submenu = historyMenu
        historyMenu.delegate = self
        rebuildHistoryMenu()

        // Bookmarks
        let (bmItem, _) = menu("Bookmarks")
        bmItem.submenu = bookmarksMenu

        // Tab
        let (_, tabMenu) = menu("Tab")
        add(tabMenu, "New Tab", #selector(newTab), target: self)
        add(tabMenu, "Duplicate Tab", #selector(duplicateTab), target: self)
        add(tabMenu, "Pin Tab", #selector(togglePinTab), target: self)
        add(tabMenu, "Mute Tab", #selector(toggleMuteTab), target: self)
        add(tabMenu, "Move Tab to New Window", #selector(moveTabToNewWindow), target: self)
        tabMenu.addItem(.separator())
        add(tabMenu, "Sleep Background Tabs Now", #selector(sleepBackgroundTabs), target: self)

        // Window
        let (windowItem, windowMenu) = menu("Window")
        add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)))
        windowMenu.addItem(.separator())
        add(windowMenu, "Show Next Tab", #selector(nextTab), "\u{0009}", [.control], target: self)
        add(windowMenu, "Show Previous Tab", #selector(previousTab), "\u{0009}", [.control, .shift], target: self)
        // Arrow variants: the shortcut most people reach for first. Hidden, so the menu lists
        // each command once, but their key equivalents still work.
        add(windowMenu, "Show Next Tab", #selector(nextTab), "\u{F703}", [.command, .option], target: self)
        add(windowMenu, "Show Previous Tab", #selector(previousTab), "\u{F702}", [.command, .option], target: self)
        for item in windowMenu.items.suffix(2) { item.isHidden = true; item.allowsKeyEquivalentWhenHidden = true }
        windowMenu.addItem(.separator())
        for n in 1...9 {
            add(windowMenu, "Tab \(n)", #selector(selectTabByNumber(_:)), "\(n)", target: self, tag: n - 1)
        }
        windowMenu.addItem(.separator())
        add(windowMenu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = windowMenu
        _ = windowItem

        NSApp.mainMenu = main
    }

    /// Refresh the history submenu lazily when it is opened, not on every page load.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === historyMenu { rebuildHistoryMenu() }
    }
}
