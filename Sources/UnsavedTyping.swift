import Foundation
import WebKit

/// What one frame has reported about typing since its page loaded. Times are milliseconds
/// since 1970, as the page's own clock gives them.
struct FrameTyping: Equatable {
    var site: String
    /// The user has typed something Facet would lose by sleeping the tab.
    var typed: Bool
    /// Last typing Facet can't put back itself: rich editors, fields in frames or shadow DOM.
    var editAt: Double
    /// Start of the site's latest request that could be a save.
    var saveAt: Double
    /// A file was chosen in a file field. Facet can't put that back, and no save covers it.
    var file: Bool
}

/// Keeps what the user typed when a background tab goes to sleep.
///
/// A tracker in the page notes real typing (never script-made events). It goes into a frame
/// only once the user clicks into it: each frame it runs in costs WebKit a script world of
/// a few hundred kilobytes, and most frames are ads and embeds nobody types in. Plain form
/// fields in the page are saved by Facet when the tab sleeps and put back when it wakes, so
/// those tabs still free their memory. Typing Facet can't put back keeps the tab awake until the
/// page has saved it: its own site has sent a request since the last keystroke, and the page
/// doesn't warn about leaving. Google Docs, Notion and Gmail drafts work that way.
///
/// Everything runs in WebKit's isolated `defaultClient` world, so pages can't see or spoof it.
/// Passwords, card numbers and one-time codes are never recorded.
final class TypingTracker: NSObject, WKScriptMessageHandler {
    static let shared = TypingTracker()
    static let handlerName = "facetTyping"

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: UnsavedTyping.trackerJS, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.add(shared, contentWorld: .defaultClient, name: handlerName)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let view = message.webView as? FacetWebView else { return }
        view.owner?.handleTypingMessage(body, fromMainFrame: message.frameInfo.isMainFrame)
    }
}

enum UnsavedTyping {
    /// Reads one frame's report. A nil frame means the frame's page went away.
    static func parse(_ body: [String: Any]) -> (id: String, frame: FrameTyping?)? {
        guard let id = body["id"] as? String, !id.isEmpty, id.count <= 32 else { return nil }
        if body["gone"] as? Bool == true { return (id, nil) }
        func time(_ key: String) -> Double? {
            guard let n = body[key] as? NSNumber else { return nil }
            let v = n.doubleValue
            return v.isFinite && v >= 0 ? v : nil
        }
        guard let site = body["site"] as? String, site.count <= 253,
              let typed = body["typed"] as? Bool, let file = body["file"] as? Bool,
              let editAt = time("editAt"), let saveAt = time("saveAt") else { return nil }
        return (id, FrameTyping(site: site, typed: typed, editAt: editAt, saveAt: saveAt, file: file))
    }

    /// True while typing that only the page can keep hasn't been saved by its site, or the
    /// page warned about leaving and hasn't saved since.
    static func isUnsaved(_ frames: [FrameTyping], warnedThroughSave: Double?) -> Bool {
        if frames.contains(where: \.file) { return true }
        var edits: [String: Double] = [:], saves: [String: Double] = [:]
        for f in frames {
            if f.editAt > 0 { edits[f.site] = max(edits[f.site] ?? 0, f.editAt) }
            saves[f.site] = max(saves[f.site] ?? 0, f.saveAt)
        }
        if let warned = warnedThroughSave, (saves.values.max() ?? 0) <= warned { return true }
        return edits.contains { site, at in at > (saves[site] ?? 0) }
    }

    /// Kept fields go back only into the page they came from; the fragment doesn't matter.
    static func samePage(_ a: URL, _ b: URL) -> Bool {
        var x = URLComponents(url: a, resolvingAgainstBaseURL: false); x?.fragment = nil
        var y = URLComponents(url: b, resolvingAgainstBaseURL: false); y?.fragment = nil
        guard let u = x?.url else { return false }
        return u == y?.url
    }

    /// Status text for Sleep Background Tabs.
    static func sleepSummary(slept: Int, kept: Int) -> String {
        let s = "Slept \(slept) tab\(slept == 1 ? "" : "s")"
        switch (slept, kept) {
        case (0, 0): return "Nothing to sleep"
        case (_, 0): return s
        case (0, _): return "Kept \(kept) tab\(kept == 1 ? "" : "s") awake for unsaved typing"
        default: return "\(s), kept \(kept) awake for unsaved typing"
        }
    }

