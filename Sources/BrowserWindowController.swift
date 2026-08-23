import AppKit
import WebKit

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class BrowserWindowController: NSWindowController, NSWindowDelegate {

    private(set) var tabs: [Tab] = []
    private(set) var activeIndex = 0
    let isPrivateWindow: Bool

    private let root = FlippedView()
    private let tabStrip = TabStripView()
    private let toolbarRow = FlippedView()
    private let progressBar = ProgressBar()
    private let webContainer = FlippedView()
    private let startView = StartView()

    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let shieldButton = NSButton()
    private let bookmarkButton = NSButton()
    private let urlField = URLField()
    private let statusLabel = NSTextField(labelWithString: "")

    private let findRow = FlippedView()
    private let findField = NSTextField()
    private let findCount = NSTextField(labelWithString: "")
    private var findVisible = false

    private var hibernationTimer: Timer?
    private var memoryTimer: Timer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var sessionSaveScheduled = false
    private var suppressCompletion = false
    private var statusResetWork: DispatchWorkItem?

    private let chromeTopHeight: CGFloat = 36 + 38
    private var findRowHeight: CGFloat { findVisible ? 34 : 0 }

    var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }

    // MARK: - Init

    init(isPrivate: Bool = false) {
        self.isPrivateWindow = isPrivate
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init(window: w)

        w.delegate = self
        w.title = isPrivate ? "Kestrel Private" : "Kestrel"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 520, height: 380)
        w.tabbingMode = .disallowed          // we manage our own tabs
        w.setFrameAutosaveName(isPrivate ? "KestrelPrivateWindow" : "KestrelWindow")
        w.backgroundColor = .windowBackgroundColor

        buildChrome()
        w.contentView = root

        startHibernationTimer()
        startMemoryReadout()
        installMemoryPressureHandling()

        Downloads.shared.statusHandler = { [weak self] msg in self?.showStatus(msg) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Chrome

    private func buildChrome() {
        root.addSubview(tabStrip)
        root.addSubview(toolbarRow)
        root.addSubview(progressBar)
        root.addSubview(findRow)
        root.addSubview(webContainer)

        tabStrip.delegate = self
        progressBar.active = false
        findRow.isHidden = true

        func setup(_ b: NSButton, _ symbol: String, _ tip: String, _ action: Selector) {
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.imageScaling = .scaleProportionallyDown
            b.target = self
            b.action = action
            b.toolTip = tip
            b.contentTintColor = .secondaryLabelColor
        }

        setup(backButton, "chevron.left", "Back (\u{2318}[)", #selector(goBack))
        setup(forwardButton, "chevron.right", "Forward (\u{2318}])", #selector(goForward))
        setup(reloadButton, "arrow.clockwise", "Reload (\u{2318}R)", #selector(reloadOrStop))
        setup(shieldButton, "shield.lefthalf.filled", "Ad & tracker blocking", #selector(toggleBlocking))
        setup(bookmarkButton, "star", "Bookmark (\u{2318}D)", #selector(toggleBookmark))

        urlField.placeholderString = "Search or enter address"
        urlField.font = .systemFont(ofSize: 13)
        urlField.bezelStyle = .roundedBezel
        urlField.focusRingType = .none
        urlField.delegate = self
        urlField.target = self
        urlField.action = #selector(urlFieldCommitted)
        urlField.onCancel = { [weak self] in self?.focusWebContent() }

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingHead

        [backButton, forwardButton, reloadButton, urlField, bookmarkButton,
         shieldButton, statusLabel].forEach { toolbarRow.addSubview($0) }

        // Find bar
        findField.placeholderString = "Find on page"
        findField.font = .systemFont(ofSize: 12)
        findField.bezelStyle = .roundedBezel
        findField.target = self
        findField.action = #selector(findNext)
        findCount.font = .systemFont(ofSize: 11)
        findCount.textColor = .tertiaryLabelColor
        let prev = NSButton(title: "", target: self, action: #selector(findPrevious))
        prev.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")
        let next = NSButton(title: "", target: self, action: #selector(findNext))
        next.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")
        let done = NSButton(title: "Done", target: self, action: #selector(hideFindBar))
        [prev, next, done].forEach { $0.bezelStyle = .accessoryBarAction; $0.isBordered = false }
        [findField, prev, next, findCount, done].forEach { findRow.addSubview($0) }

        startView.onOpen = { [weak self] urlString in
            guard let self, let u = URL(string: urlString) else { return }
            self.activeTab?.load(u)
            self.refreshChrome()
            self.attachActiveTab()
        }
    }

    override func windowDidLoad() { super.windowDidLoad() }

    private func layoutChrome() {
        let b = root.bounds
        let trafficLightInset: CGFloat = 78
        tabStrip.frame = NSRect(x: trafficLightInset, y: 0,
                                width: max(0, b.width - trafficLightInset), height: 36)
        toolbarRow.frame = NSRect(x: 0, y: 36, width: b.width, height: 38)
        progressBar.frame = NSRect(x: 0, y: chromeTopHeight - 2, width: b.width, height: 2)

        findRow.frame = NSRect(x: 0, y: chromeTopHeight, width: b.width, height: findRowHeight)
        findRow.isHidden = !findVisible
        let webY = chromeTopHeight + findRowHeight
        webContainer.frame = NSRect(x: 0, y: webY, width: b.width, height: max(0, b.height - webY))
        startView.frame = webContainer.bounds
        activeTab?.webView?.frame = webContainer.bounds

        // Toolbar row internals
        let y: CGFloat = 7
        let h: CGFloat = 24
        backButton.frame = NSRect(x: 10, y: y, width: 26, height: h)
        forwardButton.frame = NSRect(x: 38, y: y, width: 26, height: h)
        reloadButton.frame = NSRect(x: 68, y: y, width: 26, height: h)

        var right = b.width - 12
        if Config.shared.showMemoryReadout {
            statusLabel.isHidden = false
            let w: CGFloat = 128
            statusLabel.frame = NSRect(x: right - w, y: 9, width: w, height: 16)
            right -= w + 6
        } else {
            statusLabel.isHidden = true
        }
        shieldButton.frame = NSRect(x: right - 26, y: y, width: 26, height: h)
        right -= 28
        bookmarkButton.frame = NSRect(x: right - 26, y: y, width: 26, height: h)
        right -= 30

        let urlX: CGFloat = 102
        urlField.frame = NSRect(x: urlX, y: 6, width: max(80, right - urlX), height: 25)

        // Find row internals
        if findVisible {
            findField.frame = NSRect(x: 12, y: 5, width: 260, height: 24)
            let subs = findRow.subviews.compactMap { $0 as? NSButton }
            if subs.count >= 3 {
                subs[0].frame = NSRect(x: 280, y: 6, width: 24, height: 22)
                subs[1].frame = NSRect(x: 306, y: 6, width: 24, height: 22)
                subs[2].frame = NSRect(x: b.width - 70, y: 6, width: 58, height: 22)
            }
            findCount.frame = NSRect(x: 338, y: 8, width: 160, height: 16)
        }
    }

    func windowDidResize(_ notification: Notification) { layoutChrome() }

    func windowDidBecomeKey(_ notification: Notification) {
        activeTab?.lastActive = Date()
        Downloads.shared.statusHandler = { [weak self] msg in self?.showStatus(msg) }
    }

    func windowWillClose(_ notification: Notification) {
        saveSessionNow()
        hibernationTimer?.invalidate()
        memoryTimer?.invalidate()
        memoryPressureSource?.cancel()
        AppDelegate.shared?.windowClosed(self)
    }

    // MARK: - Tabs

    @discardableResult
    func newTab(url: URL? = nil, activate: Bool = true, configuration: WKWebViewConfiguration? = nil) -> Tab {
        let tab = Tab(url: url, isPrivate: isPrivateWindow, delegate: self, configuration: configuration)
        tabs.append(tab)
        // An opener-created tab must have its web view before we return it to WebKit.
        if configuration != nil { tab.ensureLoaded() }
        if activate {
            activeIndex = tabs.count - 1
            attachActiveTab()
            if url == nil { focusURLField() }
        }
        refreshChrome()
        scheduleSessionSave()
        return tab
    }

    func restore(saved: [SavedTab], activeIndex idx: Int) {
        for s in saved {
            let t = Tab(saved: s, delegate: self)
            tabs.append(t)
        }
        activeIndex = min(max(0, idx), max(0, tabs.count - 1))
        attachActiveTab()
        refreshChrome()
    }

    func selectTab(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    func selectRelativeTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let n = tabs.count
        selectTab(index: ((activeIndex + delta) % n + n) % n)
    }

    func closeTab(index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        tab.webView?.removeFromSuperview()
        tab.hibernate()
        tabs.remove(at: index)
        if tabs.isEmpty {
            saveSessionNow()
            window?.close()
            return
        }
        if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
        else if index < activeIndex { activeIndex -= 1 }
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    func closeActiveTab() { closeTab(index: activeIndex) }

    /// Swap the visible web view. Waking a hibernated tab happens here.
    private func attachActiveTab() {
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let tab = activeTab else { return }
        tab.lastActive = Date()

        if tab.url == nil && !tab.hasEverLoaded {
            startView.rebuild()
            startView.frame = webContainer.bounds
            webContainer.addSubview(startView)
            return
        }
        let wv = tab.ensureLoaded()
        wv.frame = webContainer.bounds
        webContainer.addSubview(wv)
        window?.makeFirstResponder(wv)
    }

    private func focusWebContent() {
        if let wv = activeTab?.webView { window?.makeFirstResponder(wv) }
    }

    func focusURLField() {
        window?.makeFirstResponder(urlField)
    }

    // MARK: - Chrome refresh

    func refreshChrome() {
        layoutChrome()
        tabStrip.update(tabs: tabs, selected: activeIndex)

        guard let tab = activeTab else { return }
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        backButton.contentTintColor = tab.canGoBack ? .secondaryLabelColor : .quaternaryLabelColor
        forwardButton.contentTintColor = tab.canGoForward ? .secondaryLabelColor : .quaternaryLabelColor

        reloadButton.image = NSImage(systemSymbolName: tab.isLoading ? "xmark" : "arrow.clockwise",
                                     accessibilityDescription: tab.isLoading ? "Stop" : "Reload")
        progressBar.active = tab.isLoading && tab.progress < 1
        progressBar.progress = tab.progress

        if window?.firstResponder !== urlField.currentEditor() {
            let text = tab.url.map { u -> String in
                let s = u.absoluteString
                return s == "about:blank" ? "" : Store.displayForm(s)
            } ?? ""
            if urlField.stringValue != text { urlField.stringValue = text }
        }

        let bookmarked = tab.url.map { Store.shared.isBookmarked($0) } ?? false
        bookmarkButton.image = NSImage(systemSymbolName: bookmarked ? "star.fill" : "star",
                                        accessibilityDescription: "Bookmark")
        bookmarkButton.contentTintColor = bookmarked ? .systemYellow : .secondaryLabelColor

        let blocking = Config.shared.blockAdsAndTrackers && ContentBlocker.ruleList != nil
        shieldButton.contentTintColor = blocking ? .controlAccentColor : .quaternaryLabelColor
        shieldButton.toolTip = blocking
            ? "Blocking \(ContentBlocker.ruleCount) ad & tracker rules \u{2014} click to disable"
            : "Ad & tracker blocking off \u{2014} click to enable"

        window?.title = tab.displayTitle
    }

    // MARK: - Actions

    @objc func goBack() { activeTab?.goBack() }
    @objc func goForward() { activeTab?.goForward() }

    @objc func reloadOrStop() {
        guard let tab = activeTab else { return }
        tab.isLoading ? tab.stop() : tab.reload()
    }

    @objc func reload() { activeTab?.reload() }

    @objc func toggleBlocking() {
        Config.shared.blockAdsAndTrackers.toggle()
        Config.shared.save()
        if Config.shared.blockAdsAndTrackers {
            ContentBlocker.load { [weak self] _ in
                self?.reloadAllForRuleChange()
            }
        } else {
            reloadAllForRuleChange()
        }
    }

    private func reloadAllForRuleChange() {
        // Content rules are baked into a configuration at creation time, so tabs must
        // be rebuilt. Hibernating them does exactly that, for free.
        for (i, tab) in tabs.enumerated() where i != activeIndex { tab.hibernate() }
        if let tab = activeTab {
            tab.webView?.removeFromSuperview()
            tab.hibernate()
            attachActiveTab()
        }
        refreshChrome()
        showStatus(Config.shared.blockAdsAndTrackers ? "Blocking on" : "Blocking off")
    }

    @objc func toggleBookmark() {
        guard let tab = activeTab, let u = tab.url else { return }
        let added = Store.shared.toggleBookmark(url: u, title: tab.title)
        showStatus(added ? "Bookmarked" : "Bookmark removed")
        refreshChrome()
        AppDelegate.shared?.rebuildBookmarksMenu()
    }

    @objc private func urlFieldCommitted() {
        let raw = urlField.stringValue
        guard let url = Config.shared.resolve(input: raw) else { return }
        if activeTab == nil { newTab(url: url); return }
        activeTab?.load(url)
        attachActiveTab()
        refreshChrome()
        focusWebContent()
        scheduleSessionSave()
    }

    @objc func zoomIn() { adjustZoom(1.1) }
    @objc func zoomOut() { adjustZoom(1 / 1.1) }
    @objc func zoomReset() { activeTab?.webView?.pageZoom = 1 }

    private func adjustZoom(_ factor: CGFloat) {
        guard let wv = activeTab?.webView else { return }
        wv.pageZoom = min(3, max(0.4, wv.pageZoom * factor))
        showStatus("Zoom \(Int(wv.pageZoom * 100))%")
    }

    // MARK: - Find

    @objc func showFindBar() {
        findVisible = true
        layoutChrome()
        window?.makeFirstResponder(findField)
    }

    @objc func hideFindBar() {
        findVisible = false
        findCount.stringValue = ""
        layoutChrome()
        focusWebContent()
    }

    @objc func findNext() { runFind(backwards: false) }
    @objc func findPrevious() { runFind(backwards: true) }

    private func runFind(backwards: Bool) {
        guard let wv = activeTab?.webView, !findField.stringValue.isEmpty else { return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.caseSensitive = false
        cfg.wraps = true
        wv.find(findField.stringValue, configuration: cfg) { [weak self] result in
            self?.findCount.stringValue = result.matchFound ? "" : "Not found"
        }
    }

    // MARK: - Hibernation

    private func startHibernationTimer() {
        hibernationTimer?.invalidate()
        guard Config.shared.hibernateAfterMinutes > 0 else { return }
        hibernationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.hibernateIdleTabs()
        }
    }

    private func hibernateIdleTabs() {
        let threshold = Config.shared.hibernateAfterMinutes * 60
        var slept = 0
        for (i, tab) in tabs.enumerated() where i != activeIndex {
            if tab.canHibernate(idleFor: threshold) { tab.hibernate(); slept += 1 }
        }
        if slept > 0 {
            refreshChrome()
            saveSessionNow()
        }
    }

    /// Menu action: put every background tab to sleep right now.
    @objc func hibernateBackgroundTabsNow() {
        var slept = 0
        for (i, tab) in tabs.enumerated() where i != activeIndex {
            if !tab.isHibernated { tab.hibernate(); slept += 1 }
        }
        refreshChrome()
        showStatus(slept == 0 ? "Nothing to sleep" : "Slept \(slept) tab\(slept == 1 ? "" : "s")")
    }

    private func installMemoryPressureHandling() {
        guard Config.shared.hibernateOnMemoryPressure else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            NSLog("Kestrel: memory pressure, sleeping background tabs")
            self.hibernateBackgroundTabsNow()
            URLCache.shared.removeAllCachedResponses()
        }
        src.resume()
        memoryPressureSource = src
    }

    // MARK: - Memory readout

    private func startMemoryReadout() {
        guard Config.shared.showMemoryReadout else { return }
        updateMemoryReadout()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self, let w = self.window,
                  w.isVisible, w.occlusionState.contains(.visible) else { return }
            self.updateMemoryReadout()
        }
    }

    private func updateMemoryReadout() {
        guard statusResetWork == nil else { return }   // a transient message is showing
        let s = MemoryMonitor.sample()
        let sleeping = tabs.filter { $0.isHibernated }.count
        var text = s.display
        if sleeping > 0 { text += "  \u{00B7}  \(sleeping) asleep" }
        statusLabel.stringValue = text
        statusLabel.toolTip = "\(s.display) total \u{2014} app \(ByteCountFormatter.string(fromByteCount: Int64(s.appBytes), countStyle: .memory)) + \(s.helperCount) web process\(s.helperCount == 1 ? "" : "es")"
    }

    func showStatus(_ message: String) {
        statusResetWork?.cancel()
        statusLabel.stringValue = message
        let work = DispatchWorkItem { [weak self] in
            self?.statusResetWork = nil
            self?.updateMemoryReadout()
        }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - Session

    private func scheduleSessionSave() {
        guard !isPrivateWindow, !sessionSaveScheduled else { return }
        sessionSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.sessionSaveScheduled = false
            self?.saveSessionNow()
        }
    }

    func saveSessionNow() {
        guard !isPrivateWindow else { return }
        let snapshots = tabs.filter { $0.url != nil }.map { $0.snapshot() }
        Store.shared.saveSession(snapshots, activeIndex: activeIndex)
        Store.shared.flush()
    }
}

// MARK: - Delegates

extension BrowserWindowController: TabDelegate {
    func tabDidChangeState(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }
        if idx == activeIndex {
            refreshChrome()
        } else {
            tabStrip.update(tabs: tabs, selected: activeIndex)
        }
        if !tab.isLoading { scheduleSessionSave() }
    }

    func tab(_ tab: Tab, openNewTabWith url: URL?, configuration: WKWebViewConfiguration?, activate: Bool) -> Tab? {
        let previous = activeIndex
        let newOne = newTab(url: url, activate: true, configuration: configuration)
        if !activate, tabs.indices.contains(previous) {
            activeIndex = previous
            attachActiveTab()
            refreshChrome()
        }
        return newOne
    }

    func tabRequestsClose(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }
        closeTab(index: idx)
    }

    func tabStatus(_ tab: Tab, message: String?) {
        if let message { showStatus(message) }
    }
}

extension BrowserWindowController: TabStripDelegate {
    func tabStripDidSelect(index: Int) { selectTab(index: index) }
    func tabStripDidRequestClose(index: Int) { closeTab(index: index) }
    func tabStripDidRequestNewTab() { newTab() }
}

extension BrowserWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === urlField, !suppressCompletion,
              let editor = urlField.currentEditor() as? NSTextView else { return }
        suppressCompletion = true
        editor.complete(nil)
        suppressCompletion = false
    }

    func control(_ control: NSControl, textView: NSTextView, completions words: [String],
                 forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        index.pointee = -1     // do not auto-insert; let the user arrow down
        return Store.shared.suggestions(for: textView.string)
    }
}
