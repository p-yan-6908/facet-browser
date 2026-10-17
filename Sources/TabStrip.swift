import AppKit

protocol TabStripDelegate: AnyObject {
    func tabStripDidSelect(index: Int)
    func tabStripDidRequestClose(index: Int)
    func tabStripDidRequestNewTab()
    /// Title/handler pairs for a tab's right-click menu; "-" means a separator.
    func tabStripContextActions(index: Int) -> [(String, () -> Void)]
    func tabStripDidRequestMove(from: Int, to: Int)
    func tabStripDidToggleMute(index: Int)
    /// The tab was dragged off the strip and dropped at `screenPoint`.
    func tabStripDidDetach(index: Int, at screenPoint: NSPoint)
}

/// One view per tab, everything drawn by hand. A stock NSTableView or NSSegmented
/// control would add layers, cells and layout passes we do not need.
final class TabItemView: NSView, NSViewToolTipOwner {
    var title: String = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var favicon: NSImage? { didSet { if favicon !== oldValue { needsDisplay = true } } }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var isHibernated = false { didSet { if isHibernated != oldValue { needsDisplay = true } } }
    var isLoading = false { didSet { if isLoading != oldValue { needsDisplay = true } } }
    var progress: Double = 0 { didSet { if isLoading && progress != oldValue { needsDisplay = true } } }
    var isPrivate = false { didSet { if isPrivate != oldValue { needsDisplay = true } } }
    var isPinned = false { didSet { if isPinned != oldValue { needsDisplay = true } } }
    var isAudible = false { didSet { if isAudible != oldValue { needsDisplay = true } } }
    var isMuted = false { didSet { if isMuted != oldValue { needsDisplay = true } } }

    private var hovering = false { didSet { needsDisplay = true } }
    private var closeHovering = false { didSet { if closeHovering != oldValue { needsDisplay = true } } }
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onToggleMute: (() -> Void)?
    /// Built when the menu opens, not on every state change of every tab.
    var contextActionsProvider: (() -> [(String, () -> Void)])?
    /// Drag-to-reorder. The strip owns the reordering logic; the item only reports
    /// where the press started and where the pointer is now.
    var onDragBegan: ((CGFloat) -> Void)?      // press x within this item
    var onDragChanged: ((NSPoint) -> Void)?    // pointer, window coordinates
    var onDragEnded: (() -> Void)?
    /// Hover text, built when it shows so a live tab's memory figure is current.
    var toolTipProvider: (() -> String)?

