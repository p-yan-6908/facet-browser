import AppKit
import WebKit

/// Toolbar button for downloads: an arrow with a progress ring while anything runs.
final class DownloadsToolbarButton: ToolbarButton {
    var fraction: Double? { didSet { needsDisplay = true } }
    var isRunning = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isRunning else { return }
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let ring = NSBezierPath()
        ring.appendArc(withCenter: c, radius: 10, startAngle: 0, endAngle: 360)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.5).setStroke()
        ring.lineWidth = 1.6
        ring.stroke()
        let arc = NSBezierPath()
        let sweep = CGFloat(360 * max(0.06, fraction ?? 0.25))
        // The view is not flipped, so clockwise from the top runs from 90 downward.
        arc.appendArc(withCenter: c, radius: 10, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        NSColor.controlAccentColor.setStroke()
        arc.lineWidth = 1.6
        arc.lineCapStyle = .round
        arc.stroke()
    }
}

/// The downloads popover: this session's downloads, newest first, with the actions
/// Chrome's download bubble offers. Built only while it is open.
final class DownloadsViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "Downloads")
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let folderButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let list = FlippedView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No downloads in this session")
    private var rows: [DownloadRowView] = []
    private var observer: NSObjectProtocol?
    /// Supplies a live web view for Retry, which WebKit requires to restart a download.
    var webViewProvider: (() -> WKWebView?)?

    private let width: CGFloat = 360
    private let rowHeight: CGFloat = 52
    private let headerHeight: CGFloat = 40

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        clearButton.target = self; clearButton.action = #selector(clearList)
        folderButton.target = self; folderButton.action = #selector(openFolder)
        [clearButton, folderButton].forEach { $0.bezelStyle = .rounded; $0.controlSize = .small }
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        [titleLabel, clearButton, folderButton, scroll, emptyLabel].forEach { root.addSubview($0) }
        view = root
        rebuild()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        observer = NotificationCenter.default.addObserver(forName: .facetDownloadsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        rebuild()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func rebuild() {
        guard isViewLoaded else { return }
        let items = Downloads.shared.items
        if rows.map(\.item.id) == items.map(\.id) {
            rows.forEach { $0.refresh() }
        } else {
            rows.forEach { $0.removeFromSuperview() }
            rows = items.map { item in
                let row = DownloadRowView(item: item)
                row.onRetry = { [weak self] item in
                    guard let wv = self?.webViewProvider?() else { return }
                    Downloads.shared.retry(item, using: wv)
                }
                list.addSubview(row)
                return row
            }
        }
        let contentHeight = CGFloat(rows.count) * (rowHeight + 2) + 8
        let listHeight = min(360, max(56, contentHeight))
        let height = headerHeight + listHeight
        view.setFrameSize(NSSize(width: width, height: height))
        preferredContentSize = view.frame.size

        // The root view is not flipped: the header sits at the top.
        titleLabel.frame = NSRect(x: 14, y: height - 28, width: 140, height: 18)
        folderButton.frame = NSRect(x: width - 14 - 110, y: height - 32, width: 110, height: 24)
        clearButton.frame = NSRect(x: width - 14 - 110 - 62, y: height - 32, width: 58, height: 24)
        clearButton.isEnabled = items.contains { !$0.isActive }
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: listHeight)
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(listHeight, contentHeight))
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: 4 + CGFloat(i) * (rowHeight + 2), width: width, height: rowHeight)
        }
        emptyLabel.isHidden = !items.isEmpty
        emptyLabel.frame = NSRect(x: 0, y: listHeight / 2 - 9, width: width, height: 18)
    }

    @objc private func clearList() { Downloads.shared.clearInactive() }
    @objc private func openFolder() { Downloads.shared.revealFolder() }
}

/// One download: file icon, name, status/progress, and its actions.
final class DownloadRowView: NSView {
    let item: DownloadItem
    var onRetry: ((DownloadItem) -> Void)?
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let primary = NSButton()
    private let reveal = NSButton()
    private var hovering = false { didSet { needsDisplay = true } }

    init(item: DownloadItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 52))
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 12.5, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0; bar.maxValue = 1
        for b in [primary, reveal] {
            b.isBordered = false
            b.bezelStyle = .accessoryBarAction
            b.imagePosition = .imageOnly
            b.target = self
        }
        reveal.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Show in Finder")
        reveal.toolTip = "Show in Finder"
        reveal.action = #selector(revealPressed)
        primary.action = #selector(primaryPressed)
        [icon, name, status, bar, primary, reveal].forEach { addSubview($0) }
        icon.frame = NSRect(x: 14, y: 10, width: 32, height: 32)
        name.frame = NSRect(x: 54, y: 28, width: 228, height: 17)
        status.frame = NSRect(x: 54, y: 10, width: 228, height: 15)
        bar.frame = NSRect(x: 54, y: 6, width: 228, height: 6)
        primary.frame = NSRect(x: 290, y: 14, width: 24, height: 24)
        reveal.frame = NSRect(x: 320, y: 14, width: 24, height: 24)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        name.stringValue = item.filename
        status.stringValue = item.statusText
        if let dest = item.destination, item.state == .finished {
            icon.image = NSWorkspace.shared.icon(forFile: dest.path)
        } else {
            icon.image = NSWorkspace.shared.icon(for: .data)
        }
        bar.isHidden = !item.isActive
        bar.isIndeterminate = item.fraction == nil
        if let f = item.fraction { bar.doubleValue = f } else { bar.startAnimation(nil) }
        status.frame.origin.y = item.isActive ? 14 : 10
        switch item.state {
        case .running:
            primary.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")
            primary.toolTip = "Cancel"; primary.isHidden = false
        case .failed, .cancelled:
            primary.image = NSImage(systemSymbolName: "arrow.clockwise.circle.fill", accessibilityDescription: "Retry")
            primary.toolTip = item.resumeData != nil ? "Resume" : "Retry"; primary.isHidden = item.sourceURL == nil
        case .finished:
            primary.isHidden = true
        }
        status.textColor = { if case .failed = item.state { return .systemRed }; return .secondaryLabelColor }()
        toolTip = item.sourceURL?.absoluteString
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering, item.state == .finished else { return }
        NSColor.quaternaryLabelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    /// Clicking a finished row opens the file, like Chrome's download bubble.
    override func mouseUp(with event: NSEvent) {
        if event.clickCount >= 1, item.state == .finished { Downloads.shared.open(item) }
    }

    @objc private func primaryPressed() {
        if item.isActive { Downloads.shared.cancel(item) } else { onRetry?(item) }
    }

    @objc private func revealPressed() { Downloads.shared.reveal(item) }
}
