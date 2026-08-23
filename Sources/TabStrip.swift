import AppKit

protocol TabStripDelegate: AnyObject {
    func tabStripDidSelect(index: Int)
    func tabStripDidRequestClose(index: Int)
    func tabStripDidRequestNewTab()
}

/// One view per tab, everything drawn by hand. A stock NSTableView or NSSegmented
/// control would add layers, cells and layout passes we do not need.
final class TabItemView: NSView {
    var title: String = "" { didSet { needsDisplay = true } }
    var favicon: NSImage? { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var isHibernated = false { didSet { needsDisplay = true } }
    var isLoading = false { didSet { needsDisplay = true } }
    var progress: Double = 0 { didSet { if isLoading { needsDisplay = true } } }
    var isPrivate = false { didSet { needsDisplay = true } }

    private var hovering = false { didSet { needsDisplay = true } }
    private var closeHovering = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    private var showsTitle: Bool { bounds.width >= 76 }
    private var showsClose: Bool { bounds.width >= 58 && (hovering || isSelected) }
    private var closeRect: NSRect {
        NSRect(x: bounds.maxX - 22, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; closeHovering = false }
    override func mouseMoved(with event: NSEvent) {
        closeHovering = closeRect.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if showsClose, closeRect.contains(p) { onClose?(); return }
        if event.type == .otherMouseDown { onClose?(); return }
        onSelect?()
    }

    override func otherMouseDown(with event: NSEvent) { onClose?() }  // middle-click closes

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 3)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)

        if isSelected {
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovering {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.14).setFill()
            path.fill()
        }

        var x = r.minX + 8.0
        let iconSize: CGFloat = 16
        let iconY = (bounds.height - iconSize) / 2

        if isLoading {
            // A quiet arc instead of a spinning NSProgressIndicator: no timer, no layer.
            let c = NSPoint(x: x + iconSize / 2, y: bounds.midY)
            let ring = NSBezierPath()
            ring.appendArc(withCenter: c, radius: 6, startAngle: 0, endAngle: 360)
            NSColor.tertiaryLabelColor.setStroke()
            ring.lineWidth = 2
            ring.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: 6, startAngle: 90,
                          endAngle: 90 - CGFloat(360 * max(0.08, progress)), clockwise: true)
            NSColor.controlAccentColor.setStroke()
            arc.lineWidth = 2
            arc.stroke()
            x += iconSize + 6
        } else if let icon = favicon {
            let rect = NSRect(x: x, y: iconY, width: iconSize, height: iconSize)
            if isHibernated {
                NSGraphicsContext.current?.saveGraphicsState()
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.45)
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            x += iconSize + 6
        } else {
            // Letter tile fallback so tabs never look empty.
            let letter = String(title.first.map(String.init)?.uppercased() ?? "\u{2022}")
            let rect = NSRect(x: x, y: iconY, width: iconSize, height: iconSize)
            let bg = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSColor.tertiaryLabelColor.withAlphaComponent(isHibernated ? 0.2 : 0.35).setFill()
            bg.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let s = NSAttributedString(string: letter, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
            x += iconSize + 6
        }

        if showsTitle {
            let rightPad: CGFloat = showsClose ? 26 : 8
            let width = max(0, r.maxX - x - rightPad)
            if width > 8 {
                let color: NSColor = isSelected ? .labelColor
                    : (isHibernated ? .tertiaryLabelColor : .secondaryLabelColor)
                let ps = NSMutableParagraphStyle()
                ps.lineBreakMode = .byTruncatingTail
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .medium : .regular),
                    .foregroundColor: color,
                    .paragraphStyle: ps,
                ]
                let s = NSAttributedString(string: title, attributes: attrs)
                let h = s.size().height
                s.draw(with: NSRect(x: x, y: bounds.midY - h / 2, width: width, height: h),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }

        if isPrivate {
            let dot = NSBezierPath(ovalIn: NSRect(x: r.minX + 3, y: r.minY + 3, width: 5, height: 5))
            NSColor.systemPurple.setFill()
            dot.fill()
        }

        if showsClose {
            let cr = closeRect
            if closeHovering {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setFill()
                NSBezierPath(roundedRect: cr, xRadius: 4, yRadius: 4).fill()
            }
            let inset = cr.insetBy(dx: 4.5, dy: 4.5)
            let x1 = NSBezierPath()
            x1.move(to: NSPoint(x: inset.minX, y: inset.minY))
            x1.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            x1.move(to: NSPoint(x: inset.maxX, y: inset.minY))
            x1.line(to: NSPoint(x: inset.minX, y: inset.maxY))
            (closeHovering ? NSColor.labelColor : NSColor.secondaryLabelColor).setStroke()
            x1.lineWidth = 1.3
            x1.lineCapStyle = .round
            x1.stroke()
        }
    }
}

final class TabStripView: NSView {
    weak var delegate: TabStripDelegate?
    private var items: [TabItemView] = []
    private let newTabButton = NSButton()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        newTabButton.bezelStyle = .accessoryBarAction
        newTabButton.isBordered = false
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        newTabButton.imageScaling = .scaleProportionallyDown
        newTabButton.target = self
        newTabButton.action = #selector(newTab)
        newTabButton.toolTip = "New Tab (\u{2318}T)"
        addSubview(newTabButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func newTab() { delegate?.tabStripDidRequestNewTab() }

    /// Rebuild only when the tab count changes; otherwise update in place so
    /// typing in a page title does not churn the view hierarchy.
    func update(tabs: [Tab], selected: Int) {
        if items.count != tabs.count {
            items.forEach { $0.removeFromSuperview() }
            items = tabs.indices.map { i in
                let v = TabItemView()
                v.onSelect = { [weak self] in self?.delegate?.tabStripDidSelect(index: i) }
                v.onClose = { [weak self] in self?.delegate?.tabStripDidRequestClose(index: i) }
                addSubview(v)
                return v
            }
        }
        for (i, tab) in tabs.enumerated() {
            let v = items[i]
            v.onSelect = { [weak self] in self?.delegate?.tabStripDidSelect(index: i) }
            v.onClose = { [weak self] in self?.delegate?.tabStripDidRequestClose(index: i) }
            v.title = tab.displayTitle
            v.favicon = tab.favicon
            v.isSelected = (i == selected)
            v.isHibernated = tab.isHibernated
            v.isLoading = tab.isLoading
            v.progress = tab.progress
            v.isPrivate = tab.isPrivate
            v.toolTip = tab.isHibernated
                ? "\(tab.displayTitle) \u{2014} sleeping (0 MB)"
                : tab.url?.absoluteString ?? tab.displayTitle
        }
        layoutTabs()
    }

    private func layoutTabs() {
        let buttonW: CGFloat = 28
        let available = max(0, bounds.width - buttonW - 4)
        guard !items.isEmpty else {
            newTabButton.frame = NSRect(x: 2, y: (bounds.height - 22) / 2, width: buttonW, height: 22)
            return
        }
        let w = min(210, max(44, available / CGFloat(items.count)))
        var x: CGFloat = 0
        for v in items {
            v.frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
            x += w
        }
        newTabButton.frame = NSRect(x: min(x + 3, bounds.width - buttonW - 2),
                                    y: (bounds.height - 22) / 2, width: buttonW, height: 22)
    }

    override func layout() {
        super.layout()
        layoutTabs()
    }
}

/// 2px determinate bar under the toolbar. Hidden at rest so there is nothing to animate.
final class ProgressBar: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var active = false { didSet { isHidden = !active; needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard active else { return }
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * CGFloat(max(0.02, progress)), height: bounds.height).fill()
    }
}
