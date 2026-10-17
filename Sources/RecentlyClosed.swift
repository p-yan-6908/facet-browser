import Foundation

/// Tabs and windows closed this session, newest last, for ⌘⇧T and History → Recently
/// Closed. Private windows never add to it. Memory only: a few KB of addresses and
/// back/forward state, the same snapshot a sleeping tab keeps.
final class RecentlyClosed {
    static let shared = RecentlyClosed()

    enum Entry {
        case tab(SavedTab)
        case window(SavedWindow)
    }

    struct Item {
        let id = UUID()
        let entry: Entry
        /// The window a tab was closed from, to put it back there while that window is open.
        weak var window: BrowserWindowController?

        var title: String {
            switch entry {
            case .tab(let t):
                return t.title.isEmpty ? Store.displayForm(t.url) : t.title
            case .window(let w):
                let first = w.tabs.first.map { $0.title.isEmpty ? Store.displayForm($0.url) : $0.title } ?? ""
                return w.tabs.count == 1 ? "Window: \(first)" : "Window: \(first) and \(w.tabs.count - 1) more"
            }
        }
    }

    private(set) var items: [Item] = []
    let limit = 25

    func add(tab: SavedTab, from window: BrowserWindowController?) {
        append(Item(entry: .tab(tab), window: window))
    }

    func add(window: SavedWindow) {
        append(Item(entry: .window(window), window: nil))
    }

    private func append(_ item: Item) {
        items.append(item)
        if items.count > limit { items.removeFirst(items.count - limit) }
    }

    func popLast() -> Item? { items.popLast() }

    func remove(id: UUID) -> Item? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: i)
    }

    func removeAll() { items.removeAll() }
}
