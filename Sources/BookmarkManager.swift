import AppKit

/// The Bookmarks side of the library window: the folder tree in an outline view, with search,
/// rename in place, New Folder, Delete, and drag to move or reorder (or to add a link dragged
/// in from a page). An outline view costs no renderer, unlike Chrome's web-page manager.
final class BookmarkOutline: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let nodeType = NSPasteboard.PasteboardType("com.facet.bookmark-node")
    let outline = LibraryOutlineView()
    let scroll = NSScrollView()
    private(set) var query = ""
    private(set) var matches: [BookmarkNode] = []
    private var loadedOnce = false
    /// Opens a page; the flag says whether to bring it to the front.
    var onOpen: ((URL, Bool) -> Void)?
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    override init() {
        super.init()
        for (id, title, width) in [("title", "Name", 330.0), ("address", "Address", 280.0), ("date", "Added", 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            column.minWidth = 80
            outline.addTableColumn(column)
            if id == "title" { outline.outlineTableColumn = column }
        }
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.rowHeight = 22
        outline.style = .inset
        outline.target = self
        outline.doubleAction = #selector(openSelected)
        outline.onDelete = { [weak self] in self?.deleteSelected() }
        outline.menuProvider = { [weak self] in self?.contextMenu() }
        outline.registerForDraggedTypes([Self.nodeType, .URL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
    }

    var isSearching: Bool { !query.isEmpty }

    /// Reloads, keeping open folders open. A search shows matching bookmarks as a flat list.
    func reload(query raw: String) {
        let open = Set((0..<outline.numberOfRows).compactMap { row -> UUID? in
            guard let node = outline.item(atRow: row) as? BookmarkNode, outline.isItemExpanded(node) else { return nil }
            return node.id
        })
        query = raw.trimmingCharacters(in: .whitespaces).lowercased()
        matches = isSearching ? Array(Store.shared.bookmarkRoots.flatMap(\.allBookmarks).filter {
            $0.title.lowercased().contains(query) || ($0.url ?? "").lowercased().contains(query)
        }.prefix(5_000)) : []
        outline.reloadData()
        guard !isSearching else { return }
        func reopen(_ node: BookmarkNode) {
            guard node.isFolder else { return }
            if open.contains(node.id) || (!loadedOnce && Store.shared.isRoot(node)) { outline.expandItem(node) }
            node.children.forEach(reopen)
        }
        Store.shared.bookmarkRoots.forEach(reopen)
        loadedOnce = true
    }

    var countText: String {
        if isSearching { return "\(matches.count) match\(matches.count == 1 ? "" : "es")" }
        let bookmarks = Store.shared.bookmarkRoots.flatMap(\.allBookmarks).count
        let folders = Store.shared.bookmarkFolders.count - Store.shared.bookmarkRoots.count
        return "\(bookmarks) bookmark\(bookmarks == 1 ? "" : "s") in \(folders) folder\(folders == 1 ? "" : "s")"
    }

    var selectedNodes: [BookmarkNode] {
        var rows = outline.selectedRowIndexes
        if rows.isEmpty, outline.clickedRow >= 0 { rows = [outline.clickedRow] }
        return rows.compactMap { outline.item(atRow: $0) as? BookmarkNode }
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if isSearching { return item == nil ? matches.count : 0 }
        guard let node = item as? BookmarkNode else { return Store.shared.bookmarkRoots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if isSearching { return matches[index] }
        guard let node = item as? BookmarkNode else { return Store.shared.bookmarkRoots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !isSearching && (item as? BookmarkNode)?.isFolder == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? BookmarkNode, let id = tableColumn?.identifier else { return nil }
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id)
        switch id.rawValue {
        case "title":
            cell.textField?.stringValue = node.title
            cell.textField?.isEditable = !Store.shared.isRoot(node)
            cell.textField?.font = .systemFont(ofSize: 13, weight: Store.shared.isRoot(node) ? .semibold : .regular)
            cell.imageView?.image = node.isFolder ? BookmarkFolderMenu.folderIcon
                : FaviconStore.shared.icon(forHost: node.url.flatMap { URL(string: $0)?.host }) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        case "address":
            cell.textField?.stringValue = node.url.map(Store.displayForm)
                ?? "\(node.children.count) item\(node.children.count == 1 ? "" : "s")"
        default:
            cell.textField?.stringValue = node.added.timeIntervalSince1970 > 0 && !Store.shared.isRoot(node) ? dateFormatter.string(from: node.added) : ""
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        text.target = self
        text.action = #selector(titleEdited(_:))
        cell.addSubview(text)
        cell.textField = text
        if id.rawValue == "title" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ])
        } else {
            text.textColor = .secondaryLabelColor
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func titleEdited(_ sender: NSTextField) {
        guard let node = outline.item(atRow: outline.row(for: sender)) as? BookmarkNode else { return }
        Store.shared.rename(node, to: sender.stringValue)
    }

    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? BookmarkNode, !Store.shared.isRoot(node) else { return nil }
        let p = NSPasteboardItem()
        p.setString(node.id.uuidString, forType: Self.nodeType)
        if let url = node.url { p.setString(url, forType: .URL); p.setString(url, forType: .string) }
        return p
    }

    private func draggedNodes(_ info: NSDraggingInfo) -> [BookmarkNode] {
        guard info.draggingSource as? NSOutlineView === outline else { return [] }
        return (info.draggingPasteboard.pasteboardItems ?? []).compactMap {
            $0.string(forType: Self.nodeType).flatMap(UUID.init(uuidString:)).flatMap(Store.shared.bookmarkNode(withID:))
        }
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        return urls.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    /// Where a drop lands: onto a folder, between items, or after a bookmark it was dropped on.
    /// The top level holds only the two fixed folders.
    func dropTarget(item: Any?, childIndex: Int) -> (folder: BookmarkNode, index: Int?)? {
        guard let node = item as? BookmarkNode else { return nil }
        if node.isFolder { return (node, childIndex < 0 ? nil : childIndex) }
        guard let parent = node.parent, let i = parent.children.firstIndex(where: { $0 === node }) else { return nil }
        return (parent, i + 1)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard !isSearching, let target = dropTarget(item: item, childIndex: index) else { return [] }
        if (item as? BookmarkNode)?.isFolder == false { outlineView.setDropItem(target.folder, dropChildIndex: target.index ?? -1) }
        let nodes = draggedNodes(info)
        if !nodes.isEmpty { return nodes.allSatisfy { !Store.shared.isRoot($0) && !$0.contains(target.folder) } ? .move : [] }
        return draggedURLs(info).isEmpty ? [] : .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let target = dropTarget(item: item, childIndex: index) else { return false }
        let nodes = draggedNodes(info)
        if nodes.isEmpty {
            let urls = draggedURLs(info)
            for (offset, url) in urls.enumerated() {
                Store.shared.addBookmark(url: url, title: url.host ?? url.absoluteString, in: target.folder, at: target.index.map { $0 + offset })
            }
            return !urls.isEmpty
        }
        return move(nodes, to: target.folder, at: target.index)
    }

    /// Moves nodes in order to one place, as one drag does.
    @discardableResult
    func move(_ nodes: [BookmarkNode], to folder: BookmarkNode, at index: Int?) -> Bool {
        var at = index, moved = false
        for node in nodes where Store.shared.move(node, to: folder, at: at) {
            moved = true
            if at != nil, let i = folder.children.firstIndex(where: { $0 === node }) { at = i + 1 }
        }
        if moved { outline.expandItem(folder) }
        return moved
    }

    // MARK: - Actions

    @objc func openSelected() {
        let nodes = selectedNodes
        if nodes.count == 1, let folder = nodes.first, folder.isFolder {
            outline.isItemExpanded(folder) ? outline.collapseItem(folder) : outline.expandItem(folder)
            return
        }
        let urls = nodes.flatMap(\.allBookmarks).compactMap { $0.url.flatMap(URL.init(string:)) }
        for (i, url) in urls.prefix(100).enumerated() { onOpen?(url, i == 0) }
    }

    func deleteSelected() {
        let nodes = selectedNodes.filter { !Store.shared.isRoot($0) }
        guard !nodes.isEmpty, BookmarkActions.confirmDelete(nodes) else { return }
        Store.shared.remove(nodes)
    }

    /// New Folder inside the selected folder, or beside the selected bookmark.
    func newFolder() {
        let selected = selectedNodes.first
        let parent = selected.map { $0.isFolder ? $0 : ($0.parent ?? Store.shared.bookmarkBar) } ?? Store.shared.bookmarkBar
        guard let folder = BookmarkActions.promptNewFolder(in: parent) else { return }
        outline.expandItem(parent)
        let row = outline.row(forItem: folder)
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false); outline.scrollRowToVisible(row) }
    }

    private func contextMenu() -> NSMenu? {
        let nodes = selectedNodes
        guard !nodes.isEmpty else { return nil }
        let menu = NSMenu()
        let count = nodes.flatMap(\.allBookmarks).count
        if count > 0 {
            menu.addItem(ClosureMenuItem(nodes.count == 1 && nodes[0].url != nil ? "Open" : "Open All (\(count))") { [weak self] in
                let urls = nodes.flatMap(\.allBookmarks).compactMap { $0.url.flatMap(URL.init(string:)) }
                for (i, url) in urls.prefix(100).enumerated() { self?.onOpen?(url, i == 0) }
            })
        }
        if let url = nodes.first?.url, nodes.count == 1 {
            menu.addItem(ClosureMenuItem("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New Folder\u{2026}") { [weak self] in self?.newFolder() })
        if nodes.count == 1, !Store.shared.isRoot(nodes[0]) {
            menu.addItem(ClosureMenuItem("Rename\u{2026}") { BookmarkActions.promptRename(nodes[0]) })
        }
        if nodes.contains(where: { !Store.shared.isRoot($0) }) {
            menu.addItem(ClosureMenuItem("Delete") { [weak self] in self?.deleteSelected() })
        }
        return menu
    }
}

/// Delete/Backspace removes rows, Return opens, and right-click asks for a menu.
final class LibraryOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }
        if event.keyCode == 36 || event.keyCode == 76 { sendAction(doubleAction, to: target); return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return menuProvider?()
    }
}
