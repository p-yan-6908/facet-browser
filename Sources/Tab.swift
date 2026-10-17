import AppKit
import WebKit

protocol TabDelegate: AnyObject {
    func tabDidChangeState(_ tab: Tab)
    func tab(_ tab: Tab, openNewTabWith url: URL?, configuration: WKWebViewConfiguration?, activate: Bool) -> Tab?
    func tabRequestsClose(_ tab: Tab)
    func tabStatus(_ tab: Tab, message: String?)
    func tab(_ tab: Tab, didHoverLink url: URL?)
    func tab(_ tab: Tab, openInNewWindow url: URL, isPrivate: Bool)
    func tab(_ tab: Tab, askAssistant prompt: String)
    /// A background tab needs the user (a JavaScript dialog), so bring it forward.
    func tabRequestsAttention(_ tab: Tab)
    func presentingWindow(for tab: Tab) -> NSWindow?
}

extension TabDelegate {
    func tab(_ tab: Tab, didHoverLink url: URL?) {}
    func tab(_ tab: Tab, openInNewWindow url: URL, isPrivate: Bool) {}
    func tab(_ tab: Tab, askAssistant prompt: String) {}
    func tabRequestsAttention(_ tab: Tab) {}
    func presentingWindow(for tab: Tab) -> NSWindow? { nil }
}

/// Shared WebKit plumbing. A single data store across every tab means one cookie
/// and cache jar; WebKit itself decides how to pool content processes.
enum WebKitEnv {
    /// Matches the installed Safari, so sites that gate features on the version string
    /// see a current browser.
    static let safariVersion: String = {
        let full = Bundle(path: "/Applications/Safari.app")?
            .infoDictionary?["CFBundleShortVersionString"] as? String ?? "26.0"
        let parts = full.split(separator: ".").prefix(2)
        return parts.count == 2 ? parts.joined(separator: ".") : "\(full).0"
    }()

    /// One ephemeral store for every private window, so private tabs share a sign-in the
    /// way Chrome's incognito windows do. Dropped when the last private window closes.
    private static var privateStore: WKWebsiteDataStore?

    static func dataStore(private isPrivate: Bool) -> WKWebsiteDataStore {
        guard isPrivate else { return .default() }
        if let privateStore { return privateStore }
        let store = WKWebsiteDataStore.nonPersistent()
        privateStore = store
        return store
    }

    static func discardPrivateStore() { privateStore = nil }

    static func makeConfiguration(private isPrivate: Bool = false) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = dataStore(private: isPrivate)
        // Identify as Safari: many sites gate features on the UA and WKWebView's
        // default string has no Version/Safari suffix.
        cfg.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        // No autoplay. This alone removes a large share of background CPU and decode memory.
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.suppressesIncrementalRendering = false
        cfg.preferences.isFraudulentWebsiteWarningEnabled = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Without this the fullscreen button in YouTube and other players does nothing.
        if #available(macOS 12.3, *) { cfg.preferences.isElementFullscreenEnabled = true }
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        ContentBlocker.install(in: cfg.userContentController)
        PageBridge.install(in: cfg.userContentController)
        return cfg
    }
}

final class Tab: NSObject {
    let id = UUID()
    weak var delegate: TabDelegate?
    let isPrivate: Bool

    /// nil while hibernated. Creating this is what allocates a WebKit content process.
    private(set) var webView: WKWebView?

    var url: URL?
    var title: String = ""
    var favicon: NSImage?
    var isLoading = false
    var progress: Double = 0
    var lastActive = Date()
    var isHibernated: Bool { webView == nil }
    var hasEverLoaded = false

    /// Pinned tabs sit compactly at the left of the strip and survive restarts.
    var isPinned = false
    /// The tab whose link opened this one, so link-opened tabs land beside their opener.
    weak var opener: Tab?
    var isMuted = false {
        didSet { guard oldValue != isMuted else { return }; applyMute(); delegate?.tabDidChangeState(self) }
    }
    private(set) var isPlayingAudio = false
    private(set) var hoveredLink: URL?
    private(set) var pageContext: PageContext?
    /// Set while the tab shows Facet's own error page, so Reload retries the real URL.
    private(set) var errorURL: URL?
    private var errorNavigation: WKNavigation?
    /// The address being loaded, kept because WebKit forgets it when the load fails.
    private var provisionalURL: URL?
    private var crashTimes: [Date] = []
    private var dialogCount = 0
    private var dialogsSuppressed = false
    private var observingAudio = false
    private static var audioContext = 0

    /// User and agent retention state. These are intentionally tiny and remain while
    /// the renderer is gone.
    var keepAwake = false
    private(set) var agentLeaseCount = 0
    var isAgentLeased: Bool { agentLeaseCount > 0 }
    private(set) var semanticState: TabSemanticState?
    private var lastAgentElements: [String: AgentElement] = [:]

    /// Full session snapshot (back/forward list + scroll offset) kept while hibernated.
    private var savedInteractionState: Data?
    private var pendingURL: URL?
    /// For window.open/target=_blank: WebKit requires the new web view be built from the
    /// exact configuration it handed us, and it performs the navigation itself.
    private var providedConfiguration: WKWebViewConfiguration?
    private var webKitWillLoad = false
    private var observations: [NSKeyValueObservation] = []