    /// Injected at document start into the main frame, and into a frame when focus moves into
    /// it. Reports at most once a second while the user types (first change at once, the rest
    /// in one trailing message), and watches for save requests only once there is typing.
    static let trackerJS = """
    (() => {
      if (window.__facetTyping) return;
      const T = window.__facetTyping = {edited: new Set(), typed: false, editAt: 0, saveAt: 0, file: false, watching: false, dead: false};
      const id = Math.random().toString(36).slice(2, 12);
      const siteOf = host => {
        const h = String(host || '').toLowerCase().replace(/\\.$/, '');
        const p = h.split('.');
        if (p.length <= 2 || h.includes(':') || /^\\d+$/.test(p[p.length - 1])) return h;
        const n = p[p.length - 1].length === 2 && /^(co|com|net|org|gov|edu|ac|ne|or|go)$/.test(p[p.length - 2]) ? 3 : 2;
        return p.slice(-n).join('.');
      };
      let site = '';
      try { site = siteOf(new URL(self.origin).hostname); } catch (_) { try { site = siteOf(location.hostname); } catch (_) {} }
      let lastSent = 0, timer = 0;
      const post = m => { try { webkit.messageHandlers.facetTyping.postMessage(m); } catch (_) {} };
      const send = () => {
        timer = 0;
        if (T.dead) return;
        lastSent = Date.now();
        post({id, site, typed: T.typed, editAt: T.editAt, saveAt: T.saveAt, file: T.file});
      };
      T.report = () => {
        if (timer || T.dead) return;
        const wait = lastSent + 1000 - Date.now();
        if (wait <= 0) send(); else timer = setTimeout(send, wait);
      };
      // A request to the page's own site, made by script, that isn't plainly analytics.
      const analytics = /(^|\\/)(collect|track|tracking|analytics|telemetry|metrics|logs?|logging|beacon|events?|ping|rum|jot|client_event|stats|pixel|impressions?)(\\/|\\.|$)/i;
      T.watch = () => {
        if (T.watching) return;
        T.watching = true;
        try {
          new PerformanceObserver(list => {
            for (const e of list.getEntries()) {
              if (e.initiatorType !== 'fetch' && e.initiatorType !== 'xmlhttprequest') continue;
              let u; try { u = new URL(e.name); } catch (_) { continue; }
              if (siteOf(u.hostname) !== site || analytics.test(u.pathname)) continue;
              const at = performance.timeOrigin + e.startTime;
              if (at > T.saveAt) { T.saveAt = at; T.report(); }
            }
          }).observe({type: 'resource', buffered: true});
        } catch (_) {}
      };
      const sensitive = el => {
        const type = String(el.type || '').toLowerCase();
        if (type === 'password' || type === 'hidden') return true;
        const hint = [el.getAttribute('autocomplete'), el.name, el.id].join(' ').toLowerCase();
        return /password|one-time-code|cc-|card.?num|cvc|cvv|security.?code|\\bssn\\b|\\botp\\b/.test(hint);
      };
      const onEdit = ev => {
        if (!ev.isTrusted || T.dead) return;
        const el = (ev.composedPath && ev.composedPath()[0]) || ev.target;
        if (!el || el.nodeType !== 1) return;
        const tag = el.tagName;
        if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
          if (sensitive(el)) return;
          if (String(el.type || '').toLowerCase() === 'file') {
            if (!el.files || !el.files.length) return;
            T.file = true;
          } else if (window === top && el.getRootNode() === document && T.edited.size < 500) {
            T.edited.add(el);
          } else {
            T.editAt = Date.now();
          }
        } else {
          T.editAt = Date.now();
        }
        T.typed = true;
        T.watch();
        T.report();
      };
      addEventListener('input', onEdit, true);
      addEventListener('change', onEdit, true);
      // Focus moved into a frame: Facet puts the tracker there too.
      addEventListener('blur', ev => {
        const a = document.activeElement;
        if (ev.target === window && !T.dead && a && (a.tagName === 'IFRAME' || a.tagName === 'FRAME')) post({id, t: 'frameFocus'});
      }, true);
      addEventListener('pagehide', () => {
        T.dead = true;
        if (timer) { clearTimeout(timer); timer = 0; }
        if (window !== top && T.typed) post({id, gone: true});
      }, true);
      // Back from the back/forward cache with the typing still in it: say so again, after
      // Facet has reset the tab for the restored page.
      addEventListener('pageshow', ev => {
        if (!ev.persisted || !T.dead) return;
        T.dead = false; lastSent = 0;
        if (T.typed || T.watching) setTimeout(() => T.report(), 500);
      }, true);
    })();
    """

