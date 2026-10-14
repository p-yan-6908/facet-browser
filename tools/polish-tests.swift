import AppKit
import WebKit
import SQLite3

/// Intercepts URLSession requests in-process. No provider calls leave this test process.
final class FixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var mode = "text"
    static var requests = 0
    static var stops = 0
    private var work: DispatchWorkItem?
    static func reset(_ value: String) { lock.lock(); mode = value; requests = 0; stops = 0; lock.unlock() }
    static var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (requests, stops) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; let index = Self.requests; let mode = Self.mode; Self.lock.unlock()
        let anthropic = request.url!.path.hasSuffix("/messages")
        let object: [String: Any]
        if mode == "tools" && index == 1 {
            object = anthropic
                ? ["content": [["type": "tool_use", "id": "call1", "name": "close_tab", "input": ["tab_id": "fixture"]]]]
                : ["output": [["type": "function_call", "call_id": "call1", "name": "close_tab", "arguments": "{\"tab_id\":\"fixture\"}"]]]
        } else if mode == "error" {
            object = ["error": ["message": "fixture rejected request"]]
        } else {
            object = anthropic
                ? ["content": [["type": "text", "text": "Fixture answer"]]]
                : ["output": [["type": "message", "content": [["type": "output_text", "text": "Fixture answer"]]]]]
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: mode == "error" ? 401 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + (mode == "delay" ? 1 : 0.02), execute: work)
    }
    override func stopLoading() { work?.cancel(); Self.lock.lock(); Self.stops += 1; Self.lock.unlock() }
}

