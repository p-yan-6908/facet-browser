import AppKit
import SQLite3

extension PolishTests {
    /// The folder tree: migration, persistence, editing, and imports that keep folders.
    static func bookmarkFolders(_ root: URL) throws {
        let store = Store.shared
        let file = Config.supportDir.appendingPathComponent("bookmarks.json")
        store.flushBookmarks()
        let before = try? Data(contentsOf: file)
        defer {
            store.flushBookmarks()
            if let before { try? before.write(to: file) } else { try? FileManager.default.removeItem(at: file) }
            store.reloadBookmarks()
        }

        // Version 1 was a flat list shown on the bar; it becomes the bar's contents in order.
        let v1: [[String: Any]] = [["url": "https://one.test/", "title": "One", "visits": 1, "last": 1_700_000_000.0],
                                   ["url": "https://two.test/", "title": "Two", "visits": 1, "last": 1_700_000_100.0]]
        try JSONSerialization.data(withJSONObject: v1).write(to: file)
        store.reloadBookmarks()
        expect(store.bookmarkBar.children.map(\.title) == ["One", "Two"] && store.otherBookmarks.children.isEmpty,
               "flat bookmarks migrate onto the bar in order")
        expect(store.bookmarkBar.children.first?.added.timeIntervalSince1970 == 1_700_000_000, "migration keeps when each was added")

        // Build a small tree and read it back from disk.
        let work = store.addFolder(title: "Work", in: store.bookmarkBar)
        let deep = store.addFolder(title: "Deep", in: work)
        let doc = store.addBookmark(url: URL(string: "https://docs.test/")!, title: "Docs", in: work)
        store.addBookmark(url: URL(string: "https://deep.test/")!, title: "Deep page", in: deep)
        store.addBookmark(url: URL(string: "https://other.test/")!, title: "", in: store.otherBookmarks)
        store.lastUsedFolder = work
        expect((try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]) != nil, "edits are written after a short pause, not at once")
        store.flushBookmarks()
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        expect(saved?["version"] as? Int == 2, "bookmarks are saved as a version 2 tree")
        store.reloadBookmarks()
        let reloadedWork = store.bookmarkBar.children.first { $0.title == "Work" }
        expect(reloadedWork?.id == work.id && reloadedWork?.children.map(\.title) == ["Deep", "Docs"]
               && reloadedWork?.children.first?.children.first?.url == "https://deep.test/", "folders survive a reload")
        expect(store.otherBookmarks.children.first?.title == "other.test", "an untitled bookmark is named after its host")
        expect(store.lastUsedFolder.id == work.id, "the last folder chosen is remembered")
        guard let w = reloadedWork, let d = w.children.first, let docNode = w.children.last else { return }
        expect(store.bookmarks.map(\.url) == ["https://one.test/", "https://two.test/", "https://deep.test/", "https://docs.test/", "https://other.test/"],
               "the flat list follows tree order")
        _ = doc

        // New bookmarks go to the last folder chosen, or the bar once that folder is gone.
        let viaDefault = store.addBookmark(url: URL(string: "https://default.test/")!, title: "Default")
        expect(viaDefault.parent === w, "\u{2318}D uses the last folder chosen")

        // Moving: reorder, into folders, and the moves that must be refused.
        expect(store.move(viaDefault, to: w, at: 0) && w.children.first === viaDefault, "bookmarks reorder within a folder")
        expect(store.move(viaDefault, to: w, at: 2) && w.children.firstIndex { $0 === viaDefault } == 1, "a later index accounts for the item's own removal")
        expect(store.move(docNode, to: d) && d.children.last === docNode, "bookmarks move into subfolders")
        expect(!store.move(w, to: d), "a folder cannot move inside itself")
        expect(!store.move(store.bookmarkBar, to: store.otherBookmarks), "top-level folders stay put")
        expect(!store.move(viaDefault, to: docNode), "nothing moves into a bookmark")
        store.rename(store.bookmarkBar, to: "Renamed")
        expect(store.bookmarkBar.title == "Bookmarks Bar", "top-level folders cannot be renamed")
        store.rename(d, to: "  ")
        expect(d.title == "New Folder", "an empty folder name falls back")

