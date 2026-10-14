import AppKit

/// Native macOS settings window. Preferences are persisted through Config and applied
/// live where possible; secrets remain in-memory/Keychain as appropriate.
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init(importSourceProvider: @escaping () -> [BrowserImportSource] = { BrowserImportService.shared.detectSources() }) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        super.init(window: w)
        w.title = "Facet Settings"
        w.minSize = NSSize(width: 620, height: 480)
        w.center()

        tabs.tabStyle = .toolbar
        tabs.addChild(GeneralSettingsViewController())
        tabs.addChild(MemorySettingsViewController())
        tabs.addChild(AgentSettingsViewController())
        tabs.addChild(ImportSettingsViewController(sourceProvider: importSourceProvider))
        tabs.addChild(PrivacySettingsViewController())
        w.contentViewController = tabs
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        for child in tabs.children {
            (child as? SettingsPane)?.reloadFromConfig()
        }
    }

    func selectImportPane() {
        tabs.selectedTabViewItemIndex = 3
    }
}

private protocol SettingsPane: AnyObject {
    func reloadFromConfig()
}

private class SettingsPaneViewController: NSViewController, SettingsPane {
    let root = NSView()
    let content = NSView()
    private let heading = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")

    init(title: String, subtitle: String, symbol: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
        self.subtitle.stringValue = subtitle
        self.heading.stringValue = title
        _ = symbol
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = root
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        root.addSubview(heading)
        root.addSubview(subtitle)
        root.addSubview(content)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds, pad: CGFloat = 24
        heading.frame = NSRect(x: pad, y: b.height - 48, width: b.width - 2 * pad, height: 26)
        subtitle.frame = NSRect(x: pad, y: b.height - 86, width: b.width - 2 * pad, height: 34)
        content.frame = NSRect(x: pad, y: pad, width: b.width - 2 * pad, height: max(100, b.height - 120))
    }

    func reloadFromConfig() {}

    func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }

    func checkbox(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.font = .systemFont(ofSize: 13)
        return b
    }

    func commit() {
        Config.shared.save()
        AppDelegate.shared?.settingsDidChange()
    }
}

private final class GeneralSettingsViewController: SettingsPaneViewController, NSTextFieldDelegate {
    private let homepage = NSTextField()
    private let search = NSTextField()
    private var restore: NSButton!
    private var devTools: NSButton!

