import Foundation
import AppKit

struct HistoryEntry {
    var url: String
    var title: String
    var visits: Int
    var lastVisit: Date
}

/// A bookmark, or a folder of them. Folders have no URL.
final class BookmarkNode {
    let id: UUID
    var title: String
    var url: String?
    var added: Date
    fileprivate(set) var children: [BookmarkNode] = []
    fileprivate(set) weak var parent: BookmarkNode?

    var isFolder: Bool { url == nil }

    init(id: UUID = UUID(), title: String, url: String? = nil, added: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.added = added
    }

    /// True when `other` is this node or anywhere inside it.
    func contains(_ other: BookmarkNode) -> Bool {
        var node: BookmarkNode? = other
        while let n = node { if n === self { return true }; node = n.parent }
        return false
    }

    /// The bookmarks in this folder and its subfolders, in order.
    var allBookmarks: [BookmarkNode] { isFolder ? children.flatMap(\.allBookmarks) : [self] }

    fileprivate func insert(_ child: BookmarkNode, at index: Int?) {
        child.parent = self
        children.insert(child, at: min(max(0, index ?? children.count), children.count))
    }

    fileprivate func removeChild(_ child: BookmarkNode) {
        children.removeAll { $0 === child }
        child.parent = nil
    }
}

/// One bookmark read from another browser, with the folders it sat in.
struct ImportedBookmark {
    enum Root { case bar, other }
    var url: String
    var title: String
    var added: Date = Date()
    var root: Root = .other
    var folders: [String] = []
}

struct SavedTab {
    var url: String
    var title: String
    /// WKWebView.interactionState blob: full back/forward list + scroll position.
    var interactionState: Data?
    var pinned: Bool = false
}

extension Notification.Name {
    /// Posted whenever the bookmark list changes, so every bookmarks bar can redraw.
    static let facetBookmarksChanged = Notification.Name("FacetBookmarksChanged")
}

struct SavedWindow {
    var tabs: [SavedTab]
    var activeIndex: Int
    var frame: NSRect?
}

/// Flat-file persistence. Everything is small, loaded once, and written debounced,
/// so there is no database engine resident in memory.
final class Store {
    static let shared = Store()

    private(set) var history: [HistoryEntry] = []
    private var historyIndex: [String: Int] = [:]
    private let maxHistory = 4000

    private var historyURL: URL { Config.supportDir.appendingPathComponent("history.json") }
    private var bookmarksURL: URL { Config.supportDir.appendingPathComponent("bookmarks.json") }
    private var sessionURL: URL { Config.supportDir.appendingPathComponent("session.json") }

    private var historyDirty = false
    private var saveTimer: Timer?

