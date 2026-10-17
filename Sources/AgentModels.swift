import Foundation

struct AgentConversationMessage {
    let role: String
    let text: String
}

enum AgentApprovalDecision {
    case deny
    case allowOnce
    case allowForSite
    case allowSafeForTask
    /// Explicit, task-scoped "YOLO" mode. It skips future action approval prompts for
    /// the current run only; private-window exclusion, URL validation, and snapshot
    /// credential redaction remain enforced by the browser/tool layer.
    case allowAllForTask
}

struct AgentApprovalRequest {
    let tool: String
    let args: [String: Any]
    let site: String?
    let sensitive: Bool
}


struct AgentElement: Codable {
    let ref: String
    let role: String
    let name: String
    let value: String?
    let href: String?
    let disabled: Bool
    /// Choices for <select> elements, so the model can fill them by visible text.
    let options: [String]?
}

struct AgentPageSnapshot: Codable {
    let url: String
    let title: String
    let text: String
    let headings: [String]
    let elements: [AgentElement]
}

struct TabSemanticState {
    var title: String
    var url: String
    var text: String
    var headings: [String]
    var updatedAt: Date
}

struct AgentTabInfo: Codable {
    let id: String
    let title: String
    let url: String
    let active: Bool
    let sleeping: Bool
    let keepAwake: Bool
    let cachedText: String?
}

enum AgentToolError: Error, LocalizedError {
    case cancelled
    case tabNotFound
    case pageNotReady
    case elementNotFound(String)
    case javascript(String)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Stopped. Actions already completed were not undone."
        case .tabNotFound: return "Tab not found"
        case .pageNotReady: return "Page is not ready"
        case .elementNotFound(let ref): return "Element \(ref) was not found"
        case .javascript(let message): return "Page script failed: \(message)"
        case .invalidArgument(let message): return message
        }
    }
}