    init() {
        super.init(title: "General", subtitle: "Startup and browsing defaults.", symbol: "gearshape")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        restore = checkbox("Restore tabs when Facet opens", action: #selector(changed))
        devTools = checkbox("Enable Web Inspector / developer tools", action: #selector(changed))
        homepage.placeholderString = "about:blank"
        search.placeholderString = "https://www.google.com/search?q=%s"
        homepage.target = self; homepage.action = #selector(changed)
        search.target = self; search.action = #selector(changed)
        [homepage, search, restore!, devTools!].forEach { content.addSubview($0) }
        reloadFromConfig()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard isViewLoaded else { return }
        let w = content.bounds.width
        let homeLabel = ensureLabel("Homepage", tag: 1001)
        let searchLabel = ensureLabel("Search URL (%s = query)", tag: 1002)
        homeLabel.frame = NSRect(x: 0, y: 300, width: 180, height: 20)
        homepage.frame = NSRect(x: 190, y: 296, width: w - 190, height: 26)
        searchLabel.frame = NSRect(x: 0, y: 254, width: 180, height: 20)
        search.frame = NSRect(x: 190, y: 250, width: w - 190, height: 26)
        restore.frame = NSRect(x: 0, y: 196, width: w, height: 24)
        devTools.frame = NSRect(x: 0, y: 160, width: w, height: 24)
    }

    private func ensureLabel(_ text: String, tag: Int) -> NSTextField {
        if let l = content.viewWithTag(tag) as? NSTextField { return l }
        let l = label(text); l.tag = tag; content.addSubview(l); return l
    }

    override func reloadFromConfig() {
        guard isViewLoaded else { return }
        homepage.stringValue = Config.shared.homepage
        search.stringValue = Config.shared.searchTemplate
        restore.state = Config.shared.restoreSessionOnLaunch ? .on : .off
        devTools.state = Config.shared.enableDeveloperTools ? .on : .off
    }

    @objc private func changed() {
        Config.shared.homepage = homepage.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.shared.searchTemplate = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.shared.restoreSessionOnLaunch = restore.state == .on
        Config.shared.enableDeveloperTools = devTools.state == .on
        commit()
    }
}

private final class MemorySettingsViewController: SettingsPaneViewController {
    private let budget = NSPopUpButton()
    private let sleepAfter = NSPopUpButton()
    private var pressure: NSButton!
    private var readout: NSButton!
    private let note = NSTextField(wrappingLabelWithString: "The RAM value is a target, not a hard process limit. Facet sleeps eligible background renderers before the target is exceeded; the active page and protected media tabs remain live.")

    private let budgets: [(String, Int)] = [("Off", 0), ("750 MB", 750), ("1 GB", 1024), ("1.5 GB", 1536), ("2 GB", 2048), ("3 GB", 3072)]
    private let sleeps: [(String, Double)] = [("Never", 0), ("1 minute", 1), ("2 minutes", 2), ("5 minutes", 5), ("10 minutes", 10), ("15 minutes", 15), ("30 minutes", 30)]

    init() { super.init(title: "Memory", subtitle: "Control Facet's working set and tab hibernation.", symbol: "memorychip") }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        for (title, value) in budgets { budget.addItem(withTitle: title); budget.lastItem?.representedObject = value }
        for (title, value) in sleeps { sleepAfter.addItem(withTitle: title); sleepAfter.lastItem?.representedObject = value }
        budget.target = self; budget.action = #selector(changed)
        sleepAfter.target = self; sleepAfter.action = #selector(changed)
        pressure = checkbox("Hibernate background tabs immediately on macOS memory pressure", action: #selector(changed))
        readout = checkbox("Show live memory usage in the browser toolbar", action: #selector(changed))
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        [budget, sleepAfter, pressure!, readout!, note].forEach { content.addSubview($0) }
        reloadFromConfig()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let w = content.bounds.width
        let budgetLabel = ensureLabel("RAM target", tag: 1101)
        let sleepLabel = ensureLabel("Sleep inactive tabs after", tag: 1102)
        budgetLabel.frame = NSRect(x: 0, y: 300, width: 180, height: 20)
        budget.frame = NSRect(x: 190, y: 296, width: 200, height: 28)
        sleepLabel.frame = NSRect(x: 0, y: 252, width: 180, height: 20)
        sleepAfter.frame = NSRect(x: 190, y: 248, width: 200, height: 28)
        pressure.frame = NSRect(x: 0, y: 194, width: w, height: 24)
        readout.frame = NSRect(x: 0, y: 158, width: w, height: 24)
        note.frame = NSRect(x: 0, y: 76, width: w, height: 62)
    }

    private func ensureLabel(_ text: String, tag: Int) -> NSTextField {
        if let l = content.viewWithTag(tag) as? NSTextField { return l }
        let l = label(text); l.tag = tag; content.addSubview(l); return l
    }

    override func reloadFromConfig() {
        guard isViewLoaded else { return }
        if let i = budgets.firstIndex(where: { $0.1 == Config.shared.memoryBudgetMB }) { budget.selectItem(at: i) }
        if let i = sleeps.firstIndex(where: { abs($0.1 - Config.shared.hibernateAfterMinutes) < 0.001 }) { sleepAfter.selectItem(at: i) }
        pressure.state = Config.shared.hibernateOnMemoryPressure ? .on : .off
        readout.state = Config.shared.showMemoryReadout ? .on : .off
    }

    @objc private func changed() {
        Config.shared.memoryBudgetMB = budget.selectedItem?.representedObject as? Int ?? 1536
        Config.shared.hibernateAfterMinutes = sleepAfter.selectedItem?.representedObject as? Double ?? 5
        Config.shared.hibernateOnMemoryPressure = pressure.state == .on
        Config.shared.showMemoryReadout = readout.state == .on
        commit()
        if Config.shared.memoryBudgetMB > 0 { MemoryBudgetController.shared.enforceBudget(reason: "settings changed") }
    }
}

private final class AgentSettingsViewController: SettingsPaneViewController {
    private var enabled: NSButton!
    private let provider = NSPopUpButton()
    private let endpoint = NSTextField()
    private let model = NSTextField()
    private let maxTabs = NSPopUpButton()
    private let apiKey = NSSecureTextField()
    private let authURL = NSTextField()
    private let tokenURL = NSTextField()
    private let clientID = NSTextField()
    private let scopes = NSTextField()
    private let oauthButton = NSButton(title: "Connect OAuth", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")

    init() { super.init(title: "Agent", subtitle: "Inference provider, credentials, and the agent's live-tab budget.", symbol: "sparkles") }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        enabled = checkbox("Enable Facet Agent", action: #selector(changed))
        for p in AgentProviderKind.allCases { provider.addItem(withTitle: p.displayName); provider.lastItem?.representedObject = p.rawValue }
        provider.target = self; provider.action = #selector(providerChanged)
        endpoint.placeholderString = "Provider base URL or full inference endpoint"
        model.placeholderString = "Model"
        apiKey.placeholderString = "API key (kept only for this Facet session)"
        authURL.placeholderString = "OAuth authorization URL"
        tokenURL.placeholderString = "OAuth token URL"
        clientID.placeholderString = "Provider-issued native/public client ID"
        scopes.placeholderString = "space separated scopes"
        for n in 1...4 { maxTabs.addItem(withTitle: "\(n)"); maxTabs.lastItem?.representedObject = n }
        [endpoint, model, authURL, tokenURL, clientID, scopes].forEach { $0.target = self; $0.action = #selector(changed) }
        apiKey.target = self; apiKey.action = #selector(apiKeyChanged)
        maxTabs.target = self; maxTabs.action = #selector(changed)
        oauthButton.target = self; oauthButton.action = #selector(toggleOAuth); oauthButton.bezelStyle = .rounded
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        [enabled!, provider, endpoint, model, maxTabs, apiKey, authURL, tokenURL, clientID, scopes, oauthButton, status].forEach { content.addSubview($0) }
        reloadFromConfig()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let w = content.bounds.width, labelW: CGFloat = 125, fieldX: CGFloat = 140
        enabled.frame = NSRect(x: 0, y: 332, width: w, height: 24)
        var y: CGFloat = 292
        func row(_ text: String, _ view: NSView, _ tag: Int) {
            let l = ensureLabel(text, tag: tag); l.frame = NSRect(x: 0, y: y + 4, width: labelW, height: 20)
            view.frame = NSRect(x: fieldX, y: y, width: w - fieldX, height: 26); y -= 38
        }
        row("Provider", provider, 1201)
        row("Endpoint", endpoint, 1202)
        row("Model", model, 1203)
        row("Max live tabs", maxTabs, 1204)
        if !apiKey.isHidden { row("API key", apiKey, 1205) }
        if !authURL.isHidden {
            row("Authorization URL", authURL, 1206); row("Token URL", tokenURL, 1207)
            row("Client ID", clientID, 1208); row("Scopes", scopes, 1209)
            oauthButton.frame = NSRect(x: fieldX, y: y - 2, width: 150, height: 28); y -= 38
        }
        status.frame = NSRect(x: 0, y: max(0, y - 36), width: w, height: 40)
    }

    private func ensureLabel(_ text: String, tag: Int) -> NSTextField {
        if let l = content.viewWithTag(tag) as? NSTextField { l.isHidden = false; return l }
        let l = label(text); l.tag = tag; content.addSubview(l); return l
    }
    private func hideLabel(_ tag: Int) { content.viewWithTag(tag)?.isHidden = true }

    private var selectedProvider: AgentProviderKind {
        AgentProviderKind(rawValue: provider.selectedItem?.representedObject as? String ?? "") ?? .openAI
    }

    override func reloadFromConfig() {
        guard isViewLoaded else { return }
        let p = AgentProviderKind.configured
        if let i = AgentProviderKind.allCases.firstIndex(of: p) { provider.selectItem(at: i) }
        enabled.state = Config.shared.agentEnabled ? .on : .off
        endpoint.stringValue = Config.shared.agentBaseURL.isEmpty ? p.defaultBaseURL : Config.shared.agentBaseURL
        model.stringValue = Config.shared.agentModel.isEmpty ? p.defaultModel : Config.shared.agentModel
        maxTabs.selectItem(withTitle: "\(Config.shared.agentMaxLiveTabs)")
        loadOAuthFields(p)
        refreshProviderUI()
    }

    @objc private func providerChanged() {
        let p = selectedProvider
        Config.shared.agentProvider = p.rawValue
        Config.shared.agentBaseURL = p.defaultBaseURL
        Config.shared.agentModel = p.defaultModel
        endpoint.stringValue = p.defaultBaseURL; model.stringValue = p.defaultModel
        BrowserAgentService.shared.apiKeyOverride = nil; apiKey.stringValue = ""
        loadOAuthFields(p); changed()
    }

    private func loadOAuthFields(_ p: AgentProviderKind) {
        if p == .openAIOAuth {
            authURL.stringValue = Config.shared.agentOpenAIOAuthAuthorizationURL
            tokenURL.stringValue = Config.shared.agentOpenAIOAuthTokenURL
            clientID.stringValue = Config.shared.agentOpenAIOAuthClientID
            scopes.stringValue = Config.shared.agentOpenAIOAuthScopes
        } else if p == .anthropicOAuth {
            authURL.stringValue = Config.shared.agentAnthropicOAuthAuthorizationURL
            tokenURL.stringValue = Config.shared.agentAnthropicOAuthTokenURL
            clientID.stringValue = Config.shared.agentAnthropicOAuthClientID
            scopes.stringValue = Config.shared.agentAnthropicOAuthScopes
        } else { authURL.stringValue = ""; tokenURL.stringValue = ""; clientID.stringValue = ""; scopes.stringValue = "" }
    }

    private func refreshProviderUI() {
        let p = selectedProvider, oauth = p.usesOAuth
        apiKey.isHidden = oauth; if oauth { hideLabel(1205) }
        for v in [authURL, tokenURL, clientID, scopes, oauthButton] { v.isHidden = !oauth }
        for tag in 1206...1209 { if !oauth { hideLabel(tag) } }
        if oauth {
            let connected = AgentOAuthManager.shared.isConnected(p)
            oauthButton.title = connected ? "Disconnect OAuth" : "Connect OAuth"
            status.stringValue = connected ? "Connected. Access/refresh tokens are stored in macOS Keychain." : "OAuth requires provider-issued client metadata. Facet does not reuse private Codex/Claude client credentials."
        } else {
            status.stringValue = BrowserAgentService.shared.hasCredential ? "A credential is available for this provider." : "Enter a session-only API key here, or provide the matching environment variable."
        }
        view.needsLayout = true
    }

    @objc private func apiKeyChanged() {
        let key = apiKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        BrowserAgentService.shared.apiKeyOverride = key.isEmpty ? nil : key
        refreshProviderUI()
    }

    @objc private func changed() {
        let p = selectedProvider
        Config.shared.agentEnabled = enabled.state == .on
        Config.shared.agentProvider = p.rawValue
        Config.shared.agentBaseURL = endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.shared.agentModel = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.shared.agentMaxLiveTabs = maxTabs.selectedItem?.representedObject as? Int ?? 1
        if p == .openAIOAuth {
            Config.shared.agentOpenAIOAuthAuthorizationURL = authURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Config.shared.agentOpenAIOAuthTokenURL = tokenURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Config.shared.agentOpenAIOAuthClientID = clientID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Config.shared.agentOpenAIOAuthScopes = scopes.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if p == .anthropicOAuth {
            Config.shared.agentAnthropicOAuthAuthorizationURL = authURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Config.shared.agentAnthropicOAuthTokenURL = tokenURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Config.shared.agentAnthropicOAuthClientID = clientID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Config.shared.agentAnthropicOAuthScopes = scopes.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        commit(); refreshProviderUI()
    }

    @objc private func toggleOAuth() {
        let p = selectedProvider; guard p.usesOAuth else { return }
        changed()
        if AgentOAuthManager.shared.isConnected(p) { AgentOAuthManager.shared.disconnect(p); refreshProviderUI(); return }
        oauthButton.isEnabled = false; status.stringValue = "Opening OAuth login…"
        AgentOAuthManager.shared.beginLogin(provider: p) { [weak self] result in
            guard let self else { return }; self.oauthButton.isEnabled = true
            if case .failure(let e) = result { self.status.stringValue = "OAuth error: \(e.localizedDescription)" }
            self.refreshProviderUI()
        }
    }
}

private final class ImportSettingsViewController: SettingsPaneViewController {
    private let source = NSPopUpButton()
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let chooseButton = NSButton(title: "Choose Chromium Profile Folder…", target: nil, action: nil)
    private var importBookmarks: NSButton!
    private var importHistory: NSButton!
    private var importSessions: NSButton!
    private let importButton = NSButton(title: "Import Selected Data", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "Chrome session migration is experimental and best-effort. Saved passwords, passkeys, extensions, and app storage are not imported; some sites will still require login.")
    private var sources: [BrowserImportSource] = []
    private var isImporting = false
    private var customSources: [BrowserImportSource] = []
    private let sourceProvider: () -> [BrowserImportSource]

    init(sourceProvider: @escaping () -> [BrowserImportSource]) {
        self.sourceProvider = sourceProvider
        super.init(title: "Import", subtitle: "Bring bookmarks, history, and optional Chrome sessions.", symbol: "square.and.arrow.down")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        importBookmarks = checkbox("Bookmarks", action: #selector(selectionChanged))
        importHistory = checkbox("Browsing history", action: #selector(selectionChanged))
        importSessions = checkbox("Sign-in sessions — Experimental (Chrome only)", action: #selector(selectionChanged))
        importSessions.state = .off
        importSessions.toolTip = "Optional, sensitive account data. Requires confirmation and may require macOS Keychain permission. Saved passwords are not imported."
        source.target = self; source.action = #selector(sourceChanged)
        refreshButton.target = self; refreshButton.action = #selector(refreshSources)
        chooseButton.target = self; chooseButton.action = #selector(chooseProfileFolder)
        importButton.target = self; importButton.action = #selector(importPressed)
        [refreshButton, chooseButton, importButton].forEach { $0.bezelStyle = .rounded }
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11); note.textColor = .tertiaryLabelColor
        [source, refreshButton, chooseButton, importBookmarks!, importHistory!, importSessions!, importButton, status, note].forEach { content.addSubview($0) }
        refreshSources()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let w = content.bounds.width
        let label = ensureLabel("Browser / profile", tag: 1301)
        label.frame = NSRect(x: 0, y: 300, width: 125, height: 20)
        source.frame = NSRect(x: 140, y: 296, width: max(220, w - 240), height: 28)
        refreshButton.frame = NSRect(x: w - 88, y: 296, width: 88, height: 28)
        chooseButton.frame = NSRect(x: 140, y: 254, width: max(210, w - 140), height: 28)
        importBookmarks.frame = NSRect(x: 140, y: 220, width: 180, height: 24)
        importHistory.frame = NSRect(x: 140, y: 188, width: 180, height: 24)
        importSessions.frame = NSRect(x: 140, y: 156, width: max(300, w - 140), height: 24)
        importButton.frame = NSRect(x: 140, y: 112, width: 160, height: 30)
        status.frame = NSRect(x: 0, y: 54, width: w, height: 48)
        note.frame = NSRect(x: 0, y: 6, width: w, height: 38)
    }

    private func ensureLabel(_ text: String, tag: Int) -> NSTextField {
        if let l = content.viewWithTag(tag) as? NSTextField { return l }
        let l = label(text); l.tag = tag; content.addSubview(l); return l
    }

    override func reloadFromConfig() {
        if isViewLoaded { refreshSources() }
    }

    @objc private func refreshSources() {
        guard !isImporting else { return }
        let previous = selectedSource?.id
        sources = sourceProvider()
        for custom in customSources where !sources.contains(where: { $0.profileURL == custom.profileURL }) { sources.append(custom) }
        source.removeAllItems()
        for s in sources {
            source.addItem(withTitle: s.displayName)
            source.lastItem?.representedObject = s.id
        }
        if let previous, let i = sources.firstIndex(where: { $0.id == previous }) { source.selectItem(at: i) }
        else if !sources.isEmpty { source.selectItem(at: 0) }
        status.stringValue = sources.isEmpty
            ? "No supported browser profiles were detected automatically. You can still choose a Chromium profile folder manually."
            : "Detected \(sources.count) importable browser profile\(sources.count == 1 ? "" : "s")."
        sourceChanged()
    }

    private var selectedSource: BrowserImportSource? {
        guard source.indexOfSelectedItem >= 0, sources.indices.contains(source.indexOfSelectedItem) else { return nil }
        return sources[source.indexOfSelectedItem]
    }

    @objc private func sourceChanged() {
        importSessions.state = .off // A different profile or refresh always requires a fresh opt-in.
        importSessions.isEnabled = !isImporting && (selectedSource?.hasSessions ?? false)
        guard let s = selectedSource else {
            importBookmarks.isEnabled = false; importHistory.isEnabled = false; importButton.isEnabled = false
            return
        }
        importBookmarks.isEnabled = s.hasBookmarks
        importHistory.isEnabled = s.hasHistory
        if !s.hasBookmarks { importBookmarks.state = .off }
        else if importBookmarks.state == .off && importHistory.state == .off { importBookmarks.state = .on }
        if !s.hasHistory { importHistory.state = .off }
        else if importBookmarks.state == .off && importHistory.state == .off { importHistory.state = .on }
        selectionChanged()
    }

    @objc private func selectionChanged() {
        importButton.isEnabled = !isImporting && selectedSource != nil &&
            ((importBookmarks.state == .on && importBookmarks.isEnabled) || (importHistory.state == .on && importHistory.isEnabled) ||
             (importSessions.state == .on && importSessions.isEnabled))
    }

    @objc private func chooseProfileFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Chromium browser profile folder"
        panel.prompt = "Choose Profile"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let custom = BrowserImportService.shared.customChromiumSource(profileURL: url) else {
            status.stringValue = "That folder does not contain a Chromium Bookmarks, History, or Cookies file. Choose a profile folder such as Default or Profile 1."
            return
        }
        if !customSources.contains(where: { $0.profileURL == custom.profileURL }) { customSources.append(custom) }
        refreshSources()
        if let i = sources.firstIndex(where: { $0.profileURL == custom.profileURL }) { source.selectItem(at: i) }
        status.stringValue = "Custom Chromium profile selected."
        sourceChanged()
    }

    @objc private func importPressed() {
        guard !isImporting, let s = selectedSource else { return }
        let b = importBookmarks.state == .on && importBookmarks.isEnabled
        let h = importHistory.state == .on && importHistory.isEnabled
        let c = importSessions.state == .on && importSessions.isEnabled
        guard b || h || c else { return }
        setRunning(true)
        if c {
            let consent = NSAlert()
            consent.alertStyle = .warning
            consent.messageText = "Import experimental Chrome sign-in sessions?"
            consent.informativeText = "From: \(s.displayName)\n\nThis copies supported cookies, including account sign-in tokens and site preferences, into Facet's normal windows. Only import your own profile. Existing Facet cookies are kept; private windows remain separate.\n\nClose Chrome first. macOS may ask permission to read Chrome Safe Storage in Keychain. Facet will not bypass denied access or export plaintext files. Device-bound logins, passkeys, and sites using other storage may still require you to sign in again."
            consent.addButton(withTitle: "Cancel")
            consent.addButton(withTitle: "Import Sessions")
            guard consent.runModal() == .alertSecondButtonReturn else { setRunning(false); return }
        }
        status.stringValue = "Importing from \(s.displayName)…" + (c ? " Check for a macOS Keychain permission prompt." : "")
        status.toolTip = status.stringValue
        BrowserImportService.shared.importData(from: s, bookmarks: b, history: h, sessions: c) { [weak self] result in
            guard let self else { return }
            self.setRunning(false)
            switch result {
            case .success(let r):
                AppDelegate.shared?.browserDataWasImported()
                var text = "Imported \(r.bookmarksAdded) new bookmark\(r.bookmarksAdded == 1 ? "" : "s") and \(r.historyAdded) new history entr\(r.historyAdded == 1 ? "y" : "ies")."
                if r.bookmarksRead > r.bookmarksAdded || r.historyRead > r.historyAdded { text += " Existing items were merged without duplication." }
                if c {
                    text += " \(r.cookiesImported) cookies imported across \(r.cookieSites) hosts; \(r.cookiesPreserved) existing cookies kept; \(r.cookiesSkipped) skipped. Reload your sites. Some sites will still require login."
                }
                if !r.warnings.isEmpty { text += " " + r.warnings.joined(separator: " ") }
                self.status.stringValue = text
                self.status.toolTip = text
                if c {
                    let summary = NSAlert()
                    summary.messageText = "Chrome session import finished"
                    summary.informativeText = text
                    summary.addButton(withTitle: "OK")
                    if let window = self.view.window { summary.beginSheetModal(for: window) }
                }
            case .failure(let error):
                self.status.stringValue = "Import failed: \(error.localizedDescription)"
                self.status.toolTip = self.status.stringValue
            }
        }
    }

    private func setRunning(_ running: Bool) {
        isImporting = running
        source.isEnabled = !running; refreshButton.isEnabled = !running; chooseButton.isEnabled = !running
        importBookmarks.isEnabled = !running && (selectedSource?.hasBookmarks ?? false)
        importHistory.isEnabled = !running && (selectedSource?.hasHistory ?? false)
        importSessions.isEnabled = !running && (selectedSource?.hasSessions ?? false)
        if !running { importSessions.state = .off }
        selectionChanged()
    }
}

private final class PrivacySettingsViewController: SettingsPaneViewController {
    private var blocking: NSButton!
    private let editBlocklist = NSButton(title: "Edit Blocklist…", target: nil, action: nil)
    private let clearHistory = NSButton(title: "Clear History…", target: nil, action: nil)
    private let clearData = NSButton(title: "Clear Cookies & Cache…", target: nil, action: nil)

    init() { super.init(title: "Privacy", subtitle: "Tracking protection and local browsing data.", symbol: "hand.raised") }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        blocking = checkbox("Block ads and trackers using Facet's native WebKit rules", action: #selector(blockingChanged))
        editBlocklist.target = self; editBlocklist.action = #selector(editBlocklistPressed)
        clearHistory.target = AppDelegate.shared; clearHistory.action = #selector(AppDelegate.clearHistory)
        clearData.target = AppDelegate.shared; clearData.action = #selector(AppDelegate.clearWebsiteData)
        [editBlocklist, clearHistory, clearData].forEach { $0.bezelStyle = .rounded }
        [blocking!, editBlocklist, clearHistory, clearData].forEach { content.addSubview($0) }
        reloadFromConfig()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let w = content.bounds.width
        blocking.frame = NSRect(x: 0, y: 300, width: w, height: 24)
        editBlocklist.frame = NSRect(x: 0, y: 244, width: 140, height: 30)
        clearHistory.frame = NSRect(x: 0, y: 178, width: 140, height: 30)
        clearData.frame = NSRect(x: 152, y: 178, width: 175, height: 30)
    }

    override func reloadFromConfig() { if isViewLoaded { blocking.state = Config.shared.blockAdsAndTrackers ? .on : .off } }

    @objc private func blockingChanged() {
        Config.shared.blockAdsAndTrackers = blocking.state == .on
        Config.shared.save()
        AppDelegate.shared?.contentBlockingSettingDidChange()
    }

    @objc private func editBlocklistPressed() { AppDelegate.shared?.openBlocklist() }
}
