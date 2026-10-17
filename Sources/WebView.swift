import AppKit
import WebKit

/// What the page last reported about the element under a right-click.
struct PageContext {
    var link: URL?
    var image: URL?
    var selection: String
    var at: Date
}

/// Link-hover and context-menu details from the page. The script and its handler live
/// in WKContentWorld.defaultClient, an isolated world: page scripts share the DOM events
/// but cannot see or call the handler, so a page cannot spoof what the status bubble
/// shows or what a context-menu command acts on.
final class PageBridge: NSObject, WKScriptMessageHandler {
    static let shared = PageBridge()
    static let handlerName = "facetPage"

    static let source = """
    (() => {
      if (window.__facetBridge) return; window.__facetBridge = true;
      const post = m => { try { webkit.messageHandlers.facetPage.postMessage(m); } catch (_) {} };
      const linkFor = t => {
        for (let e = t; e && e !== document; e = e.parentNode)
          if (e.tagName === 'A' && typeof e.href === 'string' && e.href) return e.href;
        return '';
      };
      let last = '';
      document.addEventListener('mouseover', ev => {
        const href = linkFor(ev.target);
        if (href !== last) { last = href; post({t: 'hover', href}); }
      }, {capture: true, passive: true});
      document.addEventListener('mouseout', ev => {
        if (!ev.relatedTarget && last) { last = ''; post({t: 'hover', href: ''}); }
      }, {capture: true, passive: true});
      document.addEventListener('contextmenu', ev => {
        const t = ev.target;
        const image = t && t.tagName === 'IMG' ? (t.currentSrc || t.src || '') : '';
        post({t: 'context', href: linkFor(t), image, selection: String(getSelection() || '').slice(0, 4000)});
      }, {capture: true});
    \(PasswordForms.captureJS)
    })();
    """

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.add(shared, contentWorld: .defaultClient, name: handlerName)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let view = message.webView as? FacetWebView else { return }
        view.owner?.handleBridgeMessage(body)
    }
}

/// WKWebView with a back-pointer to its tab, so the shared bridge and the context menu
/// can reach the tab without a retain cycle.
final class FacetWebView: WKWebView {
    weak var owner: Tab?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        owner?.customizeContextMenu(menu)
    }
}

/// Menu item that runs a closure. Menus retain their items, so the closure lives exactly
/// as long as the menu does.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
