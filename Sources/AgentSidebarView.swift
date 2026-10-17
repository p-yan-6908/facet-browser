import AppKit

/// Lightweight native panel embedded beside the active web page. It owns no WebKit
/// view and keeps only transcript text in memory; model/page state lives in the shared
/// agent service and bounded tab leases.
final class AgentSidebarView: NSView, NSTextViewDelegate {
    private let background = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Assistant")
    private let providerLabel = NSTextField(labelWithString: "")
    private let transcriptScroll = NSScrollView()
    private let transcript = NSTextView()
    private let promptField = NSTextField()
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Settings\u{2026}", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let separator = NSBox()
    private var quickActions: [NSButton] = []
    private var isRunning = false
    var onClose: (() -> Void)?

    private static let quickPrompts: [(String, String)] = [
        ("Summarize page", "Summarize this page in a few bullet points."),
        ("Key facts", "List the key facts, numbers and dates on this page."),
        ("Compare tabs", "Compare the pages in my open tabs and tell me how they differ."),
    ]

    private let bodyFont = NSFont.systemFont(ofSize: 12.5)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        background.material = .sidebar
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        addSubview(background)
        separator.boxType = .separator; addSubview(separator)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        providerLabel.font = .systemFont(ofSize: 10); providerLabel.textColor = .secondaryLabelColor
        providerLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 10); statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        transcript.isEditable = false; transcript.isSelectable = true
        transcript.font = bodyFont
        transcript.backgroundColor = .clear
        transcript.textContainerInset = NSSize(width: 8, height: 8)
        transcript.isVerticallyResizable = true; transcript.isHorizontallyResizable = false
        transcript.textContainer?.widthTracksTextView = true
        transcript.delegate = self
        transcript.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.borderType = .noBorder

        promptField.placeholderString = "Ask about your tabs or give Facet a task\u{2026}"
        promptField.target = self; promptField.action = #selector(send)
        promptField.setAccessibilityLabel("Assistant task")
        runButton.target = self; runButton.action = #selector(send)
        clearButton.target = self; clearButton.action = #selector(clearConversation)
        settingsButton.target = AppDelegate.shared; settingsButton.action = #selector(AppDelegate.openSettings)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close assistant")
        closeButton.isBordered = false; closeButton.target = self; closeButton.action = #selector(closePressed)
        [runButton, clearButton, settingsButton].forEach { $0.bezelStyle = .rounded; $0.controlSize = .small }

        quickActions = Self.quickPrompts.enumerated().map { index, entry in
            let b = NSButton(title: entry.0, target: self, action: #selector(quickAction(_:)))
            b.bezelStyle = .inline
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.tag = index
            b.toolTip = entry.1
            return b
        }

        ([titleLabel, providerLabel, transcriptScroll, promptField, runButton, clearButton,
          settingsButton, closeButton, statusLabel] + quickActions).forEach { addSubview($0) }
        refreshProviderLabel(); refreshTranscript()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        background.frame = bounds
        separator.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
        let pad: CGFloat = 12
        titleLabel.frame = NSRect(x: pad, y: bounds.height - 34, width: 110, height: 20)
        closeButton.frame = NSRect(x: bounds.width - pad - 22, y: bounds.height - 34, width: 22, height: 22)
        settingsButton.frame = NSRect(x: bounds.width - pad - 112, y: bounds.height - 36, width: 84, height: 24)
        clearButton.frame = NSRect(x: bounds.width - pad - 172, y: bounds.height - 36, width: 54, height: 24)
        providerLabel.frame = NSRect(x: pad, y: bounds.height - 55, width: bounds.width - 2 * pad, height: 15)
        statusLabel.frame = NSRect(x: pad, y: 8, width: bounds.width - 2 * pad - 72, height: 15)
        runButton.frame = NSRect(x: bounds.width - pad - 64, y: 6, width: 64, height: 26)
        promptField.frame = NSRect(x: pad, y: 40, width: bounds.width - 2 * pad, height: 28)

        // Quick actions sit just above the prompt, wrapping only if the sidebar is narrow.
        var x = pad
        let chipsY: CGFloat = 76
        for b in quickActions {
            let w = ceil(b.intrinsicContentSize.width) + 4
            if x + w > bounds.width - pad { b.isHidden = true; continue }
            b.isHidden = false
            b.frame = NSRect(x: x, y: chipsY, width: w, height: 20)
            x += w + 6
        }
        transcriptScroll.frame = NSRect(x: pad, y: 104, width: bounds.width - 2 * pad,
                                        height: max(120, bounds.height - 168))
    }

    func activate() {
        refreshProviderLabel(); refreshTranscript()
        BrowserAgentService.shared.requestApproval = { [weak self] request, completion in
            self?.presentApproval(request, completion: completion) ?? completion(.deny)
        }
        window?.makeFirstResponder(promptField)
    }

    func prepareToHide() {
        if isRunning { BrowserAgentService.shared.cancel() }
    }

    /// Puts a ready-made request in the prompt field for the user to review and send.
    func prefill(_ prompt: String) {
        guard !isRunning else { return }
        promptField.stringValue = prompt
        window?.makeFirstResponder(promptField)
        promptField.currentEditor()?.moveToEndOfDocument(nil)
    }

    @objc private func quickAction(_ sender: NSButton) {
        guard !isRunning, Self.quickPrompts.indices.contains(sender.tag) else { return }
        promptField.stringValue = Self.quickPrompts[sender.tag].1
        send()
    }

    private func presentApproval(_ request: AgentApprovalRequest,
                                 completion: @escaping (AgentApprovalDecision) -> Void) {
        guard let window, isRunning else { completion(.deny); return }
        let alert = NSAlert()
        alert.messageText = "Allow assistant to \(request.tool.replacingOccurrences(of: "_", with: " "))?"
        let details = request.args.sorted { $0.key < $1.key }
            .map { "\($0.key): \(String(describing: $0.value).prefix(500))" }.joined(separator: "\n")
        let site = request.site.map { "\nSite: \($0)" } ?? ""
        alert.informativeText = "Review this action before allowing it.\(site)\n\n" + details
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: request.sensitive ? "Allow Once + Safe Actions" : "Allow This Site")
        alert.addButton(withTitle: "Allow Safe Actions This Task")
        alert.addButton(withTitle: "YOLO This Task")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response.rawValue {
            case NSApplication.ModalResponse.alertSecondButtonReturn.rawValue: completion(.allowOnce)
            case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue:
                completion(request.sensitive ? .allowSafeForTask : .allowForSite)
            case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1: completion(.allowSafeForTask)
            case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 2:
                self?.confirmYOLO(completion: completion) ?? completion(.deny)
            default: completion(.deny)
            }
        }
    }

    private func confirmYOLO(completion: @escaping (AgentApprovalDecision) -> Void) {
        guard let window, isRunning else { completion(.deny); return }
        let warning = NSAlert()
        warning.alertStyle = .critical
        warning.messageText = "Enable YOLO for this task?"
        warning.informativeText = "Facet will stop asking before browser-changing actions for the rest of this task, including form fills, submissions, navigation, and closing tabs. Completed actions cannot be undone. Private windows, credential-field redaction, and URL safety checks still remain enforced."
        warning.addButton(withTitle: "Cancel")
        warning.addButton(withTitle: "Enable YOLO")
        DispatchQueue.main.async {
            warning.beginSheetModal(for: window) { response in
                if response == .alertSecondButtonReturn {
                    self.statusLabel.stringValue = "YOLO enabled \u{00B7} no more action prompts this task"
                    completion(.allowAllForTask)
                } else { completion(.deny) }
            }
        }
    }

    @objc private func send() {
        if isRunning { BrowserAgentService.shared.cancel(); return }
        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard Config.shared.agentActive, BrowserAgentService.shared.hasCredential else {
            append(note("\nSet up and enable an AI provider in Settings first.\n")); return
        }
        activate()
        promptField.stringValue = ""
        append(header("You"))
        append(body(prompt))
        append(header("Assistant"))
        setRunning(true)
        BrowserAgentService.shared.run(prompt: prompt,
            status: { [weak self] text in self?.statusLabel.stringValue = text },
            delta: { [weak self] text in guard let self else { return }; self.append(self.body(text)) }) { [weak self] result in
                guard let self else { return }
                if let sheet = self.window?.attachedSheet { self.window?.endSheet(sheet, returnCode: .abort) }
                self.setRunning(false)
                switch result {
                case .success:
                    // Re-render the finished conversation with formatting.
                    self.refreshTranscript()
                case .failure(let error):
                    self.append(self.note("\n\(error.localizedDescription)\n", color: .systemRed))
                    self.promptField.stringValue = prompt
                }
                self.refreshProviderLabel()
                self.window?.makeFirstResponder(self.promptField)
            }
    }

    private func setRunning(_ running: Bool) {
        isRunning = running
        runButton.title = running ? "Stop" : "Run"
        promptField.isEnabled = !running; clearButton.isEnabled = !running; settingsButton.isEnabled = !running
        quickActions.forEach { $0.isEnabled = !running }
    }

    @objc private func clearConversation() {
        guard !isRunning else { return }
        BrowserAgentService.shared.clearConversation(); refreshTranscript()
    }

    @objc private func closePressed() { prepareToHide(); onClose?() }

    private func refreshProviderLabel() {
        let p = AgentProviderKind.configured
        providerLabel.stringValue = "\(p.displayName) \u{00B7} \(Config.shared.agentModel)"
        if !isRunning { statusLabel.stringValue = Config.shared.agentActive ? "Ready \u{00B7} context stays in memory" : "Disabled in Settings" }
    }

    private func refreshTranscript() {
        guard !isRunning else { return }
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Facet Assistant\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        text.append(note("Context stays in memory until Clear or quit. Private windows are excluded.\n"))
        for message in BrowserAgentService.shared.conversationSnapshot {
            if message.role == "user" {
                text.append(header("You"))
                text.append(body(message.text))
            } else {
                text.append(header("Assistant"))
                text.append(Self.renderMarkdown(message.text, font: bodyFont))
            }
            text.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        }
        transcript.textStorage?.setAttributedString(text)
        transcript.scrollToEndOfDocument(nil)
    }

    private func header(_ role: String) -> NSAttributedString {
        NSAttributedString(string: "\n\(role)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: role == "You" ? NSColor.controlAccentColor : NSColor.secondaryLabelColor])
    }

    private func body(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: bodyFont, .foregroundColor: NSColor.textColor])
    }

    private func note(_ text: String, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color])
    }

    /// Inline Markdown (bold, italic, code, links) for assistant replies. Block syntax such
    /// as lists is kept as written, which reads fine in a narrow sidebar.
    static func renderMarkdown(_ text: String, font: NSFont) -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text, attributes: plain)
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var attrs = plain
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                if intent.contains(.code) {
                    runFont = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                    attrs[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.2)
                }
            }
            attrs[.font] = runFont
            if let link = run.link, ["http", "https"].contains(link.scheme?.lowercased() ?? "") { attrs[.link] = link }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return out
    }

    /// Links in replies open as background tabs in this window rather than leaving Facet.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let controller = window?.windowController as? BrowserWindowController else { return false }
        controller.newTab(url: url, activate: false).ensureLoaded()
        return true
    }

    private func append(_ text: NSAttributedString) {
        transcript.textStorage?.append(text)
        transcript.scrollToEndOfDocument(nil)
    }
}
