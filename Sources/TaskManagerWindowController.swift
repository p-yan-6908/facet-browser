import AppKit

/// One line of the Task Manager: the browser itself, a tab, or WebKit's shared helpers.
struct TaskManagerRow {
    enum Kind { case browser, tab, helpers }
    let kind: Kind
    let title: String
    let status: String
    /// nil when there is no live process to measure (a sleeping tab).
    let bytes: UInt64?
    weak var tab: Tab?
    weak var window: BrowserWindowController?
}

enum TaskManager {
    /// The browser, then every tab heaviest first with sleeping tabs last, then the WebKit
    /// helpers every tab shares (networking, GPU). A process two tabs share, such as a page
    /// and the popup it opened, is shown on both but counted once.
    static func rows(windows: [BrowserWindowController], sample: MemorySample,
                     footprint: (pid_t) -> UInt64 = MemoryMonitor.footprint(of:)) -> [TaskManagerRow] {
        var tabRows: [TaskManagerRow] = []
        var counted = Set<pid_t>(), tabBytes: UInt64 = 0
        for window in windows {
            for tab in window.tabs {
                var bytes: UInt64?
                if let pid = tab.webProcessID {
                    let b = footprint(pid)
                    bytes = b
                    if counted.insert(pid).inserted { tabBytes += b }
                }
                let title = (window.isPrivateWindow ? "Private: " : "") + tab.displayTitle
                tabRows.append(TaskManagerRow(kind: .tab, title: title, status: status(of: tab, in: window),
                                              bytes: bytes, tab: tab, window: window))
            }
        }
        tabRows.sort { ($0.bytes ?? 0, $1.title) > ($1.bytes ?? 0, $0.title) }
        let helpers = sample.totalBytes > sample.appBytes &+ tabBytes ? sample.totalBytes - sample.appBytes - tabBytes : 0
        return [TaskManagerRow(kind: .browser, title: "Facet", status: "Browser", bytes: sample.appBytes)]
            + tabRows
            + [TaskManagerRow(kind: .helpers, title: "WebKit networking and graphics", status: "Shared", bytes: helpers)]
    }

    static func status(of tab: Tab, in window: BrowserWindowController) -> String {
        if tab.isHibernated { return "Asleep" }
        if tab === window.activeTab && window.isContentVisible { return "On screen" }
        if tab.isAgentLeased { return "In use by agent" }
        if tab.isPlayingAudio { return "Playing audio" }
        if tab.keepAwake { return "Kept awake" }
        return "Background"
    }

    /// Sleeping is refused only for the page someone is looking at and for agent work.
    static func canSleep(_ row: TaskManagerRow) -> Bool {
        guard let tab = row.tab, let window = row.window, !tab.isHibernated, !tab.isAgentLeased else { return false }
        return !(tab === window.activeTab && window.isContentVisible)
    }
}

/// Chrome's Task Manager: what each tab costs right now, with Sleep and Close. It samples
/// only while it is open and visible, every two seconds.
final class TaskManagerWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var windowsProvider: () -> [BrowserWindowController] = { AppDelegate.shared?.allControllers ?? [] }
    private(set) var rows: [TaskManagerRow] = []
    let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let sleepButton = NSButton(title: "Sleep Tab", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close Tab", target: nil, action: nil)
    private var timer: Timer?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Task Manager"
        w.minSize = NSSize(width: 440, height: 240)
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName("FacetTaskManager")
        super.init(window: w)
        w.delegate = self
        build(in: w.contentView!)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(in content: NSView) {
        for (id, title, width) in [("task", "Task", 330.0), ("status", "Status", 120.0), ("memory", "Memory", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            if id == "memory" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(showSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        sleepButton.target = self; sleepButton.action = #selector(sleepSelected)
        closeButton.target = self; closeButton.action = #selector(closeSelected)
        sleepButton.toolTip = "Free this tab's memory now. It reloads where you left it when you return."

        for v in [scroll, summary, sleepButton, closeButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            closeButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            sleepButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            sleepButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            summary.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            summary.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: sleepButton.leadingAnchor, constant: -12),
        ])
    }

    func show() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        startSampling()
    }

    private func startSampling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }
        timer?.tolerance = 0.5
    }

    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        if window.occlusionState.contains(.visible) { if timer == nil, window.isVisible { reload(); startSampling() } }
        else { timer?.invalidate(); timer = nil }
    }

    func reload() {
        let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].tab?.id : nil })
        let sample = MemoryBudgetController.shared.sample(maxAge: 1)
        rows = TaskManager.rows(windows: windowsProvider(), sample: sample)
        table.reloadData()
        let keep = IndexSet(rows.indices.filter { rows[$0].tab.map { selected.contains($0.id) } ?? false })
        table.selectRowIndexes(keep, byExtendingSelection: false)
        let tabs = rows.filter { $0.kind == .tab }
        let asleep = tabs.filter { $0.tab?.isHibernated == true }.count
        var text = "\(sample.display) in total \u{00B7} \(tabs.count) tab\(tabs.count == 1 ? "" : "s"), \(asleep) asleep"
        if MemoryBudgetController.shared.isEnabled { text += " \u{00B7} target \(Config.shared.memoryBudgetMB) MB" }
        summary.stringValue = text
        updateButtons()
    }

    private var selectedRows: [TaskManagerRow] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }

    private func updateButtons() {
        sleepButton.isEnabled = selectedRows.contains(where: TaskManager.canSleep)
        closeButton.isEnabled = selectedRows.contains { $0.kind == .tab }
    }

    @objc func sleepSelected() {
        for row in selectedRows where TaskManager.canSleep(row) {
            row.tab?.hibernate()
            row.window?.refreshChrome()
        }
        reload()
    }

    @objc func closeSelected() {
        for row in selectedRows {
            guard let tab = row.tab, let window = row.window, let i = window.tabs.firstIndex(where: { $0 === tab }) else { continue }
            window.closeTab(index: i)
        }
        reload()
    }

    @objc private func showSelected() {
        guard rows.indices.contains(table.clickedRow), let tab = rows[table.clickedRow].tab,
              let window = rows[table.clickedRow].window, let i = window.tabs.firstIndex(where: { $0 === tab }) else { return }
        window.selectTab(index: i)
        window.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id)
        switch id.rawValue {
        case "task":
            cell.textField?.stringValue = item.title
            cell.imageView?.image = item.tab?.favicon
                ?? NSImage(systemSymbolName: item.kind == .tab ? "globe" : "gearshape", accessibilityDescription: nil)
            cell.textField?.textColor = item.tab?.isHibernated == true ? .secondaryLabelColor : .labelColor
        case "status":
            cell.textField?.stringValue = item.status
            cell.textField?.textColor = .secondaryLabelColor
        default:
            cell.textField?.stringValue = item.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "\u{2013}"
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
        var leading = cell.leadingAnchor
        if id.rawValue == "task" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = image.trailingAnchor
        }
        if id.rawValue == "memory" { text.alignment = .right; text.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular) }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
