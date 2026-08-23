import AppKit

/// Toolbar icon button: full-contrast glyph, rounded hover highlight, no borders.
///
/// The stock borderless NSButton draws its symbol at the default thin weight in
/// secondary grey, which reads as disabled. A semibold glyph in `labelColor` plus a
/// hover background is the difference between "faint decoration" and "a button".
final class ToolbarButton: NSButton {
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?
    private var symbolName: String

    /// Set for toggles that should read as "on" (the shield, a filled bookmark star).
    var isHighlighted2 = false { didSet { refresh() } }
    var onTint: NSColor = .controlAccentColor
    var normalTint: NSColor = .labelColor
    var disabledTint: NSColor = .tertiaryLabelColor

    init(symbol: String, tip: String, target: AnyObject?, action: Selector,
         pointSize: CGFloat = 13, weight: NSFont.Weight = .semibold) {
        self.symbolName = symbol
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .accessoryBarAction
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 6
        if #available(macOS 10.15, *) { layer?.cornerCurve = .continuous }
        self.target = target
        self.action = action
        toolTip = tip
        setSymbol(symbol, pointSize: pointSize, weight: weight)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String, pointSize: CGFloat = 13, weight: NSFont.Weight = .semibold) {
        symbolName = name
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(cfg)
    }

    override var isEnabled: Bool {
        didSet { refresh() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                              owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    /// Layer colours are resolved CGColors, so they have to be rebuilt when the user
    /// switches between light and dark.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        let bg: NSColor = hovering && isEnabled
            ? NSColor.quaternaryLabelColor.withAlphaComponent(0.28)
            : .clear
        // cgColor must be resolved against this view's appearance, not the app default.
        let appearance = effectiveAppearance
        var resolved: CGColor = .clear
        appearance.performAsCurrentDrawingAppearance { resolved = bg.cgColor }
        layer?.backgroundColor = resolved
        contentTintColor = !isEnabled ? disabledTint : (isHighlighted2 ? onTint : normalTint)
    }
}

/// The memory readout / transient status text, drawn as a soft capsule so it reads as
/// a deliberate part of the toolbar rather than leftover debug text.
final class StatusPill: NSView {
    var text: String = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
         .foregroundColor: NSColor.secondaryLabelColor]
    }

    /// Width the pill wants, so the toolbar can lay out around it.
    var fittingWidth: CGFloat {
        text.isEmpty ? 0 : ceil(NSAttributedString(string: text, attributes: attributes).size().width) + 18
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let s = NSAttributedString(string: text, attributes: attributes)
        let size = s.size()
        let h: CGFloat = 19
        let pill = NSRect(x: bounds.maxX - size.width - 18, y: (bounds.height - h) / 2,
                          width: size.width + 18, height: h)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill()
        s.draw(at: NSPoint(x: pill.minX + 9, y: pill.midY - size.height / 2))
    }
}

/// One-pixel hairline. A view rather than a drawn line so it can sit in the layout.
final class HairlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

/// Flat background for the find bar, so it does not float over the page.
final class BarBackgroundView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

/// The address bar: a filled capsule with a leading site-security glyph, the way every
/// current browser draws it. Focus is shown by tinting the border with the accent
/// colour rather than a system focus ring, so it reads at a glance.
final class URLBar: NSView {
    let field = URLField()
    private var focused = false
    private let glyph = NSImageView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = "Search or enter address"
        glyph.imageScaling = .scaleNone
        glyph.contentTintColor = .tertiaryLabelColor
        addSubview(glyph)
        addSubview(field)
        setGlyph("magnifyingglass", .tertiaryLabelColor)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFocused(_ on: Bool) {
        guard focused != on else { return }
        focused = on
        needsDisplay = true
    }

    private func setGlyph(_ name: String, _ color: NSColor) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        glyph.contentTintColor = color
    }

    /// Reflects what is loaded: secure, plaintext, or nothing yet.
    func showSecurity(for url: URL?) {
        switch url?.scheme?.lowercased() {
        case "https": setGlyph("lock.fill", .secondaryLabelColor)
        case "http":  setGlyph("exclamationmark.triangle.fill", .systemOrange)
        default:      setGlyph("magnifyingglass", .tertiaryLabelColor)
        }
    }

    override func layout() {
        super.layout()
        glyph.frame = NSRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        field.frame = NSRect(x: 32, y: (bounds.height - 17) / 2,
                            width: max(10, bounds.width - 44), height: 17)
    }

    /// Clicking anywhere in the capsule should start editing, not just the text itself.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (focused ? NSColor.controlBackgroundColor
                 : NSColor.quaternaryLabelColor.withAlphaComponent(0.12)).setFill()
        path.fill()
        if focused {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
        } else {
            NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1
        }
        path.stroke()
    }
}
