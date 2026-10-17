import AppKit

/// Chrome's bookmarks bar (⌘⇧B): the Bookmarks Bar folder's contents, one hand-drawn item
/// each. Folders open as menus, and a » menu holds whatever does not fit.
final class BookmarksBarView: NSView {
    /// URL and whether it should open in a new background tab.
    var onOpen: ((URL, Bool) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?
    /// A folder's Open All, and whether in a new window.
    var onOpenAll: ((BookmarkNode, Bool) -> Void)?

    private(set) var items: [BookmarkItemView] = []
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

    private var openURL: (URL) -> Void { { [weak self] url in self?.onOpen?(url, false) } }
    private var openAll: (BookmarkNode) -> Void { { [weak self] folder in self?.onOpenAll?(folder, false) } }

    func reload() {
        items.forEach { $0.removeFromSuperview() }
        items = Store.shared.bookmarkBar.children.prefix(200).map { node in
            let item = BookmarkItemView(node: node)
            item.onOpen = { [weak self] url, newTab in self?.onOpen?(url, newTab) }
            item.onOpenInNewWindow = { [weak self] url in self?.onOpenInNewWindow?(url) }
            item.onOpenAll = { [weak self] folder, newWindow in self?.onOpenAll?(folder, newWindow) }
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
            if hiddenAny || x + w > bounds.width - overflowW - 8 { item.isHidden = true; hiddenAny = true; continue }
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
        BookmarkFolderMenu.fill(menu, with: items.filter(\.isHidden).map(\.node), open: openURL, openAll: openAll)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.height + 4), in: overflow)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// A bookmark or folder on the bar. A folder opens its contents as a menu.
final class BookmarkItemView: NSView {
    let node: BookmarkNode
    var url: URL? { node.url.flatMap(URL.init(string:)) }
    var title: String { node.title.isEmpty ? (url?.host ?? node.url ?? "") : node.title }
    var onOpen: ((URL, Bool) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?
    var onOpenAll: ((BookmarkNode, Bool) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private static let attributes: [NSAttributedString.Key: Any] = {
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: ps]
    }()

    init(node: BookmarkNode) {
        self.node = node
        super.init(frame: .zero)
        toolTip = node.isFolder ? title : "\(title)\n\(node.url ?? "")"
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

    override func mouseDown(with event: NSEvent) {
        guard node.isFolder else { pressed = true; return }
        // Folders open on press, like a menu bar title.
        pressed = true
        let menu = BookmarkFolderMenu(folder: node, open: { [weak self] url in self?.onOpen?(url, false) },
                                      openAll: { [weak self] folder in self?.onOpenAll?(folder, false) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 3), in: self)
        pressed = false
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        guard let url, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(url, event.modifierFlags.contains(.command))
    }

    override func otherMouseUp(with event: NSEvent) {
        if let url { onOpen?(url, true) } else { onOpenAll?(node, false) }
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    func contextMenu() -> NSMenu {
        let node = self.node
        let menu = NSMenu()
        if let url {
            menu.addItem(ClosureMenuItem("Open") { [weak self] in self?.onOpen?(url, false) })
            menu.addItem(ClosureMenuItem("Open in New Tab") { [weak self] in self?.onOpen?(url, true) })
            menu.addItem(ClosureMenuItem("Open in New Window") { [weak self] in self?.onOpenInNewWindow?(url) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            })
        } else {
            let count = node.allBookmarks.count
            let all = ClosureMenuItem("Open All (\(count))") { [weak self] in self?.onOpenAll?(node, false) }
            let window = ClosureMenuItem("Open All in New Window") { [weak self] in self?.onOpenAll?(node, true) }
            all.isEnabled = count > 0; window.isEnabled = count > 0
            menu.autoenablesItems = false
            menu.addItem(all)
            menu.addItem(window)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("New Folder\u{2026}") { BookmarkActions.promptNewFolder(in: node) })
        }
        menu.addItem(ClosureMenuItem("Rename\u{2026}") { BookmarkActions.promptRename(node) })
        menu.addItem(ClosureMenuItem("Delete") { if BookmarkActions.confirmDelete([node]) { Store.shared.remove([node]) } })
        return menu
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || pressed {
            NSColor.quaternaryLabelColor.withAlphaComponent(pressed ? 0.35 : 0.2).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let iconRect = NSRect(x: 6, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let symbol = node.isFolder ? "folder" : "globe"
        if !node.isFolder, let icon = FaviconStore.shared.icon(forHost: url?.host) {
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))) {
            glyph.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let s = NSAttributedString(string: title, attributes: Self.attributes)
        let h = s.size().height
        s.draw(with: NSRect(x: 26, y: (bounds.height - h) / 2, width: bounds.width - 32, height: h),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// A folder's contents as a menu, built when it opens, so thousands of imported bookmarks
/// cost nothing until someone looks. Subfolders are submenus of the same kind.
final class BookmarkFolderMenu: NSMenu, NSMenuDelegate {
    let folder: BookmarkNode
    private let open: (URL) -> Void
    private let openAll: (BookmarkNode) -> Void

    static var folderIcon: NSImage? { NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder") }

    init(folder: BookmarkNode, open: @escaping (URL) -> Void, openAll: @escaping (BookmarkNode) -> Void) {
        self.folder = folder
        self.open = open
        self.openAll = openAll
        super.init(title: folder.title)
        delegate = self
    }

    required init(coder: NSCoder) { fatalError() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        let count = folder.allBookmarks.count
        if count > 0 {
            addItem(ClosureMenuItem("Open All (\(count)) in Tabs") { [folder, openAll] in openAll(folder) })
            addItem(.separator())
        }
        if folder.children.isEmpty {
            let empty = NSMenuItem(title: "(Empty)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            addItem(empty)
        }
        Self.fill(self, with: folder.children, open: open, openAll: openAll)
    }

    /// Bookmarks as items and folders as submenus, appended to `menu`.
    static func fill(_ menu: NSMenu, with nodes: [BookmarkNode], open: @escaping (URL) -> Void,
                     openAll: @escaping (BookmarkNode) -> Void) {
        for node in nodes {
            let title = String((node.title.isEmpty ? (node.url ?? "") : node.title).prefix(60))
            if node.isFolder {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = folderIcon
                item.submenu = BookmarkFolderMenu(folder: node, open: open, openAll: openAll)
                menu.addItem(item)
            } else if let url = node.url.flatMap(URL.init(string:)) {
                let item = ClosureMenuItem(title) { open(url) }
                item.image = FaviconStore.shared.icon(forHost: url.host)
                item.toolTip = url.absoluteString
                menu.addItem(item)
            }
        }
    }
}

/// The small prompts bookmark editing shares between the bar, the menus and the manager.
enum BookmarkActions {
    /// A one-field sheet-less prompt; nil when cancelled.
    static func prompt(title: String, message: String = "", value: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func promptRename(_ node: BookmarkNode) {
        guard !Store.shared.isRoot(node),
              let name = prompt(title: node.isFolder ? "Rename Folder" : "Rename Bookmark", value: node.title, button: "Save") else { return }
        Store.shared.rename(node, to: name)
    }

    @discardableResult
    static func promptNewFolder(in parent: BookmarkNode) -> BookmarkNode? {
        guard let name = prompt(title: "New Folder", message: "In \(parent.title)", value: "New Folder", button: "Create") else { return nil }
        return Store.shared.addFolder(title: name, in: parent)
    }

    /// Folders that hold bookmarks are confirmed first; Facet has no bookmark undo.
    static func confirmDelete(_ nodes: [BookmarkNode]) -> Bool {
        let count = nodes.filter(\.isFolder).reduce(0) { $0 + $1.allBookmarks.count }
        guard count > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = nodes.count == 1 ? "Delete \u{201C}\(nodes[0].title)\u{201D}?" : "Delete \(nodes.count) items?"
        alert.informativeText = "This also deletes the \(count) bookmark\(count == 1 ? "" : "s") inside."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
