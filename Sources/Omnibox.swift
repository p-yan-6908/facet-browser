import AppKit

/// One row of the address-bar dropdown.
struct OmniboxSuggestion: Equatable {
    enum Kind { case search, url, history, bookmark, openTab }
    let kind: Kind
    let title: String
    let detail: String
    let url: URL?
    /// What the address field shows while this row is highlighted.
    let fillText: String
    var tabID: UUID? = nil
}

/// Ranking for the address bar. Pure functions over the store, so it is cheap to run on
/// every keystroke and easy to test.
enum Omnibox {
    /// The address to complete `typed` to inline, keeping the user's own characters, or nil.
    /// Only addresses visited more than once (or bookmarked) qualify, and only hosts or
    /// paths that start with exactly what was typed, so a search is never hijacked by a
    /// one-off visit.
    static func inlineCompletion(for typed: String, store: Store = .shared) -> String? {
        let q = typed.lowercased()
        guard q.count >= 2, !q.contains(where: { $0.isWhitespace }), !q.contains("://") else { return nil }
        let bookmarked = Set(store.bookmarks.map(\.url))
        var scores: [String: Double] = [:]
        let now = Date()
        for entry in store.bookmarks + store.history {
            let isBookmark = bookmarked.contains(entry.url)
            guard entry.visits >= 2 || isBookmark else { continue }
            var display = Store.displayForm(entry.url)
            if display.lowercased().hasPrefix("www.") && !q.hasPrefix("www.") { display = String(display.dropFirst(4)) }
            let lower = display.lowercased()
            guard lower.hasPrefix(q) else { continue }
            // Complete to the host unless the user has already typed past it.
            let hostEnd = lower.firstIndex(of: "/") ?? lower.endIndex
            let host = String(display[..<hostEnd])
            let candidate = q.count <= host.count ? host : display
            let age = max(0, now.timeIntervalSince(entry.lastVisit) / 86_400)
            scores[candidate, default: 0] += Double(max(1, entry.visits) + (isBookmark ? 5 : 0)) / (1 + age * 0.1)
        }
        // Highest score wins; on a tie the shorter address is the more likely target.
        guard let best = scores.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key.count > $1.key.count })?.key,
              best.count > typed.count else { return nil }
        return typed + best.dropFirst(typed.count)
    }

    static func suggestions(for typed: String, completion: String?,
                            openTabs: [(id: UUID, title: String, url: URL)],
                            limit: Int = 8, store: Store = .shared, config: Config = .shared) -> [OmniboxSuggestion] {
        let input = typed.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return [] }
        var rows: [OmniboxSuggestion] = []
        var seen = Set<String>()
        func key(_ display: String) -> String {
            let lower = display.lowercased()
            let bare = lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
            return bare.hasSuffix("/") ? String(bare.dropLast()) : bare
        }
        let search = OmniboxSuggestion(kind: .search, title: input, detail: "\(config.searchEngineName) Search",
                                       url: config.searchURL(for: input), fillText: input)

        // Row 0 is always what Enter does with the text as it stands.
        if let completion, let url = config.resolve(input: completion), !config.isSearchQuery(completion) {
            let match = store.rankedEntries(for: completion, limit: 6).first { key(Store.displayForm($0.entry.url)) == key(completion) }
            let display = Store.displayForm(match?.entry.url ?? url.absoluteString)
            rows.append(OmniboxSuggestion(kind: match?.bookmarked == true ? .bookmark : .history,
                                          title: match.map { $0.entry.title.isEmpty ? display : $0.entry.title } ?? display,
                                          detail: display, url: url, fillText: completion))
            seen.insert(key(completion))
            rows.append(search)
        } else if !config.isSearchQuery(input), let url = config.resolve(input: input) {
            let display = Store.displayForm(url.absoluteString)
            rows.append(OmniboxSuggestion(kind: .url, title: display, detail: "", url: url, fillText: input))
            seen.insert(key(display))
            rows.append(search)
        } else {
            rows.append(search)
        }

        let q = input.lowercased()
        if q.count >= 2 {
            for tab in openTabs where rows.count < 4 {
                let display = Store.displayForm(tab.url.absoluteString)
                guard tab.title.lowercased().contains(q) || display.lowercased().contains(q) else { continue }
                rows.append(OmniboxSuggestion(kind: .openTab, title: tab.title.isEmpty ? display : tab.title,
                                              detail: display, url: tab.url, fillText: display, tabID: tab.id))
                seen.insert(key(display))
            }
        }

        for (entry, bookmarked) in store.rankedEntries(for: input, limit: limit * 2) where rows.count < limit {
            let display = Store.displayForm(entry.url)
            guard !seen.contains(key(display)), let url = URL(string: entry.url) else { continue }
            seen.insert(key(display))
            rows.append(OmniboxSuggestion(kind: bookmarked ? .bookmark : .history,
                                          title: entry.title.isEmpty ? display : entry.title,
                                          detail: display, url: url, fillText: display))
        }
        return rows
    }
}

