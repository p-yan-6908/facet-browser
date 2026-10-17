import AppKit
import WebKit

/// Cookies and storage for one site. WebKit groups site data by registrable domain
/// ("bbc.co.uk"), so a record belongs to a host that is that domain or a subdomain of it.
enum SiteData {
    static func belongs(_ recordName: String, to host: String) -> Bool {
        let h = host.lowercased(), name = recordName.lowercased()
        return !name.isEmpty && (h == name || h.hasSuffix("." + name))
    }

    static func clear(host: String, in store: WKWebsiteDataStore, completion: @escaping (Int) -> Void) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let mine = records.filter { belongs($0.displayName, to: host) }
            store.removeData(ofTypes: types, for: mine) { completion(mine.count) }
        }
    }
}

/// What the certificate says, in a line or two.
struct CertificateSummary {
    let subject: String
    let issuer: String?
    let validUntil: Date?

    init?(trust: SecTrust) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        subject = SecCertificateCopySubjectSummary(leaf) as String? ?? "Unknown"
        issuer = chain.count > 1 ? SecCertificateCopySubjectSummary(chain[1]) as String? : nil
        let key = kSecOIDX509V1ValidityNotAfter
        let values = SecCertificateCopyValues(leaf, [key] as CFArray, nil) as? [CFString: Any]
        let entry = values?[key] as? [CFString: Any]
        validUntil = (entry?[kSecPropertyKeyValue] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
    }
}

/// Chrome's page info, opened from the lock in the address bar: whether the connection is
/// secure, the permissions this site was given, its zoom, ad blocking here, and its data.
final class PageInfoController: NSViewController {
    private weak var tab: Tab?
    private weak var browser: BrowserWindowController?
    private let stack = NSStackView()
    var onFinish: (() -> Void)?

    init(tab: Tab, browser: BrowserWindowController) {
        self.tab = tab
        self.browser = browser
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Readable names for the permission kinds SiteSettings stores.
    static func permissionName(_ kind: String) -> String {
        switch kind {
        case "camera": return "Camera"
        case "microphone": return "Microphone"
        case "camera+microphone": return "Camera and microphone"
        case let k where k.hasPrefix("open:"): return "Open \(k.dropFirst(5)): links"
        default: return kind.capitalized
        }
    }

    /// Headline and explanation for the connection, as Chrome words them.
    static func security(for url: URL?, onlySecureContent: Bool) -> (symbol: String, title: String, detail: String?) {
        switch url?.scheme?.lowercased() {
        case "https" where onlySecureContent:
            return ("lock.fill", "Connection is secure", "Information you send to this site is private.")
        case "https":
            return ("lock.trianglebadge.exclamationmark", "Parts of this page are not secure", "Some images or other files on it are loaded without encryption.")
        case "http":
            return ("exclamationmark.triangle.fill", "Connection is not secure", "Don\u{2019}t enter passwords or payment details on this site.")
        case "file":
            return ("doc", "This is a file on your Mac", nil)
        default:
            return ("info.circle", "Facet page", nil)
        }
    }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        view = stack
        rebuild()
    }