        // The same page in two folders: one entry in the flat list, both removed together.
        let twin = store.addBookmark(url: URL(string: "https://docs.test/")!, title: "Docs again", in: store.otherBookmarks)
        expect(store.bookmarks.filter { $0.url == "https://docs.test/" }.count == 1 && store.bookmark(for: URL(string: "https://docs.test/")!) === docNode,
               "a page bookmarked twice is listed once")
        store.remove([twin])
        store.remove([w])
        expect(!store.isBookmarked(URL(string: "https://deep.test/")!) && !store.isBookmarked(URL(string: "https://docs.test/")!),
               "deleting a folder deletes what is inside")
        expect(store.addBookmark(url: URL(string: "https://after.test/")!, title: "After").parent === store.bookmarkBar,
               "with its folder gone, \u{2318}D falls back to the bar")
        let tabs = store.addFolder(title: "Saved Tabs", in: store.otherBookmarks, pages: [(URL(string: "https://a.test/")!, "A"), (URL(string: "https://b.test/")!, "")])
        expect(tabs.children.map(\.title) == ["A", "b.test"], "Bookmark All Tabs saves every page in one folder")

        // Imports keep folders, merge them by name, and stay idempotent.
        let imported = [ImportedBookmark(url: "https://bar.test/", title: "Bar", root: .bar),
                        ImportedBookmark(url: "https://news.test/", title: "News", root: .bar, folders: ["News"]),
                        ImportedBookmark(url: "https://swift.test/", title: "Swift", root: .other, folders: ["Dev", "Swift"]),
                        ImportedBookmark(url: "https://one.test/", title: "Ignored", root: .other, folders: ["Dev"])]
        expect(store.importBookmarks(imported) == 3 && store.importBookmarks(imported) == 0, "folder imports are idempotent")
        expect(store.bookmarkBar.children.filter { $0.isFolder && $0.title == "News" }.count == 1, "imported folders merge by name")
        let dev = store.otherBookmarks.children.first { $0.title == "Dev" }
        expect(dev?.children.first?.title == "Swift" && dev?.children.first?.children.first?.url == "https://swift.test/"
               && dev?.children.count == 1, "nested imported folders keep their place; known pages keep theirs")

        // Readers: Chrome roots and folders, Firefox's parent chain, Safari's top-level lists.
        let importer = BrowserImportService.shared
        let chrome = root.appendingPathComponent("ChromeFolders")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        let tree: [String: Any] = ["roots": [
            "bookmark_bar": ["name": "Bookmarks bar", "children": [
                ["url": "https://x.test/", "name": "X", "date_added": "13344473600000000"],
                ["name": "News", "children": [["url": "https://y.test/", "name": "Y"],
                                               ["name": "Tech", "children": [["url": "https://z.test/", "name": "Z"]]]]]]],
            "other": ["name": "Other bookmarks", "children": [["url": "https://w.test/", "name": "W"]]],
            "synced": ["name": "Mobile bookmarks", "children": [["url": "https://v.test/", "name": "V"]]]]]
        try JSONSerialization.data(withJSONObject: tree).write(to: chrome.appendingPathComponent("Bookmarks"))
        let (cb, _, _) = try importer.readData(from: importer.customChromiumSource(profileURL: chrome)!, bookmarks: true, history: false)
        func shape(_ list: [ImportedBookmark]) -> [String] { list.map { "\($0.title)@\($0.root == .bar ? "bar" : "other")/\($0.folders.joined(separator: "/"))" } }
        expect(shape(cb) == ["X@bar/", "Y@bar/News", "Z@bar/News/Tech", "W@other/", "V@other/Mobile Bookmarks"], "Chrome bookmarks keep their folders")
        expect(cb.first?.added.timeIntervalSince1970 == 1_700_000_000, "Chrome bookmark dates convert")

