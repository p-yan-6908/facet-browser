import AppKit
import UniformTypeIdentifiers
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
    private let bookmarksBar = BookmarksBarView()
    private let progressBar = ProgressBar()
    private let webContainer = FlippedView()
    private let startView = StartView()
    private let linkStatus = LinkStatusView()
    private let agentSidebar = AgentSidebarView()
    private var agentSidebarVisible = false
    private let agentSidebarWidth: CGFloat = 360

    private let chromeBackground = NSVisualEffectView()
    private let hairline = HairlineView()

    private var backButton: ToolbarButton!
    private var forwardButton: ToolbarButton!
    private var reloadButton: ToolbarButton!
    private var shieldButton: ToolbarButton!
    private var bookmarkButton: ToolbarButton!
    private var assistantButton: ToolbarButton!
    private var downloadsButton: DownloadsToolbarButton!
    private let urlBar = URLBar()
    private var urlField: URLField { urlBar.field }
    private let statusPill = StatusPill()
    private let omnibox = OmniboxPopup()
    /// What the user has typed, without any inline completion, for Escape to restore.
    private var omniboxTyped = ""
    private var omniboxTypedLength = 0
    private var downloadsPopover: NSPopover?

    private let findRow = BarBackgroundView()
    private let findField = NSTextField()
    private let findCount = NSTextField(labelWithString: "")
    private var findPrevButton: ToolbarButton!
    private var findNextButton: ToolbarButton!
    private let findDoneButton = NSButton()
    private var findVisible = false
    private var findWork: DispatchWorkItem?

    private var hibernationTimer: Timer?
    private var memoryTimer: Timer?
    private var sessionSaveScheduled = false
    private var statusResetWork: DispatchWorkItem?
    /// When the window stopped being visible (minimized, hidden, fully covered).
    private var hiddenSince: Date?
    private var observers: [NSObjectProtocol] = []
    /// Most recently closed tabs, for Reopen Closed Tab.

    private let tabRowHeight: CGFloat = 36
    private let toolRowHeight: CGFloat = 38
    private let bookmarksRowHeight: CGFloat = 28
    private var bookmarksBarVisible: Bool { Config.shared.showBookmarksBar }
    private var chromeTopHeight: CGFloat {
        tabRowHeight + toolRowHeight + (bookmarksBarVisible ? bookmarksRowHeight : 0)
    }
    private var findRowHeight: CGFloat { findVisible ? 34 : 0 }

    /// Chrome's zoom levels, so ⌘+ and ⌘- land on the same familiar steps.
    private static let zoomSteps: [CGFloat] = [0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }
    private var pinnedCount: Int { tabs.prefix { $0.isPinned }.count }

    /// True when this window's page is actually on screen, not minimized or fully covered.
    var isContentVisible: Bool {
        guard let w = window else { return false }
        return w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
    }

    // MARK: - Init

    init(isPrivate: Bool = false) {
        self.isPrivateWindow = isPrivate
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init(window: w)

        w.delegate = self
        w.title = isPrivate ? "Facet Private" : "Facet"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 520, height: 380)
        w.tabbingMode = .disallowed          // we manage our own tabs
        w.backgroundColor = .windowBackgroundColor
        if #available(macOS 11.0, *) { w.titlebarSeparatorStyle = .none }

        buildChrome()
        w.contentView = root
        // Restoring an autosaved frame can synchronously emit a resize notification.
        // Wait until the toolbar controls exist before applying it.
        w.setFrameAutosaveName(isPrivate ? "FacetPrivateWindow" : "FacetWindow")

        startHibernationTimer()
        startMemoryReadout()

        Downloads.shared.statusHandler = { [weak self] msg in self?.showStatus(msg) }
        // The star follows bookmark changes made anywhere: the bubble, the bar, the manager.
        observers.append(NotificationCenter.default.addObserver(forName: .facetBookmarksChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshChrome()
        })
        observers.append(NotificationCenter.default.addObserver(forName: .facetDownloadsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDownloadsButton()
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Chrome

    private func buildChrome() {
        // One vibrant layer behind the whole chrome gives the standard native toolbar
        // look for the cost of a single layer.
        chromeBackground.material = .titlebar
        chromeBackground.blendingMode = .withinWindow
        chromeBackground.state = .followsWindowActiveState
        root.addSubview(chromeBackground)

        root.addSubview(tabStrip)
        root.addSubview(toolbarRow)
        root.addSubview(bookmarksBar)
        root.addSubview(progressBar)
        root.addSubview(findRow)
        root.addSubview(hairline)
        root.addSubview(webContainer)
        root.addSubview(linkStatus)
        root.addSubview(agentSidebar)
        agentSidebar.isHidden = true
        agentSidebar.onClose = { [weak self] in self?.setAgentSidebarVisible(false) }
        linkStatus.isHidden = true

        tabStrip.delegate = self
        progressBar.active = false
        findRow.isHidden = true

        bookmarksBar.onOpen = { [weak self] url, inNewTab in
            guard let self else { return }
            if inNewTab { self.newTab(url: url, activate: false).ensureLoaded() } else { self.open(url) }
        }
        bookmarksBar.onOpenAll = { folder, newWindow in AppDelegate.shared?.openBookmarks(in: folder, newWindow: newWindow) }
        bookmarksBar.onOpenInNewWindow = { [weak self] url in
            guard let self else { return }
            AppDelegate.shared?.openInNewWindow(url, isPrivate: self.isPrivateWindow)
        }

        backButton = ToolbarButton(symbol: "chevron.backward", tip: "Back (\u{2318}[) \u{2014} hold for history",
                                   target: self, action: #selector(goBack))
        forwardButton = ToolbarButton(symbol: "chevron.forward", tip: "Forward (\u{2318}]) \u{2014} hold for history",
                                      target: self, action: #selector(goForward))
        backButton.menuProvider = { [weak self] in self?.historyMenu(back: true) }
        forwardButton.menuProvider = { [weak self] in self?.historyMenu(back: false) }
        reloadButton = ToolbarButton(symbol: "arrow.clockwise", tip: "Reload (\u{2318}R)",
                                     target: self, action: #selector(reloadOrStop))
        bookmarkButton = ToolbarButton(symbol: "star", tip: "Bookmark (\u{2318}D)",
                                       target: self, action: #selector(toggleBookmark))
        bookmarkButton.onTint = .systemYellow
        shieldButton = ToolbarButton(symbol: "shield.lefthalf.filled",
                                     tip: "Ad & tracker blocking",
                                     target: self, action: #selector(showBlockingMenu))
        downloadsButton = DownloadsToolbarButton(symbol: "arrow.down.circle", tip: "Downloads (\u{2318}\u{21E7}J)",
                                                 target: self, action: #selector(toggleDownloadsPopover))
        assistantButton = ToolbarButton(symbol: "sparkles", tip: "Assistant (\u{2318}\u{21E7}K)",
                                        target: self, action: #selector(assistantButtonPressed))

        urlField.delegate = self
        urlField.target = self
        urlField.action = #selector(urlFieldCommitted)
        urlField.onCancel = { [weak self] in self?.revertAddressBar() }
        statusPill.onClick = { AppDelegate.shared?.showTaskManager() }
        urlBar.onSiteInfo = { [weak self] in self?.showPageInfo() }
        urlField.onPasteAndGo = { [weak self] text in
            guard let self else { return }
            self.urlField.stringValue = text
            self.urlFieldCommitted()
        }
        omnibox.onActivate = { [weak self] index in self?.activateSuggestion(at: index) }

        [backButton, forwardButton, reloadButton, urlBar, bookmarkButton,
         shieldButton, downloadsButton, assistantButton, statusPill].forEach { toolbarRow.addSubview($0!) }

        // Find bar
        findField.placeholderString = "Find on page"
        findField.font = .systemFont(ofSize: 12)
        findField.bezelStyle = .roundedBezel
        findField.delegate = self
        findField.target = self
        findField.action = #selector(findNext)
        findCount.font = .systemFont(ofSize: 11)
        findCount.textColor = .secondaryLabelColor
        findPrevButton = ToolbarButton(symbol: "chevron.up", tip: "Previous (\u{2318}\u{21E7}G)",
                                       target: self, action: #selector(findPrevious), pointSize: 11)
        findNextButton = ToolbarButton(symbol: "chevron.down", tip: "Next (\u{2318}G)",
                                       target: self, action: #selector(findNext), pointSize: 11)
        findDoneButton.title = "Done"
        findDoneButton.bezelStyle = .rounded
        findDoneButton.controlSize = .small
        findDoneButton.target = self
        findDoneButton.action = #selector(hideFindBar)
        [findField, findPrevButton, findNextButton, findCount, findDoneButton]
            .forEach { findRow.addSubview($0!) }

        startView.onOpen = { [weak self] urlString in
            guard let self, let u = URL(string: urlString) else { return }
            self.open(u)
        }
        startView.onFocusAddressBar = { [weak self] in self?.focusURLField() }
    }

    override func windowDidLoad() { super.windowDidLoad() }

    private func layoutChrome() {
        let b = root.bounds
        let trafficLightInset: CGFloat = 82

        tabStrip.frame = NSRect(x: trafficLightInset, y: 0,
                                width: max(0, b.width - trafficLightInset), height: tabRowHeight)
        toolbarRow.frame = NSRect(x: 0, y: tabRowHeight, width: b.width, height: toolRowHeight)
        bookmarksBar.isHidden = !bookmarksBarVisible
        if bookmarksBarVisible {
            bookmarksBar.frame = NSRect(x: 0, y: tabRowHeight + toolRowHeight, width: b.width, height: bookmarksRowHeight)
        }
        progressBar.frame = NSRect(x: 0, y: chromeTopHeight - 3, width: b.width, height: 3)

        findRow.frame = NSRect(x: 0, y: chromeTopHeight, width: b.width, height: findRowHeight)
        findRow.isHidden = !findVisible

        let chromeBottom = chromeTopHeight + findRowHeight
        chromeBackground.frame = NSRect(x: 0, y: 0, width: b.width, height: chromeBottom)
        hairline.frame = NSRect(x: 0, y: chromeBottom - 1, width: b.width, height: 1)

        let sidebarWidth = agentSidebarVisible ? min(agentSidebarWidth, max(300, b.width * 0.38)) : 0
        webContainer.frame = NSRect(x: 0, y: chromeBottom, width: max(0, b.width - sidebarWidth),
                                    height: max(0, b.height - chromeBottom))
        agentSidebar.frame = NSRect(x: b.width - sidebarWidth, y: chromeBottom, width: sidebarWidth,
                                    height: max(0, b.height - chromeBottom))
        agentSidebar.isHidden = !agentSidebarVisible
        startView.frame = webContainer.bounds
        activeTab?.webView?.frame = webContainer.bounds
        layoutLinkStatus()

        // Toolbar row internals. Buttons get a 30x28 hit area so the hover highlight
        // reads as a real target rather than a tight box around the glyph.
        let bw: CGFloat = 30, bh: CGFloat = 28
        let y = (toolRowHeight - bh) / 2
        backButton.frame = NSRect(x: 12, y: y, width: bw, height: bh)
        forwardButton.frame = NSRect(x: 44, y: y, width: bw, height: bh)
        reloadButton.frame = NSRect(x: 78, y: y, width: bw, height: bh)

        var right = b.width - 12
        if Config.shared.showMemoryReadout {
            statusPill.isHidden = false
            let w = max(64, min(190, statusPill.fittingWidth))
            statusPill.frame = NSRect(x: right - w, y: 0, width: w, height: toolRowHeight)
            right -= w + 4
        } else {
            statusPill.isHidden = true
        }
        let showAssistant = Config.shared.agentActive && !isPrivateWindow
        assistantButton.isHidden = !showAssistant
        if showAssistant {
            assistantButton.frame = NSRect(x: right - bw, y: y, width: bw, height: bh)
            right -= bw + 2
        }
        let showDownloads = !Downloads.shared.items.isEmpty
        downloadsButton.isHidden = !showDownloads
        if showDownloads {
            downloadsButton.frame = NSRect(x: right - bw, y: y, width: bw, height: bh)
            right -= bw + 2
        }
        shieldButton.frame = NSRect(x: right - bw, y: y, width: bw, height: bh)
        right -= bw + 2
        bookmarkButton.frame = NSRect(x: right - bw, y: y, width: bw, height: bh)
        right -= bw + 8

        let urlX: CGFloat = 116
        let fieldH: CGFloat = 28
        urlBar.frame = NSRect(x: urlX, y: (toolRowHeight - fieldH) / 2,
                              width: max(90, right - urlX), height: fieldH)

        // Find row internals
        if findVisible {
            findField.frame = NSRect(x: 14, y: 5, width: 250, height: 24)
            findPrevButton.frame = NSRect(x: 272, y: 5, width: 26, height: 24)
            findNextButton.frame = NSRect(x: 300, y: 5, width: 26, height: 24)
            findCount.frame = NSRect(x: 334, y: 9, width: 200, height: 16)
            findDoneButton.frame = NSRect(x: b.width - 78, y: 5, width: 64, height: 24)
        }
    }

    private func layoutLinkStatus() {
        guard !linkStatus.text.isEmpty else { linkStatus.isHidden = true; return }
        let area = webContainer.frame
        let w = linkStatus.fittingWidth(max: max(120, area.width * 0.6))
        linkStatus.frame = NSRect(x: area.minX + 4, y: area.maxY - 26, width: w, height: 22)
        linkStatus.isHidden = false
    }

    /// Called when a setting changes the shape of the chrome, such as the bookmarks bar.
    func chromeLayoutDidChange() {
        layoutChrome()
    }

    func windowDidResize(_ notification: Notification) {
        omnibox.hide()
        layoutChrome()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        activeTab?.lastActive = Date()
        Downloads.shared.statusHandler = { [weak self] msg in self?.showStatus(msg) }
        if agentSidebarVisible { agentSidebar.activate() }
    }

    func windowDidResignKey(_ notification: Notification) {
        omnibox.hide()
    }

    /// A window nobody can see does not need a live page. Its active tab may sleep after
    /// the usual idle time, and wakes the moment the window is visible again.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if isContentVisible {
            hiddenSince = nil
            if let tab = activeTab, tab.isHibernated, tab.hasEverLoaded || tab.url != nil {
                attachActiveTab()
                refreshChrome()
            }
        } else if hiddenSince == nil {
            hiddenSince = Date()
        }
    }

    func windowWillClose(_ notification: Notification) {
        omnibox.hide()
        saveSessionNow()
        if AppDelegate.shared?.isTerminating != true, let closing = sessionSnapshot() {
            RecentlyClosed.shared.add(window: closing)
        }
        hibernationTimer?.invalidate()
        memoryTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        AppDelegate.shared?.windowClosed(self)
    }

    func toggleAgentSidebar() {
        guard !isPrivateWindow else { showStatus("Assistant is unavailable in Private windows"); return }
        setAgentSidebarVisible(!agentSidebarVisible)
    }

    func setAgentSidebarVisible(_ visible: Bool) {
        guard !isPrivateWindow else { return }
        agentSidebarVisible = visible
        if visible { agentSidebar.activate() } else { agentSidebar.prepareToHide() }
        layoutChrome()
        if !visible { focusWebContent() }
    }

    @objc private func assistantButtonPressed() {
        guard Config.shared.agentActive else { showStatus("Assistant is disabled in Settings"); return }
        toggleAgentSidebar()
    }

    /// Opens the assistant with a prompt ready to send (context menu, page actions).
    func askAssistant(_ prompt: String) {
        guard !isPrivateWindow else { showStatus("Assistant is unavailable in Private windows"); return }
        guard Config.shared.agentActive else { showStatus("Assistant is disabled in Settings"); return }
        if !agentSidebarVisible { setAgentSidebarVisible(true) }
        agentSidebar.prefill(prompt)
    }

    // MARK: - Tabs

    @discardableResult
    func newTab(url: URL? = nil, activate: Bool = true, configuration: WKWebViewConfiguration? = nil,
                opener: Tab? = nil) -> Tab {
        let tab = Tab(url: url, isPrivate: isPrivateWindow, delegate: self, configuration: configuration)
        tab.opener = opener
        let index = insertionIndex(after: opener)
        tabs.insert(tab, at: index)
        // Keep the selection on the same tab, not the same slot.
        if tabs.count > 1, index <= activeIndex { activeIndex += 1 }
        // An opener-created tab must have its web view before we return it to WebKit.
        if configuration != nil {
            MemoryBudgetController.shared.prepareToActivate(tab)
            tab.ensureLoaded()
        }
        if activate {
            activeIndex = index
            attachActiveTab()
            if url == nil && configuration == nil { focusURLField() }
        }
        refreshChrome()
        scheduleSessionSave()
        return tab
    }

    /// Tabs opened from a link go right after their opener (and after its earlier
    /// children), the way Chrome places them; everything else goes at the end.
    private func insertionIndex(after opener: Tab?) -> Int {
        guard let opener, let i = tabs.firstIndex(where: { $0 === opener }) else { return tabs.count }
        var j = i + 1
        while j < tabs.count, tabs[j].opener === opener { j += 1 }
        return max(j, pinnedCount)
    }

    func restore(saved: [SavedTab], activeIndex idx: Int) {
        let restored = saved.map { Tab(saved: $0, delegate: self) }
        let active = restored.indices.contains(idx) ? restored[idx] : restored.first
        // Pinned tabs always lead the strip.
        tabs += restored.filter(\.isPinned) + restored.filter { !$0.isPinned }
        activeIndex = active.flatMap { a in tabs.firstIndex { $0 === a } } ?? 0
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
        if tab.url != nil, !isPrivateWindow { RecentlyClosed.shared.add(tab: tab.snapshot(), from: self) }
        let wasActive = index == activeIndex
        tab.webView?.removeFromSuperview()
        tab.hibernate()
        tabs.remove(at: index)
        if tabs.isEmpty {
            saveSessionNow()
            window?.close()
            return
        }
        if wasActive {
            // Like Chrome: closing the last tab a page opened returns to that page.
            if let opener = tab.opener, let o = tabs.firstIndex(where: { $0 === opener }),
               !(tabs.indices.contains(index) && tabs[index].opener === opener) {
                activeIndex = o
            } else {
                activeIndex = min(index, tabs.count - 1)
            }
        } else if index < activeIndex {
            activeIndex -= 1
        }
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    func closeActiveTab() { closeTab(index: activeIndex) }

    private func close(_ victims: [Tab]) {
        let keep = activeTab
        for tab in victims {
            if tab.url != nil, !isPrivateWindow { RecentlyClosed.shared.add(tab: tab.snapshot(), from: self) }
            tab.webView?.removeFromSuperview()
            tab.hibernate()
        }
        tabs.removeAll { t in victims.contains { $0 === t } }
        guard !tabs.isEmpty else { saveSessionNow(); window?.close(); return }
        activeIndex = keep.flatMap { k in tabs.firstIndex { $0 === k } } ?? min(activeIndex, tabs.count - 1)
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    /// Restores a closed tab with its history and scroll position intact.
    func reopen(_ saved: SavedTab) {
        let tab = Tab(saved: saved, delegate: self)
        let index = tab.isPinned ? pinnedCount : tabs.count
        tabs.insert(tab, at: index)
        activeIndex = index
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    func setPinned(_ pinned: Bool, for tab: Tab) {
        guard tab.isPinned != pinned, let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        let active = activeTab
        tabs.remove(at: i)
        tab.isPinned = pinned
        tabs.insert(tab, at: pinnedCount)
        activeIndex = active.flatMap { a in tabs.firstIndex { $0 === a } } ?? 0
        refreshChrome()
        scheduleSessionSave()
    }

    func duplicate(_ tab: Tab) {
        guard tab.url != nil, let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        var saved = tab.snapshot()
        saved.pinned = false
        let copy = Tab(saved: saved, delegate: self)
        let index = max(i + 1, pinnedCount)
        tabs.insert(copy, at: index)
        activeIndex = index
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    /// Hands a live tab to a brand-new window without reloading it.
    func moveTabToNewWindow(_ tab: Tab) {
        guard tabs.count > 1, tabs.contains(where: { $0 === tab }), let app = AppDelegate.shared else {
            showStatus("This is the only tab in the window"); return
        }
        detach(tab)
        app.makeBrowserWindow(isPrivate: isPrivateWindow).adopt(tab)
    }

    /// Dropping a dragged-out tab on another window's tab strip moves it there; anywhere else
    /// it gets a window of its own under the pointer. Either way the page moves live.
    func moveTab(_ tab: Tab, toScreenPoint point: NSPoint) {
        let others = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
            .filter { $0 !== self && $0.isPrivateWindow == isPrivateWindow }
        for target in others {
            guard let at = target.tabStripIndex(atScreenPoint: point) else { continue }
            detach(tab)
            target.adopt(tab, at: at)
            target.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard tabs.count > 1, let app = AppDelegate.shared else { return }
        detach(tab)
        let c = app.makeBrowserWindow(isPrivate: isPrivateWindow)
        c.adopt(tab)
        c.window?.setFrameTopLeftPoint(NSPoint(x: point.x - 80, y: point.y + 14))
    }

    /// Where on this window's tab strip a tab dropped at a screen point would land, if it
    /// is over the strip at all.
    func tabStripIndex(atScreenPoint point: NSPoint) -> Int? {
        guard let window, window.isVisible, window.frame.contains(point) else { return nil }
        let local = tabStrip.convert(window.convertPoint(fromScreen: point), from: nil)
        guard tabStrip.bounds.insetBy(dx: 0, dy: -8).contains(local) else { return nil }
        return tabStrip.insertionIndex(atX: local.x)
    }

    /// The tab strip's frame in screen coordinates.
    var tabStripScreenFrame: NSRect? {
        guard let window else { return nil }
        return window.convertToScreen(tabStrip.convert(tabStrip.bounds, to: nil))
    }

    /// Takes a tab out of this window, still awake, to move it to another. A window left
    /// with no tabs closes.
    private func detach(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        let wasActive = i == activeIndex
        tabs.remove(at: i)
        tab.webView?.removeFromSuperview()
        if tabs.isEmpty { saveSessionNow(); window?.close(); return }
        if wasActive { activeIndex = min(i, tabs.count - 1) } else if i < activeIndex { activeIndex -= 1 }
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    func adopt(_ tab: Tab, at requested: Int? = nil) {
        tab.delegate = self
        tab.opener = nil
        // Pinned tabs stay in the pinned section, others after it.
        let wanted = requested ?? tabs.count
        let index = tab.isPinned ? min(wanted, pinnedCount) : max(pinnedCount, min(wanted, tabs.count))
        tabs.insert(tab, at: index)
        activeIndex = index
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    /// Swap the visible web view. Waking a hibernated tab happens here.
    private func attachActiveTab() {
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        linkStatus.text = ""
        linkStatus.isHidden = true
        if findVisible { findCount.stringValue = "" }
        guard let tab = activeTab else { return }
        tab.lastActive = Date()
        MemoryBudgetController.shared.prepareToActivate(tab)

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

    /// Loads a URL in the current tab, or a new one when there is none.
    func open(_ url: URL, inNewTab: Bool = false) {
        if activeTab == nil || inNewTab { newTab(url: url); return }
        activeTab?.load(url)
        attachActiveTab()
        refreshChrome()
        focusWebContent()
        scheduleSessionSave()
    }

    // MARK: - Chrome refresh

    func refreshChrome() {
        layoutChrome()
        tabStrip.update(tabs: tabs, selected: activeIndex)

        guard let tab = activeTab else { return }
        // ToolbarButton handles its own enabled/disabled tinting.
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward

        reloadButton.setSymbol(tab.isLoading ? "xmark" : "arrow.clockwise")
        reloadButton.toolTip = tab.isLoading ? "Stop loading (\u{2318}.)" : "Reload (\u{2318}R)"
        progressBar.active = tab.isLoading && tab.progress < 1
        progressBar.progress = tab.progress

        if window?.firstResponder !== urlField.currentEditor() {
            let text = tab.url.map { u -> String in
                let s = u.absoluteString
                return s == "about:blank" ? "" : Store.displayForm(s)
            } ?? ""
            if urlField.stringValue != text { urlField.stringValue = text }
        }

        urlBar.showSecurity(for: tab.url)
        let bookmarked = tab.url.map { Store.shared.isBookmarked($0) } ?? false
        bookmarkButton.setSymbol(bookmarked ? "star.fill" : "star")
        bookmarkButton.isHighlighted2 = bookmarked
        bookmarkButton.isEnabled = tab.url != nil

        let blockingOn = Config.shared.blockAdsAndTrackers && ContentBlocker.ruleList != nil
        let siteExempt = SiteSettings.shared.isBlockingDisabled(for: tab.url)
        let blocking = blockingOn && !siteExempt
        shieldButton.isHighlighted2 = blocking
        shieldButton.setSymbol(blocking ? "shield.lefthalf.filled" : "shield.slash")
        shieldButton.toolTip = blocking
            ? "Blocking \(ContentBlocker.ruleCount) ad & tracker rules \u{2014} click for options"
            : blockingOn ? "Blocking is off for this site \u{2014} click for options"
            : "Ad & tracker blocking is off \u{2014} click for options"
        assistantButton.isHighlighted2 = agentSidebarVisible
        refreshDownloadsButton(layout: false)

        window?.title = tab.displayTitle
    }

    private func refreshDownloadsButton(layout: Bool = true) {
        let running = Downloads.shared.activeCount > 0
        downloadsButton.isRunning = running
        downloadsButton.fraction = Downloads.shared.aggregateFraction
        downloadsButton.toolTip = running
            ? "\(Downloads.shared.activeCount) download\(Downloads.shared.activeCount == 1 ? "" : "s") in progress"
            : "Downloads (\u{2318}\u{21E7}J)"
        if layout && downloadsButton.isHidden == !Downloads.shared.items.isEmpty { layoutChrome() }
    }

    // MARK: - Actions

    @objc func goBack() { activeTab?.goBack() }
    @objc func goForward() { activeTab?.goForward() }

    @objc func reloadOrStop() {
        guard let tab = activeTab else { return }
        tab.isLoading ? tab.stop() : tab.reload()
    }

    @objc func reload() { activeTab?.reload() }
    @objc func hardReload() { activeTab?.hardReload() }

    @objc func stopLoading() {
        guard let tab = activeTab, tab.isLoading else { return }
        tab.stop()
        refreshChrome()
    }

    private func historyMenu(back: Bool) -> NSMenu? {
        guard let tab = activeTab else { return nil }
        let menu = NSMenu()
        for item in tab.historyItems(back: back) {
            let title = (item.title?.isEmpty == false ? item.title! : Store.displayForm(item.url.absoluteString))
            let entry = ClosureMenuItem(Tab.abbreviate(title, 60)) { [weak tab] in tab?.go(to: item) }
            entry.image = isPrivateWindow ? nil : FaviconStore.shared.icon(forHost: item.url.host)
            menu.addItem(entry)
        }
        if !menu.items.isEmpty && !isPrivateWindow {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Show All History") { AppDelegate.shared?.showHistory() })
        }
        return menu
    }

    /// The shield's menu: blocking on this site, and blocking everywhere.
    @objc func showBlockingMenu() {
        let url = activeTab?.url
        let everywhere = Config.shared.blockAdsAndTrackers
        let exempt = SiteSettings.shared.isBlockingDisabled(for: url)
        let isWeb = url?.scheme == "http" || url?.scheme == "https"
        let host = isWeb ? SiteSettings.key(for: url) : nil
        let menu = NSMenu()
        menu.autoenablesItems = false
        let site = ClosureMenuItem(host.map { "Block Ads on \($0)" } ?? "Block Ads on This Site") {
            AppDelegate.shared?.setBlocking(enabled: exempt, forSiteOf: url)
        }
        site.state = everywhere && !exempt ? .on : .off
        // Private windows read site settings but never write them.
        site.isEnabled = everywhere && host != nil && !isPrivateWindow
        menu.addItem(site)
        let all = ClosureMenuItem("Block Ads and Trackers Everywhere") { [weak self] in self?.toggleBlocking() }
        all.state = everywhere ? .on : .off
        menu.addItem(all)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: shieldButton.isFlipped ? shieldButton.bounds.maxY + 4 : -4), in: shieldButton)
    }

    /// Puts a recompiled rule list into every live page, and reloads those on `site`.
    func contentRulesDidChange(reloadingSiteOf site: URL?) {
        let key = SiteSettings.key(for: site)
        for tab in tabs {
            guard let wv = tab.webView else { continue }
            ContentBlocker.install(in: wv.configuration.userContentController)
            if let host = SiteSettings.key(for: tab.url), let key, host == key || host.hasSuffix("." + key) { wv.reload() }
        }
        refreshChrome()
    }

    @objc func toggleBlocking() {
        Config.shared.blockAdsAndTrackers.toggle()
        Config.shared.save()
        if let app = AppDelegate.shared { app.contentBlockingSettingDidChange(); return }
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

    /// ⌘D and the star: bookmark the page at once, then show Chrome's bubble to name it, choose
    /// its folder, or remove it. A page already bookmarked opens the same bubble to edit.
    @objc func toggleBookmark() {
        guard let tab = activeTab, let u = tab.url else { return }
        let existing = Store.shared.bookmark(for: u)
        let node = existing ?? Store.shared.addBookmark(url: u, title: tab.title)
        let editor = BookmarkEditorController(node: node, isNew: existing == nil)
        editor.onFinish = { [weak self] in self?.transientPopover?.close() }
        // Semitransient, so the New Folder prompt does not dismiss it.
        present(editor, from: bookmarkButton.bounds, in: bookmarkButton, behavior: .semitransient)
    }

    @objc private func urlFieldCommitted() {
        omnibox.hide()
        let raw = urlField.stringValue
        guard let url = Config.shared.resolve(input: raw) else { return }
        // ⌘Return opens the result in a new tab, as in Chrome.
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        open(url, inNewTab: newTab)
    }

    // MARK: - Popovers

    private var transientPopover: NSPopover?

    /// One transient popover at a time; its content closes it when done.
    private func present(_ controller: NSViewController, from rect: NSRect, in view: NSView,
                         behavior: NSPopover.Behavior = .transient) {
        transientPopover?.close()
        let popover = NSPopover()
        popover.behavior = behavior
        popover.contentViewController = controller
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        transientPopover = popover
    }

    /// ⌘⇧A: search every open tab in windows of this kind.
    @objc func showTabSearch() {
        if let p = transientPopover, p.isShown, p.contentViewController is TabSearchController { p.close(); return }
        let kind = isPrivateWindow
        let controller = TabSearchController { [weak self] in
            (AppDelegate.shared?.allControllers ?? [self].compactMap { $0 }).filter { $0.isPrivateWindow == kind }
        }
        controller.onFinish = { [weak self] in self?.transientPopover?.close() }
        present(controller, from: NSRect(x: max(0, tabStrip.bounds.maxX - 44), y: 0, width: 44, height: tabStrip.bounds.height), in: tabStrip)
    }

    func showPageInfo() {
        guard let tab = activeTab, tab.url != nil else { return }
        let controller = PageInfoController(tab: tab, browser: self)
        controller.onFinish = { [weak self] in self?.transientPopover?.close() }
        present(controller, from: urlBar.siteInfoAnchor, in: urlBar)
    }

    private func revertAddressBar() {
        omnibox.hide()
        urlField.stringValue = activeTab?.url.map { Store.displayForm($0.absoluteString) } ?? ""
        focusWebContent()
    }

    @objc func zoomIn() { stepZoom(up: true) }
    @objc func zoomOut() { stepZoom(up: false) }

    @objc func zoomReset() {
        guard let tab = activeTab, tab.webView != nil else { return }
        tab.setPageZoom(1)
        showStatus("Zoom 100%")
    }

    private func stepZoom(up: Bool) {
        guard let tab = activeTab, tab.webView != nil else { return }
        let current = tab.pageZoom
        let next = up ? Self.zoomSteps.first { $0 > current + 0.001 } : Self.zoomSteps.last { $0 < current - 0.001 }
        guard let zoom = next else { return }
        tab.setPageZoom(zoom)
        showStatus("Zoom \(Int((zoom * 100).rounded()))%")
    }

    // MARK: - Page commands

    @objc func printPage() {
        guard let tab = activeTab, let wv = tab.webView, let window else { NSSound.beep(); return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        let op = wv.printOperation(with: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.jobTitle = tab.displayTitle
        // WKWebView prints blank pages unless its print view has a real frame.
        op.view?.frame = wv.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func suggestedFilename(_ ext: String) -> String {
        let base = (activeTab?.displayTitle ?? "Page")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return String(base.prefix(120)) + "." + ext
    }

    @objc func savePageAs() {
        guard let wv = activeTab?.webView, let window else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename("webarchive")
        panel.allowedContentTypes = [.webArchive]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let dest = panel.url else { return }
            wv.createWebArchiveData { result in
                switch result {
                case .success(let data):
                    do { try data.write(to: dest, options: .atomic); self?.showStatus("Saved \(dest.lastPathComponent)") }
                    catch { self?.showStatus("Couldn\u{2019}t save: \(error.localizedDescription)") }
                case .failure(let error):
                    self?.showStatus("Couldn\u{2019}t save: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc func exportPDF() {
        guard let wv = activeTab?.webView, let window else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename("pdf")
        panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let dest = panel.url else { return }
            wv.createPDF(configuration: WKPDFConfiguration()) { result in
                switch result {
                case .success(let data):
                    do { try data.write(to: dest, options: .atomic); self?.showStatus("Exported \(dest.lastPathComponent)") }
                    catch { self?.showStatus("Couldn\u{2019}t export: \(error.localizedDescription)") }
                case .failure(let error):
                    self?.showStatus("Couldn\u{2019}t export: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Opens Web Inspector for the current page (⌥⌘I). WebKit exposes this only as SPI,
    /// so fall back to the context-menu route when it is unavailable.
    @objc func showWebInspector() {
        guard Config.shared.enableDeveloperTools else { showStatus("Turn on developer tools in Settings"); return }
        guard let wv = activeTab?.webView else { return }
        let getter = NSSelectorFromString("_inspector")
        guard wv.responds(to: getter), let inspector = wv.perform(getter)?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: NSSelectorFromString("show")) else {
            showStatus("Right-click the page and choose Inspect Element"); return
        }
        inspector.perform(NSSelectorFromString("show"))
    }

    // MARK: - Downloads

    @objc func toggleDownloadsPopover() {
        if let popover = downloadsPopover, popover.isShown { popover.performClose(nil); return }
        guard !Downloads.shared.items.isEmpty else { Downloads.shared.revealFolder(); return }
        let controller = DownloadsViewController()
        controller.webViewProvider = { [weak self] in
            self?.activeTab?.webView ?? self?.tabs.first { !$0.isHibernated }?.webView
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        if downloadsButton.isHidden { layoutChrome() }
        popover.show(relativeTo: downloadsButton.bounds, of: downloadsButton,
                     preferredEdge: downloadsButton.isFlipped ? .maxY : .minY)
        downloadsPopover = popover
    }

    // MARK: - Find

    @objc func showFindBar() {
        findVisible = true
        layoutChrome()
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
        if !findField.stringValue.isEmpty { runFind(backwards: false) }
    }

    @objc func hideFindBar() {
        findVisible = false
        findCount.stringValue = ""
        findWork?.cancel()
        layoutChrome()
        focusWebContent()
    }

    /// ⌘E: search for whatever is selected on the page.
    @objc func useSelectionForFind() {
        activeTab?.webView?.evaluateJavaScript("String(getSelection() || '')") { [weak self] result, _ in
            guard let self, let text = result as? String else { return }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { NSSound.beep(); return }
            self.findField.stringValue = String(clean.prefix(200))
            self.findVisible = true
            self.layoutChrome()
            self.runFind(backwards: false)
        }
    }

    @objc func findNext() { runFind(backwards: false) }
    @objc func findPrevious() { runFind(backwards: true) }

    private func scheduleIncrementalFind() {
        findWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runFind(backwards: false) }
        findWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func runFind(backwards: Bool) {
        guard let wv = activeTab?.webView else { return }
        let query = findField.stringValue
        guard !query.isEmpty else { findCount.stringValue = ""; return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.caseSensitive = false
        cfg.wraps = true
        wv.find(query, configuration: cfg) { [weak self, weak wv] result in
            guard let self, let wv, self.findField.stringValue == query else { return }
            guard result.matchFound else {
                self.findCount.textColor = .systemRed
                self.findCount.stringValue = "No matches"
                return
            }
            self.countMatches(query, in: wv)
        }
    }

    /// WebKit's public find API reports only found / not found, so count in the page text.
    private func countMatches(_ query: String, in wv: WKWebView) {
        let js = """
        (() => { const q = \(Tab.jsLiteral(query.lowercased())); const t = (document.body ? document.body.innerText : '').toLowerCase();
        let n = 0, i = 0; while ((i = t.indexOf(q, i)) !== -1 && n < 1000) { n++; i += q.length; } return n; })()
        """
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, self.findField.stringValue == query else { return }
            let n = max(1, (result as? NSNumber)?.intValue ?? 1)
            self.findCount.textColor = .secondaryLabelColor
            self.findCount.stringValue = n >= 1000 ? "1000+ matches" : "\(n) match\(n == 1 ? "" : "es")"
        }
    }

    // MARK: - Hibernation

    private func startHibernationTimer() {
        hibernationTimer?.invalidate()
        guard Config.shared.hibernateAfterMinutes > 0 else { return }
        hibernationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.hibernateIdleTabs()
        }
        hibernationTimer?.tolerance = 5
    }

    private func hibernateIdleTabs() {
        let threshold = Config.shared.hibernateAfterMinutes * 60
        var slept = 0
        for (i, tab) in tabs.enumerated() {
            if i == activeIndex {
                // The page on screen never sleeps; the one in a window nobody can see may.
                guard let since = hiddenSince, !isContentVisible,
                      Date().timeIntervalSince(since) >= threshold, tab.canHibernateForBudget else { continue }
                tab.hibernate(); slept += 1
            } else if tab.canHibernate(idleFor: threshold) {
                tab.hibernate(); slept += 1
            }
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
            if tab.canHibernateForBudget { tab.hibernate(); slept += 1 }
        }
        refreshChrome()
        showStatus(slept == 0 ? "Nothing to sleep" : "Slept \(slept) tab\(slept == 1 ? "" : "s")")
    }

    // MARK: - Memory readout

    private func startMemoryReadout() {
        memoryTimer?.invalidate()
        memoryTimer = nil
        guard Config.shared.showMemoryReadout else {
            statusPill.isHidden = true
            layoutChrome()
            return
        }
        updateMemoryReadout()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self, self.isContentVisible else { return }
            self.updateMemoryReadout()
        }
        memoryTimer?.tolerance = 2
    }

    private func updateMemoryReadout() {
        guard statusResetWork == nil else { return }   // a transient message is showing
        let s = MemoryBudgetController.shared.sample(maxAge: 1.0)
        let sleeping = MemoryBudgetController.shared.sleepingTabCount
        var text = MemoryBudgetController.shared.budgetDisplay(sample: s)
        if sleeping > 0 { text += " \u{00B7} \(sleeping) asleep" }
        statusPill.text = text
        let budgetNote = MemoryBudgetController.shared.isEnabled ? " \u{00B7} target \(Config.shared.memoryBudgetMB) MB" : ""
        statusPill.toolTip = "\(s.display) total\(budgetNote) \u{2014} app \(ByteCountFormatter.string(fromByteCount: Int64(s.appBytes), countStyle: .memory)) + \(s.helperCount) web process\(s.helperCount == 1 ? "" : "es"). Click for the Task Manager."
        layoutChrome()
    }

    func memoryBudgetDidChange() {
        if Config.shared.showMemoryReadout { updateMemoryReadout() }
        refreshChrome()
    }

    func settingsDidChange() {
        startHibernationTimer()
        startMemoryReadout()
        refreshChrome()
        layoutChrome()
    }

    func contentBlockingSettingDidChange() {
        reloadAllForRuleChange()
    }

    func showStatus(_ message: String) {
        statusResetWork?.cancel()
        statusPill.text = message
        layoutChrome()
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

    func sessionSnapshot() -> SavedWindow? {
        guard !isPrivateWindow else { return nil }
        let saved = tabs.filter { $0.url != nil }
        let snapshots = saved.map { $0.snapshot() }
        guard !snapshots.isEmpty else { return nil }
        let active = activeTab.flatMap { a in saved.firstIndex { $0 === a } } ?? min(activeIndex, snapshots.count - 1)
        return SavedWindow(tabs: snapshots, activeIndex: active, frame: window?.frame)
    }

    func saveSessionNow() {
        guard !isPrivateWindow else { return }
        AppDelegate.shared?.saveApplicationSession()
        Store.shared.flush()
    }

    // MARK: - Omnibox

    private func omniboxTabs() -> [(id: UUID, title: String, url: URL)] {
        let windows = (AppDelegate.shared?.allControllers ?? [self]).filter { $0.isPrivateWindow == isPrivateWindow }
        let current = activeTab
        return windows.flatMap { w in
            w.tabs.compactMap { t -> (id: UUID, title: String, url: URL)? in
                guard t !== current, let url = t.url else { return nil }
                return (id: t.id, title: t.displayTitle, url: url)
            }
        }
    }

    private func updateOmnibox() {
        guard let editor = urlField.currentEditor() as? NSTextView else { return }
        let text = editor.string
        let length = (text as NSString).length
        // Backspacing must never re-complete what the user is deleting.
        let deleting = text.count <= omniboxTypedLength
        omniboxTypedLength = text.count
        omniboxTyped = text
        var completion: String?
        let selection = editor.selectedRange()
        if !deleting, selection.location == length, selection.length == 0,
           let c = Omnibox.inlineCompletion(for: text) {
            completion = c
            editor.string = c
            editor.setSelectedRange(NSRange(location: length, length: (c as NSString).length - length))
        }
        let items = Omnibox.suggestions(for: text, completion: completion, openTabs: omniboxTabs())
        if items.isEmpty { omnibox.hide() } else { omnibox.show(items, below: urlBar) }
    }

    private func activateSuggestion(at index: Int) {
        guard omnibox.suggestions.indices.contains(index) else { return }
        let suggestion = omnibox.suggestions[index]
        omnibox.hide()
        if suggestion.kind == .openTab, let id = suggestion.tabID {
            switchToTab(id: id)
        } else if let url = suggestion.url {
            open(url)
        }
    }

    /// "Switch to Tab": bring that tab forward, and drop the empty tab it was typed into.
    private func switchToTab(id: UUID) {
        let blank = activeTab.flatMap { $0.url == nil && !$0.hasEverLoaded ? $0 : nil }
        for controller in AppDelegate.shared?.allControllers ?? [self] {
            guard let i = controller.tabs.firstIndex(where: { $0.id == id }) else { continue }
            controller.window?.makeKeyAndOrderFront(nil)
            controller.selectTab(index: i)
            if let blank, let j = tabs.firstIndex(where: { $0 === blank }) { closeTab(index: j) }
            return
        }
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
        let newOne = newTab(url: url, activate: activate, configuration: configuration, opener: tab)
        if !activate && configuration == nil {
            // A background tab from a link starts loading now, so it is ready when clicked.
            MemoryBudgetController.shared.prepareToActivate(newOne)
            newOne.lastActive = Date()
            newOne.ensureLoaded()
            tabStrip.update(tabs: tabs, selected: activeIndex)
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

    func tab(_ tab: Tab, didHoverLink url: URL?) {
        guard tab === activeTab else { return }
        linkStatus.text = url?.absoluteString ?? ""
        layoutLinkStatus()
    }

    func tab(_ tab: Tab, openInNewWindow url: URL, isPrivate: Bool) {
        AppDelegate.shared?.openInNewWindow(url, isPrivate: isPrivate)
    }

    func tab(_ tab: Tab, askAssistant prompt: String) {
        askAssistant(prompt)
    }

    /// A login was submitted: offer to save or update it, unless it is already saved unchanged
    /// or the site was declined. Only the visible tab prompts.
    func tab(_ tab: Tab, didSubmitLogin username: String, password: String, on url: URL) {
        guard tab === activeTab, !SiteSettings.shared.isSavePasswordSuppressed(for: url) else { return }
        let decision = PasswordStore.shared.decision(url: url, username: username, password: password)
        guard decision != .ignore else { return }
        let host = PasswordStore.key(for: url) ?? url.host ?? ""
        let prompt = PasswordPromptController(host: host, username: username, password: password,
                                              mode: decision == .update ? .update : .save)
        prompt.onSave = { [weak self] name, secret in
            PasswordStore.shared.save(url: url, username: name, password: secret)
            self?.showStatus(decision == .update ? "Password updated" : "Password saved")
        }
        prompt.onNever = { SiteSettings.shared.setSavePasswordSuppressed(true, for: url) }
        prompt.onFinish = { [weak self] in self?.transientPopover?.close() }
        present(prompt, from: bookmarkButton.bounds, in: bookmarkButton, behavior: .semitransient)
    }

    func tabRequestsAttention(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }), idx != activeIndex else { return }
        selectTab(index: idx)
    }

    func presentingWindow(for tab: Tab) -> NSWindow? { window }
}

extension BrowserWindowController: TabStripDelegate {
    func tabStripDidSelect(index: Int) { selectTab(index: index) }
    func tabStripDidRequestClose(index: Int) { closeTab(index: index) }
    func tabStripDidRequestNewTab() { newTab() }
    func tabStripDidDetach(index: Int, at screenPoint: NSPoint) {
        guard tabs.indices.contains(index) else { return }
        moveTab(tabs[index], toScreenPoint: screenPoint)
    }

    func tabStripDidToggleMute(index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].isMuted.toggle()
    }

    func tabStripDidRequestMove(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let moved = tabs[from]
        let pinned = pinnedCount
        // Pinned and unpinned tabs each stay in their own section.
        guard moved.isPinned ? to < pinned : to >= pinned else { return }
        let active = activeTab
        tabs.remove(at: from)
        tabs.insert(moved, at: to)
        // Keep the selection on the same tab, not the same slot.
        activeIndex = active.flatMap { a in tabs.firstIndex { $0 === a } } ?? activeIndex
        refreshChrome()
        scheduleSessionSave()
    }

    /// Handlers capture the Tab itself, not its index, so a menu left open while tabs
    /// move around cannot act on the wrong one.
    func tabStripContextActions(index: Int) -> [(String, () -> Void)] {
        guard tabs.indices.contains(index) else { return [] }
        let tab = tabs[index]
        var items: [(String, () -> Void)] = []

        items.append(("Reload", { [weak self] in
            tab.reload(); self?.refreshChrome()
        }))
        if tab.url != nil {
            items.append(("Duplicate Tab", { [weak self] in self?.duplicate(tab) }))
        }
        items.append((tab.isPinned ? "Unpin Tab" : "Pin Tab", { [weak self] in
            self?.setPinned(!tab.isPinned, for: tab)
        }))
        items.append((tab.isMuted ? "Unmute Tab" : "Mute Tab", { tab.isMuted.toggle() }))
        if let u = tab.url {
            items.append(("Copy Address", {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(u.absoluteString, forType: .string)
            }))
        }
        items.append(("-", {}))
        items.append((tab.keepAwake ? "Allow Tab to Sleep" : "Keep Tab Awake", { [weak self] in
            tab.keepAwake.toggle()
            self?.refreshChrome()
            self?.showStatus(tab.keepAwake ? "Tab will stay awake" : "Tab can sleep again")
        }))
        if !tab.isHibernated {
            items.append(("Put Tab to Sleep", { [weak self] in
                guard let self else { return }
                // Never tear down the tab currently on screen.
                if tab === self.activeTab { self.showStatus("Can\u{2019}t sleep the active tab"); return }
                if !tab.canHibernateForBudget { self.showStatus("Tab is protected or playing media"); return }
                tab.hibernate()
                self.refreshChrome()
            }))
        }
        if tabs.count > 1 {
            items.append(("-", {}))
            items.append(("Move Tab to New Window", { [weak self] in self?.moveTabToNewWindow(tab) }))
        }
        items.append(("-", {}))
        items.append(("Close Tab", { [weak self] in
            guard let self, let i = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.closeTab(index: i)
        }))
        if tabs.count > 1 {
            items.append(("Close Other Tabs", { [weak self] in
                guard let self else { return }
                // Pinned tabs are kept, as in Chrome.
                self.close(self.tabs.filter { $0 !== tab && !$0.isPinned })
                if let i = self.tabs.firstIndex(where: { $0 === tab }) { self.selectTab(index: i) }
            }))
        }
        if index < tabs.count - 1 {
            items.append(("Close Tabs to the Right", { [weak self] in
                guard let self, let i = self.tabs.firstIndex(where: { $0 === tab }) else { return }
                self.close(Array(self.tabs[(i + 1)...]).filter { !$0.isPinned })
            }))
        }
        return items
    }
}

extension BrowserWindowController: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === urlField else { return }
        urlBar.setFocused(true)
        omniboxTypedLength = 0
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === urlField else { return }
        urlBar.setFocused(false)
        omnibox.hide()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === urlField { updateOmnibox() }
        else if field === findField { scheduleIncrementalFind() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === findField {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                hideFindBar(); return true
            case #selector(NSResponder.insertNewline(_:)):
                findWork?.cancel()
                runFind(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true
            default:
                return false
            }
        }
        guard control === urlField else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard omnibox.isVisible,
                  let row = omnibox.move(selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1) else { return false }
            textView.string = row.fillText
            textView.setSelectedRange(NSRange(location: (row.fillText as NSString).length, length: 0))
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if omnibox.isVisible, omnibox.selectedIndex > 0 {
                activateSuggestion(at: omnibox.selectedIndex); return true
            }
            omnibox.hide()
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            // First Escape closes the dropdown and restores what was typed; the second
            // restores the page address and returns focus to the page.
            if omnibox.isVisible {
                omnibox.hide()
                textView.string = omniboxTyped
                textView.setSelectedRange(NSRange(location: (omniboxTyped as NSString).length, length: 0))
                return true
            }
            revertAddressBar()
            return true
        default:
            return false
        }
    }
}