    private init() {
        history = Store.readEntries(historyURL)
        reindex()
        loadBookmarks()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.flush()
        }
        saveTimer?.tolerance = 5  // let macOS batch this wake-up with others
    }

    private func reindex() {
        historyIndex.removeAll(keepingCapacity: true)
        for (i, e) in history.enumerated() { historyIndex[e.url] = i }
    }

    // MARK: - History

    func recordVisit(url: URL, title: String) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let key = url.absoluteString
        if let i = historyIndex[key] {
            history[i].visits += 1
            history[i].lastVisit = Date()
            if !title.isEmpty { history[i].title = title }
        } else {
            history.append(HistoryEntry(url: key, title: title, visits: 1, lastVisit: Date()))
            historyIndex[key] = history.count - 1
        }
        historyDirty = true
    }

    func updateTitle(url: URL, title: String) {
        guard !title.isEmpty, let i = historyIndex[url.absoluteString] else { return }
        history[i].title = title
        historyDirty = true
    }

    func recentHistory(limit: Int) -> [HistoryEntry] {
        history.sorted { $0.lastVisit > $1.lastVisit }.prefix(limit).map { $0 }
    }

    func clearHistory() {
        history = []
        historyIndex = [:]
        historyDirty = true
        flush()
    }

    /// Removes visits made since `date`, for the Clear Browsing Data time ranges.
    func clearHistory(since date: Date) {
        history.removeAll { $0.lastVisit >= date }
        reindex()
        historyDirty = true
        flush()
    }

    func removeHistory(urls: Set<String>) {
        guard !urls.isEmpty else { return }
        history.removeAll { urls.contains($0.url) }
        reindex()
        historyDirty = true
        flush()
    }

    /// Merge imported history idempotently: repeated imports do not inflate visit counts.
    /// Existing Facet activity wins when it is newer; otherwise imported title/date fill in.
    @discardableResult
    func importHistory(_ entries: [HistoryEntry]) -> Int {
        var added = 0
        for e in entries {
            guard let u = URL(string: e.url), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            if let i = historyIndex[e.url] {
                history[i].visits = max(history[i].visits, max(1, e.visits))
                if e.lastVisit > history[i].lastVisit {
                    history[i].lastVisit = e.lastVisit
                    if !e.title.isEmpty { history[i].title = e.title }
                } else if history[i].title.isEmpty && !e.title.isEmpty {
                    history[i].title = e.title
                }
            } else {
                history.append(HistoryEntry(url: e.url, title: e.title, visits: max(1, e.visits), lastVisit: e.lastVisit))
                historyIndex[e.url] = history.count - 1
                added += 1
            }
        }
        if !entries.isEmpty { historyDirty = true }
        return added
    }

    /// Frecency-ranked matches over bookmarks and history, with titles, for the omnibox.
    func rankedEntries(for query: String, limit: Int = 8) -> [(entry: HistoryEntry, bookmarked: Bool)] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let now = Date()
        var scored: [(HistoryEntry, Bool, Double)] = []
        var seen = Set<String>()
        let bookmarkURLs = Set(bookmarks.map(\.url))
        for e in bookmarks + history {
            let display = Store.displayForm(e.url)
            if seen.contains(display) { continue }
            let hay = display.lowercased()
            let bare = hay.hasPrefix("www.") ? String(hay.dropFirst(4)) : hay
            let titleHit = e.title.lowercased().contains(q)
            let urlHit = hay.range(of: q)
            guard urlHit != nil || titleHit else { continue }
            seen.insert(display)
            let bookmarked = bookmarkURLs.contains(e.url)
            var score = Double(max(1, e.visits)) + (bookmarked ? 4 : 0)
            // Prefix matches on the host beat matches buried in a path or query string.
            if bare.hasPrefix(q) || hay.hasPrefix(q) { score *= 6 }
            else if let r = urlHit, hay.distance(from: hay.startIndex, to: r.lowerBound) < 12 { score *= 2 }
            if titleHit { score += 2 }
            let ageDays = now.timeIntervalSince(e.lastVisit) / 86_400
            score /= (1 + max(0, ageDays) * 0.25)
            if display.count < 40 { score *= 1.3 }  // prefer clean landing pages
            scored.append((e, bookmarked, score))
        }
        return scored.sorted { $0.2 > $1.2 }.prefix(limit).map { ($0.0, $0.1) }
    }

    /// Frecency-ranked prefix/substring match over history + bookmarks, for the URL bar.
    func suggestions(for query: String, limit: Int = 8) -> [String] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let now = Date()
        var scored: [(String, Double)] = []
        var seen = Set<String>()

        for e in bookmarks + history {
            let display = Store.displayForm(e.url)
            if seen.contains(display) { continue }
            let hay = display.lowercased()
            let titleHit = e.title.lowercased().contains(q)
            guard let range = hay.range(of: q) ?? (titleHit ? hay.startIndex..<hay.startIndex : nil) else { continue }
            seen.insert(display)

            var score = Double(e.visits)
            // Prefix matches on the host beat matches buried in a query string.
            if range.lowerBound == hay.startIndex { score *= 6 }
            else if hay.distance(from: hay.startIndex, to: range.lowerBound) < 12 { score *= 2 }
            if titleHit { score += 2 }
            let ageDays = now.timeIntervalSince(e.lastVisit) / 86_400
            score /= (1 + ageDays * 0.25)
            if display.count < 40 { score *= 1.3 }  // prefer clean landing pages
            scored.append((display, score))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    /// Strip the scheme for display/typing; the resolver adds https:// back.
    static func displayForm(_ urlString: String) -> String {
        var s = urlString
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasSuffix("/"), s.filter({ $0 == "/" }).count == 1 { s.removeLast() }
        return s
    }

    // MARK: - Bookmarks

    /// Chrome's two top-level folders. Neither can be renamed, moved or deleted.
    let bookmarkBar = BookmarkNode(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B0B0")!, title: "Bookmarks Bar")
    let otherBookmarks = BookmarkNode(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!, title: "Other Bookmarks")
    var bookmarkRoots: [BookmarkNode] { [bookmarkBar, otherBookmarks] }

    /// Every bookmark in tree order, flattened for the omnibox and the History-style lists.
    private(set) var bookmarks: [HistoryEntry] = []
    private var bookmarkNodes: [String: [BookmarkNode]] = [:]
    private var lastFolderID: UUID?

    /// Where ⌘D puts a new bookmark: the folder last chosen in the bookmark bubble, as in Chrome.
    var lastUsedFolder: BookmarkNode {
        get { lastFolderID.flatMap(bookmarkNode(withID:)).flatMap { $0.isFolder ? $0 : nil } ?? bookmarkBar }
        set { lastFolderID = newValue.id; saveBookmarks() }
    }

    func isRoot(_ node: BookmarkNode) -> Bool { node === bookmarkBar || node === otherBookmarks }

    func isBookmarked(_ url: URL) -> Bool { bookmarkNodes[url.absoluteString] != nil }

    func bookmark(for url: URL) -> BookmarkNode? { bookmarkNodes[url.absoluteString]?.first }

    func bookmarkNode(withID id: UUID) -> BookmarkNode? {
        func find(_ n: BookmarkNode) -> BookmarkNode? { n.id == id ? n : n.children.lazy.compactMap(find).first }
        return bookmarkRoots.lazy.compactMap(find).first
    }

    /// Every folder depth first, with its depth, for folder pickers.
    var bookmarkFolders: [(folder: BookmarkNode, depth: Int)] {
        func walk(_ n: BookmarkNode, _ depth: Int) -> [(folder: BookmarkNode, depth: Int)] {
            [(n, depth)] + n.children.filter(\.isFolder).flatMap { walk($0, depth + 1) }
        }
        return bookmarkRoots.flatMap { walk($0, 0) }
    }

    @discardableResult
    func addBookmark(url: URL, title: String, in folder: BookmarkNode? = nil, at index: Int? = nil) -> BookmarkNode {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = BookmarkNode(title: clean.isEmpty ? (url.host ?? url.absoluteString) : clean, url: url.absoluteString)
        (folder.flatMap { $0.isFolder ? $0 : nil } ?? lastUsedFolder).insert(node, at: index)
        saveBookmarks()
        return node
    }

    /// A new folder, optionally filled with pages (Bookmark All Tabs) in one save.
    @discardableResult
    func addFolder(title: String, in folder: BookmarkNode, at index: Int? = nil,
                   pages: [(url: URL, title: String)] = []) -> BookmarkNode {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = BookmarkNode(title: clean.isEmpty ? "New Folder" : clean)
        for page in pages {
            let t = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
            node.insert(BookmarkNode(title: t.isEmpty ? (page.url.host ?? page.url.absoluteString) : t, url: page.url.absoluteString), at: nil)
        }
        (folder.isFolder ? folder : folder.parent ?? bookmarkBar).insert(node, at: index)
        saveBookmarks()
        return node
    }

    /// Moves `node` into `folder` before the child now at `index` (the end when nil). Refuses
    /// to move a top-level folder or to put a folder inside itself.
    @discardableResult
    func move(_ node: BookmarkNode, to folder: BookmarkNode, at index: Int? = nil) -> Bool {
        guard !isRoot(node), folder.isFolder, !node.contains(folder) else { return false }
        var target = index
        if let old = node.parent {
            if old === folder, let from = old.children.firstIndex(where: { $0 === node }), let t = target, from < t { target = t - 1 }
            old.removeChild(node)
        }
        folder.insert(node, at: target)
        saveBookmarks()
        return true
    }

    func remove(_ nodes: [BookmarkNode]) {
        let removable = nodes.filter { !isRoot($0) }
        guard !removable.isEmpty else { return }
        removable.forEach { $0.parent?.removeChild($0) }
        saveBookmarks()
    }

    func rename(_ node: BookmarkNode, to title: String) {
        guard !isRoot(node) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        node.title = clean.isEmpty ? (node.isFolder ? "New Folder" : node.url.flatMap { URL(string: $0)?.host } ?? node.url ?? "") : clean
        saveBookmarks()
    }

    /// ⌘D before the bubble existed, and the tests' shorthand: bookmark the page, or remove
    /// every bookmark of it.
    func toggleBookmark(url: URL, title: String) -> Bool {
        if let nodes = bookmarkNodes[url.absoluteString] { remove(nodes); return false }
        addBookmark(url: url, title: title)
        return true
    }

    func removeBookmarks(urls: Set<String>) {
        remove(urls.flatMap { bookmarkNodes[$0] ?? [] })
    }

    func renameBookmark(url: String, title: String) {
        guard let node = bookmarkNodes[url]?.first else { return }
        rename(node, to: title)
    }

    /// Merge imported bookmarks by URL, keeping the folders they came from: bar items onto the
    /// bar, the rest under Other Bookmarks, folders merged by name. A URL Facet already has
    /// keeps its place, and its title unless that is blank.
    @discardableResult
    func importBookmarks(_ entries: [ImportedBookmark]) -> Int {
        var added = 0
        for e in entries {
            guard let u = URL(string: e.url), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            if let existing = bookmarkNodes[e.url]?.first {
                if existing.title.isEmpty && !e.title.isEmpty { existing.title = e.title }
                continue
            }
            var folder = e.root == .bar ? bookmarkBar : otherBookmarks
            for name in e.folders {
                if let match = folder.children.first(where: { $0.isFolder && $0.title == name }) { folder = match }
                else { let f = BookmarkNode(title: name); folder.insert(f, at: nil); folder = f }
            }
            let node = BookmarkNode(title: e.title.isEmpty ? (u.host ?? e.url) : e.title, url: e.url, added: e.added)
            folder.insert(node, at: nil)
            bookmarkNodes[e.url] = [node]
            added += 1
        }
        if !entries.isEmpty { saveBookmarks() }
        return added
    }

    private func reindexBookmarks() {
        let all = bookmarkRoots.flatMap(\.allBookmarks)
        bookmarkNodes = Dictionary(grouping: all, by: { $0.url ?? "" })
        var seen = Set<String>()
        bookmarks = all.compactMap { n in
            guard let url = n.url, seen.insert(url).inserted else { return nil }
            return HistoryEntry(url: url, title: n.title, visits: 1, lastVisit: n.added)
        }
    }

    private var bookmarkWrite: DispatchWorkItem?

    /// Views update at once; the file is written half a second later, so a burst of edits (a
    /// drag of many items, a big import) writes once.
    private func saveBookmarks() {
        reindexBookmarks()
        NotificationCenter.default.post(name: .facetBookmarksChanged, object: nil)
        bookmarkWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushBookmarks() }
        bookmarkWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes pending bookmark changes now: at quit, and before the file is read back.
    func flushBookmarks() {
        guard let pending = bookmarkWrite else { return }
        pending.cancel()
        bookmarkWrite = nil
        func encode(_ n: BookmarkNode) -> [String: Any] {
            var d: [String: Any] = ["id": n.id.uuidString, "title": n.title, "added": n.added.timeIntervalSince1970]
            if let url = n.url { d["url"] = url } else { d["children"] = n.children.map(encode) }
            return d
        }
        var root: [String: Any] = ["version": 2, "bar": encode(bookmarkBar), "other": encode(otherBookmarks)]
        if let lastFolderID { root["lastFolder"] = lastFolderID.uuidString }
        if let data = try? JSONSerialization.data(withJSONObject: root) { try? data.write(to: bookmarksURL, options: .atomic) }
    }

    /// Reads bookmarks.json again, replacing what is in memory.
    func reloadBookmarks() {
        flushBookmarks()
        for root in bookmarkRoots { root.children.forEach { root.removeChild($0) } }
        lastFolderID = nil
        loadBookmarks()
    }

    /// Version 2 is a tree. Version 1 was a flat list, all of it shown on the bar, so it
    /// becomes the bar's contents.
    private func loadBookmarks() {
        defer { reindexBookmarks() }
        guard let data = try? Data(contentsOf: bookmarksURL), let json = try? JSONSerialization.jsonObject(with: data) else { return }
        func decode(_ d: [String: Any]) -> BookmarkNode {
            let url = d["url"] as? String
            let node = BookmarkNode(id: (d["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                                    title: d["title"] as? String ?? "", url: url,
                                    added: Date(timeIntervalSince1970: d["added"] as? Double ?? d["last"] as? Double ?? 0))
            if url == nil { (d["children"] as? [[String: Any]] ?? []).forEach { node.insert(decode($0), at: nil) } }
            return node
        }
        if let flat = json as? [[String: Any]] {
            for d in flat where d["url"] is String { bookmarkBar.insert(decode(d), at: nil) }
        } else if let root = json as? [String: Any] {
            for (key, folder) in [("bar", bookmarkBar), ("other", otherBookmarks)] {
                ((root[key] as? [String: Any])?["children"] as? [[String: Any]] ?? []).forEach { folder.insert(decode($0), at: nil) }
            }
            lastFolderID = (root["lastFolder"] as? String).flatMap(UUID.init(uuidString:))
        }
    }

    // MARK: - Session

    /// Persist every normal window atomically. Version 2 stays backward-compatible
    /// with the original single-window session file.
    func saveSession(windows: [SavedWindow], selectedWindow: Int?) {
        func encodeTab(_ t: SavedTab) -> [String: Any] {
            var d: [String: Any] = ["url": t.url, "title": t.title]
            if let state = t.interactionState { d["state"] = state.base64EncodedString() }
            if t.pinned { d["pinned"] = true }
            return d
        }
        let encoded: [[String: Any]] = windows.map { w in
            var d: [String: Any] = ["tabs": w.tabs.map(encodeTab), "active": w.activeIndex]
            if let f = w.frame { d["frame"] = ["x": f.origin.x, "y": f.origin.y, "w": f.size.width, "h": f.size.height] }
            return d
        }
        var payload: [String: Any] = ["version": 2, "windows": encoded]
        if let selectedWindow { payload["selectedWindow"] = selectedWindow }
        if let data = try? JSONSerialization.data(withJSONObject: payload) { try? data.write(to: sessionURL, options: .atomic) }
    }

    func loadSessionWindows() -> (windows: [SavedWindow], selectedWindow: Int?) {
        guard let data = try? Data(contentsOf: sessionURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], nil) }
        func decodeTabs(_ arr: [[String: Any]]) -> [SavedTab] {
            arr.compactMap { e in
                guard let url = e["url"] as? String, !url.isEmpty else { return nil }
                let state = (e["state"] as? String).flatMap { Data(base64Encoded: $0) }
                return SavedTab(url: url, title: e["title"] as? String ?? "", interactionState: state,
                                pinned: e["pinned"] as? Bool ?? false)
            }
        }
        func decodeFrame(_ any: Any?) -> NSRect? {
            guard let d = any as? [String: Any], let x = d["x"] as? NSNumber,
                  let y = d["y"] as? NSNumber, let w = d["w"] as? NSNumber,
                  let h = d["h"] as? NSNumber, w.doubleValue >= 520, h.doubleValue >= 380 else { return nil }
            return NSRect(x: x.doubleValue, y: y.doubleValue, width: w.doubleValue, height: h.doubleValue)
        }
        if let rawWindows = root["windows"] as? [[String: Any]] {
            let windows = rawWindows.compactMap { d -> SavedWindow? in
                guard let arr = d["tabs"] as? [[String: Any]] else { return nil }
                let tabs = decodeTabs(arr); guard !tabs.isEmpty else { return nil }
                let active = min(max(0, d["active"] as? Int ?? 0), max(0, tabs.count - 1))
                return SavedWindow(tabs: tabs, activeIndex: active, frame: decodeFrame(d["frame"]))
            }
            return (windows, root["selectedWindow"] as? Int)
        }
        guard let arr = root["tabs"] as? [[String: Any]] else { return ([], nil) }
        let tabs = decodeTabs(arr); guard !tabs.isEmpty else { return ([], nil) }
        let active = min(max(0, root["active"] as? Int ?? 0), max(0, tabs.count - 1))
        return ([SavedWindow(tabs: tabs, activeIndex: active, frame: nil)], 0)
    }

    // MARK: - Disk

    func flush() {
        flushBookmarks()
        guard historyDirty else { return }
        historyDirty = false
        if history.count > maxHistory {
            // Ranking by visit count alone would discard every new site once the list filled
            // with repeat visits (an import does that at once). Keep the last day outright,
            // then whatever the omnibox's frecency still ranks highest.
            let now = Date()
            func keep(_ e: HistoryEntry) -> Double {
                let ageDays = max(0, now.timeIntervalSince(e.lastVisit) / 86_400)
                return ageDays < 1 ? .infinity : Double(max(1, e.visits)) / (1 + ageDays * 0.25)
            }
            history = history.sorted { (keep($0), $0.lastVisit) > (keep($1), $1.lastVisit) }
                .prefix(maxHistory).map { $0 }
            reindex()
        }
        write(history, to: historyURL)
    }

    private func write(_ entries: [HistoryEntry], to url: URL) {
        let arr: [[String: Any]] = entries.map {
            ["url": $0.url, "title": $0.title, "visits": $0.visits, "last": $0.lastVisit.timeIntervalSince1970]
        }
        if let data = try? JSONSerialization.data(withJSONObject: arr) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func readEntries(_ url: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let u = d["url"] as? String else { return nil }
            return HistoryEntry(url: u,
                                title: d["title"] as? String ?? "",
                                visits: d["visits"] as? Int ?? 1,
                                lastVisit: Date(timeIntervalSince1970: d["last"] as? Double ?? 0))
        }
    }
}