        let places = root.appendingPathComponent("folders-places.sqlite")
        var db: OpaquePointer?; sqlite3_open(places.path, &db); defer { sqlite3_close(db) }
        try sql(db, """
            CREATE TABLE moz_places(id INTEGER, url TEXT, title TEXT, visit_count INTEGER, last_visit_date INTEGER);
            CREATE TABLE moz_bookmarks(id INTEGER, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, dateAdded INTEGER, guid TEXT);
            INSERT INTO moz_places VALUES (1,'https://tool.test/','',1,0),(2,'https://read.test/','',1,0),(3,'https://menu.test/','',1,0),(4,'https://phone.test/','',1,0),(5,'https://tag.test/','',1,0);
            INSERT INTO moz_bookmarks VALUES (1,2,NULL,0,0,'','0','root________'),(2,2,NULL,1,0,'menu','0','menu________'),
              (3,2,NULL,1,1,'toolbar','0','toolbar_____'),(4,2,NULL,1,2,'tags','0','tags________'),(6,2,NULL,1,4,'mobile','0','mobile______'),
              (10,2,NULL,3,1,'Reading','0','folderguid01'),(20,1,1,3,0,'Tool',1700000000000000,'b1'),(21,1,2,10,0,'Read',0,'b2'),
              (22,1,3,2,0,'Menu',0,'b3'),(23,1,4,6,0,'Phone',0,'b4'),(24,1,5,4,0,'Tagged',0,'b5');
            """)
        let ff = BrowserImportSource(id: "fff", browserName: "Firefox", profileName: "Folders", profileURL: root, format: .firefox, bookmarksURL: places, historyURL: nil)
        let (fb, _, _) = try importer.readData(from: ff, bookmarks: true, history: false)
        expect(Set(shape(fb)) == ["Tool@bar/", "Read@bar/Reading", "Menu@other/", "Phone@other/Mobile Bookmarks"], "Firefox bookmarks keep their folders and skip tags")

        let plist: [String: Any] = ["Children": [
            ["Title": "BookmarksBar", "Children": [["URLString": "https://fav.test/", "URIDictionary": ["title": "Fav"]],
                                                  ["Title": "Folder", "Children": [["URLString": "https://in.test/", "URIDictionary": ["title": "In"]]]]]],
            ["Title": "BookmarksMenu", "Children": [["URLString": "https://m.test/", "URIDictionary": ["title": "M"]]]],
            ["Title": "com.apple.ReadingList", "Children": [["URLString": "https://later.test/", "URIDictionary": ["title": "Later"]]]]]]
        let safariFile = root.appendingPathComponent("Bookmarks.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: safariFile)
        let sf = BrowserImportSource(id: "sff", browserName: "Safari", profileName: "Folders", profileURL: root, format: .safari, bookmarksURL: safariFile, historyURL: nil)
        let (sb, _, _) = try importer.readData(from: sf, bookmarks: true, history: false)
        expect(shape(sb) == ["Fav@bar/", "In@bar/Folder", "M@other/", "Later@other/Reading List"], "Safari bookmarks keep their folders")
    }