@main
struct PolishTests {
    static var checks = 0
    static var failures: [String] = []
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message); print("FAIL: \(message)") }
    }
    @discardableResult static func wait(_ message: String, seconds: Double = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        let ok = condition(); expect(ok, message); return ok
    }
    static func sql(_ db: OpaquePointer?, _ text: String) throws {
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "FixtureSQL", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("facet-polish-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Redirect before initializing either singleton; real Facet files are never loaded.
        Config.supportDir = root
        defer { try? FileManager.default.removeItem(at: root) }
        Config.shared.memoryBudgetMB = 0
        Config.shared.enableDeveloperTools = false
        Config.shared.blockAdsAndTrackers = false
        URLProtocol.registerClass(FixtureProtocol.self)
        try imports(root)
        try navigation()
        try chromeSessions(root)
        sessionAndMemory(root)
        assistant()
        if CommandLine.arguments.contains("--webkit") { try webKitPrivacy(); assistantSidebarUI(); try cookieStoreRoundTrip(); sessionImportConsentUI(root) }
        else { print("SKIP: WebKit UI probes (run with --webkit in a macOS GUI session)") }
        print("\(checks - failures.count)/\(checks) checks passed")
        if !failures.isEmpty { exit(1) }
    }

    static func imports(_ root: URL) throws {
        let profile = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let historyURL = profile.appendingPathComponent("History")
        var db: OpaquePointer?
        guard sqlite3_open(historyURL.path, &db) == SQLITE_OK else { fatalError("fixture open") }
        defer { sqlite3_close(db) }
        try sql(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE urls(url TEXT,title TEXT,visit_count INTEGER,last_visit_time INTEGER); INSERT INTO urls VALUES('https://example.test/','Chrome title',7,13344473600000000);")
        let bookmarksURL = profile.appendingPathComponent("Bookmarks")
        let bookmarks: [String: Any] = ["roots": ["bookmark_bar": ["children": [
            ["url": "https://example.test/", "name": "Example"],
            ["children": [["url": "https://nested.test/", "name": "Nested"], ["url": "https://example.test/", "name": "Duplicate"], ["url": "javascript:alert(1)", "name": "Unsafe"]]]
        ]]]]
        try JSONSerialization.data(withJSONObject: bookmarks).write(to: bookmarksURL)
        let importer = BrowserImportService.shared
        let source = importer.customChromiumSource(profileURL: profile)!
        let beforeDB = try Data(contentsOf: historyURL)
        let beforeWAL = try Data(contentsOf: URL(fileURLWithPath: historyURL.path + "-wal"))
        let (b, h, warnings) = try importer.readData(from: source, bookmarks: true, history: true)
        expect(b.count == 2, "nested bookmarks deduplicated and non-web URLs excluded")
        expect(h.count == 1 && h[0].title == "Chrome title" && h[0].visits == 7, "committed WAL history is included")
        expect(h.first?.lastVisit.timeIntervalSince1970 == 1_700_000_000, "Chrome timestamp conversion")
        expect(warnings.isEmpty, "valid import has no warning")
        let afterDB = try Data(contentsOf: historyURL), afterWAL = try Data(contentsOf: URL(fileURLWithPath: historyURL.path + "-wal"))
        expect(beforeDB == afterDB && beforeWAL == afterWAL, "source database and WAL are unchanged")
        try sql(db, "BEGIN; INSERT INTO urls VALUES('https://uncommitted.test/','Not committed',1,13344473600000000);")
        let (_, isolated, _) = try importer.readData(from: source, bookmarks: false, history: true)
        expect(isolated.count == 1, "uncommitted history is excluded")
        try sql(db, "ROLLBACK;")
        expect(Store.shared.importBookmarks(b) == 2 && Store.shared.importBookmarks(b) == 0, "bookmark import is idempotent")
        expect(Store.shared.importHistory(h) == 1 && Store.shared.importHistory(h) == 0, "history import is idempotent")
        expect(Store.shared.history.first?.visits == 7, "repeat import does not inflate visits")
        try Data("not json".utf8).write(to: bookmarksURL)
        let (_, partial, partialWarnings) = try importer.readData(from: source, bookmarks: true, history: true)
        expect(partial.count == 1 && partialWarnings.count == 1, "partial import retains readable history and warns")
        do { _ = try importer.readData(from: source, bookmarks: true, history: false); expect(false, "total failure must throw") }
        catch { expect(true, "total failure throws") }
        do { _ = try importer.readData(from: source, bookmarks: false, history: false); expect(false, "empty selection must throw") }
        catch { expect(true, "empty selection throws") }
        var completed = false
        importer.importData(from: source, bookmarks: true, history: false) { result in
            expect(Thread.isMainThread, "import completion delivered on main thread")
            if case .success = result { expect(false, "async import must not report all-failed as success") }
            completed = true
        }
        wait("async import finishes", until: { completed })
        try sql(db, "INSERT INTO urls VALUES('https://large.test/','Huge',9223372036854775807,13344473600000000);")
        let (_, large, _) = try importer.readData(from: source, bookmarks: false, history: true)
        expect(large.contains { $0.visits == Int(Int32.max) }, "oversized visit count is safely clamped")

        let places = profile.appendingPathComponent("places.sqlite")
        var firefox: OpaquePointer?; sqlite3_open(places.path, &firefox); defer { sqlite3_close(firefox) }
        try sql(firefox, "CREATE TABLE moz_places(id INTEGER,url TEXT,title TEXT,visit_count INTEGER,last_visit_date INTEGER); CREATE TABLE moz_bookmarks(fk INTEGER,title TEXT,dateAdded INTEGER,type INTEGER); INSERT INTO moz_places VALUES(1,'https://firefox.test/','History',3,1700000000000000); INSERT INTO moz_bookmarks VALUES(1,'Bookmark',1700000000000000,1);")
        let ff = BrowserImportSource(id: "ff", browserName: "Firefox", profileName: "Test", profileURL: profile, format: .firefox, bookmarksURL: places, historyURL: places)
        let (fb, fh, _) = try importer.readData(from: ff, bookmarks: true, history: true)
        expect(fb.first?.title == "Bookmark" && fh.first?.lastVisit.timeIntervalSince1970 == 1_700_000_000, "Firefox SQL and timestamps still work")
        let safariURL = profile.appendingPathComponent("History.db")
        var safari: OpaquePointer?; sqlite3_open(safariURL.path, &safari); defer { sqlite3_close(safari) }
        try sql(safari, "CREATE TABLE history_items(id INTEGER,url TEXT,visit_count INTEGER); CREATE TABLE history_visits(history_item INTEGER,title TEXT,visit_time REAL); INSERT INTO history_items VALUES(1,'https://safari.test/',2); INSERT INTO history_visits VALUES(1,'Safari title',721692800);")
        let sf = BrowserImportSource(id: "sf", browserName: "Safari", profileName: "Test", profileURL: profile, format: .safari, bookmarksURL: nil, historyURL: safariURL)
        let (_, sh, _) = try importer.readData(from: sf, bookmarks: false, history: true)
        expect(sh.first?.lastVisit.timeIntervalSince1970 == 1_700_000_000, "Safari timestamp conversion still works")
    }

    static func navigation() throws {
        let cases = ["localhost:3000/path?q=1": "http://localhost:3000/path?q=1", "LOCALHOST:8080": "http://LOCALHOST:8080", "127.0.0.1:8000": "http://127.0.0.1:8000", "192.168.1.2": "http://192.168.1.2", "[::1]:9000/a": "http://[::1]:9000/a", "example.com?q=hello#top": "https://example.com?q=hello#top", "example.com:8443/path": "https://example.com:8443/path", "https://example.com/a": "https://example.com/a"]
        for (input, output) in cases { expect(Config.shared.resolve(input: input)?.absoluteString == output, "resolve \(input)") }
        for query in ["two words", "hello\nworld", "999.999.999.999", "example.com:99999"] {
            expect(Config.shared.resolve(input: query)?.host == "www.google.com", "search fallback for \(query)")
        }
        expect(Config.shared.resolve(input: " \n") == nil, "blank input ignored")
        for input in ["file:///etc/passwd", "about:blank", "https://user:secret@example.com/"] {
            do { _ = try BrowserAgentSession.webURL(input); expect(false, "agent blocks \(input)") } catch { expect(true, "agent blocks non-web or credential URL") }
        }
        expect(AgentEndpoint.openAI(" https://api.example.test/v1/ ")?.path == "/v1/responses", "endpoint suffix normalization")
        expect(AgentEndpoint.anthropic("http://127.0.0.1:8080/v1/messages/")?.path == "/v1/messages", "local provider and full endpoint supported")
        for input in ["file:///tmp/key", "relative", "https://user:pass@host/v1", "http://remote.test/v1", "https://host/v1?key=secret", "https://host/v1#fragment"] {
            expect(AgentEndpoint.openAI(input) == nil, "reject unsafe endpoint \(input)")
        }
    }

    static func sessionAndMemory(_ root: URL) {
        var estimator = MemoryReclaimEstimator()
        let mb: UInt64 = 1_048_576
        estimator.observe(before: 500 * mb, after: 400 * mb)
        expect(estimator.observations == 1 && estimator.learnedBytes == 100 * mb, "adaptive RAM estimator learns measured reclaim")
        let learned = estimator.learnedBytes
        estimator.observe(before: 400 * mb, after: 397 * mb)
        expect(estimator.observations == 1 && estimator.learnedBytes == learned, "adaptive RAM estimator ignores process noise")
        estimator.observe(before: 400 * mb, after: 200 * mb)
        expect(estimator.observations == 2 && estimator.learnedBytes > learned, "adaptive RAM estimator adapts to heavier pages")
        expect(estimator.predictedWakeBytes > estimator.conservativeReclaimBytes, "pre-wake estimate stays conservative")

        let a = SavedTab(url: "https://one.test/", title: "One", interactionState: Data([1,2,3]))
        let b = SavedTab(url: "https://two.test/", title: "Two", interactionState: nil)
        let frame = NSRect(x: 20, y: 30, width: 900, height: 700)
        Store.shared.saveSession(windows: [SavedWindow(tabs: [a,b], activeIndex: 1, frame: frame), SavedWindow(tabs: [b], activeIndex: 0, frame: nil)], selectedWindow: 1)
        let multi = Store.shared.loadSessionWindows()
        expect(multi.windows.count == 2 && multi.selectedWindow == 1, "multi-window session persists every normal window")
        expect(multi.windows[0].activeIndex == 1 && multi.windows[0].tabs.count == 2, "multi-window active tab and tabs round-trip")
        expect(multi.windows[0].frame?.size.width == 900 && multi.windows[0].tabs[0].interactionState == Data([1,2,3]), "window frame and interaction state round-trip")

        let legacy: [String: Any] = ["tabs": [["url":"https://legacy.test/","title":"Legacy"]], "active": 0]
        let sessionURL = Config.supportDir.appendingPathComponent("session.json")
        try? JSONSerialization.data(withJSONObject: legacy).write(to: sessionURL, options: .atomic)
        let migrated = Store.shared.loadSessionWindows()
        expect(migrated.windows.count == 1 && migrated.windows[0].tabs.first?.url == "https://legacy.test/", "legacy single-window session migrates")

        expect(BrowserAgentService.tools.contains { ($0["name"] as? String) == "visual_inspect" }, "visual fallback tool registered")
        expect(!BrowserAgentService.requiresApproval("visual_inspect"), "visual inspection remains read-only")
    }

    static func assistant() {
        let service = BrowserAgentService.shared
        service.apiKeyOverride = "synthetic-key"
        Config.shared.agentEnabled = true
        Config.shared.agentBaseURL = "https://provider.invalid/v1"
        Config.shared.agentModel = "fixture"
        for provider in ["openai", "anthropic"] {
            Config.shared.agentProvider = provider
            FixtureProtocol.reset("delay")
            var completions = 0
            service.run(prompt: "fixture", status: { _ in }) { result in
                completions += 1
                if case .failure(let error) = result { expect(error is AgentToolError, "\(provider) cancelled with agent error") }
                else { expect(false, "\(provider) cancellation must fail") }
            }
            wait("\(provider) started request", until: { FixtureProtocol.counts.0 == 1 })
            var rejectedConcurrent = false
            service.run(prompt: "second", status: { _ in }) { if case .failure = $0 { rejectedConcurrent = true } }
            expect(rejectedConcurrent, "\(provider) rejects concurrent run")
            service.cancel(); service.cancel()
            expect(completions == 1, "\(provider) cancellation completes once immediately")
            wait("\(provider) cancels network request", until: { FixtureProtocol.counts.1 > 0 })
            RunLoop.current.run(until: Date().addingTimeInterval(1.1))
            expect(completions == 1 && FixtureProtocol.counts.0 == 1, "\(provider) late response cannot restart tools")

            FixtureProtocol.reset("tools")
            var approvals = 0, done = false
            service.requestApproval = { request, reply in approvals += 1; expect(request.tool == "close_tab", "approval names exact action"); reply(.deny) }
            service.run(prompt: "fixture", status: { _ in }) { result in
                if case .success(let answer) = result { expect(answer == "Fixture answer", "\(provider) returns answer after denied action") }
                else { expect(false, "\(provider) tool loop should finish") }
                done = true
            }
            wait("\(provider) runs again after stop", until: { done })
            expect(approvals == 1 && FixtureProtocol.counts.0 == 2, "\(provider) tool dispatch requires approval and continues with denial")

            FixtureProtocol.reset("tools")
            var pending: ((AgentApprovalDecision) -> Void)?, stopped = 0
            service.requestApproval = { _, reply in pending = reply }
            service.run(prompt: "fixture", status: { _ in }) { _ in stopped += 1 }
            wait("\(provider) waits for approval", until: { pending != nil })
            service.cancel(); pending?(.allowOnce)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            expect(stopped == 1 && FixtureProtocol.counts.0 == 1, "\(provider) late approval after Stop cannot execute or continue")

            FixtureProtocol.reset("error")
            var failure: String?
            service.run(prompt: "fixture", status: { _ in }) { if case .failure(let error) = $0 { failure = error.localizedDescription } }
            wait("\(provider) HTTP error delivered", until: { failure != nil })
            expect(failure?.contains("fixture rejected") == true, "\(provider) preserves actionable API error")
        }
        let yoloSession = BrowserAgentSession()
        var yoloApprovals = 0, yoloOutputs = 0
        service.requestApproval = { _, reply in yoloApprovals += 1; reply(.allowAllForTask) }
        service.executeTool(name: "close_tab", args: [:], session: yoloSession) { _ in yoloOutputs += 1 }
        service.executeTool(name: "close_tab", args: [:], session: yoloSession) { _ in yoloOutputs += 1 }
        expect(yoloApprovals == 1 && yoloOutputs == 2, "YOLO approval suppresses later prompts within the same task scope")
        yoloSession.finish()

        FixtureProtocol.reset("text")
        var resetDone = false
        service.run(prompt: "new task resets permissions", status: { _ in }) { _ in resetDone = true }
        wait("new task completes after YOLO", until: { resetDone })
        let resetSession = BrowserAgentSession()
        var resetApprovals = 0
        service.requestApproval = { _, reply in resetApprovals += 1; reply(.deny) }
        service.executeTool(name: "close_tab", args: [:], session: resetSession) { _ in }
        expect(resetApprovals == 1, "YOLO never persists into the next task")
        resetSession.finish()

        service.requestApproval = nil
        let session = BrowserAgentSession()
        var denied = ""
        service.executeTool(name: "close_tab", args: [:], session: session) { denied = $0 }
        expect(denied.contains("approval is required"), "tools fail closed without approval UI")
        session.finish()
        var lateTool = false
        service.executeTool(name: "list_tabs", args: [:], session: session) { _ in lateTool = true }
        expect(!lateTool, "finished session suppresses tool dispatch")
        for name in ["open_tab", "activate_tab", "close_tab", "navigate", "click", "fill", "press"] {
            expect(BrowserAgentService.requiresApproval(name), "\(name) approval registration")
        }
    }

    static func assistantSidebarUI() {
        FixtureProtocol.reset("delay")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let sidebar = AgentSidebarView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        window.contentView = sidebar
        sidebar.activate()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(sidebar)
        guard let run = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Run" }),
              let clear = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Clear" }),
              let prompt = views.compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString?.contains("Facet") == true }),
              let scroll = views.compactMap({ $0 as? NSScrollView }).first,
              let transcript = scroll.documentView as? NSTextView else {
            expect(false, "native agent sidebar controls registered"); return
        }
        expect(transcript.string.contains("Private windows are excluded"), "sidebar discloses private-window boundary")
        prompt.stringValue = "Sidebar fixture"
        run.performClick(nil)
        wait("sidebar starts agent task", until: { FixtureProtocol.counts.0 == 1 })
        expect(run.title == "Stop" && !prompt.isEnabled && !clear.isEnabled, "sidebar exposes Stop while running")
        run.performClick(nil)
        expect(run.title == "Run" && prompt.isEnabled && clear.isEnabled, "sidebar Stop restores controls")
        sidebar.prepareToHide()
        window.close()
    }

    static func webKitPrivacy() throws {
        _ = NSApplication.shared
        FixtureProtocol.reset("text")
        let sleeping = Tab(url: nil, isPrivate: true, delegate: nil)
        var cancelled = false
        sleeping.captureAgentSnapshot(isCancelled: { true }) {
            if case .failure(AgentToolError.cancelled) = $0 { cancelled = true }
        }
        expect(cancelled && sleeping.isHibernated, "cancelled snapshot never wakes a sleeping tab")
        let tab = Tab(url: nil, isPrivate: true, delegate: nil)
        let view = tab.ensureLoaded()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let url = URL(string: "https://privacy.invalid/")!
        Store.shared.recordVisit(url: url, title: "Public title")
        view.loadHTMLString("<title>Private title</title><input type=password value=PASSWORD_SECRET><input autocomplete=one-time-code value=OTP_SECRET><input autocomplete=cc-number value=CARD_SECRET><input value=ordinary>", baseURL: url)
        wait("private HTML loaded", seconds: 15, until: { view.title == "Private title" && !view.isLoading })
        expect(Store.shared.history.first(where: { $0.url == url.absoluteString })?.title == "Public title", "private title observer does not update normal history")
        var snapshot: AgentPageSnapshot?
        tab.captureAgentSnapshot { if case .success(let value) = $0 { snapshot = value } }
        wait("snapshot captured", seconds: 15, until: { snapshot != nil })
        if let snapshot {
            let text = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8)!
            expect(!text.contains("PASSWORD_SECRET") && !text.contains("OTP_SECRET") && !text.contains("CARD_SECRET"), "sensitive form values redacted from names and values")
            expect(snapshot.elements.contains { $0.value == "ordinary" }, "ordinary form values remain usable")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        expect(FixtureProtocol.counts.0 == 0, "private favicons never use shared URLSession cache")
        tab.hibernate()
    }
}
