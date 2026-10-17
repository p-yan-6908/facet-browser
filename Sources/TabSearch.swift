import AppKit

/// ⌘⇧A, as in Chrome: find any open tab by title or address across every window of the same
/// kind (normal or private), sleeping tabs included. Nothing is woken until it is chosen.
enum TabSearch {
    struct Match {
        let tab: Tab
        weak var window: BrowserWindowController?
    }

    /// Every word must appear in the title or address. Matches at the start of the title or
    /// address rank first, then matches at the start of a title word, then the most recently
    /// used tab. An empty query lists every tab, most recently used first.
    static func rank(_ query: String, in windows: [BrowserWindowController]) -> [Match] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let words = q.split(separator: " ").map(String.init)
        var scored: [(match: Match, score: Int, used: Date)] = []
        for window in windows {
            for tab in window.tabs {
                let title = tab.displayTitle.lowercased()
                let address = tab.url.map { Store.displayForm($0.absoluteString).lowercased() } ?? ""
                guard words.allSatisfy({ title.contains($0) || address.contains($0) }) else { continue }
                var score = 0
                if let first = words.first {
                    let bare = address.hasPrefix("www.") ? String(address.dropFirst(4)) : address
                    if title.hasPrefix(q) || bare.hasPrefix(q) { score += 4 }
                    let titleWords = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    if titleWords.contains(where: { $0.hasPrefix(first) }) { score += 2 }
                }
                scored.append((Match(tab: tab, window: window), score, tab.lastActive))
            }
        }
        return scored.sorted { ($0.score, $0.used) > ($1.score, $1.used) }.map(\.match)
    }
}

/// The popover's content: a search field over a list of matching tabs.
final class TabSearchController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let field = NSSearchField()
    let table = NSTableView()
    private(set) var matches: [TabSearch.Match] = []
    private let windows: () -> [BrowserWindowController]
    /// Called after a tab is chosen or the search is cancelled, to close the popover.
    var onFinish: (() -> Void)?

    init(windows: @escaping () -> [BrowserWindowController]) {
        self.windows = windows
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 380))
        field.placeholderString = "Search tabs"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        column.width = 376
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 38
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        for v in [field, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    func refresh() {
        matches = TabSearch.rank(field.stringValue, in: windows())
        table.reloadData()
        if !matches.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): choose(table.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { onFinish?() } else { field.stringValue = ""; refresh() }
            return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let row = max(0, min(matches.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() { choose(table.clickedRow) }

    /// Switches to the chosen tab, waking it only now.
    func choose(_ row: Int) {
        guard matches.indices.contains(row), let window = matches[row].window,
              let index = window.tabs.firstIndex(where: { $0 === matches[row].tab }) else { return }
        window.selectTab(index: index)
        window.window?.makeKeyAndOrderFront(nil)
        onFinish?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard matches.indices.contains(row) else { return nil }
        let tab = matches[row].tab
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("tab"), owner: self) as? TabSearchCell ?? TabSearchCell()
        cell.identifier = NSUserInterfaceItemIdentifier("tab")
        cell.titleLabel.stringValue = tab.displayTitle
        let site = tab.url.map { Store.displayForm($0.absoluteString) } ?? "New Tab"
        cell.detailLabel.stringValue = tab.isHibernated && tab.url != nil ? "\(site) \u{00B7} asleep" : site
        cell.icon.image = tab.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        cell.icon.alphaValue = tab.isHibernated ? 0.5 : 1
        return cell
    }
}

final class TabSearchCell: NSTableCellView {
    let icon = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: 13)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, detailLabel] { label.lineBreakMode = .byTruncatingTail }
        for v in [icon, titleLabel, detailLabel] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
