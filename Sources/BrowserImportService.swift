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
    /// The Keychain name a Chromium browser encrypts its cookies with ("Chrome" for "Chrome Safe
    /// Storage"), when Facet knows it. A profile folder picked by hand is recognised by where it lives.
    var sessionKeyring: String? {
        guard format == .chromium else { return nil }
        let byName = ["Google Chrome": "Chrome", "Chrome": "Chrome", "Brave": "Brave", "Brave-Browser": "Brave",
                      "Microsoft Edge": "Microsoft Edge", "Chromium": "Chromium", "Arc": "Arc", "Vivaldi": "Vivaldi",
                      "Opera": "Opera", "com.operasoftware.Opera": "Opera"]
        if let keyring = byName[browserName] { return keyring }
        let path = profileURL.path
        let byPath = [("/Google/Chrome/", "Chrome"), ("/BraveSoftware/", "Brave"), ("/Microsoft Edge/", "Microsoft Edge"),
                      ("/Chromium/", "Chromium"), ("/Arc/User Data/", "Arc"), ("/Vivaldi/", "Vivaldi"), ("/com.operasoftware.Opera/", "Opera")]
        return byPath.first { path.contains($0.0) }?.1
    }

    /// Where this browser keeps cookies. Safari's file sits in its protected container and is
    /// located only after consent, so detection never touches it.
    var cookiesURL: URL? {
        switch format {
        case .chromium: return ChromeSessionImport.cookieDatabase(in: profileURL)
        case .firefox:
            let url = profileURL.appendingPathComponent("cookies.sqlite")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .safari: return nil
        }
    }

    var hasSessions: Bool {
        switch format {
        case .chromium: return sessionKeyring != nil && cookiesURL != nil
        case .firefox: return cookiesURL != nil
        case .safari: return true
        }
    }
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

    /// Chromium browsers whose cookie key Facet knows, so a cookie-only profile is still worth listing.
    private static let keyringBrowsers: Set<String> = ["Google Chrome", "Brave", "Microsoft Edge", "Chromium", "Arc", "Vivaldi", "Opera"]

    private func detectChromium(browserName: String, root: URL) -> [BrowserImportSource] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        let friendly = chromiumProfileNames(root: root)
        var profileDirs: [URL] = []

        // Opera-family profiles often store the files directly in the root.
        if fm.fileExists(atPath: root.appendingPathComponent("Bookmarks").path) ||
            fm.fileExists(atPath: root.appendingPathComponent("History").path) ||
            (Self.keyringBrowsers.contains(browserName) && ChromeSessionImport.cookieDatabase(in: root) != nil) {
            profileDirs.append(root)
        }
        if let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for dir in dirs {
                let n = dir.lastPathComponent
                guard n == "Default" || n.hasPrefix("Profile ") || n.hasPrefix("Person ") else { continue }
                if fm.fileExists(atPath: dir.appendingPathComponent("Bookmarks").path) ||
                    fm.fileExists(atPath: dir.appendingPathComponent("History").path) ||
                    (Self.keyringBrowsers.contains(browserName) && ChromeSessionImport.cookieDatabase(in: dir) != nil) { profileDirs.append(dir) }
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
                var bookmarkEntries: [ImportedBookmark] = [], historyEntries: [HistoryEntry] = []
                var warnings: [String] = []
                if bookmarks || history {
                    do { (bookmarkEntries, historyEntries, warnings) = try self.readData(from: source, bookmarks: bookmarks, history: history) }
                    catch { warnings.append("Bookmarks/history: \(error.localizedDescription)") }
                }
                var cookieBatch: ChromeCookieBatch?
                if sessions {
                    do { cookieBatch = try SessionImport.read(from: source) }
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
        -> ([ImportedBookmark], [HistoryEntry], [String]) {
        var warnings: [String] = []
        var bookmarkEntries: [ImportedBookmark] = []
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

    private func readBookmarks(_ source: BrowserImportSource) throws -> [ImportedBookmark] {
        switch source.format {
        case .chromium: return try readChromiumBookmarks(source.bookmarksURL)
        case .firefox: return try readFirefoxBookmarks(source.bookmarksURL)
        case .safari: return try readSafariBookmarks(source.bookmarksURL)
        }
    }

    private static func isWeb(_ url: String) -> Bool {
        ["http", "https"].contains(URL(string: url)?.scheme?.lowercased() ?? "")
    }

    /// Chromium roots: the bar's contents go to Facet's bar, "Other bookmarks" to Other
    /// Bookmarks, and phone bookmarks to a Mobile Bookmarks folder there. Folders keep their names.
    private func readChromiumBookmarks(_ url: URL?) throws -> [ImportedBookmark] {
        guard let url else { return [] }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw BrowserImportError.unreadable("Could not read bookmarks from \(url.path): \(error.localizedDescription)") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { throw BrowserImportError.invalidFormat("Unrecognized Chromium bookmark format.") }
        var result: [ImportedBookmark] = []
        func walk(_ any: Any, root: ImportedBookmark.Root, folders: [String], isRoot: Bool) {
            guard let node = any as? [String: Any] else { return }
            let name = node["name"] as? String ?? ""
            if let u = node["url"] as? String, Self.isWeb(u) {
                // Chrome stores microseconds since 1601 as a string.
                let micros = Double(node["date_added"] as? String ?? "") ?? 0
                let added = micros > 0 ? Date(timeIntervalSince1970: micros / 1_000_000 - 11_644_473_600) : Date()
                result.append(ImportedBookmark(url: u, title: name, added: added, root: root, folders: folders))
            }
            guard let children = node["children"] as? [Any] else { return }
            let inside = isRoot ? folders : folders + [name.isEmpty ? "Untitled Folder" : name]
            children.forEach { walk($0, root: root, folders: inside, isRoot: false) }
        }
        let order = ["bookmark_bar", "other", "synced"] + roots.keys.sorted().filter { !["bookmark_bar", "other", "synced"].contains($0) }
        for key in order {
            guard let value = roots[key] else { continue }
            walk(value, root: key == "bookmark_bar" ? .bar : .other, folders: key == "synced" ? ["Mobile Bookmarks"] : [], isRoot: true)
        }
        return dedupe(result)
    }

    /// Firefox keeps folders as rows whose `parent` chains up to fixed roots: the toolbar
    /// becomes the bar, the menu and unfiled bookmarks go to Other Bookmarks, and mobile
    /// bookmarks to a Mobile Bookmarks folder there.
    private func readFirefoxBookmarks(_ url: URL?) throws -> [ImportedBookmark] {
        guard let url else { return [] }
        let treeSQL = "SELECT b.id AS id, b.parent AS parent, b.type AS type, COALESCE(b.guid,'') AS guid, COALESCE(NULLIF(b.title,''),NULLIF(p.title,''),'') AS title, p.url AS url, COALESCE(b.dateAdded,0) AS added FROM moz_bookmarks b LEFT JOIN moz_places p ON b.fk=p.id ORDER BY b.parent, b.position;"
        guard let rows = try? querySQLite(url, sql: treeSQL) else { return try readFirefoxBookmarksFlat(url) }
        var folders: [Int: (parent: Int, title: String, guid: String)] = [:]
        for row in rows where Int(number(row["type"])) == 2 {
            folders[Int(number(row["id"]))] = (Int(number(row["parent"])), row["title"] as? String ?? "", row["guid"] as? String ?? "")
        }
        func place(_ parent: Int) -> (ImportedBookmark.Root, [String])? {
            var path: [String] = [], id = parent
            for _ in 0..<64 {
                guard let f = folders[id] else { return nil }
                switch f.guid {
                case "toolbar_____": return (.bar, path)
                case "menu________", "unfiled_____": return (.other, path)
                case "mobile______": return (.other, ["Mobile Bookmarks"] + path)
                case "root________", "tags________": return nil
                default: path.insert(f.title.isEmpty ? "Untitled Folder" : f.title, at: 0); id = f.parent
                }
            }
            return nil
        }
        var result: [ImportedBookmark] = []
        for row in rows where Int(number(row["type"])) == 1 {
            guard let u = row["url"] as? String, Self.isWeb(u), let (root, path) = place(Int(number(row["parent"]))) else { continue }
            let micros = number(row["added"])
            result.append(ImportedBookmark(url: u, title: row["title"] as? String ?? "",
                                           added: micros > 0 ? Date(timeIntervalSince1970: micros / 1_000_000) : Date(),
                                           root: root, folders: path))
        }
        return dedupe(result)
    }

    /// Older or partial places databases without folder columns: everything to Other Bookmarks.
    private func readFirefoxBookmarksFlat(_ url: URL) throws -> [ImportedBookmark] {
        let sql = "SELECT p.url AS url, COALESCE(NULLIF(b.title,''),NULLIF(p.title,''),'') AS title, COALESCE(b.dateAdded,0) AS added FROM moz_bookmarks b JOIN moz_places p ON b.fk=p.id WHERE b.type=1 AND (p.url LIKE 'http://%' OR p.url LIKE 'https://%') ORDER BY b.dateAdded DESC;"
        let rows = try querySQLite(url, sql: sql)
        return dedupe(rows.compactMap { row in
            guard let u = row["url"] as? String else { return nil }
            let micros = number(row["added"])
            return ImportedBookmark(url: u, title: row["title"] as? String ?? "",
                                    added: micros > 0 ? Date(timeIntervalSince1970: micros / 1_000_000) : Date())
        })
    }

    /// Safari's top-level lists: Favorites ("BookmarksBar") become the bar, the Bookmarks menu
    /// goes to Other Bookmarks, and the Reading List to a folder there.
    private func readSafariBookmarks(_ url: URL?) throws -> [ImportedBookmark] {
        guard let url else { return [] }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            throw BrowserImportError.unreadable("Safari bookmarks could not be read. macOS may require Full Disk Access for Facet. \(error.localizedDescription)")
        }
        var format = PropertyListSerialization.PropertyListFormat.binary
        let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        var result: [ImportedBookmark] = []
        func walk(_ any: Any, root: ImportedBookmark.Root, folders: [String], depth: Int) {
            guard let d = any as? [String: Any] else { return }
            if let u = d["URLString"] as? String, Self.isWeb(u) {
                let uri = d["URIDictionary"] as? [String: Any]
                result.append(ImportedBookmark(url: u, title: uri?["title"] as? String ?? "", root: root, folders: folders))
            }
            guard let children = d["Children"] as? [Any] else { return }
            let title = d["Title"] as? String ?? ""
            var r = root, inside = folders
            if depth == 1 {
                switch title {
                case "BookmarksBar": r = .bar; inside = []
                case "BookmarksMenu": r = .other; inside = []
                case "com.apple.ReadingList": r = .other; inside = ["Reading List"]
                default: r = .other; inside = [title.isEmpty ? "Untitled Folder" : title]
                }
            } else if depth > 1 {
                inside = folders + [title.isEmpty ? "Untitled Folder" : title]
            }
            children.forEach { walk($0, root: r, folders: inside, depth: depth + 1) }
        }
        walk(obj, root: .other, folders: [], depth: 0)
        return dedupe(result)
    }

    /// The same page bookmarked twice keeps its first place.
    private func dedupe(_ entries: [ImportedBookmark]) -> [ImportedBookmark] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.url).inserted }
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