    /// Run in the main frame just before sleeping. Returns the typed form fields to keep, and
    /// whether the page warns about leaving (asked only when there is editor typing; a page
    /// warning that way is exactly what a browser asks before closing a tab).
    static let prepareJS = """
    const T = window.__facetTyping;
    if (!T) return {fields: [], warns: false};
    const locate = el => {
      if (el.id && document.querySelectorAll('#' + CSS.escape(el.id)).length === 1) return {sel: '#' + CSS.escape(el.id), idx: 0};
      const tag = el.tagName.toLowerCase();
      const sel = el.name ? tag + '[name="' + CSS.escape(el.name) + '"]' : tag;
      return {sel, idx: Array.prototype.indexOf.call(document.querySelectorAll(sel), el)};
    };
    const fields = [];
    let size = 0;
    for (const el of T.edited) {
      if (!el.isConnected) continue;
      const type = String(el.type || '').toLowerCase();
      const f = Object.assign(locate(el), {tag: el.tagName, type});
      if (f.idx < 0) continue;
      if (type === 'checkbox' || type === 'radio') {
        if (el.checked === el.defaultChecked) continue;
        f.checked = el.checked;
      } else {
        if (el.value === '') continue;
        f.value = String(el.value);
        size += f.value.length;
      }
      fields.push(f);
    }
    if (size > 2000000) return {fields: [], warns: false, tooBig: true};
    let warns = false;
    if (probe) {
      try {
        const e = document.createEvent('BeforeUnloadEvent');
        e.initEvent('beforeunload', false, true);
        window.dispatchEvent(e);
        warns = e.defaultPrevented || (typeof e.returnValue === 'string' && e.returnValue !== '');
      } catch (_) {}
    }
    return {fields, warns};
    """

    /// Run in the main frame after the page loads again. Fills each kept field the page left
    /// empty, with the events script-driven forms (React, Vue) listen for, waiting up to ten
    /// seconds for fields a page builds late. Returns the fields it couldn't find.
    static let restoreJS = """
    const T = window.__facetTyping;
    const setter = {
      INPUT: Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set,
      TEXTAREA: Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set,
      SELECT: Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set,
    };
    const find = f => {
      const el = document.querySelectorAll(f.sel)[f.idx];
      return el && el.tagName === f.tag && String(el.type || '').toLowerCase() === f.type ? el : null;
    };
    const untouched = el => {
      if (el.tagName === 'SELECT') {
        const d = Array.prototype.findIndex.call(el.options, o => o.defaultSelected);
        return el.selectedIndex === (d < 0 ? 0 : d);
      }
      return el.value === '' || el.value === el.defaultValue;
    };
    const apply = (f, el) => {
      if ('checked' in f) {
        if (el.checked === el.defaultChecked && el.checked !== !!f.checked) el.click();
      } else if (untouched(el) && el.value !== f.value) {
        setter[el.tagName].call(el, f.value);
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
      }
      if (T && T.edited.size < 500) T.edited.add(el);
    };
    let pending = fields.slice(), restored = 0;
    const pass = () => {
      pending = pending.filter(f => {
        const el = find(f);
        if (!el) return true;
        apply(f, el); restored++;
        return false;
      });
    };
    pass();
    if (pending.length) {
      await new Promise(resolve => {
        let timer = 0;
        const observer = new MutationObserver(() => { pass(); if (!pending.length) done(); });
        function done() { observer.disconnect(); clearTimeout(timer); resolve(); }
        timer = setTimeout(done, 10000);
        observer.observe(document.documentElement || document, {childList: true, subtree: true});
      });
    }
    if (T && restored) { T.typed = true; T.report(); }
    return {restored, missing: pending};
    """
}
