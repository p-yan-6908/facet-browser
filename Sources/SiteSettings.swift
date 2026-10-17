import Foundation

/// Per-site preferences Chrome remembers between visits: page zoom, camera/microphone
/// decisions, and sites where ad blocking is turned off. One small JSON file, written debounced. Private windows read it but never
/// write to it.
final class SiteSettings {
    static let shared = SiteSettings(fileURL: Config.supportDir.appendingPathComponent("site-settings.json"))

    private let fileURL: URL
    private var zoomLevels: [String: Double] = [:]
    private var permissions: [String: Bool] = [:]
    private var blockingDisabled = Set<String>()
    private var saveWork: DispatchWorkItem?

    init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        zoomLevels = root["zoom"] as? [String: Double] ?? [:]
        permissions = root["permissions"] as? [String: Bool] ?? [:]
        blockingDisabled = Set(root["noBlocking"] as? [String] ?? [])
    }

    /// Settings are keyed by host without a leading www., so www.example.com and
    /// example.com share a zoom level the way they do in Chrome.
    static func key(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func zoom(for url: URL?) -> Double? {
        Self.key(for: url).flatMap { zoomLevels[$0] }
    }

    func setZoom(_ value: Double, for url: URL?) {
        guard let key = Self.key(for: url) else { return }
        if abs(value - 1) < 0.01 { zoomLevels.removeValue(forKey: key) }
        else { zoomLevels[key] = (value * 100).rounded() / 100 }
        scheduleSave()
    }

    /// nil means "ask". `kind` is a short stable name such as "camera" or "microphone".
    func permission(_ kind: String, for host: String) -> Bool? {
        permissions["\(host.lowercased())|\(kind)"]
    }

    func setPermission(_ kind: String, for host: String, allowed: Bool) {
        permissions["\(host.lowercased())|\(kind)"] = allowed
        scheduleSave()
    }

    /// Sites where ad and tracker blocking is off, keyed like zoom. Subdomains follow.
    var sitesWithoutBlocking: [String] { blockingDisabled.sorted() }

    func isBlockingDisabled(for url: URL?) -> Bool {
        guard let host = Self.key(for: url) else { return false }
        return blockingDisabled.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func setBlockingDisabled(_ disabled: Bool, for url: URL?) {
        guard let key = Self.key(for: url) else { return }
        if disabled { blockingDisabled.insert(key) }
        else { blockingDisabled = blockingDisabled.filter { key != $0 && !key.hasSuffix("." + $0) } }
        scheduleSave()
    }

    func resetPermissions() {
        permissions.removeAll()
        scheduleSave()
    }

    func resetAll() {
        permissions.removeAll()
        zoomLevels.removeAll()
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func flush() {
        saveWork?.cancel(); saveWork = nil
        let root: [String: Any] = ["zoom": zoomLevels, "permissions": permissions, "noBlocking": blockingDisabled.sorted()]
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
