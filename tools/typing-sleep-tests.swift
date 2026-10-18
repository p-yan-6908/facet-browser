import AppKit
import WebKit

extension PolishTests {
    /// The decisions behind keeping typing when a tab sleeps. No WebKit.
    static func typingDecisions() {
        let body: [String: Any] = ["id": "f1", "site": "google.com", "typed": true, "editAt": 1000.0, "saveAt": 0.0, "file": false]
        let parsed = UnsavedTyping.parse(body)
        expect(parsed?.id == "f1" && parsed?.frame == FrameTyping(site: "google.com", typed: true, editAt: 1000, saveAt: 0, file: false),
               "a frame's typing report parses")
        expect(UnsavedTyping.parse(["id": "f1", "gone": true]).map { $0.frame == nil } == true, "a frame that went away is dropped")
        var bad = body; bad["editAt"] = Double.nan
        var long = body; long["id"] = String(repeating: "x", count: 40)
        expect(UnsavedTyping.parse(bad) == nil && UnsavedTyping.parse(["site": "x"]) == nil && UnsavedTyping.parse(long) == nil,
               "malformed typing reports are ignored")

        func frame(_ site: String, edit: Double = 0, save: Double = 0, file: Bool = false) -> FrameTyping {
            FrameTyping(site: site, typed: true, editAt: edit, saveAt: save, file: file)
        }
        expect(!UnsavedTyping.isUnsaved([frame("a.test")], warnedThroughSave: nil), "typing only in form fields never holds a tab awake")
        expect(UnsavedTyping.isUnsaved([frame("a.test", edit: 10)], warnedThroughSave: nil), "editor typing with no save holds the tab awake")
        expect(!UnsavedTyping.isUnsaved([frame("a.test", edit: 10, save: 11)], warnedThroughSave: nil), "a save after the last keystroke releases it")
        expect(UnsavedTyping.isUnsaved([frame("a.test", edit: 10, save: 9)], warnedThroughSave: nil), "a save before the last keystroke doesn't")
        expect(!UnsavedTyping.isUnsaved([frame("google.com", edit: 10), frame("google.com", save: 12)], warnedThroughSave: nil),
               "a save from another frame of the same site counts (Google Docs types in a frame)")
        expect(UnsavedTyping.isUnsaved([frame("disqus.com", edit: 10), frame("news.test", save: 12)], warnedThroughSave: nil),
               "another site's request doesn't count as a save")
        expect(UnsavedTyping.isUnsaved([frame("a.test", file: true)], warnedThroughSave: nil), "a chosen file holds the tab awake")
        expect(UnsavedTyping.isUnsaved([frame("a.test", edit: 10, save: 11)], warnedThroughSave: 11)
               && !UnsavedTyping.isUnsaved([frame("a.test", edit: 10, save: 12)], warnedThroughSave: 11),
               "a page that warned about leaving is unsaved until it saves again")
        expect(UnsavedTyping.samePage(URL(string: "https://a.test/f?x=1#top")!, URL(string: "https://a.test/f?x=1")!)
               && !UnsavedTyping.samePage(URL(string: "https://a.test/f?x=1")!, URL(string: "https://a.test/f?x=2")!),
               "kept fields go back only to the same page")
        expect(UnsavedTyping.sleepSummary(slept: 0, kept: 0) == "Nothing to sleep"
               && UnsavedTyping.sleepSummary(slept: 2, kept: 1) == "Slept 2 tabs, kept 1 awake for unsaved typing"
               && UnsavedTyping.sleepSummary(slept: 0, kept: 1) == "Kept 1 tab awake for unsaved typing",
               "Sleep Background Tabs says what it kept awake")
    }

    @discardableResult
    static func typingJS(_ tab: Tab, _ body: String, in world: WKContentWorld = .page) -> Any? {
        guard let wv = tab.webView else { return nil }
        var done = false
        var out: Any?
        wv.callAsyncJavaScript(body, arguments: [:], in: nil, in: world) { result in
            if case .success(let v) = result { out = v }
            done = true
        }
        let end = Date().addingTimeInterval(5)
        while !done && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return out
    }

