import AppKit
import WebKit

/// Downloads land in ~/Downloads with a de-duplicated name. No download manager
/// window, no background service -- WebKit streams straight to disk.
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    /// Set by the active window so finished downloads can be announced in the toolbar.
    var statusHandler: ((String) -> Void)?
    private(set) var recent: [URL] = []

    private var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    private func uniqueDestination(for name: String) -> URL {
        let safe = name.isEmpty ? "download" : name
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

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dest = uniqueDestination(for: suggestedFilename)
        statusHandler?("Downloading \(dest.lastPathComponent)\u{2026}")
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let name = download.progress.fileURL?.lastPathComponent ?? "file"
        if let u = download.progress.fileURL { recent.insert(u, at: 0); recent = Array(recent.prefix(20)) }
        statusHandler?("Saved \(name) to Downloads")
        NSSound(named: "Glass")?.play()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        statusHandler?("Download failed: \(error.localizedDescription)")
    }

    func revealFolder() {
        NSWorkspace.shared.open(folder)
    }
}