    /// The views over the tree: folder menus, the bar, the ⌘D bubble, and the manager.
    static func bookmarkUI() {
        _ = NSApplication.shared
        let store = Store.shared
        let file = Config.supportDir.appendingPathComponent("bookmarks.json")
        store.flushBookmarks()
        let before = try? Data(contentsOf: file)
        defer {
            store.flushBookmarks()
            if let before { try? before.write(to: file) } else { try? FileManager.default.removeItem(at: file) }
            store.reloadBookmarks()
        }
        store.remove(store.bookmarkBar.children + store.otherBookmarks.children)
        let folder = store.addFolder(title: "Reading", in: store.bookmarkBar)
        let sub = store.addFolder(title: "Later", in: folder)
        store.addBookmark(url: URL(string: "https://r1.test/")!, title: "R1", in: folder)
        store.addBookmark(url: URL(string: "https://r2.test/")!, title: "R2", in: sub)
        let top = store.addBookmark(url: URL(string: "https://top.test/")!, title: "Top", in: store.bookmarkBar)

        // Folder menus fill only when opened.
        var opened: [URL] = [], openedAll: [BookmarkNode] = []
        let menu = BookmarkFolderMenu(folder: folder, open: { opened.append($0) }, openAll: { openedAll.append($0) })
        expect(menu.items.isEmpty, "folder menus are empty until opened")
        menu.menuNeedsUpdate(menu)
        expect(menu.items.map(\.title) == ["Open All (2) in Tabs", "", "Later", "R1"] && menu.items[2].submenu is BookmarkFolderMenu,
               "folder menus list Open All, subfolders as submenus, then bookmarks")
        if let r1 = menu.items.last as? ClosureMenuItem { _ = r1.target?.perform(r1.action, with: r1) }
        if let all = menu.items.first as? ClosureMenuItem { _ = all.target?.perform(all.action, with: all) }
        expect(opened == [URL(string: "https://r1.test/")!] && openedAll.first === folder, "menu items open pages and folders")

        // The bar shows the Bookmarks Bar folder, folders included.
        let bar = BookmarksBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 28))
        expect(bar.items.map(\.title) == ["Reading", "Top"] && bar.items.first?.node.isFolder == true, "the bar shows folders and bookmarks")
        expect(bar.items.first?.contextMenu().items.first?.title == "Open All (2)", "a bar folder offers Open All")

        // The ⌘D bubble renames and files the bookmark when it closes, once.
        let editor = BookmarkEditorController(node: top, isNew: true)
        _ = editor.view
        editor.nameField.stringValue = "Top page"
        if let i = editor.folderPopup.itemArray.firstIndex(where: { ($0.representedObject as? BookmarkNode) === sub }) { editor.folderPopup.selectItem(at: i) }
        expect(editor.folderPopup.itemArray.contains { $0.title == "Later" && $0.indentationLevel == 2 }, "the folder picker indents subfolders")
        editor.commit()
        expect(top.title == "Top page" && top.parent === sub && store.lastUsedFolder === sub, "the bubble renames, files, and remembers the folder")
        editor.nameField.stringValue = "Changed later"
        editor.commit()
        expect(top.title == "Top page", "the bubble applies its edits only once")
        let removing = BookmarkEditorController(node: top, isNew: false)
        _ = removing.view
        removing.removeBookmark()
        expect(!store.isBookmarked(URL(string: "https://top.test/")!), "Remove deletes the bookmark")

        // The manager's outline: roots open, search flattens, drops land in folders.
        let outline = BookmarkOutline()
        outline.scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        outline.reload(query: "")
        expect(outline.outline.isItemExpanded(store.bookmarkBar) && outline.outline.numberOfRows == 3,
               "the manager opens with the top-level folders expanded")
        outline.outline.expandItem(folder)
        outline.reload(query: "")
        expect(outline.outline.isItemExpanded(folder), "reloading keeps open folders open")
        outline.reload(query: "r2")
        expect(outline.matches.map(\.title) == ["R2"] && outline.outline.numberOfRows == 1, "searching lists matching bookmarks flat")
        outline.reload(query: "")
        let r1 = folder.children.last!
        expect(outline.dropTarget(item: nil, childIndex: 0) == nil, "nothing drops beside the top-level folders")
        expect(outline.dropTarget(item: r1, childIndex: -1).map { $0.folder === folder && $0.index == 2 } == true,
               "dropping on a bookmark lands just after it")
        expect(outline.move([r1], to: store.otherBookmarks, at: 0) && store.otherBookmarks.children.first === r1, "dragging moves bookmarks between folders")
        expect(!outline.move([folder], to: sub, at: nil), "a folder cannot be dragged into itself")
        expect(outline.countText == "2 bookmarks in 2 folders", "the manager counts bookmarks and folders")

        // Open All opens one page and leaves the rest asleep.
        let pages = store.addFolder(title: "Pages", in: store.otherBookmarks,
                                    pages: (1...3).map { (URL(string: "about:blank#\($0)")!, "P\($0)") })
        let app = AppDelegate()
        app.openBookmarks(in: pages, newWindow: true)
        let window = app.allControllers.last
        expect(window?.tabs.count == 3 && window?.tabs.filter(\.hasEverLoaded).count == 1, "Open All wakes only the first tab")
        window?.window?.close()
    }
}