/// The dropdown itself: a borderless child window under the address bar that never takes
/// key status, so typing keeps going to the address field.
final class OmniboxPopup: NSObject {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let panel: Panel
    private let list = OmniboxListView()
    private(set) var suggestions: [OmniboxSuggestion] = []
    var onActivate: ((Int) -> Void)?

    var isVisible: Bool { panel.isVisible }
    var selectedIndex: Int { list.selected }
    var selectedSuggestion: OmniboxSuggestion? {
        suggestions.indices.contains(list.selected) ? suggestions[list.selected] : nil
    }

    override init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        list.autoresizingMask = [.width, .height]
        effect.addSubview(list)
        panel.contentView = effect
        list.onActivate = { [weak self] index in self?.onActivate?(index) }
    }

    func show(_ items: [OmniboxSuggestion], below anchor: NSView) {
        guard let parent = anchor.window, !items.isEmpty else { hide(); return }
        suggestions = items
        list.items = items
        list.selected = 0
        let height = CGFloat(items.count) * OmniboxListView.rowHeight + 12
        let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let width = max(anchorRect.width, 460)
        panel.setFrame(NSRect(x: anchorRect.minX, y: anchorRect.minY - height - 4, width: width, height: height), display: true)
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        list.needsDisplay = true
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        suggestions = []
    }

    /// Moves the highlight, wrapping, and returns the newly highlighted row.
    @discardableResult
    func move(_ delta: Int) -> OmniboxSuggestion? {
        guard !suggestions.isEmpty else { return nil }
        let n = suggestions.count
        list.selected = ((list.selected + delta) % n + n) % n
        list.needsDisplay = true
        return selectedSuggestion
    }
}

final class OmniboxListView: NSView {
    static let rowHeight: CGFloat = 30
    var items: [OmniboxSuggestion] = [] { didSet { hover = -1 } }
    var selected = 0
    var onActivate: ((Int) -> Void)?
    private var hover = -1 { didSet { if hover != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }

    private func row(at point: NSPoint) -> Int? {
        let i = Int(floor((point.y - 6) / Self.rowHeight))
        return items.indices.contains(i) ? i : nil
    }

    override func mouseMoved(with event: NSEvent) { hover = row(at: convert(event.locationInWindow, from: nil)) ?? -1 }
    override func mouseExited(with event: NSEvent) { hover = -1 }
    override func mouseDown(with event: NSEvent) {
        if let i = row(at: convert(event.locationInWindow, from: nil)) { onActivate?(i) }
    }

    private func symbol(for kind: OmniboxSuggestion.Kind) -> String {
        switch kind {
        case .search: return "magnifyingglass"
        case .url: return "globe"
        case .history: return "clock"
        case .bookmark: return "star"
        case .openTab: return "square.on.square"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, item) in items.enumerated() {
            let r = NSRect(x: 6, y: 6 + CGFloat(i) * Self.rowHeight, width: bounds.width - 12, height: Self.rowHeight)
            let isSelected = i == selected
            if isSelected {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            } else if i == hover {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            let primary: NSColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
            let secondary: NSColor = isSelected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor

            let iconRect = NSRect(x: r.minX + 10, y: r.midY - 8, width: 16, height: 16)
            if item.kind != .search, item.kind != .url, let icon = FaviconStore.shared.icon(forHost: item.url?.host) {
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [secondary]))
                if let img = NSImage(systemSymbolName: symbol(for: item.kind), accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                    let s = img.size
                    img.draw(in: NSRect(x: iconRect.midX - s.width / 2, y: iconRect.midY - s.height / 2, width: s.width, height: s.height),
                             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }

            var right = r.maxX - 10
            if item.kind == .openTab {
                let badge = NSAttributedString(string: "Switch to Tab", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: secondary])
                let bs = badge.size()
                let br = NSRect(x: right - bs.width - 14, y: r.midY - 10, width: bs.width + 14, height: 20)
                (isSelected ? NSColor.white.withAlphaComponent(0.18) : NSColor.quaternaryLabelColor.withAlphaComponent(0.3)).setFill()
                NSBezierPath(roundedRect: br, xRadius: 10, yRadius: 10).fill()
                badge.draw(at: NSPoint(x: br.minX + 7, y: br.midY - bs.height / 2))
                right = br.minX - 8
            }

            let ps = NSMutableParagraphStyle()
            ps.lineBreakMode = .byTruncatingTail
            let text = NSMutableAttributedString(string: item.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: primary, .paragraphStyle: ps])
            if !item.detail.isEmpty && item.detail != item.title {
                let detailColor: NSColor = isSelected ? secondary : (item.kind == .search ? .secondaryLabelColor : .linkColor)
                text.append(NSAttributedString(string: "  \u{2014}  \(item.detail)", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: detailColor, .paragraphStyle: ps]))
            }
            let x = iconRect.maxX + 10
            let h = text.size().height
            text.draw(with: NSRect(x: x, y: r.midY - h / 2, width: max(0, right - x), height: h),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
