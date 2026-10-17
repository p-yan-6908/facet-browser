import AppKit
import CoreServices
import WebKit

extension Notification.Name {
    static let facetDownloadsChanged = Notification.Name("FacetDownloadsChanged")
}

/// One download. Rows in the downloads popover read from here; nothing is persisted.
final class DownloadItem: NSObject {
    enum State: Equatable { case running, finished, failed(String), cancelled }

    let id = UUID()
    fileprivate(set) var download: WKDownload?
    fileprivate(set) var sourceURL: URL?
    let pageURL: URL?
    fileprivate(set) var filename: String
    fileprivate(set) var destination: URL?
    fileprivate(set) var state: State = .running
    fileprivate(set) var completedBytes: Int64 = 0
    fileprivate(set) var totalBytes: Int64 = -1
    fileprivate(set) var resumeData: Data?
    fileprivate var cancelledByUser = false
    fileprivate var progressObservation: NSKeyValueObservation?

    init(download: WKDownload, page: URL?) {
        self.download = download
        self.sourceURL = download.originalRequest?.url
        self.pageURL = page
        self.filename = download.originalRequest?.url?.lastPathComponent ?? "download"
    }

    var isActive: Bool { state == .running }
    var fraction: Double? { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : nil }

    var statusText: String {
        func size(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, n), countStyle: .file) }
        switch state {
        case .running: return totalBytes > 0 ? "\(size(completedBytes)) of \(size(totalBytes))" : size(completedBytes)
        case .finished: return size(max(completedBytes, totalBytes))
        case .failed(let reason): return "Failed \u{2014} \(reason)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Downloads land in ~/Downloads with a de-duplicated name. WebKit streams straight to
/// disk; Facet only keeps the list of this session's downloads for the toolbar popover.
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    /// Set by the active window so finished downloads can be announced in the toolbar.
    var statusHandler: ((String) -> Void)?
    /// Replaced in tests so fixtures never write to the real Downloads folder.
    var folderOverride: URL?
    private(set) var items: [DownloadItem] = []
    private var notifyScheduled = false

    var recent: [URL] { items.filter { $0.state == .finished }.compactMap(\.destination) }
    var activeCount: Int { items.filter(\.isActive).count }

    /// Combined progress of running downloads, for the toolbar ring. nil when unknown.
    var aggregateFraction: Double? {
        let running = items.filter { $0.isActive && $0.totalBytes > 0 }
        guard !running.isEmpty else { return nil }
        let total = running.reduce(Int64(0)) { $0 + $1.totalBytes }
        let done = running.reduce(Int64(0)) { $0 + min($1.completedBytes, $1.totalBytes) }
        return total > 0 ? Double(done) / Double(total) : nil
    }

    var folder: URL {
        folderOverride
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// Server-suggested names are untrusted: no path separators, no hidden dotfiles.
    static func sanitizedFilename(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        s = s.filter { !$0.isNewline && $0 != "\0" }
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > 200 {
            let ext = (s as NSString).pathExtension
            let stem = String((s as NSString).deletingPathExtension.prefix(190))
            s = ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        return s.isEmpty ? "download" : s
    }

    private func uniqueDestination(for name: String) -> URL {
        let safe = Self.sanitizedFilename(name)
        var candidate = folder.appendingPathComponent(safe)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var i = 2
        repeat {
            let newName = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            i += 1
        } while FileManager.default.fileExists(atPath: candidate.path) && i < 500
        return candidate
    }

    // MARK: - Tracking

    @discardableResult
    func track(_ download: WKDownload, page: URL?) -> DownloadItem {
        if let existing = item(for: download) { return existing }
        download.delegate = self
        let item = DownloadItem(download: download, page: page)
        observe(item, download)
        items.insert(item, at: 0)
        // Keep the list short: drop the oldest finished entries first.
        while items.count > 50, let i = items.lastIndex(where: { !$0.isActive }) { items.remove(at: i) }
        notify()
        return item
    }

    private func observe(_ item: DownloadItem, _ download: WKDownload) {
        item.progressObservation = download.progress.observe(\.completedUnitCount) { [weak self, weak item] progress, _ in
            let done = progress.completedUnitCount, total = progress.totalUnitCount
            DispatchQueue.main.async {
                guard let item, item.isActive else { return }
                item.completedBytes = done
                if total > 0 { item.totalBytes = total }
                self?.notify(throttled: true)
            }
        }
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    /// Progress callbacks arrive many times a second; the UI needs a few frames at most.
    private func notify(throttled: Bool = false) {
        guard throttled else {
            NotificationCenter.default.post(name: .facetDownloadsChanged, object: self); return
        }
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.notifyScheduled = false
            NotificationCenter.default.post(name: .facetDownloadsChanged, object: self)
        }
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let item = track(download, page: nil)
        let dest = uniqueDestination(for: suggestedFilename)
        item.filename = dest.lastPathComponent
        item.destination = dest
        if let url = response.url { item.sourceURL = item.sourceURL ?? url }
        if response.expectedContentLength > 0 { item.totalBytes = response.expectedContentLength }
        statusHandler?("Downloading \(dest.lastPathComponent)\u{2026}")
        notify()
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.progressObservation = nil
        item.download = nil
        item.state = .finished
        if let dest = item.destination {
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
            if let size { item.completedBytes = size; item.totalBytes = size }
            Self.applyQuarantine(to: dest, source: item.sourceURL, page: item.pageURL)
            // Bounces the Downloads stack in the Dock, as Safari and Chrome do.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"),
                                                         object: dest.resolvingSymlinksInPath().path)
        }
        statusHandler?("Saved \(item.filename) to Downloads")
        NSSound(named: "Glass")?.play()
        notify()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        item.progressObservation = nil
        item.download = nil
        item.resumeData = resumeData
        item.state = item.cancelledByUser ? .cancelled : .failed(error.localizedDescription)
        if !item.cancelledByUser { statusHandler?("Download failed: \(error.localizedDescription)") }
        notify()
    }

    // MARK: - Actions

    func cancel(_ item: DownloadItem) {
        guard item.isActive, let download = item.download else { return }
        item.cancelledByUser = true
        download.cancel { [weak item] data in DispatchQueue.main.async { item?.resumeData = data } }
    }

    /// Resumes from WebKit's resume data when there is some, otherwise starts over.
    func retry(_ item: DownloadItem, using webView: WKWebView) {
        guard !item.isActive else { return }
        let restart: (WKDownload) -> Void = { [weak self] download in
            guard let self else { return }
            download.delegate = self
            item.download = download
            item.state = .running
            item.cancelledByUser = false
            item.resumeData = nil
            self.observe(item, download)
            self.notify()
        }
        if let data = item.resumeData {
            webView.resumeDownload(fromResumeData: data) { restart($0) }
        } else if let source = item.sourceURL {
            if let dest = item.destination { try? FileManager.default.removeItem(at: dest) }
            webView.startDownload(using: URLRequest(url: source)) { restart($0) }
        }
    }

    func reveal(_ item: DownloadItem) {
        if let dest = item.destination, FileManager.default.fileExists(atPath: dest.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } else {
            revealFolder()
        }
    }

    func open(_ item: DownloadItem) {
        guard item.state == .finished, let dest = item.destination else { return }
        NSWorkspace.shared.open(dest)
    }

    func clearInactive() {
        items.removeAll { !$0.isActive }
        notify()
    }

    func revealFolder() {
        NSWorkspace.shared.open(folder)
    }

    /// Marks a finished download as coming from the web so Gatekeeper checks it before it
    /// can run, exactly as Safari and Chrome do. Left alone if WebKit already tagged it.
    static func applyQuarantine(to file: URL, source: URL?, page: URL?) {
        var url = file
        if let existing = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties,
           !existing.isEmpty { return }
        var props: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Facet",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let source, ["http", "https"].contains(source.scheme?.lowercased() ?? "") {
            props[kLSQuarantineDataURLKey as String] = source
        }
        if let page, ["http", "https"].contains(page.scheme?.lowercased() ?? "") {
            props[kLSQuarantineOriginURLKey as String] = page
        }
        var values = URLResourceValues()
        values.quarantineProperties = props
        try? url.setResourceValues(values)
    }
}