    /// Types the way a user does: the editing commands raise trusted input events.
    static func typeInto(_ tab: Tab, _ selector: String, _ text: String, frame: String = "document") {
        typingJS(tab, """
        const doc = \(frame);
        const el = doc.querySelector(\(PasswordForms.jsLiteral(selector)));
        el.focus();
        if (el.select) el.select(); else doc.getSelection().selectAllChildren(el);
        doc.execCommand('insertText', false, \(PasswordForms.jsLiteral(text)));
        return 1
        """)
    }

    /// Real WebKit pages: form fields kept across sleep, editors held until their site saves.
    static func typingSleepWebKit() throws {
        _ = NSApplication.shared
        var port: UInt16 = 0
        var saves = 0
        let reactLike = """
        (function track(node) {
          const d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
          let current = node.value;
          Object.defineProperty(node, 'value', {configurable: true,
            get() { return d.get.call(this); }, set(v) { current = '' + v; d.set.call(this, v); }});
          document.addEventListener('input', e => {
            if (e.target !== node) return;
            const next = d.get.call(node);
            if (next !== current) { current = next; appState.app = next; node.setAttribute('value', next); }
          }, true);
        })
        """
        let server = try LoopbackServer { request in
            let line = request.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ").map(String.init)
            let method = parts.first ?? "GET", target = parts.count > 1 ? parts[1] : "/"
            let path = String(target.split(separator: "?").first ?? "/")
            if method == "POST" || path.hasPrefix("/api/") || path == "/collect" {
                if path == "/api/save" && request.contains("Host: 127.0.0.1") { saves += 1 }
                return LoopbackServer.response("204 No Content", ["Access-Control-Allow-Origin": "*"], Data())
            }
            switch path {
            case "/form":
                return LoopbackServer.html("""
                <title>Form</title>
                <form><input id=name><textarea id=notes></textarea>
                <select id=size><option value=s>S</option><option value=m>M</option><option value=l>L</option></select>
                <input id=agree type=checkbox><input name=nick><input id=pw type=password>
                <input id=card autocomplete=cc-number><input id=scripted><input id=prefilled></form>
                <div id=later></div>
                <script>
                  window.appState = {app: ''};
                  const app = document.createElement('input'); app.id = 'app'; document.forms[0].appendChild(app);
                  (\(reactLike))(app);
                  document.getElementById('prefilled').value = 'server value';
                  setTimeout(() => { const late = document.createElement('input'); late.id = 'late';
                    document.getElementById('later').appendChild(late); }, 400);
                </script>
                """)
            case "/editor":
                return LoopbackServer.html("""
                <title>Editor</title><div id=doc contenteditable=true>start</div>
                <script>
                  const mode = new URLSearchParams(location.search).get('mode');
                  window.dirty = false; let t = 0;
                  const save = () => fetch('/api/save', {method: 'POST', body: document.getElementById('doc').textContent});
                  document.getElementById('doc').addEventListener('input', () => {
                    dirty = true;
                    if (mode === 'analytics') {
                      fetch('/collect?e=key');
                      fetch('http://localhost:\(port)/api/save', {method: 'POST', mode: 'no-cors', body: 'x'});
                    }
                    if (mode === 'autosave' || mode === 'stubborn') {
                      clearTimeout(t);
                      t = setTimeout(() => save().then(() => { if (mode === 'autosave') dirty = false; }), 300);
                    }
                  });
                  window.finishSave = () => save().then(() => { dirty = false; });
                  addEventListener('beforeunload', e => {
                    if (dirty && (mode === 'autosave' || mode === 'stubborn')) { e.preventDefault(); e.returnValue = ''; }
                  });
                </script>
                """)
            case "/frames":
                return LoopbackServer.html("""
                <title>Frames</title><iframe id=f src="/frame-editor"></iframe>
                <script>
                  const mode = new URLSearchParams(location.search).get('mode');
                  addEventListener('message', e => {
                    if (e.data === 'typed' && mode === 'autosave') setTimeout(() => fetch('/api/save', {method: 'POST', body: 'x'}), 300);
                  });
                </script>
                """)
            case "/frame-editor":
                return LoopbackServer.html("""
                <div id=doc contenteditable=true>frame</div><textarea id=ta></textarea>
                <script>document.addEventListener('input', () => parent.postMessage('typed', '*'));</script>
                """)
            default:
                return LoopbackServer.html("<title>Blank</title><p>blank</p>")
            }
        }
        defer { server.stop() }
        guard wait("typing fixture server ready", until: { server.port != nil }), let p = server.port else { return }
        port = p
        func page(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
        let c = BrowserWindowController(isPrivate: true)
        MemoryBudgetController.shared.register(c)
        defer { MemoryBudgetController.shared.unregister(c) }
        let front = c.newTab(url: page("/blank"))
        func open(_ path: String, title: String) -> Tab {
            let tab = c.newTab(url: page(path), activate: false)
            tab.ensureLoaded().frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            wait("\(title) page loads", seconds: 15, until: { tab.webView?.isLoading == false && tab.title == title })
            return tab
        }
        func trySleep(_ tab: Tab) -> Bool? {
            var result: Bool?
            tab.sleep(if: { tab !== c.activeTab }) { result = $0 }
            wait("the page answers before sleeping", until: { result != nil })
            return result
        }
        func pause(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

        // Form fields: kept when the tab sleeps, put back when it wakes.
        let form = open("/form", title: "Form")
        wait("the late field is built", until: { typingJS(form, "return !!document.getElementById('late')") as? Bool == true })
        for (selector, text) in [("#name", "Ada Lovelace"), ("#notes", "first line\nsecond line"), ("#app", "react state"),
                                 ("[name=nick]", "ada"), ("#late", "built late"), ("#prefilled", "mine"),
                                 ("#pw", "hunter2"), ("#card", "4111111111111111")] {
            typeInto(form, selector, text)
        }
        typingJS(form, "const s = document.getElementById('scripted'); s.value = 'set by script'; s.dispatchEvent(new Event('input', {bubbles: true})); return 1")
        // Choosing from a menu and ticking a box need real clicks; mark them as the tracker would.
        typingJS(form, """
        const T = window.__facetTyping, s = document.getElementById('size'), a = document.getElementById('agree');
        s.value = 'l'; a.checked = true; T.edited.add(s); T.edited.add(a); return 1
        """, in: .defaultClient)
        wait("typing in the page is noticed", until: { form.hasTyped })
        expect(!form.hasUnsavedTyping && form.canHibernateForBudget, "typing in plain form fields doesn't hold a tab awake")
        expect(typingJS(form, "return typeof window.__facetTyping") as? String == "undefined", "the page can't see Facet's typing tracker")
        expect(trySleep(form) == true && form.isHibernated, "a tab with typed form fields still sleeps and frees its process")
        let kept = String(describing: form.keptFields ?? [])
        expect(kept.contains("Ada Lovelace") && kept.contains("built late") && (form.keptFields?.count ?? 0) == 8,
               "the typed fields are kept while the tab sleeps")
        expect(!kept.contains("hunter2") && !kept.contains("4111") && !kept.contains("set by script"),
               "passwords, card numbers and values set by script are never kept")
        expect(form.hoverDescription.contains("your typing is kept"), "hover text says the typing is kept")

        form.ensureLoaded().frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let read = """
        const v = id => (document.getElementById(id) || {}).value;
        return JSON.stringify([v('name'), v('notes'), v('app'), appState.app, document.querySelector('[name=nick]').value, v('late'),
          v('size'), document.getElementById('agree').checked, v('prefilled'), v('pw'), v('card'), v('scripted')])
        """
        let expected = #"["Ada Lovelace","first line\nsecond line","react state","react state","ada","built late","l",true,"server value","","",""]"#
        wait("typing comes back when the tab wakes", seconds: 15, until: { typingJS(form, read) as? String == expected })
        if typingJS(form, read) as? String != expected { print("  restored:", typingJS(form, read) ?? "nil") }
        expect(form.keptFields == nil, "kept fields are used up once they are back")
        wait("put-back typing counts as typing again", until: { form.hasTyped })
        expect(trySleep(form) == true && String(describing: form.keptFields ?? []).contains("Ada Lovelace"),
               "sleeping again keeps the same typing again")
        form.ensureLoaded().frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        wait("typing comes back a second time", seconds: 15, until: { typingJS(form, read) as? String == expected })

        // An editor that never saves: the tab stays awake until the page goes away.
        let plain = open("/blank", title: "Blank")
        let editor = open("/editor?mode=none", title: "Editor")
        typeInto(editor, "#doc", "my draft")
        wait("unsaved editor typing is noticed", until: { editor.hasUnsavedTyping })
        pause(1.5)
        expect(editor.hasUnsavedTyping && !editor.canHibernateForBudget && trySleep(editor) == false && !editor.isHibernated,
               "a page with unsaved editor typing stays awake")
        expect(editor.hoverDescription.contains("awake to keep unsaved typing"), "hover text says why the tab is awake")
        let rows = TaskManager.rows(windows: [c], sample: MemoryMonitor.sample())
        let row = rows.first { $0.tab === editor }
        expect(row?.status == "Unsaved typing" && row.map(TaskManager.canSleep) == false, "Task Manager shows unsaved typing and won't sleep it")
        plain.keepAwake = true
        let plainRow = TaskManager.rows(windows: [c], sample: MemoryMonitor.sample()).first { $0.tab === plain }
        expect(plainRow.map(TaskManager.canSleep) == true, "Task Manager can still sleep a tab kept awake")
        var forced: Bool?
        plain.sleep { forced = $0 }
        expect(forced == false && !plain.isHibernated, "automatic sleep leaves a tab kept awake alone")
        plain.sleep(overridingKeepAwake: true) { forced = $0 }
        expect(forced == true && plain.isHibernated, "an explicit Sleep Tab sleeps it anyway")
        plain.keepAwake = false
        plain.ensureLoaded().frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        wait("the kept-awake tab wakes again", seconds: 10, until: { plain.webView?.isLoading == false && plain.title == "Blank" })
        var editorForced: Bool?
        editor.sleep(overridingKeepAwake: true) { editorForced = $0 }
        expect(editorForced == false && !editor.isHibernated, "even an explicit Sleep Tab won't drop unsaved typing")
        MemoryBudgetController.shared.handleMemoryPressure()
        wait("memory pressure sleeps untyped background tabs", until: { plain.isHibernated })
        expect(!editor.isHibernated && (typingJS(editor, "return document.getElementById('doc').textContent") as? String)?.contains("my draft") == true,
               "memory pressure leaves unsaved typing alone")
        c.contentBlockingSettingDidChange()
        expect(!editor.isHibernated && (typingJS(editor, "return document.getElementById('doc').textContent") as? String)?.contains("my draft") == true,
               "switching blocking on or off doesn't rebuild tabs and lose typing")
        editor.load(page("/blank"))
        wait("leaving the page releases the tab", seconds: 10, until: { editor.title == "Blank" && !editor.hasTyped && editor.canHibernateForBudget })

        // An editor that saves as you type, like Google Docs: awake only until it has saved.
        let docs = open("/editor?mode=autosave", title: "Editor")
        let savesBefore = saves
        typeInto(docs, "#doc", "autosaved words")
        wait("an autosaving editor is unsaved right after typing", until: { docs.hasUnsavedTyping })
        wait("and saved once its save request goes out", until: { !docs.hasUnsavedTyping })
        expect(saves > savesBefore && trySleep(docs) == true && docs.isHibernated, "an autosaving editor sleeps once it has saved")

        // Saved by request but still warning about leaving: the page's word wins.
        let stubborn = open("/editor?mode=stubborn", title: "Editor")
        typeInto(stubborn, "#doc", "not done")
        wait("a warning editor is unsaved right after typing", until: { stubborn.hasUnsavedTyping })
        wait("its save request is seen", until: { !stubborn.hasUnsavedTyping })
        expect(trySleep(stubborn) == false && !stubborn.isHibernated && stubborn.hasUnsavedTyping,
               "a page that warns about leaving stays awake")
        typingJS(stubborn, "finishSave(); return 1")
        wait("it is released after its next save", until: { !stubborn.hasUnsavedTyping })
        expect(trySleep(stubborn) == true, "and then sleeps")

        // Analytics and other sites' requests aren't saves.
        let tracked = open("/editor?mode=analytics", title: "Editor")
        typeInto(tracked, "#doc", "tracked words")
        wait("typing in the tracked editor is noticed", until: { tracked.hasUnsavedTyping })
        wait("the analytics and cross-site requests are made", until: {
            server.requests.contains { $0.hasPrefix("GET /collect") } && server.requests.contains { $0.contains("Host: localhost") }
        })
        pause(1.5)
        expect(tracked.hasUnsavedTyping, "analytics and other sites' requests don't count as saving")

        // Editors inside frames, saved by the page around them (how Google Docs types).
        let framed = open("/frames?mode=autosave", title: "Frames")
        let inFrame = "document.getElementById('f').contentDocument"
        wait("the frame loads", until: { typingJS(framed, "return !!\(inFrame).getElementById('doc')") as? Bool == true })
        expect(framed.trackedFrameCount == 0, "frames get no tracker until someone clicks into them")
        // Clicking into a frame of the page being used: the page sees focus leave for it.
        func show(_ tab: Tab) {
            if let i = c.tabs.firstIndex(where: { $0 === tab }) { c.selectTab(index: i) }
        }
        show(framed)
        _ = c.window?.makeFirstResponder(framed.webView)
        typingJS(framed, "\(inFrame).getElementById('doc').focus(); return 1")
        wait("focusing a frame puts the tracker there", until: { framed.trackedFrameCount >= 1 })
        typeInto(framed, "#doc", "framed words", frame: inFrame)
        wait("typing in a frame is noticed", until: { framed.hasUnsavedTyping })
        show(front)
        wait("a save from the page around it counts", until: { !framed.hasUnsavedTyping })
        expect(trySleep(framed) == true, "a framed editor sleeps once its site has saved")
        let unsavedFrame = open("/frames?mode=none", title: "Frames")
        wait("the second frame loads", until: { typingJS(unsavedFrame, "return !!\(inFrame).getElementById('ta')") as? Bool == true })
        // A page that focuses its own frame in the background: found when the user clicks in.
        typingJS(unsavedFrame, "\(inFrame).getElementById('ta').focus(); return 1")
        pause(0.3)
        expect(unsavedFrame.trackedFrameCount == 0, "a frame focused in the background isn't tracked yet")
        show(unsavedFrame)
        _ = c.window?.makeFirstResponder(unsavedFrame.webView)
        wait("clicking into the page finds the focused frame", until: { unsavedFrame.trackedFrameCount >= 1 })
        typeInto(unsavedFrame, "#ta", "frame text", frame: inFrame)
        wait("typing in a frame's text box is noticed", until: { unsavedFrame.hasUnsavedTyping })
        show(front)
        pause(1.2)
        expect(unsavedFrame.hasUnsavedTyping && trySleep(unsavedFrame) == false, "a text box in a frame holds the tab until saved")
        _ = front
        for tab in c.tabs { tab.hibernate() }
    }
}
