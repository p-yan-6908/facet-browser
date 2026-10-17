import AppKit

/// Chrome's bookmarks bar (⌘⇧B): one hand-drawn item per bookmark, with a » menu for
/// whatever does not fit.
final class BookmarksBarView: NSView {
    /// URL and whether it should open in a new background tab.
    var onOpen: ((URL, Bool) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?

    private var items: [BookmarkItemView] = []
    private let overflow = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "For quick access, bookmark pages with \u{2318}D. They appear here.")
    private var observer: NSObjectProtocol?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overflow.isBordered = false
        overflow.bezelStyle = .accessoryBarAction
        overflow.image = NSImage(systemSymbolName: "chevron.right.2", accessibilityDescription: "More bookmarks")
        overflow.imagePosition = .imageOnly
        overflow.target = self
        overflow.action = #selector(showOverflow)
        overflow.toolTip = "More bookmarks"
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        addSubview(overflow)
        addSubview(emptyLabel)
        observer = NotificationCenter.default.addObserver(forName: .facetBookmarksChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func reload() {
        items.forEach { $0.removeFromSuperview() }
        items = Store.shared.bookmarks.prefix(200).compactMap { entry in
            guard let url = URL(string: entry.url) else { return nil }
            let item = BookmarkItemView(url: url, title: entry.title.isEmpty ? (url.host ?? entry.url) : entry.title)
            item.onOpen = { [weak self] newTab in self?.onOpen?(url, newTab) }
            item.onOpenInNewWindow = { [weak self] in self?.onOpenInNewWindow?(url) }
            addSubview(item)
            return item
        }
        emptyLabel.isHidden = !items.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h: CGFloat = 22, y = (bounds.height - h) / 2
        let overflowW: CGFloat = 26
        var x: CGFloat = 8
        var hiddenAny = false
        for item in items {
            let w = item.fittingWidth
            if x + w > bounds.width - overflowW - 8 { item.isHidden = true; hiddenAny = true; continue }
            item.isHidden = false
            item.frame = NSRect(x: x, y: y, width: w, height: h)
            x += w + 2
        }
        overflow.isHidden = !hiddenAny
        overflow.frame = NSRect(x: bounds.width - overflowW - 6, y: y, width: overflowW, height: h)
        emptyLabel.frame = NSRect(x: 14, y: (bounds.height - 15) / 2, width: max(0, bounds.width - 28), height: 15)
    }

    @objc private func showOverflow() {
        let menu = NSMenu()
        for item in items where item.isHidden {
            let url = item.url
            let mi = ClosureMenuItem(String(item.title.prefix(60))) { [weak self] in self?.onOpen?(url, false) }
            mi.image = FaviconStore.shared.icon(forHost: url.host)
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.height + 4), in: overflow)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

final class BookmarkItemView: NSView {
    let url: URL
    let title: String
    var onOpen: ((Bool) -> Void)?
    var onOpenInNewWindow: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private static let attributes: [NSAttributedString.Key: Any] = {
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: ps]
    }()

    init(url: URL, title: String) {
        self.url = url
        self.title = title
        super.init(frame: .zero)
        toolTip = "\(title)\n\(url.absoluteString)"
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat {
        let text = NSAttributedString(string: title, attributes: Self.attributes).size().width
        return min(170, ceil(text) + 16 + 22)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(event.modifierFlags.contains(.command))
    }

    override func otherMouseUp(with event: NSEvent) { onOpen?(true) }

    override func rightMouseDown(with event: NSEvent) {
        let url = self.url, title = self.title
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open") { [weak self] in self?.onOpen?(false) })
        menu.addItem(ClosureMenuItem("Open in New Tab") { [weak self] in self?.onOpen?(true) })
        menu.addItem(ClosureMenuItem("Open in New Window") { [weak self] in self?.onOpenInNewWindow?() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Copy Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        })
        menu.addItem(ClosureMenuItem("Rename\u{2026}") { BookmarkItemView.promptRename(url: url, title: title) })
        menu.addItem(ClosureMenuItem("Delete") { Store.shared.removeBookmarks(urls: [url.absoluteString]) })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    static func promptRename(url: URL, title: String) {
        let alert = NSAlert()
        alert.messageText = "Rename Bookmark"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = title
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            Store.shared.renameBookmark(url: url.absoluteString, title: field.stringValue)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || pressed {
            NSColor.quaternaryLabelColor.withAlphaComponent(pressed ? 0.35 : 0.2).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let iconRect = NSRect(x: 6, y: (bounds.height - 14) / 2, width: 14, height: 14)
        if let icon = FaviconStore.shared.icon(forHost: url.host) {
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))) {
            globe.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let s = NSAttributedString(string: title, attributes: Self.attributes)
        let h = s.size().height
        s.draw(with: NSRect(x: 26, y: (bounds.height - h) / 2, width: bounds.width - 32, height: h),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
