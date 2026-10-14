import AppKit
import Foundation
import WebKit

enum BrowserImportFormat: String {
    case chromium
    case firefox
    case safari
}

struct BrowserImportSource: Hashable {
    let id: String
    let browserName: String
    let profileName: String
    let profileURL: URL
    let format: BrowserImportFormat
    let bookmarksURL: URL?
    let historyURL: URL?

    var displayName: String {
        profileName.isEmpty ? browserName : "\(browserName) — \(profileName)"
    }
    var hasBookmarks: Bool { bookmarksURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    var hasHistory: Bool { historyURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    var supportsChromeSessions: Bool { format == .chromium && ["Google Chrome", "Chrome"].contains(browserName) }
    var cookiesURL: URL? { ChromeSessionImport.cookieDatabase(in: profileURL) }
    var hasSessions: Bool { supportsChromeSessions && cookiesURL != nil }
}

struct BrowserImportResult {
    let bookmarksAdded: Int
    let historyAdded: Int
    let bookmarksRead: Int
    let historyRead: Int
    let warnings: [String]
    var cookiesImported = 0
    var cookiesPreserved = 0
    var cookiesSkipped = 0
    var cookieSites = 0
}

enum BrowserImportError: LocalizedError {
    case noData
    case unreadable(String)
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .noData: return "No importable browser data was found."
        case .unreadable(let s): return s
        case .invalidFormat(let s): return s
        }
    }
}

/// One-shot browser migration. Short-lived read-only SQLite connections include committed
/// WAL records and provide a consistent query snapshot without copying private data to disk.
final class BrowserImportService {
    static let shared = BrowserImportService()
    private let fm = FileManager.default
    private init() {}

    func detectSources() -> [BrowserImportSource] {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let chromiumRoots: [(String, String)] = [
            ("Google Chrome", "Google/Chrome"),
            ("Brave", "BraveSoftware/Brave-Browser"),
            ("Microsoft Edge", "Microsoft Edge"),
            ("Chromium", "Chromium"),
            ("Arc", "Arc/User Data"),
            ("Vivaldi", "Vivaldi"),
            ("Aside", "Aside"),
            ("Opera", "com.operasoftware.Opera"),
            ("Opera GX", "com.operasoftware.OperaGX")
        ]

        var sources: [BrowserImportSource] = []
        for (name, relative) in chromiumRoots {
            let root = appSupport.appendingPathComponent(relative, isDirectory: true)
            sources.append(contentsOf: detectChromium(browserName: name, root: root))
        }

        let firefox = appSupport.appendingPathComponent("Firefox/Profiles", isDirectory: true)
        if let dirs = try? fm.contentsOfDirectory(at: firefox, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let places = dir.appendingPathComponent("places.sqlite")
                guard fm.fileExists(atPath: places.path) else { continue }
                let raw = dir.lastPathComponent
                let profile = raw.split(separator: ".", maxSplits: 1).last.map(String.init) ?? raw
                sources.append(BrowserImportSource(id: "firefox:\(dir.path)", browserName: "Firefox", profileName: profile,
                                                   profileURL: dir, format: .firefox,
                                                   bookmarksURL: places, historyURL: places))
            }
        }

        let safari = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari", isDirectory: true)
        let safariBookmarks = safari.appendingPathComponent("Bookmarks.plist")
        let safariHistory = safari.appendingPathComponent("History.db")
        if fm.fileExists(atPath: safariBookmarks.path) || fm.fileExists(atPath: safariHistory.path) {
            sources.append(BrowserImportSource(id: "safari", browserName: "Safari", profileName: "Default",
                                               profileURL: safari, format: .safari,
                                               bookmarksURL: fm.fileExists(atPath: safariBookmarks.path) ? safariBookmarks : nil,
                                               historyURL: fm.fileExists(atPath: safariHistory.path) ? safariHistory : nil))
        }

