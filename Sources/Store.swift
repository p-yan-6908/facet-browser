import Foundation

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
            write(bookmarks, to: bookmarksURL)
            return false
        }
        bookmarks.append(HistoryEntry(url: url.absoluteString, title: title.isEmpty ? url.host ?? "" : title,
                                      visits: 1, lastVisit: Date()))
        write(bookmarks, to: bookmarksURL)
        return true
    }

    func removeBookmark(at index: Int) {
        guard bookmarks.indices.contains(index) else { return }
        bookmarks.remove(at: index)
        write(bookmarks, to: bookmarksURL)
    }

    // MARK: - Session

    func saveSession(_ tabs: [SavedTab], activeIndex: Int) {
        let arr: [[String: Any]] = tabs.map { t in
            var d: [String: Any] = ["url": t.url, "title": t.title]
            if let s = t.interactionState { d["state"] = s.base64EncodedString() }
            return d
        }
        let payload: [String: Any] = ["tabs": arr, "active": activeIndex]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: sessionURL, options: .atomic)
        }
    }

    func loadSession() -> (tabs: [SavedTab], activeIndex: Int) {
        guard let data = try? Data(contentsOf: sessionURL),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = d["tabs"] as? [[String: Any]] else { return ([], 0) }
        let tabs: [SavedTab] = arr.compactMap { e in
            guard let url = e["url"] as? String, !url.isEmpty else { return nil }
            let state = (e["state"] as? String).flatMap { Data(base64Encoded: $0) }
            return SavedTab(url: url, title: e["title"] as? String ?? "", interactionState: state)
        }
        return (tabs, d["active"] as? Int ?? 0)
    }

    // MARK: - Disk

    func flush() {
        guard historyDirty else { return }
        historyDirty = false
        if history.count > maxHistory {
            history = history.sorted { ($0.visits, $0.lastVisit) > ($1.visits, $1.lastVisit) }
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
