import AppKit

/// Chrome's "save password?" bubble. The login is already captured; this offers to keep it,
/// update it, or decline (once, or never for the site). The username stays editable and the
/// password can be revealed before saving.
final class PasswordPromptController: NSViewController {
    enum Mode { case save, update }
    let mode: Mode
    private let host: String
    private(set) var username: String
    private let password: String
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private var revealed = false
    /// (username, password) to store, or nil to decline. `never` suppresses the site.
    var onSave: ((String, String) -> Void)?
    var onNever: (() -> Void)?
    var onFinish: (() -> Void)?

    init(host: String, username: String, password: String, mode: Mode) {
        self.host = host
        self.username = username
        self.password = password
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let heading = NSTextField(labelWithString: mode == .update ? "Update password?" : "Save password?")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let site = NSTextField(labelWithString: host)
        site.font = .systemFont(ofSize: 12)
        site.textColor = .secondaryLabelColor
        usernameField.stringValue = username
        usernameField.placeholderString = "Username"
        usernameField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        passwordField.stringValue = password
        passwordField.isEnabled = false
        let reveal = NSButton(image: NSImage(systemSymbolName: "eye", accessibilityDescription: "Show password") ?? NSImage(),
                              target: self, action: #selector(toggleReveal))
        reveal.isBordered = false
        reveal.setButtonType(.momentaryChange)
        let passwordRow = NSStackView(views: [passwordField, reveal])
        let save = NSButton(title: mode == .update ? "Update" : "Save", target: self, action: #selector(savePressed))
        save.keyEquivalent = "\r"
        let never = NSButton(title: "Never", target: self, action: #selector(neverPressed))
        let notNow = NSButton(title: "Not Now", target: self, action: #selector(notNowPressed))
        let buttons = NSStackView(views: [never, NSView(), notNow, save])
        buttons.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Username"), usernameField],
                                      [NSTextField(labelWithString: "Password"), passwordRow]])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [heading, site, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: heading)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        view = stack
    }

    @objc private func toggleReveal() {
        // Replace the field in place so the caret and value are kept.
        revealed.toggle()
        passwordField.isEnabled = false
        if revealed {
            let plain = NSTextField(string: password)
            plain.isEnabled = false
            passwordField.superview?.replaceSubview(passwordField, with: plain)
        }
    }

    @objc private func savePressed() {
        let name = usernameField.stringValue
        onFinish?()
        onSave?(name, password)
    }

    @objc private func neverPressed() {
        onFinish?()
        onNever?()
    }

    @objc private func notNowPressed() { onFinish?() }
}
