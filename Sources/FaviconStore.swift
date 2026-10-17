import AppKit
import CryptoKit

/// Favicons, bounded in memory and on disk. Every icon is redrawn into one 32x32 bitmap
/// before it is kept, so a site's 512px touch icon cannot pin megabytes of decoded pixels
/// for each tab. Icons persist as tiny PNGs so restored, sleeping tabs show their icon
/// without waking a renderer or touching the network.
final class FaviconStore {
    static let shared = FaviconStore()

    private var cache: [String: NSImage] = [:]
    private var recency: [String] = []
    private let capacity = 256
    private var knownMissing = Set<String>()
    private var refreshedThisLaunch = Set<String>()

    /// Favicons need no cookies and are persisted by us, so an ephemeral session keeps
    /// them out of both the shared cookie jar and URLCache.
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 6
        cfg.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: cfg)
    }()

    private var folder: URL {
        let url = Config.supportDir.appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileURL(_ host: String) -> URL {
        let digest = SHA256.hash(data: Data(host.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(digest + ".png")
    }

    func icon(forHost rawHost: String?) -> NSImage? {
        guard let host = rawHost?.lowercased(), !host.isEmpty else { return nil }
        if let hit = cache[host] { touch(host); return hit }
        guard !knownMissing.contains(host) else { return nil }
        if let data = try? Data(contentsOf: fileURL(host)), let image = NSImage(data: data) {
            image.size = NSSize(width: 16, height: 16)
            insert(image, for: host)
            return image
        }
        knownMissing.insert(host)
        return nil
    }

    /// True until the icon has been fetched once this launch; disk copies may be stale.
    func needsRefresh(host: String) -> Bool { !refreshedThisLaunch.contains(host.lowercased()) }

    @discardableResult
    func store(_ data: Data, forHost rawHost: String, persist: Bool) -> NSImage? {
        let host = rawHost.lowercased()
        refreshedThisLaunch.insert(host)
        guard let source = NSImage(data: data), source.isValid, source.size.width > 0,
              let rep = Self.downsample(source) else { return nil }
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.addRepresentation(rep)
        insert(image, for: host)
        knownMissing.remove(host)
        if persist, let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: fileURL(host), options: .atomic)
        }
        return image
    }

    /// Redraws any image into a fixed-size bitmap (16pt at 2x).
    static func downsample(_ image: NSImage, pixels: Int = 32) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: 16, height: 16)
        return rep
    }

    func clearAll() {
        cache.removeAll(); recency.removeAll(); knownMissing.removeAll(); refreshedThisLaunch.removeAll()
        try? FileManager.default.removeItem(at: folder)
    }

    private func touch(_ host: String) {
        if let i = recency.firstIndex(of: host) { recency.remove(at: i) }
        recency.append(host)
    }

    private func insert(_ image: NSImage, for host: String) {
        cache[host] = image
        touch(host)
        while recency.count > capacity { cache.removeValue(forKey: recency.removeFirst()) }
    }
}
