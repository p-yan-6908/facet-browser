import Foundation
import AppKit

struct HistoryEntry {
    var url: String
    var title: String
    var visits: Int
    var lastVisit: Date
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
    private(set) var bookmarks: [HistoryEntry] = []
    private var historyIndex: [String: Int] = [:]
    private let maxHistory = 4000

    private var historyURL: URL { Config.supportDir.appendingPathComponent("history.json") }
    private var bookmarksURL: URL { Config.supportDir.appendingPathComponent("bookmarks.json") }
    private var sessionURL: URL { Config.supportDir.appendingPathComponent("session.json") }

    private var historyDirty = false
    private var saveTimer: Timer?

    private init() {
        history = Store.readEntries(historyURL)
        bookmarks = Store.readEntries(bookmarksURL)
        reindex()
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

    func isBookmarked(_ url: URL) -> Bool {
        bookmarks.contains { $0.url == url.absoluteString }
    }

    func toggleBookmark(url: URL, title: String) -> Bool {
        if let i = bookmarks.firstIndex(where: { $0.url == url.absoluteString }) {
            bookmarks.remove(at: i)
            saveBookmarks()
            return false
        }
        bookmarks.append(HistoryEntry(url: url.absoluteString, title: title.isEmpty ? url.host ?? "" : title,
                                      visits: 1, lastVisit: Date()))
        saveBookmarks()
        return true
    }

    func removeBookmark(at index: Int) {
        guard bookmarks.indices.contains(index) else { return }
        bookmarks.remove(at: index)
        saveBookmarks()
    }

    func removeBookmarks(urls: Set<String>) {
        guard !urls.isEmpty else { return }
        bookmarks.removeAll { urls.contains($0.url) }
        saveBookmarks()
    }

    func renameBookmark(url: String, title: String) {
        guard let i = bookmarks.firstIndex(where: { $0.url == url }) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks[i].title = clean.isEmpty ? (URL(string: url)?.host ?? url) : clean
        saveBookmarks()
    }

    func moveBookmark(from: Int, to: Int) {
        guard bookmarks.indices.contains(from), bookmarks.indices.contains(to), from != to else { return }
        bookmarks.insert(bookmarks.remove(at: from), at: to)
        saveBookmarks()
    }

    private func saveBookmarks() {
        write(bookmarks, to: bookmarksURL)
        NotificationCenter.default.post(name: .facetBookmarksChanged, object: nil)
    }

    /// Merge imported bookmarks by URL. Facet's existing title is preserved unless blank.
    @discardableResult
    func importBookmarks(_ entries: [HistoryEntry]) -> Int {
        var byURL: [String: Int] = [:]
        for (i, e) in bookmarks.enumerated() { byURL[e.url] = i }
        var added = 0
        for e in entries {
            guard let u = URL(string: e.url), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            if let i = byURL[e.url] {
                if bookmarks[i].title.isEmpty && !e.title.isEmpty { bookmarks[i].title = e.title }
            } else {
                bookmarks.append(HistoryEntry(url: e.url, title: e.title.isEmpty ? u.host ?? "" : e.title,
                                              visits: 1, lastVisit: e.lastVisit))
                byURL[e.url] = bookmarks.count - 1
                added += 1
            }
        }
        if !entries.isEmpty { saveBookmarks() }
        return added
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