    /// Replaced in tests. The default asks with a native sign-in sheet.
    static var credentialPrompt: (URLProtectionSpace, Int, NSWindow?, @escaping (URLCredential?) -> Void) -> Void
        = Tab.presentCredentialSheet

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return "New Tab"
    }

    init(url: URL?, isPrivate: Bool = false, delegate: TabDelegate?,
         configuration: WKWebViewConfiguration? = nil) {
        self.isPrivate = isPrivate
        self.delegate = delegate
        self.url = url
        self.pendingURL = url
        self.providedConfiguration = configuration
        self.webKitWillLoad = (configuration != nil)
        super.init()
        if !isPrivate, let url { self.favicon = FaviconStore.shared.icon(forHost: url.host) }
    }

    /// Restore from a previous session without spending a web process yet.
    init(saved: SavedTab, delegate: TabDelegate?) {
        self.isPrivate = false
        self.delegate = delegate
        self.url = URL(string: saved.url)
        self.title = saved.title
        self.isPinned = saved.pinned
        self.savedInteractionState = saved.interactionState
        self.pendingURL = URL(string: saved.url)
        super.init()
        self.favicon = FaviconStore.shared.icon(forHost: self.url?.host)
    }

    func snapshot() -> SavedTab {
        SavedTab(url: url?.absoluteString ?? "",
                 title: title,
                 interactionState: liveInteractionState() ?? savedInteractionState,
                 pinned: isPinned)
    }

    private func liveInteractionState() -> Data? {
        webView?.interactionState as? Data
    }

    // MARK: - Lifecycle

    /// Creates the web view on demand. Called when the tab is first shown or woken.
    @discardableResult
    func ensureLoaded() -> WKWebView {
        if let webView { return webView }

        let cfg = providedConfiguration ?? WebKitEnv.makeConfiguration(private: isPrivate)
        providedConfiguration = nil
        let wv = FacetWebView(frame: .zero, configuration: cfg)
        wv.owner = self
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.allowsLinkPreview = true
        wv.autoresizingMask = [.width, .height]
        if Config.shared.enableDeveloperTools, #available(macOS 13.3, *) { wv.isInspectable = true }
        webView = wv
        observe(wv)
        if isMuted { applyMute() }

        if webKitWillLoad {
            // WebKit drives the first navigation for opener-created views.
            webKitWillLoad = false
        } else if let state = savedInteractionState {
            // Restores the whole back/forward list and scroll position, then refetches.
            wv.interactionState = state
            savedInteractionState = nil
            if wv.url == nil, let u = pendingURL { wv.load(URLRequest(url: u)) }
        } else if let u = pendingURL {
            wv.load(URLRequest(url: u))
        }
        pendingURL = nil
        hasEverLoaded = true
        return wv
    }

    /// Tears the web process down entirely, keeping only enough state to come back.
    /// This is the difference between a background tab costing ~100 MB and ~2 KB.
    func hibernate() {
        guard let wv = webView else { return }
        if wv.url != nil { url = wv.url }
        savedInteractionState = liveInteractionState()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        stopObservingAudio(wv)
        (wv as? FacetWebView)?.owner = nil
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        wv.stopLoading()
        wv.removeFromSuperview()
        webView = nil
        isLoading = false
        progress = 0
        isPlayingAudio = false
        hoveredLink = nil
        pendingURL = url
        delegate?.tabDidChangeState(self)
    }

    /// True when this tab is safe to hibernate right now.
    func canHibernate(idleFor seconds: TimeInterval) -> Bool {
        guard canHibernateForBudget else { return false }
        return Date().timeIntervalSince(lastActive) >= seconds
    }

    /// Budget eviction is allowed only for ordinary background pages.
    var canHibernateForBudget: Bool {
        guard webView != nil, !keepAwake, !isAgentLeased else { return false }
        return !isPlayingMedia
    }

    /// The WebKit content process rendering this tab, or nil while it sleeps. WebKit only
    /// exposes this as SPI, so it is guarded: without it the Task Manager shows totals only.
    var webProcessID: pid_t? {
        guard let wv = webView, wv.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (wv.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    /// Chrome-style hover text: the title, then the site and what the tab costs right now.
    var hoverDescription: String {
        let site = url?.host ?? ""
        var cost = ""
        if isHibernated { cost = hasEverLoaded || url != nil ? "asleep, using no memory" : "" }
        else if let pid = webProcessID {
            cost = ByteCountFormatter.string(fromByteCount: Int64(MemoryMonitor.footprint(of: pid)), countStyle: .memory)
        }
        let detail = [site, cost].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        return detail.isEmpty ? displayTitle : "\(displayTitle)\n\(detail)"
    }

    func acquireAgentLease() { agentLeaseCount += 1 }
    /// The element a ref named in the last snapshot, for judging how risky acting on it is.
    func agentElement(ref: String) -> AgentElement? { lastAgentElements[ref] }
    func releaseAgentLease() { agentLeaseCount = max(0, agentLeaseCount - 1) }

    private var isPlayingMedia: Bool {
        // Never kill a tab that is capturing or playing.
        guard let wv = webView else { return false }
        if wv.cameraCaptureState != .none || wv.microphoneCaptureState != .none { return true }
        if isPlayingAudio { return true }
        let sel = Selector(("_isPlayingAudio"))
        guard wv.responds(to: sel) else { return false }
        return wv.value(forKey: "_isPlayingAudio") as? Bool ?? false
    }

    func load(_ url: URL) {
        self.url = url
        savedInteractionState = nil
        errorURL = nil
        if let wv = webView {
            wv.load(URLRequest(url: url))
        } else {
            pendingURL = url
            ensureLoaded()
        }
    }

    /// Ordinary reload, revalidating against the cache like Chrome's ⌘R. On Facet's own
    /// error page it retries the URL that failed rather than reloading the error page.
    func reload() {
        guard let wv = webView else { ensureLoaded(); return }
        if let failed = errorURL { errorURL = nil; wv.load(URLRequest(url: failed)); return }
        wv.reload()
    }

    /// Bypasses the cache (⌘⇧R).
    func hardReload() {
        guard let wv = webView else { ensureLoaded(); return }
        if let failed = errorURL { errorURL = nil; wv.load(URLRequest(url: failed)); return }
        wv.reloadFromOrigin()
    }

    func stop() { webView?.stopLoading() }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    var canGoBack: Bool { webView?.canGoBack ?? false }
    var canGoForward: Bool { webView?.canGoForward ?? false }

    /// Most recent first, for the long-press menus on Back and Forward.
    func historyItems(back: Bool, limit: Int = 15) -> [WKBackForwardListItem] {
        guard let list = webView?.backForwardList else { return [] }
        return Array((back ? list.backList.reversed() : list.forwardList).prefix(limit))
    }

    func go(to item: WKBackForwardListItem) { webView?.go(to: item) }

    // MARK: - Zoom

    var pageZoom: CGFloat { webView?.pageZoom ?? 1 }

    /// Zoom is remembered per site, as in Chrome. Private tabs use it but never save it.
    func setPageZoom(_ zoom: CGFloat) {
        guard let wv = webView else { return }
        wv.pageZoom = zoom
        if !isPrivate { SiteSettings.shared.setZoom(Double(zoom), for: wv.url ?? url) }
    }

    private func applySiteZoom(_ wv: WKWebView) {
        let zoom = CGFloat(SiteSettings.shared.zoom(for: wv.url) ?? 1)
        if abs(wv.pageZoom - zoom) > 0.001 { wv.pageZoom = zoom }
    }

    // MARK: - Audio

    /// WebKit has no public mute API. `_setPageMuted:` is the SPI Safari uses; when it is
    /// missing, muting the page's media elements is the best available fallback.
    private func applyMute() {
        guard let wv = webView else { return }
        let sel = NSSelectorFromString("_setPageMuted:")
        if wv.responds(to: sel), let method = class_getInstanceMethod(type(of: wv), sel) {
            typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
            unsafeBitCast(method_getImplementation(method), to: SetMuted.self)(wv, sel, isMuted ? 1 : 0)
        } else {
            wv.evaluateJavaScript("document.querySelectorAll('audio,video').forEach(m => m.muted = \(isMuted))")
        }
    }

    private func startObservingAudio(_ wv: WKWebView) {
        guard !observingAudio, wv.responds(to: NSSelectorFromString("_isPlayingAudio")) else { return }
        wv.addObserver(self, forKeyPath: "_isPlayingAudio", options: [.new], context: &Tab.audioContext)
        observingAudio = true
    }

    private func stopObservingAudio(_ wv: WKWebView) {
        guard observingAudio else { return }
        wv.removeObserver(self, forKeyPath: "_isPlayingAudio", context: &Tab.audioContext)
        observingAudio = false
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard context == &Tab.audioContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context); return
        }
        let playing = (object as? WKWebView)?.value(forKey: "_isPlayingAudio") as? Bool ?? false
        guard playing != isPlayingAudio else { return }
        isPlayingAudio = playing
        delegate?.tabDidChangeState(self)
    }

    // MARK: - Observation

    private func observe(_ wv: WKWebView) {
        func note() { delegate?.tabDidChangeState(self) }
        observations = [
            wv.observe(\.title, options: [.new]) { [weak self] w, _ in
                guard let self else { return }
                if let t = w.title, !t.isEmpty {
                    self.title = t
                    if !self.isPrivate, self.errorURL == nil, let u = w.url { Store.shared.updateTitle(url: u, title: t) }
                }
                note()
            },
            wv.observe(\.url, options: [.new]) { [weak self] w, _ in
                // A failed load briefly reports nil; keep the last real address instead.
                guard let self, let u = w.url else { return }
                self.url = u
                note()
            },
            wv.observe(\.isLoading, options: [.new]) { [weak self] w, _ in
                guard let self else { return }
                self.isLoading = w.isLoading
                note()
            },
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                guard let self else { return }
                self.progress = w.estimatedProgress
                note()
            },
            wv.observe(\.canGoBack, options: [.new]) { _, _ in note() },
            wv.observe(\.canGoForward, options: [.new]) { _, _ in note() },
        ]
        startObservingAudio(wv)
    }

    deinit {
        observations.forEach { $0.invalidate() }
        if let wv = webView { stopObservingAudio(wv) }
    }

    // MARK: - Page bridge and context menu

    func handleBridgeMessage(_ body: [String: Any]) {
        func url(_ key: String) -> URL? {
            guard let s = body[key] as? String, !s.isEmpty, let u = URL(string: s),
                  let scheme = u.scheme?.lowercased(), ["http", "https", "file", "data", "blob"].contains(scheme) else { return nil }
            return u
        }
        switch body["t"] as? String {
        case "hover":
            let link = url("href")
            guard link != hoveredLink else { return }
            hoveredLink = link
            delegate?.tab(self, didHoverLink: link)
        case "context":
            let selection = (body["selection"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            pageContext = PageContext(link: url("href"), image: url("image"), selection: selection, at: Date())
        default:
            break
        }
    }

    /// Reworks WebKit's default context menu toward Chrome's: links open in background tabs,
    /// downloads and web searches go through Facet, and selections can go to the assistant.
    func customizeContextMenu(_ menu: NSMenu) {
        let context = pageContext.flatMap { Date().timeIntervalSince($0.at) < 3 ? $0 : nil }
        pageContext = nil
        let link = context?.link
        let image = context?.image
        let selection = context?.selection ?? ""

        func replace(_ index: Int, with items: [NSMenuItem]) {
            menu.removeItem(at: index)
            for (offset, item) in items.enumerated() { menu.insertItem(item, at: index + offset) }
        }
        func openTab(_ url: URL, activate: Bool) -> () -> Void {
            { [weak self] in guard let self else { return }; _ = self.delegate?.tab(self, openNewTabWith: url, configuration: nil, activate: activate) }
        }

        for (index, item) in menu.items.enumerated().reversed() {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow":
                guard let link else { continue }
                var items: [NSMenuItem] = [
                    ClosureMenuItem("Open Link in New Tab", handler: openTab(link, activate: false)),
                    ClosureMenuItem("Open Link in New Window") { [weak self] in
                        guard let self else { return }; self.delegate?.tab(self, openInNewWindow: link, isPrivate: self.isPrivate)
                    },
                ]
                if !isPrivate {
                    items.append(ClosureMenuItem("Open Link in Private Window") { [weak self] in
                        guard let self else { return }; self.delegate?.tab(self, openInNewWindow: link, isPrivate: true)
                    })
                }
                replace(index, with: items)
            case "WKMenuItemIdentifierOpenImageInNewWindow":
                guard let image else { continue }
                replace(index, with: [ClosureMenuItem("Open Image in New Tab", handler: openTab(image, activate: false))])
            case "WKMenuItemIdentifierDownloadLinkedFile":
                guard let link else { continue }
                replace(index, with: [ClosureMenuItem(item.title) { [weak self] in self?.download(link) }])
            case "WKMenuItemIdentifierDownloadImage":
                guard let image else { continue }
                replace(index, with: [ClosureMenuItem(item.title) { [weak self] in self?.download(image) }])
            case "WKMenuItemIdentifierSearchWeb":
                guard !selection.isEmpty, let search = Config.shared.searchURL(for: selection) else { continue }
                let title = "Search \(Config.shared.searchEngineName) for \u{201C}\(Self.abbreviate(selection, 28))\u{201D}"
                replace(index, with: [ClosureMenuItem(title, handler: openTab(search, activate: true))])
            default:
                break
            }
        }

        guard !isPrivate, Config.shared.agentActive else { return }
        menu.addItem(.separator())
        if !selection.isEmpty {
            let quoted = String(selection.prefix(1_500))
            menu.addItem(ClosureMenuItem("Ask Assistant About Selection") { [weak self] in
                guard let self else { return }
                self.delegate?.tab(self, askAssistant: "Explain this text from the current page:\n\n\u{201C}\(quoted)\u{201D}")
            })
        } else if link == nil && image == nil {
            menu.addItem(ClosureMenuItem("Summarize Page with Assistant") { [weak self] in
                guard let self else { return }
                self.delegate?.tab(self, askAssistant: "Summarize the current page in a few bullet points.")
            })
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }

    static func abbreviate(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "\u{2026}" : flat
    }

    /// Starts a download from this tab, so it carries the tab's cookies and referrer.
    func download(_ url: URL) {
        guard let wv = webView else { return }
        let page = self.url
        wv.startDownload(using: URLRequest(url: url)) { download in
            Downloads.shared.track(download, page: page)
        }
    }

    // MARK: - Agent page bridge

    /// Compact, accessibility-like page representation. Element refs are written back
    /// onto the DOM so later click/fill calls do not need to resend the whole DOM.
    func captureAgentSnapshot(maxTextChars: Int = 12_000, isCancelled: @escaping () -> Bool = { false },
                              completion: @escaping (Result<AgentPageSnapshot, Error>) -> Void) {
        guard !isCancelled() else { completion(.failure(AgentToolError.cancelled)); return }
        let wv = ensureLoaded()
        let safeMax = max(1_000, min(40_000, maxTextChars))
        let deadline = Date().addingTimeInterval(15)
        let js = """
        (() => {
          const visible = e => {
            const s = getComputedStyle(e), r = e.getBoundingClientRect();
            return s.display !== 'none' && s.visibility !== 'hidden' && r.width >= 1 && r.height >= 1;
          };
          const clean = s => (s || '').replace(/\\s+/g, ' ').trim();
          const inputRole = t => ({submit:'button',button:'button',reset:'button',image:'button',file:'button',checkbox:'checkbox',radio:'radio',range:'slider'}[t] || 'textbox');
          const roleFor = e => e.getAttribute('role') || (e.tagName === 'INPUT' ? inputRole((e.type || '').toLowerCase()) : ({A:'link',BUTTON:'button',TEXTAREA:'textbox',SELECT:'combobox'}[e.tagName] || e.tagName.toLowerCase()));
          const nodes = Array.from(document.querySelectorAll('a,button,input,textarea,select,[role],[contenteditable=\"true\"]')).filter(visible).slice(0, 240);
          window.__facetAgentRefSeq = window.__facetAgentRefSeq || 0;
          const elements = nodes.map(e => {
            let ref = e.getAttribute('data-facet-agent-ref');
            if (!ref) { ref = 'e' + (++window.__facetAgentRefSeq); e.setAttribute('data-facet-agent-ref', ref); }
            const sensitive = e.type === 'password' || /(?:password|one-time-code|cc-)/i.test(e.getAttribute('autocomplete') || '');
            const name = clean(e.getAttribute('aria-label') || e.innerText || (!sensitive && e.value) || e.getAttribute('placeholder') || e.getAttribute('title') || e.getAttribute('alt'));
            const options = e.tagName === 'SELECT' ? Array.from(e.options).slice(0, 30).map(o => clean(o.text)).filter(Boolean) : undefined;
            return {ref, role: roleFor(e), name: name.slice(0, 240), value: (!sensitive && 'value' in e ? String(e.value || '').slice(0, 500) : null), href: e.href || null, disabled: !!e.disabled, options};
          });
          const headings = Array.from(document.querySelectorAll('h1,h2,h3')).filter(visible).map(e => clean(e.innerText)).filter(Boolean).slice(0, 60);
          return {url: location.href, title: document.title || '', text: (document.body ? document.body.innerText : '').slice(0, \(safeMax)), headings, elements};
        })()
        """

        func evaluateWhenReady() {
            guard !isCancelled() else { completion(.failure(AgentToolError.cancelled)); return }
            if (wv.url == nil || wv.isLoading) && Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { evaluateWhenReady() }
                return
            }
            guard wv.url != nil else { completion(.failure(AgentToolError.pageNotReady)); return }
            wv.evaluateJavaScript(js) { [weak self] result, error in
                guard !isCancelled() else { completion(.failure(AgentToolError.cancelled)); return }
                if let error { completion(.failure(error)); return }
                guard let result, JSONSerialization.isValidJSONObject(result),
                      let data = try? JSONSerialization.data(withJSONObject: result),
                      let snapshot = try? JSONDecoder().decode(AgentPageSnapshot.self, from: data) else {
                    completion(.failure(AgentToolError.pageNotReady)); return
                }
                self?.semanticState = TabSemanticState(title: snapshot.title, url: snapshot.url,
                                                       text: String(snapshot.text.prefix(4_000)),
                                                       headings: snapshot.headings, updatedAt: Date())
                self?.lastAgentElements = Dictionary(uniqueKeysWithValues: snapshot.elements.map { ($0.ref, $0) })
                completion(.success(snapshot))
            }
        }
        evaluateWhenReady()
    }

    func waitForAgentReady(timeout: TimeInterval = 20, isCancelled: @escaping () -> Bool = { false },
                           completion: @escaping (Result<String, Error>) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            guard !isCancelled() else { completion(.failure(AgentToolError.cancelled)); return }
            guard let wv = webView, wv.url != nil else {
                if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { check() } }
                else { completion(.failure(AgentToolError.pageNotReady)) }
                return
            }
            if wv.isLoading && Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { check() }; return
            }
            completion(.success(wv.url?.absoluteString ?? url?.absoluteString ?? "ready"))
        }
        check()
    }

    /// Viewport-only screenshot for visual fallback. It is never persisted to disk.
    func captureAgentScreenshot(completion: @escaping (Result<Data, Error>) -> Void) {
        guard let wv = webView else { completion(.failure(AgentToolError.pageNotReady)); return }
        let cfg = WKSnapshotConfiguration()
        cfg.rect = wv.bounds
        cfg.snapshotWidth = NSNumber(value: min(1280, max(320, wv.bounds.width)))
        wv.takeSnapshot(with: cfg) { image, error in
            if let error { completion(.failure(error)); return }
            guard let image, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.65]) else {
                completion(.failure(AgentToolError.pageNotReady)); return
            }
            completion(.success(jpeg))
        }
    }

    func agentClick(ref: String, completion: @escaping (Result<String, Error>) -> Void) {
        retryingStaleRef(ref, action: { resolved, done in
            self.runAgentElementScript(ref: resolved, body: "e.scrollIntoView({block:'center'}); e.click(); return 'clicked';", completion: done)
        }, completion: { result in
            guard case .success = result else { completion(result); return }
            self.waitForAgentReady(timeout: 8) { ready in
                if case .failure(let error) = ready, !(error is AgentToolError) { completion(.failure(error)) }
                else { completion(result) }
            }
        })
    }

    func agentFill(ref: String, text: String, completion: @escaping (Result<String, Error>) -> Void) {
        retryingStaleRef(ref, action: { resolved, done in
            self.performAgentFill(ref: resolved, text: text, completion: done)
        }, completion: completion)
    }

    private func performAgentFill(ref: String, text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let value = Self.jsLiteral(text)
        let body = """
        e.focus();
        const v = \(value);
        if (e instanceof HTMLSelectElement) {
          const want = v.trim().toLowerCase();
          const options = Array.from(e.options);
          const match = options.find(o => o.value === v || o.text.trim().toLowerCase() === want)
            || options.find(o => o.text.toLowerCase().includes(want));
          if (!match) return {ok:false, error:'no option matching ' + v};
          e.value = match.value;
        } else if (e.isContentEditable) { e.textContent = v; }
        else {
          // React and friends track the native setter, so assign through the prototype.
          const proto = e instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
            : e instanceof HTMLInputElement ? HTMLInputElement.prototype : null;
          const d = proto && Object.getOwnPropertyDescriptor(proto, 'value');
          if (d && d.set) d.set.call(e, v); else e.value = v;
        }
        e.dispatchEvent(new Event('input',{bubbles:true}));
        e.dispatchEvent(new Event('change',{bubbles:true}));
        return 'filled';
        """
        runAgentElementScript(ref: ref, body: body, completion: completion)
    }

    func agentPress(ref: String?, key: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard webView != nil else { completion(.failure(AgentToolError.pageNotReady)); return }
        let refJS = Self.jsLiteral(ref ?? "")
        let keyJS = Self.jsLiteral(key)
        let js = """
        (() => {
          const ref = \(refJS);
          const e = ref ? document.querySelector('[data-facet-agent-ref=\"' + CSS.escape(ref) + '\"]') : document.activeElement;
          if (!e) return {ok:false,error:'element not found'};
          e.focus();
          const k = \(keyJS);
          e.dispatchEvent(new KeyboardEvent('keydown',{key:k,bubbles:true}));
          e.dispatchEvent(new KeyboardEvent('keyup',{key:k,bubbles:true}));
          if (k === 'Enter' && e.form && typeof e.form.requestSubmit === 'function') e.form.requestSubmit();
          return {ok:true,value:'pressed ' + k};
        })()
        """
        runAgentResultScript(js, completion: completion)
    }

    func agentScroll(deltaY: Double, completion: @escaping (Result<String, Error>) -> Void) {
        guard let wv = webView else { completion(.failure(AgentToolError.pageNotReady)); return }
        let dy = max(-10_000, min(10_000, deltaY))
        let js = "window.scrollBy({top:\(dy),behavior:'instant'}); ({ok:true,value:'scrolled'});"
        wv.evaluateJavaScript(js) { _, error in
            if let error { completion(.failure(error)) } else { completion(.success("scrolled")) }
        }
    }

    private func retryingStaleRef(_ originalRef: String,
                                  action: @escaping (String, @escaping (Result<String, Error>) -> Void) -> Void,
                                  completion: @escaping (Result<String, Error>) -> Void) {
        let old = lastAgentElements[originalRef]
        action(originalRef) { [weak self] result in
            guard let self else { completion(result); return }
            guard case .failure(AgentToolError.elementNotFound) = result, let old else { completion(result); return }
            self.captureAgentSnapshot { fresh in
                guard case .success(let snapshot) = fresh else { completion(result); return }
                let scored = snapshot.elements.map { element -> (AgentElement, Int) in
                    var score = 0
                    if element.role == old.role { score += 2 }
                    if !old.name.isEmpty && element.name.caseInsensitiveCompare(old.name) == .orderedSame { score += 4 }
                    if let href = old.href, element.href == href { score += 3 }
                    return (element, score)
                }.filter { $0.1 >= 4 }.sorted { $0.1 > $1.1 }
                guard let best = scored.first, scored.dropFirst().first?.1 != best.1 else {
                    completion(.failure(AgentToolError.elementNotFound(originalRef))); return
                }
                action(best.0.ref, completion)
            }
        }
    }

    private func runAgentElementScript(ref: String, body: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard webView != nil else { completion(.failure(AgentToolError.pageNotReady)); return }
        let refJS = Self.jsLiteral(ref)
        let js = """
        (() => {
          const ref = \(refJS);
          const e = document.querySelector('[data-facet-agent-ref=\"' + CSS.escape(ref) + '\"]');
          if (!e) return {ok:false,error:'element not found: ' + ref};
          try { \(body) } catch (err) { return {ok:false,error:String(err)}; }
        })()
        """
        runAgentResultScript(js, completion: completion)
    }

    private func runAgentResultScript(_ js: String, completion: @escaping (Result<String, Error>) -> Void) {
        webView?.evaluateJavaScript(js) { result, error in
            if let error { completion(.failure(error)); return }
            if let d = result as? [String: Any], let ok = d["ok"] as? Bool {
                if ok { completion(.success(d["value"] as? String ?? "ok")) }
                else {
                    let message = d["error"] as? String ?? "unknown error"
                    if message.hasPrefix("element not found") {
                        let missing = message.split(separator: ":", maxSplits: 1).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                        completion(.failure(AgentToolError.elementNotFound(missing)))
                    } else { completion(.failure(AgentToolError.javascript(message))) }
                }
                return
            }
            completion(.success(result.map { String(describing: $0) } ?? "ok"))
        }
    }

    static func jsLiteral(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [string])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    private func refreshSemanticCache(in wv: WKWebView) {
        let js = """
        (() => ({title:document.title||'',url:location.href,text:(document.body?document.body.innerText:'').slice(0,4000),headings:Array.from(document.querySelectorAll('h1,h2,h3')).map(e=>(e.innerText||'').trim()).filter(Boolean).slice(0,40)}))()
        """
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let d = result as? [String: Any] else { return }
            self.semanticState = TabSemanticState(title: d["title"] as? String ?? self.title,
                                                  url: d["url"] as? String ?? self.url?.absoluteString ?? "",
                                                  text: d["text"] as? String ?? "",
                                                  headings: d["headings"] as? [String] ?? [],
                                                  updatedAt: Date())
        }
    }

    private func fetchFavicon(for wv: WKWebView) {
        // Private tabs keep their generic icon rather than leaking icon requests or
        // writing the site to the on-disk favicon cache.
        guard !isPrivate else { return }
        guard let host = wv.url?.host else { return }
        if let cached = FaviconStore.shared.icon(forHost: host) {
            favicon = cached
            delegate?.tabDidChangeState(self)
            guard FaviconStore.shared.needsRefresh(host: host) else { return }
        }

        // Prefer the declared icon closest to 32px; touch icons and SVGs are fallbacks.
        let js = """
        (function(){
          var best = null, bestScore = 1e9;
          document.querySelectorAll("link[rel~='icon'],link[rel='shortcut icon'],link[rel~='apple-touch-icon']").forEach(function(l){
            if (!l.href) return;
            var size = parseInt(((l.sizes && l.sizes.value) || '').split(/[xX ]/)[0], 10) || (/apple-touch/.test(l.rel) ? 180 : 16);
            var score = size >= 32 ? size - 32 : (32 - size) * 3;
            if (/svg/i.test(l.type || '') || /\\.svg($|\\?)/i.test(l.href)) score += 400;
            if (score < bestScore) { bestScore = score; best = l.href; }
          });
          return best || location.origin + '/favicon.ico';
        })()
        """
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let href = result as? String, let iconURL = URL(string: href),
                  ["http", "https"].contains(iconURL.scheme?.lowercased() ?? "") else { return }
            FaviconStore.session.dataTask(with: iconURL) { data, response, _ in
                guard let data, data.count < 1_000_000,
                      ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400 else { return }
                DispatchQueue.main.async {
                    guard let image = FaviconStore.shared.store(data, forHost: host, persist: true) else { return }
                    if self.url?.host == host { self.favicon = image }
                    self.delegate?.tabDidChangeState(self)
                }
            }.resume()
        }
    }

    // MARK: - Error pages

    /// Failures that are not failures: redirects and stops cancel (-999), a response that
    /// became a download interrupts the frame load (WebKit 102), and a plug-in handling
    /// the load reports 204.
    static func isBenignNavigationError(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return true }
        if error.domain == "WebKitErrorDomain" && (error.code == 102 || error.code == 204) { return true }
        return false
    }

    static func htmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func errorPageHTML(heading: String, message: String, detail: String, retryURL: String,
                              button: String = "Try Again") -> String {
        """
        <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width">
        <title>\(htmlEscape(heading))</title>
        <style>
        :root{color-scheme:light dark}
        body{font:15px/1.55 -apple-system,system-ui;display:grid;place-items:center;height:100vh;margin:0;
        color:#111;background:#fff}
        @media(prefers-color-scheme:dark){body{color:#eee;background:#1c1c1e}}
        .c{max-width:32rem;padding:2rem;text-align:center}
        h1{font-size:1.25rem;font-weight:600;margin:0 0 .5rem}
        p{opacity:.65;margin:0 0 1.5rem}
        button{font:inherit;padding:.5rem 1.1rem;border-radius:7px;border:0;background:#0a84ff;color:#fff;cursor:pointer}
        code{opacity:.5;font-size:.8rem}
        </style>
        <div class=c><h1>\(htmlEscape(heading))</h1>
        <p>\(htmlEscape(message))</p>
        <button id=retry>\(htmlEscape(button))</button>
        <p><code>\(htmlEscape(detail))</code></p></div>
        <script>document.getElementById('retry').onclick=function(){location.replace(\(jsLiteral(retryURL).replacingOccurrences(of: "<", with: "\\u003c")))}</script>
        """
    }

    private func showError(_ error: Error, in webView: WKWebView) {
        let ns = error as NSError
        guard !Self.isBenignNavigationError(ns) else { return }
        let failingURL = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
            ?? provisionalURL ?? url
        let failing = failingURL?.absoluteString ?? ""
        let host = failingURL?.host ?? failing
        let heading: String
        switch (ns.domain, ns.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet): heading = "You\u{2019}re offline"
        case (NSURLErrorDomain, NSURLErrorCannotFindHost): heading = "\(host) can\u{2019}t be found"
        case (NSURLErrorDomain, NSURLErrorTimedOut): heading = "\(host) took too long to respond"
        case (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid),
             (NSURLErrorDomain, NSURLErrorSecureConnectionFailed):
            heading = "Your connection to \(host) isn\u{2019}t private"
        default: heading = "Can\u{2019}t open \(host)"
        }
        errorURL = failingURL
        errorNavigation = webView.loadHTMLString(
            Self.errorPageHTML(heading: heading, message: ns.localizedDescription,
                               detail: "\(ns.domain) \(ns.code)", retryURL: failing),
            baseURL: failingURL)
    }

    private static func presentCredentialSheet(space: URLProtectionSpace, failures: Int, window: NSWindow?,
                                               completion: @escaping (URLCredential?) -> Void) {
        let alert = NSAlert()
        let defaultPort = space.port == 0 || space.port == 80 || space.port == 443
        alert.messageText = "Sign in to \(defaultPort ? space.host : "\(space.host):\(space.port)")"
        // The realm is site-controlled text, so it is deliberately not shown (as in Chrome).
        var notes: [String] = []
        if failures > 0 { notes.append("The user name or password was not accepted.") }
        if !space.receivesCredentialSecurely { notes.append("Your connection to this site isn\u{2019}t private, so the password will be sent unencrypted.") }
        alert.informativeText = notes.joined(separator: "\n")
        let user = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        user.placeholderString = "User name"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "Password"
        user.nextKeyView = password
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        box.addSubview(user); box.addSubview(password)
        alert.accessoryView = box
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = user
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { completion(nil); return }
            completion(URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    private func presentingWindow(for webView: WKWebView) -> NSWindow? {
        webView.window ?? delegate?.presentingWindow(for: self) ?? NSApp.keyWindow
    }

    /// Every page dialog goes through here: background tabs are brought forward first, and
    /// after the second dialog a page can be told to stop (Chrome's "prevent additional dialogs").
    private func presentPageDialog(_ alert: NSAlert, in webView: WKWebView,
                                   completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if dialogsSuppressed { completion(.cancel); return }
        if webView.window == nil { delegate?.tabRequestsAttention(self) }
        dialogCount += 1
        if dialogCount > 2 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Prevent this page from creating more dialogs"
        }
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if alert.suppressionButton?.state == .on { self?.dialogsSuppressed = true }
            completion(response)
        }
        if let window = presentingWindow(for: webView) { alert.beginSheetModal(for: window, completionHandler: done) }
        else { done(alert.runModal()) }
    }

    /// Names the app an external link would launch, for the confirmation prompt.
    private func confirmExternalOpen(_ url: URL, in webView: WKWebView) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            delegate?.tabStatus(self, message: "No app can open \(scheme): links")
            return
        }
        let host = webView.url?.host ?? ""
        if !isPrivate, !host.isEmpty, SiteSettings.shared.permission("open:\(scheme)", for: host) == true {
            NSWorkspace.shared.open(url); return
        }
        let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = "Open \(appName)?"
        alert.informativeText = host.isEmpty ? "This page wants to open \(appName)." : "\(host) wants to open \(appName)."
        alert.addButton(withTitle: "Open \(appName)")
        alert.addButton(withTitle: "Cancel")
        if !isPrivate && !host.isEmpty {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Always allow \(host) to open \(scheme): links"
        }
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on, self?.isPrivate == false {
                SiteSettings.shared.setPermission("open:\(scheme)", for: host, allowed: true)
            }
            NSWorkspace.shared.open(url)
        }
        if let window = presentingWindow(for: webView) { alert.beginSheetModal(for: window, completionHandler: done) }
        else { done(alert.runModal()) }
    }

    /// Content-Disposition: attachment, or a type WebKit cannot render, means a download.
    static func shouldDownload(canShowMIMEType: Bool, contentDisposition: String?) -> Bool {
        if !canShowMIMEType { return true }
        guard let value = contentDisposition?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return value.hasPrefix("attachment")
    }

    /// A tab that exists only because a link pointed at a file has nothing to show once
    /// the file starts downloading, so it closes itself the way Chrome's do.
    private func closeIfOnlyADownload(_ webView: WKWebView) {
        guard opener != nil, webView.backForwardList.currentItem == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.tabRequestsClose(self)
        }
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""

        // Hand off anything WebKit does not speak (mailto:, tel:, zoommtg:, ...) to the OS,
        // after asking, so a page cannot launch apps behind the user's back.
        if !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) {
            decisionHandler(.cancel)
            confirmExternalOpen(url, in: webView)
            return
        }
        // <a download> and friends.
        if action.shouldPerformDownload { decisionHandler(.download); return }
        if action.navigationType == .linkActivated {
            let flags = action.modifierFlags
            // Option-click downloads the link, as in Safari.
            if flags.contains(.option) && !flags.contains(.command) { decisionHandler(.download); return }
            // Cmd-click / middle-click opens a background tab, like every other browser.
            if flags.contains(.command) || action.buttonNumber == 2 {
                _ = delegate?.tab(self, openNewTabWith: url, configuration: nil,
                                  activate: flags.contains(.shift))
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let download = Self.shouldDownload(canShowMIMEType: navigationResponse.canShowMIMEType,
                                           contentDisposition: disposition)
        decisionHandler(download ? .download : .allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let u = webView.url { provisionalURL = u }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if navigation == nil || navigation !== errorNavigation { errorURL = nil; errorNavigation = nil }
        dialogCount = 0
        dialogsSuppressed = false
        applySiteZoom(webView)
        if hoveredLink != nil { hoveredLink = nil; delegate?.tab(self, didHoverLink: nil) }
        delegate?.tabDidChangeState(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let isErrorPage = navigation != nil && navigation === errorNavigation
        if !isErrorPage {
            if let u = webView.url, !isPrivate {
                Store.shared.recordVisit(url: u, title: webView.title ?? "")
            }
            fetchFavicon(for: webView)
            refreshSemanticCache(in: webView)
        }
        delegate?.tabDidChangeState(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // The page already committed; keep whatever rendered instead of replacing it.
        delegate?.tabDidChangeState(self)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let prompts = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                       NSURLAuthenticationMethodNTLM].contains(space.authenticationMethod)
        // Server trust and client certificates keep WebKit's default (strict) handling.
        guard prompts else { completionHandler(.performDefaultHandling, nil); return }
        if challenge.previousFailureCount == 0, let proposed = challenge.proposedCredential, proposed.hasPassword {
            completionHandler(.useCredential, proposed); return
        }
        let persistence: URLCredential.Persistence = isPrivate ? .none : .forSession
        Tab.credentialPrompt(space, challenge.previousFailureCount, presentingWindow(for: webView)) { credential in
            guard let credential, let user = credential.user else {
                // Continue without credentials so the site's own 401 page is shown.
                completionHandler(.rejectProtectionSpace, nil); return
            }
            completionHandler(.useCredential, URLCredential(user: user, password: credential.password ?? "", persistence: persistence))
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.track(download, page: url)
        closeIfOnlyADownload(webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.track(download, page: url)
        closeIfOnlyADownload(webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
        NSLog("Facet: content process terminated for \(url?.host ?? "?")")
        // A background renderer is usually killed by macOS to reclaim memory. Reloading it
        // now would spend exactly the memory the system just asked for, so it stays asleep
        // and reloads when the user comes back to it.
        if webView.window == nil && !isAgentLeased && !keepAwake {
            hibernate()
            return
        }
        // Crashing over and over: stop the reload loop and let the user decide.
        if crashTimes.count >= 3 {
            let page = webView.url ?? url
            errorURL = page
            errorNavigation = webView.loadHTMLString(
                Self.errorPageHTML(heading: "This page keeps crashing",
                                   message: "Facet stopped reloading it automatically.",
                                   detail: page?.host ?? "", retryURL: page?.absoluteString ?? "about:blank",
                                   button: "Reload"),
                baseURL: page)
            return
        }
        webView.reload()
    }
}

// MARK: - UI delegate

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open must reuse the supplied configuration.
        let tab = delegate?.tab(self, openNewTabWith: action.request.url, configuration: configuration, activate: true)
        return tab?.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        delegate?.tabRequestsClose(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = frame.securityOrigin.host
        a.informativeText = message
        a.addButton(withTitle: "OK")
        presentPageDialog(a, in: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = frame.securityOrigin.host
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        presentPageDialog(a, in: webView) { r in completionHandler(r == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert()
        a.messageText = frame.securityOrigin.host
        a.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        presentPageDialog(a, in: webView) { r in
            completionHandler(r == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    /// <input type=file>. Without this delegate method WebKit silently ignores the click.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.message = "Choose a file to upload to \(frame.securityOrigin.host)"
        if let window = presentingWindow(for: webView) {
            panel.beginSheetModal(for: window) { r in completionHandler(r == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let what: String, kind: String
        switch type {
        case .camera: what = "use your camera"; kind = "camera"
        case .microphone: what = "use your microphone"; kind = "microphone"
        case .cameraAndMicrophone: what = "use your camera and microphone"; kind = "camera+microphone"
        @unknown default: what = "use a capture device"; kind = "capture"
        }
        if !isPrivate, let remembered = SiteSettings.shared.permission(kind, for: origin.host) {
            decisionHandler(remembered ? .grant : .deny); return
        }
        let a = NSAlert()
        a.messageText = "Allow \(origin.host) to \(what)?"
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Don\u{2019}t Allow")
        if !isPrivate {
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Remember this decision for \(origin.host)"
        }
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            let allowed = r == .alertFirstButtonReturn
            if a.suppressionButton?.state == .on, self?.isPrivate == false {
                SiteSettings.shared.setPermission(kind, for: origin.host, allowed: allowed)
            }
            decisionHandler(allowed ? .grant : .deny)
        }
        if let window = presentingWindow(for: webView) { a.beginSheetModal(for: window, completionHandler: done) }
        else { done(a.runModal()) }
    }
}
