import AppKit

/// Lightweight native panel embedded beside the active web page. It owns no WebKit
/// view and keeps only transcript text in memory; model/page state lives in the shared
/// agent service and bounded tab leases.
final class AgentSidebarView: NSView {
    private let background = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Assistant")
    private let providerLabel = NSTextField(labelWithString: "")
    private let transcriptScroll = NSScrollView()
    private let transcript = NSTextView()
    private let promptField = NSTextField()
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Settings…", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let separator = NSBox()
    private var isRunning = false
    var onClose: (() -> Void)?

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
        transcript.font = .systemFont(ofSize: 12.5)
        transcript.backgroundColor = .clear
        transcript.textContainerInset = NSSize(width: 8, height: 8)
        transcript.isVerticallyResizable = true; transcript.isHorizontallyResizable = false
        transcript.textContainer?.widthTracksTextView = true
        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.borderType = .noBorder

        promptField.placeholderString = "Ask about your tabs or give Facet a task…"
        promptField.target = self; promptField.action = #selector(send)
        promptField.setAccessibilityLabel("Assistant task")
        runButton.target = self; runButton.action = #selector(send)
        clearButton.target = self; clearButton.action = #selector(clearConversation)
        settingsButton.target = AppDelegate.shared; settingsButton.action = #selector(AppDelegate.openSettings)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close assistant")
        closeButton.isBordered = false; closeButton.target = self; closeButton.action = #selector(closePressed)
        [runButton, clearButton, settingsButton].forEach { $0.bezelStyle = .rounded; $0.controlSize = .small }

        [titleLabel, providerLabel, transcriptScroll, promptField, runButton, clearButton,
         settingsButton, closeButton, statusLabel].forEach { addSubview($0) }
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
        transcriptScroll.frame = NSRect(x: pad, y: 78, width: bounds.width - 2 * pad,
                                        height: max(120, bounds.height - 142))
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
                    self.statusLabel.stringValue = "YOLO enabled · no more action prompts this task"
                    completion(.allowAllForTask)
                } else { completion(.deny) }
            }
        }
    }

    @objc private func send() {
        if isRunning { BrowserAgentService.shared.cancel(); return }
        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard Config.shared.agentEnabled, BrowserAgentService.shared.hasCredential else {
            append("\nSet up and enable an AI provider in Settings first.\n"); return
        }
        activate()
        promptField.stringValue = ""
        append("\nYou: \(prompt)\nAssistant: ")
        setRunning(true)
        BrowserAgentService.shared.run(prompt: prompt,
            status: { [weak self] text in self?.statusLabel.stringValue = text },
            delta: { [weak self] text in self?.append(text) }) { [weak self] result in
                guard let self else { return }
                if let sheet = self.window?.attachedSheet { self.window?.endSheet(sheet, returnCode: .abort) }
                switch result {
                case .success: self.append("\n")
                case .failure(let error):
                    self.append("\n\(error.localizedDescription)\n")
                    self.promptField.stringValue = prompt
                }
                self.setRunning(false); self.refreshProviderLabel()
                self.window?.makeFirstResponder(self.promptField)
            }
    }

    private func setRunning(_ running: Bool) {
        isRunning = running
        runButton.title = running ? "Stop" : "Run"
        promptField.isEnabled = !running; clearButton.isEnabled = !running; settingsButton.isEnabled = !running
    }

    @objc private func clearConversation() {
        guard !isRunning else { return }
        BrowserAgentService.shared.clearConversation(); refreshTranscript()
    }

    @objc private func closePressed() { prepareToHide(); onClose?() }

    private func refreshProviderLabel() {
        let p = AgentProviderKind.configured
        providerLabel.stringValue = "\(p.displayName) · \(Config.shared.agentModel)"
        if !isRunning { statusLabel.stringValue = Config.shared.agentEnabled ? "Ready · context stays in memory" : "Disabled in Settings" }
    }

    private func refreshTranscript() {
        guard !isRunning else { return }
        let messages = BrowserAgentService.shared.conversationSnapshot
        var text = "Facet Assistant\nContext stays in memory until Clear or quit. Private windows are excluded.\n"
        for message in messages {
            text += message.role == "user" ? "\nYou: \(message.text)\n" : "Assistant: \(message.text)\n"
        }
        transcript.string = text
        transcript.scrollToEndOfDocument(nil)
    }

    private func append(_ text: String) {
        transcript.textStorage?.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.textColor]))
        transcript.scrollToEndOfDocument(nil)
    }
}