        return sources.sorted {
            ($0.browserName.lowercased(), $0.profileName.lowercased()) < ($1.browserName.lowercased(), $1.profileName.lowercased())
        }
    }

    func customChromiumSource(profileURL: URL) -> BrowserImportSource? {
        let b = profileURL.appendingPathComponent("Bookmarks")
        let h = profileURL.appendingPathComponent("History")
        let hasB = fm.fileExists(atPath: b.path), hasH = fm.fileExists(atPath: h.path)
        guard hasB || hasH || ChromeSessionImport.cookieDatabase(in: profileURL) != nil else { return nil }
        let browser = profileURL.deletingLastPathComponent().lastPathComponent.isEmpty
            ? "Chromium browser" : profileURL.deletingLastPathComponent().lastPathComponent
        return BrowserImportSource(id: "custom:\(profileURL.path)", browserName: browser,
                                   profileName: profileURL.lastPathComponent, profileURL: profileURL,
                                   format: .chromium, bookmarksURL: hasB ? b : nil, historyURL: hasH ? h : nil)
    }

    private func detectChromium(browserName: String, root: URL) -> [BrowserImportSource] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        let friendly = chromiumProfileNames(root: root)
        var profileDirs: [URL] = []

        // Opera-family profiles often store the files directly in the root.
        if fm.fileExists(atPath: root.appendingPathComponent("Bookmarks").path) ||
            fm.fileExists(atPath: root.appendingPathComponent("History").path) ||
            (browserName == "Google Chrome" && ChromeSessionImport.cookieDatabase(in: root) != nil) {
            profileDirs.append(root)
        }
        if let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for dir in dirs {
                let n = dir.lastPathComponent
                guard n == "Default" || n.hasPrefix("Profile ") || n.hasPrefix("Person ") else { continue }
                if fm.fileExists(atPath: dir.appendingPathComponent("Bookmarks").path) ||
                    fm.fileExists(atPath: dir.appendingPathComponent("History").path) ||
                    (browserName == "Google Chrome" && ChromeSessionImport.cookieDatabase(in: dir) != nil) { profileDirs.append(dir) }
            }
        }

        let rawNames: [(URL, String, String)] = profileDirs.map { dir in
            let key = dir == root ? "Default" : dir.lastPathComponent
            return (dir, key, friendly[key] ?? key)
        }
        var counts: [String: Int] = [:]
        for (_, _, name) in rawNames { counts[name, default: 0] += 1 }
        return rawNames.map { dir, key, name in
            let profileName = (counts[name] ?? 0) > 1 ? "\(name) (\(key))" : name
            let b = dir.appendingPathComponent("Bookmarks")
            let h = dir.appendingPathComponent("History")
            return BrowserImportSource(id: "chromium:\(dir.path)", browserName: browserName, profileName: profileName,
                                       profileURL: dir, format: .chromium,
                                       bookmarksURL: fm.fileExists(atPath: b.path) ? b : nil,
                                       historyURL: fm.fileExists(atPath: h.path) ? h : nil)
        }
    }

    private func chromiumProfileNames(root: URL) -> [String: String] {
        let state = root.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: state),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = obj["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in cache {
            guard let d = value as? [String: Any], let name = d["name"] as? String, !name.isEmpty else { continue }
            result[key] = name
        }
        return result
    }

    func importData(from source: BrowserImportSource, bookmarks: Bool, history: Bool, sessions: Bool = false,
                    completion: @escaping (Result<BrowserImportResult, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var bookmarkEntries: [HistoryEntry] = [], historyEntries: [HistoryEntry] = []
                var warnings: [String] = []
                if bookmarks || history {
                    do { (bookmarkEntries, historyEntries, warnings) = try self.readData(from: source, bookmarks: bookmarks, history: history) }
                    catch { warnings.append("Bookmarks/history: \(error.localizedDescription)") }
                }
                var cookieBatch: ChromeCookieBatch?
                if sessions {
                    do { cookieBatch = try ChromeSessionImport.read(from: source) }
                    catch { warnings.append("Sign-in sessions: \(error.localizedDescription)") }
                }
                guard !bookmarkEntries.isEmpty || !historyEntries.isEmpty || cookieBatch != nil else {
                    if warnings.isEmpty { throw BrowserImportError.noData }
                    throw BrowserImportError.unreadable(warnings.joined(separator: " "))
                }
                if let cookieBatch { warnings.append(contentsOf: cookieBatch.warnings) }
                DispatchQueue.main.async {
                    let bAdded = Store.shared.importBookmarks(bookmarkEntries)
                    let hAdded = Store.shared.importHistory(historyEntries)
                    Store.shared.flush()
                    var result = BrowserImportResult(bookmarksAdded: bAdded, historyAdded: hAdded,
                                                     bookmarksRead: bookmarkEntries.count, historyRead: historyEntries.count,
                                                     warnings: warnings)
                    guard let cookieBatch else { completion(.success(result)); return }
                    ChromeSessionImport.install(cookieBatch.cookies, into: WKWebsiteDataStore.default().httpCookieStore) { installed in
                        result.cookiesImported = installed.imported
                        result.cookiesPreserved = installed.preserved
                        result.cookiesSkipped = cookieBatch.skipped + installed.rejected
                        result.cookieSites = installed.sites.count
                        if installed.imported == 0 && installed.preserved == 0 && bookmarkEntries.isEmpty && historyEntries.isEmpty {
                            completion(.failure(BrowserImportError.unreadable("WebKit did not accept any transferable cookies. You will need to sign in again.")))
                        } else { completion(.success(result)) }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Parsing is separate from persistence so failures never masquerade as successful imports.
    func readData(from source: BrowserImportSource, bookmarks: Bool, history: Bool) throws
        -> ([HistoryEntry], [HistoryEntry], [String]) {
        var warnings: [String] = []
        var bookmarkEntries: [HistoryEntry] = []
        var historyEntries: [HistoryEntry] = []
        if bookmarks {
            if source.hasBookmarks {
                do { bookmarkEntries = try readBookmarks(source) }
                catch { warnings.append("Bookmarks: \(error.localizedDescription)") }
            } else { warnings.append("Bookmarks: the selected file is no longer available.") }
        }
        if history {
            if source.hasHistory {
                do { historyEntries = try readHistory(source) }
                catch { warnings.append("History: \(error.localizedDescription)") }
            } else { warnings.append("History: the selected file is no longer available.") }
        }
        if bookmarkEntries.isEmpty && historyEntries.isEmpty {
            if !warnings.isEmpty { throw BrowserImportError.unreadable(warnings.joined(separator: " ")) }
            throw BrowserImportError.noData
        }
        return (bookmarkEntries, historyEntries, warnings)
    }

    // MARK: - Bookmarks

    private func readBookmarks(_ source: BrowserImportSource) throws -> [HistoryEntry] {
        switch source.format {
        case .chromium: return try readChromiumBookmarks(source.bookmarksURL)
        case .firefox: return try readFirefoxBookmarks(source.bookmarksURL)
        case .safari: return try readSafariBookmarks(source.bookmarksURL)
        }
    }

    private func readChromiumBookmarks(_ url: URL?) throws -> [HistoryEntry] {
        guard let url else { return [] }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw BrowserImportError.unreadable("Could not read bookmarks from \(url.path): \(error.localizedDescription)") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { throw BrowserImportError.invalidFormat("Unrecognized Chromium bookmark format.") }
        var result: [HistoryEntry] = []
        func walk(_ any: Any) {
            guard let node = any as? [String: Any] else { return }
            if let u = node["url"] as? String, let parsed = URL(string: u), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") {
                result.append(HistoryEntry(url: u, title: node["name"] as? String ?? "", visits: 1, lastVisit: Date()))
            }
            if let children = node["children"] as? [Any] { children.forEach(walk) }
        }
        roots.values.forEach(walk)
        return dedupe(result)
    }

    private func readFirefoxBookmarks(_ url: URL?) throws -> [HistoryEntry] {
        guard let url else { return [] }
        let sql = "SELECT p.url AS url, COALESCE(NULLIF(b.title,''),NULLIF(p.title,''),'') AS title, COALESCE(b.dateAdded,0) AS added FROM moz_bookmarks b JOIN moz_places p ON b.fk=p.id WHERE b.type=1 AND (p.url LIKE 'http://%' OR p.url LIKE 'https://%') ORDER BY b.dateAdded DESC;"
        let rows = try querySQLite(url, sql: sql)
        return dedupe(rows.compactMap { row in
            guard let u = row["url"] as? String else { return nil }
            let micros = number(row["added"])
            let date = micros > 0 ? Date(timeIntervalSince1970: micros / 1_000_000) : Date()
            return HistoryEntry(url: u, title: row["title"] as? String ?? "", visits: 1, lastVisit: date)
        })
    }

    private func readSafariBookmarks(_ url: URL?) throws -> [HistoryEntry] {
        guard let url else { return [] }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            throw BrowserImportError.unreadable("Safari bookmarks could not be read. macOS may require Full Disk Access for Facet. \(error.localizedDescription)")
        }
        var format = PropertyListSerialization.PropertyListFormat.binary
        let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        var result: [HistoryEntry] = []
        func walk(_ any: Any) {
            guard let d = any as? [String: Any] else { return }
            if let u = d["URLString"] as? String, let parsed = URL(string: u), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") {
                let uri = d["URIDictionary"] as? [String: Any]
                result.append(HistoryEntry(url: u, title: uri?["title"] as? String ?? "", visits: 1, lastVisit: Date()))
            }
            if let children = d["Children"] as? [Any] { children.forEach(walk) }
        }
        walk(obj)
        return dedupe(result)
    }

    // MARK: - History

    private func readHistory(_ source: BrowserImportSource) throws -> [HistoryEntry] {
        switch source.format {
        case .chromium:
            guard let url = source.historyURL else { return [] }
            let sql = "SELECT url, COALESCE(title,'') AS title, MAX(visit_count,1) AS visits, last_visit_time AS last FROM urls WHERE url LIKE 'http://%' OR url LIKE 'https://%' ORDER BY last_visit_time DESC LIMIT 10000;"
            return try querySQLite(url, sql: sql).compactMap { row in
                guard let u = row["url"] as? String else { return nil }
                let chromeMicros = number(row["last"])
                let unix = chromeMicros > 0 ? chromeMicros / 1_000_000 - 11_644_473_600 : Date().timeIntervalSince1970
                return HistoryEntry(url: u, title: row["title"] as? String ?? "",
                                    visits: visitCount(row["visits"]), lastVisit: Date(timeIntervalSince1970: unix))
            }
        case .firefox:
            guard let url = source.historyURL else { return [] }
            let sql = "SELECT url, COALESCE(title,'') AS title, MAX(visit_count,1) AS visits, COALESCE(last_visit_date,0) AS last FROM moz_places WHERE url LIKE 'http://%' OR url LIKE 'https://%' ORDER BY last_visit_date DESC LIMIT 10000;"
            return try querySQLite(url, sql: sql).compactMap { row in
                guard let u = row["url"] as? String else { return nil }
                let micros = number(row["last"])
                return HistoryEntry(url: u, title: row["title"] as? String ?? "",
                                    visits: visitCount(row["visits"]),
                                    lastVisit: micros > 0 ? Date(timeIntervalSince1970: micros / 1_000_000) : Date())
            }
        case .safari:
            guard let url = source.historyURL else { return [] }
            // Safari stores visit_time as seconds since Apple's 2001 reference date.
            let sql = "SELECT i.url AS url, COALESCE(v.title,'') AS title, MAX(i.visit_count,1) AS visits, MAX(v.visit_time) AS last FROM history_items i JOIN history_visits v ON v.history_item=i.id WHERE i.url LIKE 'http://%' OR i.url LIKE 'https://%' GROUP BY i.id ORDER BY last DESC LIMIT 10000;"
            do {
                return try querySQLite(url, sql: sql).compactMap { row in
                    guard let u = row["url"] as? String else { return nil }
                    let apple = number(row["last"])
                    return HistoryEntry(url: u, title: row["title"] as? String ?? "",
                                        visits: visitCount(row["visits"]),
                                        lastVisit: apple > 0 ? Date(timeIntervalSince1970: apple + 978_307_200) : Date())
                }
            } catch {
                throw BrowserImportError.unreadable("Safari history could not be read. macOS may require Full Disk Access for Facet. \(error.localizedDescription)")
            }
        }
    }

    private func querySQLite(_ source: URL, sql: String) throws -> [[String: Any]] {
        try BrowserSQLite(source).query(sql)
    }

    private func visitCount(_ any: Any?) -> Int {
        let value = number(any)
        guard value.isFinite else { return 1 }
        return Int(min(Double(Int32.max), max(1, value)))
    }

    private func number(_ any: Any?) -> Double {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) ?? 0 }
        return 0
    }

    private func dedupe(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        var seen = Set<String>(), out: [HistoryEntry] = []
        for e in entries where !seen.contains(e.url) { seen.insert(e.url); out.append(e) }
        return out
    }
}
