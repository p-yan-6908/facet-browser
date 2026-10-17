import Foundation

/// The page-side of the password manager: a detector that reports a submitted login to the
/// isolated bridge, and a filler that types a saved login into a page's login form. Both run
/// in WebKit's isolated `defaultClient` world, so page scripts cannot see or spoof them.
enum PasswordForms {
    /// Appended inside the bridge IIFE, so it can call the bridge's own `post`. Reads only the
    /// values the user typed and posts them to Facet's isolated handler; nothing reaches the page.
    static let captureJS = """
      const pwFieldFor = scope => {
        const pws = Array.from(scope.querySelectorAll('input[type=password]')).filter(e => !e.disabled);
        return pws.find(e => e.value) || pws[0] || null;
      };
      const userFieldFor = (scope, pw) => {
        const texts = Array.from(scope.querySelectorAll('input')).filter(e => {
          const t = (e.type || 'text').toLowerCase();
          return (t === 'text' || t === 'email' || t === 'tel') && !e.disabled;
        });
        return texts.find(e => (e.getAttribute('autocomplete') || '').includes('username'))
            || texts.find(e => (e.type || '').toLowerCase() === 'email')
            || texts.filter(e => pw && (e.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING)).pop()
            || texts[0] || null;
      };
      const reportLogin = scope => {
        const pw = pwFieldFor(scope || document);
        if (!pw || !pw.value) return;
        const user = userFieldFor(pw.form || scope || document, pw);
        post({t: 'login', u: user ? String(user.value || '') : '', p: String(pw.value || '')});
      };
      document.addEventListener('submit', ev => {
        reportLogin(ev.target && ev.target.tagName === 'FORM' ? ev.target : null);
      }, {capture: true});
      document.addEventListener('click', ev => {
        const t = ev.target;
        const btn = t && t.closest ? t.closest("button, input[type=submit], [role=button]") : null;
        if (btn && (btn.type !== 'button' || /log|sign|continue|next|submit/i.test(btn.textContent || btn.value || '')))
          setTimeout(() => reportLogin(btn.form || null), 0);
      }, {capture: true});
      window.addEventListener('pagehide', () => reportLogin(null), {capture: true});
    """

    /// Fills a saved login into the page's login form, firing the input/change events that
    /// script-driven forms watch. Returns true when a password field was filled.
    static func fillJS(username: String, password: String) -> String {
        """
        (() => {
          const U = \(jsLiteral(username)), P = \(jsLiteral(password));
          const visible = e => e.offsetParent !== null || (e.getClientRects && e.getClientRects().length > 0);
          const pws = Array.from(document.querySelectorAll('input[type=password]')).filter(e => !e.disabled);
          const pw = pws.find(visible) || pws[0];
          if (!pw) return false;
          const scope = pw.form || document;
          const texts = Array.from(scope.querySelectorAll('input')).filter(e => {
            const t = (e.type || 'text').toLowerCase();
            return (t === 'text' || t === 'email' || t === 'tel') && !e.disabled;
          });
          const user = texts.find(e => (e.getAttribute('autocomplete') || '').includes('username'))
              || texts.find(e => (e.type || '').toLowerCase() === 'email')
              || texts.filter(e => e.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING).pop()
              || texts[0];
          const setValue = (el, value) => {
            if (!el) return;
            const d = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (d && d.set) d.set.call(el, value); else el.value = value;
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
          };
          if (user && U) setValue(user, U);
          setValue(pw, P);
          return true;
        })()
        """
    }

    /// JSON string literal for safe interpolation into the scripts above.
    static func jsLiteral(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [string])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }
}
