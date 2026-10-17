import AppKit

/// History (⌘Y) and Bookmarks (⌥⌘B) in one native window: search, open, delete, and for
/// bookmarks, folders. Chrome draws these as web pages; native views cost no renderer at all.
final class LibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                     NSSearchFieldDelegate, NSWindowDelegate {
    enum Mode: Int { case history = 0, bookmarks = 1 }

    private(set) var mode: Mode = .history
    private let segmented = NSSegmentedControl(labels: ["History", "Bookmarks"], trackingMode: .selectOne,
                                               target: nil, action: nil)
    private let search = NSSearchField()
    private let table = LibraryTableView()
    private let scroll = NSScrollView()
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear Browsing Data\u{2026}", target: nil, action: nil)
    private let newFolderButton = NSButton(title: "New Folder\u{2026}", target: nil, action: nil)
    let bookmarkOutline = BookmarkOutline()
    private let countLabel = NSTextField(labelWithString: "")
    private(set) var rows: [HistoryEntry] = []
    private var bookmarkObserver: NSObjectProtocol?
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "History"
        w.minSize = NSSize(width: 520, height: 320)
        w.setFrameAutosaveName("FacetLibrary")
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
        bookmarkObserver = NotificationCenter.default.addObserver(forName: .facetBookmarksChanged, object: nil, queue: .main) { [weak self] _ in
            if self?.mode == .bookmarks { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let bookmarkObserver { NotificationCenter.default.removeObserver(bookmarkObserver) } }

    private func build() {
        guard let content = window?.contentView else { return }
        segmented.target = self
        segmented.action = #selector(modeChanged)
        segmented.selectedSegment = 0
        search.placeholderString = "Search"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)

        for (id, title, width) in [("title", "Title", 330.0), ("address", "Address", 280.0), ("date", "Visited", 160.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            column.minWidth = 80
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.style = .inset
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.menuProvider = { [weak self] in self?.contextMenu() }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        clearButton.target = AppDelegate.shared
        clearButton.action = #selector(AppDelegate.clearBrowsingData)
        newFolderButton.target = self
        newFolderButton.action = #selector(newFolder)
        [deleteButton, clearButton, newFolderButton].forEach { $0.bezelStyle = .rounded }
        bookmarkOutline.onOpen = { url, activate in AppDelegate.shared?.openInFrontWindow(url, activate: activate) }
        let bookmarksScroll = bookmarkOutline.scroll
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 11)

        for v in [segmented, search, scroll, bookmarksScroll, deleteButton, clearButton, newFolderButton, countLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            segmented.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            search.centerYAnchor.constraint(equalTo: segmented.centerYAnchor),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            search.widthAnchor.constraint(equalToConstant: 260),
            scroll.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: deleteButton.topAnchor, constant: -10),
            deleteButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            deleteButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            clearButton.centerYAnchor.constraint(equalTo: deleteButton.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            newFolderButton.centerYAnchor.constraint(equalTo: deleteButton.centerYAnchor),
            newFolderButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            bookmarksScroll.topAnchor.constraint(equalTo: scroll.topAnchor),
            bookmarksScroll.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            bookmarksScroll.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            bookmarksScroll.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            countLabel.centerYAnchor.constraint(equalTo: deleteButton.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
        ])
    }

    func show(_ mode: Mode) {
        self.mode = mode
        segmented.selectedSegment = mode.rawValue
        applyMode()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
    }

    @objc private func modeChanged() {
        mode = Mode(rawValue: segmented.selectedSegment) ?? .history
        applyMode()
    }

    private func applyMode() {
        window?.title = mode == .history ? "History" : "Bookmarks"
        table.tableColumns.first { $0.identifier.rawValue == "date" }?.title = mode == .history ? "Visited" : "Added"
        clearButton.isHidden = mode != .history
        newFolderButton.isHidden = mode != .bookmarks
        scroll.isHidden = mode != .history
        bookmarkOutline.scroll.isHidden = mode != .bookmarks
        reload()
    }

    @objc private func searchChanged() { reload() }
    func controlTextDidChange(_ obj: Notification) { reload() }

    func reload() {
        if mode == .bookmarks {
            bookmarkOutline.reload(query: search.stringValue)
            countLabel.stringValue = bookmarkOutline.countText
            deleteButton.isEnabled = true
            return
        }
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let source = Store.shared.history.sorted { $0.lastVisit > $1.lastVisit }
        let filtered = q.isEmpty ? source : source.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
        }
        rows = Array(filtered.prefix(5_000))
        table.reloadData()
        let noun = rows.count == 1 ? "page" : "pages"
        countLabel.stringValue = "\(rows.count) \(noun)" + (filtered.count > rows.count ? " (showing first \(rows.count))" : "")
        deleteButton.isEnabled = !rows.isEmpty
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let id = column.identifier
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id)
        switch id.rawValue {
        case "title":
            cell.textField?.stringValue = entry.title.isEmpty ? Store.displayForm(entry.url) : entry.title
            cell.imageView?.image = FaviconStore.shared.icon(forHost: URL(string: entry.url)?.host)
                ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        case "address":
            cell.textField?.stringValue = Store.displayForm(entry.url)
        default:
            cell.textField?.stringValue = entry.lastVisit.timeIntervalSince1970 > 0 ? dateFormatter.string(from: entry.lastVisit) : ""
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
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
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
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

    @objc private func newFolder() { bookmarkOutline.newFolder() }

    private var selectedEntries: [HistoryEntry] {
        var indexes = table.selectedRowIndexes
        if indexes.isEmpty, table.clickedRow >= 0 { indexes = [table.clickedRow] }
        return indexes.filter { rows.indices.contains($0) }.map { rows[$0] }
    }

    @objc func openSelected() {
        let entries = selectedEntries
        guard !entries.isEmpty, let app = AppDelegate.shared else { return }
        for (i, entry) in entries.prefix(20).enumerated() {
            guard let url = URL(string: entry.url) else { continue }
            app.openInFrontWindow(url, activate: i == 0)
        }
    }

    @objc func deleteSelected() {
        if mode == .bookmarks { bookmarkOutline.deleteSelected(); return }
        let urls = Set(selectedEntries.map(\.url))
        guard !urls.isEmpty else { return }
        Store.shared.removeHistory(urls: urls)
        AppDelegate.shared?.rebuildHistoryMenu()
        reload()
    }

    private func contextMenu() -> NSMenu? {
        guard !selectedEntries.isEmpty else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open") { [weak self] in self?.openSelected() })
        menu.addItem(ClosureMenuItem("Copy Address") { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.selectedEntries.map(\.url).joined(separator: "\n"), forType: .string)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete") { [weak self] in self?.deleteSelected() })
        return menu
    }
}

/// Delete/Backspace removes rows; right-click asks the controller for a menu.
final class LibraryTableView: NSTableView {
    var onDelete: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }   // delete, forward delete
        if event.keyCode == 36 || event.keyCode == 76 { sendAction(doubleAction, to: target); return }  // return, enter
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return menuProvider?()
    }
}