    private var trackingAreaRef: NSTrackingArea?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        toolTipProvider?() ?? title
    }

    override var isFlipped: Bool { true }

    private var showsTitle: Bool { !isPinned && bounds.width >= 76 }
    private var showsClose: Bool { !isPinned && bounds.width >= 58 && (hovering || isSelected) }
    private var showsAudio: Bool { (isAudible || isMuted) && !isPinned && bounds.width >= 64 }
    private var closeRect: NSRect {
        NSRect(x: bounds.maxX - 22, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }
    private var audioRect: NSRect {
        NSRect(x: bounds.maxX - (showsClose ? 42 : 24), y: (bounds.height - 16) / 2, width: 16, height: 16)
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
        closeHovering = showsClose && closeRect.contains(convert(event.locationInWindow, from: nil))
    }

    private var pressPoint: NSPoint?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if showsClose, closeRect.contains(p) { onClose?(); return }
        if showsAudio, audioRect.contains(p) { onToggleMute?(); return }
        if event.type == .otherMouseDown { onClose?(); return }
        pressPoint = p
        onSelect?()   // select on press, like Safari, so dragging the current tab feels direct
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressPoint else { return }
        let here = convert(event.locationInWindow, from: nil)
        if !dragging, abs(here.x - press.x) > 5 || abs(here.y - press.y) > 8 {
            dragging = true
            onDragBegan?(press.x)
        }
        if dragging { onDragChanged?(event.locationInWindow) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { dragging = false; onDragEnded?() }
        pressPoint = nil
    }

    override func otherMouseDown(with event: NSEvent) { onClose?() }  // middle-click closes

    override func rightMouseDown(with event: NSEvent) {
        let actions = contextActionsProvider?() ?? []
        guard !actions.isEmpty else { return super.rightMouseDown(with: event) }
        let menu = NSMenu()
        for entry in actions {
            if entry.0 == "-" { menu.addItem(.separator()); continue }
            menu.addItem(ClosureMenuItem(entry.0, handler: entry.1))
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor, pointSize: CGFloat) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size
        let r = NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

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

        let iconSize: CGFloat = 16
        var x = isPinned ? floor(bounds.midX - iconSize / 2) : r.minX + 8.0
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
            arc.appendArc(withCenter: c, radius: 6, startAngle: -90,
                          endAngle: -90 + CGFloat(360 * max(0.08, progress)), clockwise: false)
            NSColor.controlAccentColor.setStroke()
            arc.lineWidth = 2
            arc.stroke()
            x += iconSize + 6
        } else if let icon = favicon {
            let rect = NSRect(x: x, y: iconY, width: iconSize, height: iconSize)
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isHibernated ? 0.45 : 1,
                      respectFlipped: true, hints: nil)
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

        if isPinned && (isAudible || isMuted) {
            // Pinned tabs have no room for the button, so show a small badge on the icon.
            let badge = NSRect(x: bounds.midX + 3, y: iconY - 4, width: 11, height: 11)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: -1, dy: -1)).fill()
            drawSymbol(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", in: badge,
                       color: .secondaryLabelColor, pointSize: 7)
        }

        if showsTitle {
            var rightPad: CGFloat = showsClose ? 26 : 8
            if showsAudio { rightPad += 20 }
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

        if showsAudio {
            drawSymbol(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", in: audioRect,
                       color: isMuted ? .tertiaryLabelColor : .secondaryLabelColor, pointSize: 10)
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

    private var dragIndex: Int?
    /// Set while a dragged tab is far enough off the strip to become its own window.
    private var dragDetached = false
    private var dragGrabX: CGFloat = 0     // where in the tab the press landed
    private var dragPointerX: CGFloat = 0  // pointer, strip coordinates

    private let buttonWidth: CGFloat = 28
    private let pinnedWidth: CGFloat = 40

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
            items = tabs.indices.map { _ in
                let v = TabItemView()
                addSubview(v)
                return v
            }
        }
        for (i, tab) in tabs.enumerated() {
            let v = items[i]
            v.onSelect = { [weak self] in self?.delegate?.tabStripDidSelect(index: i) }
            v.onClose = { [weak self] in self?.delegate?.tabStripDidRequestClose(index: i) }
            v.onToggleMute = { [weak self] in self?.delegate?.tabStripDidToggleMute(index: i) }
            v.contextActionsProvider = { [weak self] in self?.delegate?.tabStripContextActions(index: i) ?? [] }
            v.onDragBegan = { [weak self] grabX in self?.beginDrag(i, grabX: grabX) }
            v.onDragChanged = { [weak self] p in self?.updateDrag(p) }
            v.onDragEnded = { [weak self] in self?.endDrag() }
            v.title = tab.displayTitle
            v.favicon = tab.favicon
            v.isSelected = (i == selected)
            v.isHibernated = tab.isHibernated
            v.isLoading = tab.isLoading
            v.progress = tab.progress
            v.isPrivate = tab.isPrivate
            v.isPinned = tab.isPinned
            v.isAudible = tab.isPlayingAudio
            v.isMuted = tab.isMuted
            v.toolTipProvider = { [weak tab] in tab?.hoverDescription ?? "" }
        }
        layoutTabs()
    }

    /// Every slot, left to right. Pinned tabs are a fixed icon width; the rest share what
    /// is left. Tabs shrink as far as they must so every tab stays on screen and
    /// clickable -- a lower bound would push the last tabs past the window edge.
    private func slotFrames() -> [NSRect] {
        let available = max(0, bounds.width - buttonWidth - 4)
        let pinned = items.filter(\.isPinned).count
        let unpinned = items.count - pinned
        let pw = pinned > 0 ? min(pinnedWidth, available / CGFloat(items.count)) : 0
        let rest = max(0, available - pw * CGFloat(pinned))
        let w = unpinned > 0 ? min(210, rest / CGFloat(unpinned)) : 0
        var x: CGFloat = 0
        return items.map { item in
            let width = item.isPinned ? pw : w
            defer { x += width }
            return NSRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    /// Indices a tab may move between: pinned tabs stay among pinned tabs.
    private func section(of index: Int) -> ClosedRange<Int> {
        let pinned = items.filter(\.isPinned).count
        return items[index].isPinned ? 0...max(0, pinned - 1) : min(pinned, items.count - 1)...(items.count - 1)
    }

    private func layoutTabs() {
        let frames = slotFrames()
        guard !items.isEmpty else {
            newTabButton.frame = NSRect(x: 2, y: (bounds.height - 22) / 2, width: buttonWidth, height: 22)
            return
        }
        for (i, v) in items.enumerated() where i != dragIndex { v.frame = frames[i] }
        if let d = dragIndex, items.indices.contains(d) {
            let range = section(of: d)
            let w = frames[d].width
            let minX = frames[range.lowerBound].minX
            let maxX = frames[range.upperBound].maxX - w
            let x = max(minX, min(maxX, dragPointerX - dragGrabX))
            items[d].frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
        }
        let end = frames.last?.maxX ?? 0
        newTabButton.frame = NSRect(x: min(end + 3, bounds.width - buttonWidth - 2),
                                    y: (bounds.height - 22) / 2, width: buttonWidth, height: 22)
    }

    // MARK: - Drag to reorder

    private func beginDrag(_ index: Int, grabX: CGFloat) {
        guard items.indices.contains(index) else { return }
        dragIndex = index
        dragGrabX = grabX
        dragPointerX = items[index].frame.minX + grabX
        addSubview(items[index])          // raise above its neighbours while moving
    }

    /// How far above or below the strip a dragged tab may go before dropping it opens a window.
    static let detachDistance: CGFloat = 36

    static func isDetached(_ pointer: NSPoint, stripHeight: CGFloat) -> Bool {
        pointer.y < -detachDistance || pointer.y > stripHeight + detachDistance
    }

    /// The slot a tab dropped at `x` (strip coordinates) would take.
    func insertionIndex(atX x: CGFloat) -> Int {
        slotFrames().firstIndex { x < $0.midX } ?? items.count
    }

    private func updateDrag(_ pointerInWindow: NSPoint) {
        guard let from = dragIndex, items.indices.contains(from) else { return }
        let local = convert(pointerInWindow, from: nil)
        dragPointerX = local.x
        let detached = items.count > 1 && Self.isDetached(local, stripHeight: bounds.height)
        if detached != dragDetached {
            dragDetached = detached
            items[from].alphaValue = detached ? 0.5 : 1
        }
        if detached { layoutTabs(); return }  // no reordering while torn off
        let frames = slotFrames()
        let center = dragPointerX - dragGrabX + frames[from].width / 2
        let range = section(of: from)
        var to = from
        for i in range where frames[i].minX <= center && center < frames[i].maxX { to = i }
        if center < frames[range.lowerBound].minX { to = range.lowerBound }
        if center >= frames[range.upperBound].maxX { to = range.upperBound }
        if to != from {
            dragIndex = to
            // The delegate reorders and calls update(), which re-lays out around the
            // dragged tab; grabX is preserved so the tab stays under the pointer.
            delegate?.tabStripDidRequestMove(from: from, to: to)
        }
        layoutTabs()
    }

    private func endDrag() {
        let detachedIndex = dragDetached ? dragIndex : nil
        if let i = dragIndex, items.indices.contains(i) { items[i].alphaValue = 1 }
        dragIndex = nil
        dragDetached = false
        layoutTabs()
        // After the mouse-up returns: moving the tab rebuilds the item views handling it.
        let point = NSEvent.mouseLocation
        if let detachedIndex { DispatchQueue.main.async { [weak self] in self?.delegate?.tabStripDidDetach(index: detachedIndex, at: point) } }
    }

    override func layout() {
        super.layout()
        layoutTabs()
    }

    /// Double-clicking empty strip space opens a tab, as in every other browser. Single
    /// clicks fall through so the window can still be dragged by its top bar.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            delegate?.tabStripDidRequestNewTab()
            return
        }
        super.mouseDown(with: event)
    }
}

/// 2px determinate bar under the toolbar. Hidden at rest so there is nothing to animate.
final class ProgressBar: NSView {
    var progress: Double = 0 { didSet { if progress != oldValue { needsDisplay = true } } }
    var active = false { didSet { isHidden = !active; needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard active else { return }
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * CGFloat(max(0.02, progress)), height: bounds.height).fill()
    }
}
