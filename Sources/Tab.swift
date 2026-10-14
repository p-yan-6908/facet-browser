import AppKit
import WebKit

protocol TabDelegate: AnyObject {
    func tabDidChangeState(_ tab: Tab)
    func tab(_ tab: Tab, openNewTabWith url: URL?, configuration: WKWebViewConfiguration?, activate: Bool) -> Tab?
    func tabRequestsClose(_ tab: Tab)
    func tabStatus(_ tab: Tab, message: String?)
}

/// Shared WebKit plumbing. A single data store across every tab means one cookie
/// and cache jar; WebKit itself decides how to pool content processes.
enum WebKitEnv {
    static func makeConfiguration(private isPrivate: Bool = false) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        // Identify as Safari: many sites gate features on the UA and WKWebView's
        // default string has no Version/Safari suffix.
        cfg.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        // No autoplay. This alone removes a large share of background CPU and decode memory.
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.suppressesIncrementalRendering = false
        cfg.preferences.isFraudulentWebsiteWarningEnabled = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        if let list = ContentBlocker.ruleList {
            cfg.userContentController.add(list)
        }
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
    private static var faviconCache: [String: NSImage] = [:]

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
        if !isPrivate, let url { self.favicon = Tab.faviconCache[url.host ?? ""] }
    }

    /// Restore from a previous session without spending a web process yet.
    init(saved: SavedTab, delegate: TabDelegate?) {
        self.isPrivate = false
        self.delegate = delegate
        self.url = URL(string: saved.url)
        self.title = saved.title
        self.savedInteractionState = saved.interactionState
        self.pendingURL = URL(string: saved.url)
        super.init()
        self.favicon = Tab.faviconCache[self.url?.host ?? ""]
    }

    func snapshot() -> SavedTab {
        SavedTab(url: url?.absoluteString ?? "",
                 title: title,
                 interactionState: liveInteractionState() ?? savedInteractionState)
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
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.allowsLinkPreview = true
        wv.autoresizingMask = [.width, .height]
        if Config.shared.enableDeveloperTools, #available(macOS 13.3, *) { wv.isInspectable = true }
        webView = wv
        observe(wv)

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
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        wv.stopLoading()
        wv.removeFromSuperview()
        webView = nil
        isLoading = false
        progress = 0
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

    func acquireAgentLease() { agentLeaseCount += 1 }
    func releaseAgentLease() { agentLeaseCount = max(0, agentLeaseCount - 1) }

    private var isPlayingMedia: Bool {
        // Never kill a tab that is capturing or playing.
        guard let wv = webView else { return false }
        if wv.cameraCaptureState != .none || wv.microphoneCaptureState != .none { return true }
        let sel = Selector(("_isPlayingAudio"))
        guard wv.responds(to: sel) else { return false }
        return wv.value(forKey: "_isPlayingAudio") as? Bool ?? false
    }

    func load(_ url: URL) {
        self.url = url
        savedInteractionState = nil
        if let wv = webView {
            wv.load(URLRequest(url: url))
        } else {
            pendingURL = url
            ensureLoaded()
        }
    }

    func reload() {
        guard let wv = webView else { ensureLoaded(); return }
        wv.reloadFromOrigin()
    }

    func stop() { webView?.stopLoading() }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    var canGoBack: Bool { webView?.canGoBack ?? false }
    var canGoForward: Bool { webView?.canGoForward ?? false }

    // MARK: - Observation

    private func observe(_ wv: WKWebView) {
        func note() { delegate?.tabDidChangeState(self) }
        observations = [
            wv.observe(\.title, options: [.new]) { [weak self] w, _ in
                guard let self else { return }
                if let t = w.title, !t.isEmpty {
                    self.title = t
                    if !self.isPrivate, let u = w.url { Store.shared.updateTitle(url: u, title: t) }
                }
                note()
            },
            wv.observe(\.url, options: [.new]) { [weak self] w, _ in
                guard let self else { return }
                self.url = w.url
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
    }

    deinit { observations.forEach { $0.invalidate() } }

    // MARK: - Favicon

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
          const roleFor = e => e.getAttribute('role') || ({A:'link',BUTTON:'button',INPUT:'textbox',TEXTAREA:'textbox',SELECT:'combobox'}[e.tagName] || e.tagName.toLowerCase());
          const nodes = Array.from(document.querySelectorAll('a,button,input,textarea,select,[role],[contenteditable=\"true\"]')).filter(visible).slice(0, 240);
          window.__facetAgentRefSeq = window.__facetAgentRefSeq || 0;
          const elements = nodes.map(e => {
            let ref = e.getAttribute('data-facet-agent-ref');
            if (!ref) { ref = 'e' + (++window.__facetAgentRefSeq); e.setAttribute('data-facet-agent-ref', ref); }
            const sensitive = e.type === 'password' || /(?:password|one-time-code|cc-)/i.test(e.getAttribute('autocomplete') || '');
            const name = clean(e.getAttribute('aria-label') || e.innerText || (!sensitive && e.value) || e.getAttribute('placeholder') || e.getAttribute('title') || e.getAttribute('alt'));
            return {ref, role: roleFor(e), name: name.slice(0, 240), value: (!sensitive && 'value' in e ? String(e.value || '').slice(0, 500) : null), href: e.href || null, disabled: !!e.disabled};
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
        if (e.isContentEditable) { e.textContent = v; }
        else {
          const proto = e instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const d = Object.getOwnPropertyDescriptor(proto, 'value');
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

    private static func jsLiteral(_ string: String) -> String {
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
        // URLSession.shared has a persistent cache outside the private WKWebsiteDataStore.
        // Keep private tabs on their generic icon rather than leaking icon requests to it.
        guard !isPrivate else { return }
        guard let host = wv.url?.host else { return }
        if let cached = Tab.faviconCache[host] { favicon = cached; delegate?.tabDidChangeState(self); return }

        let js = """
        (function(){var l=document.querySelector("link[rel~='icon']")||document.querySelector("link[rel='shortcut icon']");
        return l&&l.href?l.href:location.origin+'/favicon.ico';})()
        """
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let href = result as? String, let iconURL = URL(string: href) else { return }
            var req = URLRequest(url: iconURL)
            req.timeoutInterval = 6
            URLSession.shared.dataTask(with: req) { data, _, _ in
                guard let data, let img = NSImage(data: data), img.size.width > 0 else { return }
                img.size = NSSize(width: 16, height: 16)
                DispatchQueue.main.async {
                    Tab.faviconCache[host] = img
                    self.favicon = img
                    self.delegate?.tabDidChangeState(self)
                }
            }.resume()
        }
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""

        // Hand off anything WebKit does not speak (mailto:, tel:, zoommtg:, ...) to the OS.
        if !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        // Cmd-click / middle-click opens a background tab, like every other browser.
        if action.navigationType == .linkActivated {
            let flags = action.modifierFlags
            if flags.contains(.command) || action.buttonNumber == 2 {
                _ = delegate?.tab(self, openNewTabWith: url, configuration: nil,
                                  activate: flags.contains(.shift))
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        delegate?.tabDidChangeState(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let u = webView.url, !isPrivate {
            Store.shared.recordVisit(url: u, title: webView.title ?? "")
        }
        fetchFavicon(for: webView)
        refreshSemanticCache(in: webView)
        delegate?.tabDidChangeState(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    private func showError(_ error: Error, in webView: WKWebView) {
        let ns = error as NSError
        // -999 is "cancelled", which happens on every normal redirect/stop.
        guard ns.code != NSURLErrorCancelled else { return }
        let failing = (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? url?.absoluteString ?? ""
        let host = URL(string: failing)?.host ?? failing
        let html = """
        <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width">
        <style>
        :root{color-scheme:light dark}
        body{font:15px/1.55 -apple-system,system-ui;display:grid;place-items:center;height:100vh;margin:0;
        color:#111;background:#fff}
        @media(prefers-color-scheme:dark){body{color:#eee;background:#1c1c1e}}
        .c{max-width:30rem;padding:2rem;text-align:center}
        h1{font-size:1.25rem;font-weight:600;margin:0 0 .5rem}
        p{opacity:.65;margin:0 0 1.5rem}
        button{font:inherit;padding:.5rem 1.1rem;border-radius:7px;border:0;background:#0a84ff;color:#fff;cursor:pointer}
        code{opacity:.5;font-size:.8rem}
        </style>
        <div class=c><h1>Can\u{2019}t open \(host)</h1>
        <p>\(ns.localizedDescription)</p>
        <button onclick="location.reload()">Try again</button>
        <p><code>\(ns.domain) \(ns.code)</code></p></div>
        """
        webView.loadHTMLString(html, baseURL: URL(string: failing))
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = Downloads.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = Downloads.shared
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The content process was killed (usually by memory pressure). Recover in place.
        NSLog("Facet: content process terminated for \(url?.host ?? "?"), reloading")
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
        a.beginSheetModal(for: webView.window ?? NSApp.keyWindow ?? NSWindow()) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = frame.securityOrigin.host
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: webView.window ?? NSApp.keyWindow ?? NSWindow()) { r in
            completionHandler(r == .alertFirstButtonReturn)
        }
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
        a.beginSheetModal(for: webView.window ?? NSApp.keyWindow ?? NSWindow()) { r in
            completionHandler(r == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let what: String
        switch type {
        case .camera: what = "use your camera"
        case .microphone: what = "use your microphone"
        case .cameraAndMicrophone: what = "use your camera and microphone"
        @unknown default: what = "use a capture device"
        }
        let a = NSAlert()
        a.messageText = "Allow \(origin.host) to \(what)?"
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Don\u{2019}t Allow")
        a.beginSheetModal(for: webView.window ?? NSApp.keyWindow ?? NSWindow()) { r in
            decisionHandler(r == .alertFirstButtonReturn ? .grant : .deny)
        }
    }

}
