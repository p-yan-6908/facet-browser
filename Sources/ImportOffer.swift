import AppKit

/// First launch, the way Chrome and Safari do it: find the browsers on this Mac and offer to
/// bring over bookmarks, history and sign-ins from the one you use. Nothing is read until you
/// choose Import, and Keychain and Full Disk Access prompts still come from macOS.
enum ImportOffer {
    /// Browsers Facet imports from, by bundle ID, under the names detection uses.
    static let browsers: [String: String] = [
        "com.google.Chrome": "Google Chrome", "com.brave.Browser": "Brave", "com.microsoft.edgemac": "Microsoft Edge",
        "org.chromium.Chromium": "Chromium", "company.thebrowser.Browser": "Arc", "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera", "com.operasoftware.OperaGX": "Opera GX", "org.mozilla.firefox": "Firefox",
        "com.apple.Safari": "Safari",
    ]

    /// Offer once, to a profile with nothing in it yet, and never to a throwaway test profile.
    /// FACET_SHOW_IMPORT_OFFER=1 shows it anyway, to try it on a profile that already has data.
    static func shouldOffer(alreadyOffered: Bool, hasData: Bool, environment: [String: String]) -> Bool {
        if environment["FACET_SHOW_IMPORT_OFFER"] == "1" { return true }
        return !alreadyOffered && !hasData && (environment["FACET_PROFILE_DIR"] ?? "").isEmpty
    }

    /// The default browser's most recently used profile; failing that, the most recently used
    /// profile of any browser.
    static func suggested(_ sources: [BrowserImportSource], defaultBrowser bundleID: String?,
                          lastUsed: (BrowserImportSource) -> Date? = lastUsed) -> BrowserImportSource? {
        let recent = sources.sorted { (lastUsed($0) ?? .distantPast) > (lastUsed($1) ?? .distantPast) }
        if let name = bundleID.flatMap({ browsers[$0] }), let match = recent.first(where: { $0.browserName == name }) { return match }
        return recent.first
    }

    /// When a profile was last used, from its history, bookmarks or cookie file.
    static func lastUsed(_ source: BrowserImportSource) -> Date? {
        [source.historyURL, source.bookmarksURL, source.cookiesURL].compactMap { $0 }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    static func defaultBrowserBundleID() -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// What macOS may ask before sign-ins can be read, for consent text.
    static func permissionNote(for source: BrowserImportSource) -> String {
        switch source.format {
        case .chromium: return "macOS may ask permission to read \(source.sessionKeyring ?? source.browserName) Safe Storage in Keychain."
        case .safari: return "macOS may require Full Disk Access before Facet can read Safari's cookies."
        case .firefox: return "Firefox keeps them unencrypted, so no Keychain prompt appears."
        }
    }
}

struct ImportChoice {
    let source: BrowserImportSource
    let bookmarks: Bool
    let history: Bool
    let signIns: Bool
}

/// The first-launch sheet: which browser, and what to bring.
final class ImportOfferController: NSViewController {
    private let sources: [BrowserImportSource]
    private let suggested: BrowserImportSource?
    let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let bookmarks = NSButton(checkboxWithTitle: "Bookmarks", target: nil, action: nil)
    let history = NSButton(checkboxWithTitle: "Browsing history", target: nil, action: nil)
    let signIns = NSButton(checkboxWithTitle: "Stay signed in to websites", target: nil, action: nil)
    let signInNote = NSTextField(wrappingLabelWithString: "")
    let importButton = NSButton(title: "Import", target: nil, action: nil)
    var onImport: ((ImportChoice) -> Void)?
    var onFinish: (() -> Void)?

    init(sources: [BrowserImportSource], suggested: BrowserImportSource?) {
        self.sources = sources
        self.suggested = suggested
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: "Bring your browsing to Facet")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "Facet found \(sources.count == 1 ? "a browser" : "these browsers") on your Mac. Choose what to bring over. You can import again at any time from Settings \u{2192} Import.")
        intro.preferredMaxLayoutWidth = 400
        for s in sources { sourcePopup.addItem(withTitle: s.displayName); sourcePopup.lastItem?.representedObject = s.id }
        sourcePopup.selectItem(at: suggested.flatMap { s in sources.firstIndex { $0.id == s.id } } ?? 0)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        signInNote.font = .systemFont(ofSize: 11)
        signInNote.textColor = .secondaryLabelColor
        signInNote.preferredMaxLayoutWidth = 380
        for box in [bookmarks, history, signIns] { box.target = self; box.action = #selector(selectionChanged) }
        let from = NSStackView(views: [NSTextField(labelWithString: "Import from:"), sourcePopup])
        let notNow = NSButton(title: "Not Now", target: self, action: #selector(notNow))
        notNow.keyEquivalent = "\u{1b}"
        importButton.target = self
        importButton.action = #selector(importPressed)
        importButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), notNow, importButton])
        let noteRow = NSStackView(views: [signInNote])
        noteRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        let stack = NSStackView(views: [title, intro, from, bookmarks, history, signIns, noteRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: intro)
        stack.setCustomSpacing(18, after: noteRow)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        buttons.widthAnchor.constraint(equalToConstant: 400).isActive = true
        view = stack
        sourceChanged()
    }

    var selectedSource: BrowserImportSource? {
        sources.first { $0.id == sourcePopup.selectedItem?.representedObject as? String }
    }

    /// Everything the chosen browser has is ticked: the sheet itself is the consent, and
    /// macOS still asks before any protected data is read.
    @objc func sourceChanged() {
        guard let s = selectedSource else { return }
        bookmarks.isEnabled = s.hasBookmarks
        bookmarks.state = s.hasBookmarks ? .on : .off
        history.isEnabled = s.hasHistory
        history.state = s.hasHistory ? .on : .off
        signIns.isEnabled = s.hasSessions
        signIns.state = s.hasSessions ? .on : .off
        signInNote.stringValue = s.hasSessions
            ? "Copies \(s.browserName)'s sign-in cookies, including account tokens, so sites you use there stay signed in here. Passwords are not copied. Close \(s.browserName) first. \(ImportOffer.permissionNote(for: s))"
            : "Facet cannot read \(s.browserName)'s sign-ins."
        selectionChanged()
    }

    var choice: ImportChoice? {
        guard let s = selectedSource else { return nil }
        let c = ImportChoice(source: s, bookmarks: bookmarks.state == .on && bookmarks.isEnabled,
                             history: history.state == .on && history.isEnabled, signIns: signIns.state == .on && signIns.isEnabled)
        return c.bookmarks || c.history || c.signIns ? c : nil
    }

    @objc private func selectionChanged() { importButton.isEnabled = choice != nil }

    @objc func importPressed() {
        guard let choice else { return }
        onFinish?()
        onImport?(choice)
    }

    @objc private func notNow() { onFinish?() }
}
