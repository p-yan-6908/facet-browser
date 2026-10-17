import AppKit

/// Chrome's bookmark bubble: ⌘D or the star saves the page at once, then offers its name and
/// folder. Edits apply when the bubble closes, however it closes; Remove deletes the bookmark.
final class BookmarkEditorController: NSViewController {
    let node: BookmarkNode
    private let isNew: Bool
    let nameField = NSTextField()
    let folderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var onFinish: (() -> Void)?
    private var finished = false
    private var lastFolderIndex = 0

    init(node: BookmarkNode, isNew: Bool) {
        self.node = node
        self.isNew = isNew
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let heading = NSTextField(labelWithString: isNew ? "Bookmark Added" : "Edit Bookmark")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.stringValue = node.title
        nameField.widthAnchor.constraint(equalToConstant: 230).isActive = true
        folderPopup.target = self
        folderPopup.action = #selector(folderChosen)
        populateFolders(selecting: node.parent)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Name"), nameField],
                                      [NSTextField(labelWithString: "Folder"), folderPopup]])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeBookmark))
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), remove, done])
        buttons.distribution = .fill
        let stack = NSStackView(views: [heading, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        commit()
    }

    var selectedFolder: BookmarkNode? { folderPopup.selectedItem?.representedObject as? BookmarkNode }

    private func populateFolders(selecting folder: BookmarkNode?) {
        folderPopup.removeAllItems()
        guard let menu = folderPopup.menu else { return }
        for (f, depth) in Store.shared.bookmarkFolders {
            let item = NSMenuItem(title: f.title, action: nil, keyEquivalent: "")
            item.indentationLevel = min(depth, 15)
            item.image = BookmarkFolderMenu.folderIcon
            item.representedObject = f
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "New Folder\u{2026}", action: nil, keyEquivalent: ""))
        let index = menu.items.firstIndex { ($0.representedObject as? BookmarkNode) === folder } ?? 0
        folderPopup.selectItem(at: index)
        lastFolderIndex = index
    }

    @objc private func folderChosen() {
        guard selectedFolder == nil else { lastFolderIndex = folderPopup.indexOfSelectedItem; return }
        // "New Folder…": create it inside the folder that was selected, then select it.
        let parent = folderPopup.item(at: lastFolderIndex)?.representedObject as? BookmarkNode ?? Store.shared.bookmarkBar
        if let folder = BookmarkActions.promptNewFolder(in: parent) { populateFolders(selecting: folder) }
        else { folderPopup.selectItem(at: lastFolderIndex) }
    }

    /// Applies the name and folder once; later calls do nothing.
    func commit() {
        guard !finished, node.parent != nil else { return }
        finished = true
        if nameField.stringValue != node.title { Store.shared.rename(node, to: nameField.stringValue) }
        if let folder = selectedFolder {
            if folder !== node.parent { Store.shared.move(node, to: folder) }
            Store.shared.lastUsedFolder = folder
        }
    }

    @objc func finish() {
        commit()
        onFinish?()
    }

    @objc func removeBookmark() {
        finished = true
        Store.shared.remove([node])
        onFinish?()
    }
}
