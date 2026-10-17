import AppKit

/// The new-tab page, drawn natively. A blank tab in Facet allocates no web
/// process at all -- there is literally nothing to load.
final class StartView: NSView {
    var onOpen: ((String) -> Void)?
    var onFocusAddressBar: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Facet")
    private let searchButton = SearchPromptButton()
    private var tiles: [SiteTileView] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        addSubview(titleLabel)
        searchButton.onClick = { [weak self] in self?.onFocusAddressBar?() }
        addSubview(searchButton)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }

    func rebuild() {
        searchButton.text = "Search \(Config.shared.searchEngineName) or type a URL"
        tiles.forEach { $0.removeFromSuperview() }

        // Top sites by visit count, one entry per host.
        var seenHosts = Set<String>()
        var top: [(host: String, url: String)] = []
        for e in Store.shared.history.sorted(by: { $0.visits > $1.visits }) {
            guard let h = URL(string: e.url)?.host else { continue }
            let clean = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
            if seenHosts.contains(clean) { continue }
            seenHosts.insert(clean)
            top.append((clean, "https://" + h + "/"))
            if top.count == 10 { break }
        }

        tiles = top.map { site in
            let tile = SiteTileView(host: site.host, icon: FaviconStore.shared.icon(forHost: URL(string: site.url)?.host))
            tile.onClick = { [weak self] in self?.onOpen?(site.url) }
            addSubview(tile)
            return tile
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let centerY = bounds.height * 0.26
        titleLabel.frame = NSRect(x: 0, y: centerY, width: bounds.width, height: 38)
        let searchW = min(560, bounds.width - 80)
        searchButton.frame = NSRect(x: (bounds.width - searchW) / 2, y: centerY + 56, width: searchW, height: 40)

        guard !tiles.isEmpty else { return }
        // Centre a wrapping grid of tiles under the search prompt.
        let tw: CGFloat = 104, th: CGFloat = 92, gap: CGFloat = 14
        let perRow = max(1, min(5, Int((bounds.width - 40) / (tw + gap))))
        var i = 0
        while i < tiles.count {
            let rowCount = min(perRow, tiles.count - i)
            let rowWidth = CGFloat(rowCount) * tw + CGFloat(rowCount - 1) * gap
            var x = (bounds.width - rowWidth) / 2
            let y = centerY + 128 + CGFloat(i / perRow) * (th + gap)
            for j in 0..<rowCount {
                tiles[i + j].frame = NSRect(x: x, y: y, width: tw, height: th)
                x += tw + gap
            }
            i += rowCount
        }
    }
}

/// The big "Search or type a URL" capsule. Clicking it focuses the real address bar,
/// as Chrome's new-tab search box does.
final class SearchPromptButton: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(hovering ? 0.22 : 0.14).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        if let glass = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = glass.size
            glass.draw(in: NSRect(x: 18, y: bounds.midY - s.height / 2, width: s.width, height: s.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.tertiaryLabelColor]
        let s = NSAttributedString(string: text, attributes: attrs)
        s.draw(at: NSPoint(x: 46, y: bounds.midY - s.size().height / 2))
    }
}

/// A most-visited site: its favicon (or initial) over its name.
final class SiteTileView: NSView {
    let host: String
    let icon: NSImage?
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    init(host: String, icon: NSImage?) {
        self.host = host
        self.icon = icon
        super.init(frame: .zero)
        toolTip = host
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        }
        let circle = NSRect(x: bounds.midX - 24, y: 12, width: 48, height: 48)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: circle).fill()
        if let icon {
            icon.draw(in: circle.insetBy(dx: 14, dy: 14), from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        } else {
            let letter = NSAttributedString(string: String(host.first.map(String.init)?.uppercased() ?? "\u{2022}"), attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
            let s = letter.size()
            letter.draw(at: NSPoint(x: circle.midX - s.width / 2, y: circle.midY - s.height / 2))
        }
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.lineBreakMode = .byTruncatingTail
        let label = NSAttributedString(string: host, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: ps])
        label.draw(with: NSRect(x: 6, y: 66, width: bounds.width - 12, height: 16),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// URL field that gives the page its focus back on Escape and selects all on focus.
final class URLField: NSTextField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) } }
        return ok
    }
}