    private func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.preferredMaxLayoutWidth = 300
        return l
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return line
    }

    func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let tab, let browser, let url = tab.url else { return }
        let host = url.host?.lowercased() ?? ""
        let isWeb = url.scheme == "http" || url.scheme == "https"
        stack.addArrangedSubview(label(host.isEmpty ? url.absoluteString : host, size: 14, weight: .semibold))

        let s = Self.security(for: url, onlySecureContent: tab.webView?.hasOnlySecureContent ?? false)
        let icon = NSImageView(image: NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = url.scheme == "http" ? .systemOrange : .secondaryLabelColor
        let headline = NSStackView(views: [icon, label(s.title, weight: .medium)])
        headline.spacing = 6
        stack.addArrangedSubview(headline)
        if let detail = s.detail { stack.addArrangedSubview(label(detail, size: 11, color: .secondaryLabelColor)) }
        if url.scheme == "https", let trust = tab.webView?.serverTrust, let cert = CertificateSummary(trust: trust) {
            var line = "Certificate for \(cert.subject)"
            if let issuer = cert.issuer { line += ", issued by \(issuer)" }
            if let date = cert.validUntil { line += ". Valid until \(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none))" }
            stack.addArrangedSubview(label(line + ".", size: 11, color: .secondaryLabelColor))
        }
        guard isWeb, !host.isEmpty else { return }

        stack.addArrangedSubview(separator())
        let remembered = SiteSettings.shared.rememberedPermissions(for: host)
        if remembered.isEmpty {
            stack.addArrangedSubview(label("No permissions remembered for this site.", size: 11, color: .secondaryLabelColor))
        }
        for (kind, allowed) in remembered {
            let menu = NSPopUpButton(frame: .zero, pullsDown: false)
            menu.addItems(withTitles: ["Allow", "Block", "Ask"])
            menu.selectItem(at: allowed ? 0 : 1)
            menu.isEnabled = !browser.isPrivateWindow
            menu.target = self
            menu.action = #selector(permissionChanged(_:))
            menu.identifier = NSUserInterfaceItemIdentifier(kind)
            let row = NSStackView(views: [label(Self.permissionName(kind)), menu])
            row.distribution = NSStackView.Distribution.equalSpacing
            row.widthAnchor.constraint(equalToConstant: 300).isActive = true
            stack.addArrangedSubview(row)
        }

        let blocking = NSButton(checkboxWithTitle: "Block ads and trackers on this site", target: self, action: #selector(blockingChanged(_:)))
        blocking.state = Config.shared.blockAdsAndTrackers && !SiteSettings.shared.isBlockingDisabled(for: url) ? .on : .off
        blocking.isEnabled = Config.shared.blockAdsAndTrackers && !browser.isPrivateWindow
        stack.addArrangedSubview(blocking)

        if abs(tab.pageZoom - 1) > 0.01 {
            let reset = NSButton(title: "Reset", target: self, action: #selector(resetZoom))
            reset.controlSize = .small
            let row = NSStackView(views: [label("Zoom: \(Int((tab.pageZoom * 100).rounded()))%"), reset])
            row.spacing = 8
            stack.addArrangedSubview(row)
        }

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(NSButton(title: "Clear Cookies and Site Data\u{2026}", target: self, action: #selector(clearSiteData)))
    }

    @objc private func permissionChanged(_ sender: NSPopUpButton) {
        guard let kind = sender.identifier?.rawValue, let host = tab?.url?.host else { return }
        switch sender.indexOfSelectedItem {
        case 0: SiteSettings.shared.setPermission(kind, for: host, allowed: true)
        case 1: SiteSettings.shared.setPermission(kind, for: host, allowed: false)
        default: SiteSettings.shared.clearPermission(kind, for: host)
        }
    }

    @objc private func blockingChanged(_ sender: NSButton) {
        AppDelegate.shared?.setBlocking(enabled: sender.state == .on, forSiteOf: tab?.url)
    }

    @objc private func resetZoom() {
        browser?.zoomReset()
        rebuild()
    }

    @objc private func clearSiteData() {
        guard let tab, let host = tab.url?.host, let window = view.window ?? browser?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear cookies and site data for \(host)?"
        alert.informativeText = "You will be signed out of this site. Other sites are not affected."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        let store = tab.webView?.configuration.websiteDataStore ?? WebKitEnv.dataStore(private: tab.isPrivate)
        onFinish?()
        alert.beginSheetModal(for: browser?.window ?? window) { [weak tab, weak browser] response in
            guard response == .alertFirstButtonReturn else { return }
            SiteData.clear(host: host, in: store) { _ in
                tab?.reload()
                browser?.showStatus("Cleared data for \(host)")
            }
        }
    }
}
