import Foundation

enum AgentProviderKind: String, CaseIterable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case openAIOAuth = "openai_oauth"
    case anthropicOAuth = "anthropic_oauth"

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI-compatible API key"
        case .anthropic: return "Anthropic-compatible API key"
        case .openAIOAuth: return "OpenAI OAuth (PKCE)"
        case .anthropicOAuth: return "Anthropic OAuth (PKCE)"
        }
    }

    var needsAPIKey: Bool { self == .openAI || self == .anthropic }
    var usesOAuth: Bool { self == .openAIOAuth || self == .anthropicOAuth }
    var usesAnthropicProtocol: Bool { self == .anthropic || self == .anthropicOAuth }

    var defaultBaseURL: String {
        usesAnthropicProtocol ? "https://api.anthropic.com/v1" : "https://api.openai.com/v1"
    }

    var defaultModel: String {
        usesAnthropicProtocol ? "claude-sonnet-5" : "gpt-5.6-luna"
    }

    static var configured: AgentProviderKind {
        // Migrate the short-lived CLI provider names to their OAuth replacements.
        switch Config.shared.agentProvider {
        case "codex_subscription": return .openAIOAuth
        case "claude_subscription": return .anthropicOAuth
        default: return AgentProviderKind(rawValue: Config.shared.agentProvider) ?? .openAI
        }
    }
}

enum AgentEndpoint {
    static func openAI(_ raw: String) -> URL? { normalized(raw, suffix: "/responses") }
    static func anthropic(_ raw: String) -> URL? { normalized(raw, suffix: "/messages") }

    private static func normalized(_ raw: String, suffix: String) -> URL? {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        // Never transmit API credentials over plaintext to a remote host. Local providers remain supported.
        if scheme == "http" && !["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()) { return nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if !parts.path.hasSuffix(suffix) { parts.path += suffix }
        return parts.url
    }
}

enum AgentAnthropicAuth {
    case apiKey(String)
    case bearer(String)

    func apply(to request: inout URLRequest) {
        switch self {
        case .apiKey(let key): request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .bearer(let token): request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}

extension BrowserAgentService {
    func runAnthropic(messages: [[String: Any]], auth: AgentAnthropicAuth, session: BrowserAgentSession,
                      status: @escaping (String) -> Void,
                      completion: @escaping (Result<String, Error>) -> Void) {
        anthropicStep(messages: messages, auth: auth, session: session, iteration: 0,
                      status: status, completion: completion)
    }

    private func anthropicStep(messages: [[String: Any]], auth: AgentAnthropicAuth,
                               session: BrowserAgentSession, iteration: Int,
                               status: @escaping (String) -> Void,
                               completion: @escaping (Result<String, Error>) -> Void) {
        guard !session.isFinished else { return }
        guard iteration < 24 else {
            completion(.failure(AgentToolError.javascript("Agent exceeded 24 tool steps"))); return
        }
        guard let endpoint = AgentEndpoint.anthropic(Config.shared.agentBaseURL) else {
            completion(.failure(AgentToolError.invalidArgument("Invalid Anthropic endpoint"))); return
        }
        status(iteration == 0 ? "Thinking…" : "Working…")
        let anthropicTools = Self.tools.map { tool -> [String: Any] in
            ["name": tool["name"] as? String ?? "",
             "description": tool["description"] as? String ?? "",
             "input_schema": tool["parameters"] as? [String: Any] ?? [:]]
        }
        let body: [String: Any] = [
            "model": Config.shared.agentModel,
            "system": Self.systemPrompt,
            "messages": messages,
            "tools": anthropicTools,
            "max_tokens": 2500
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        auth.apply(to: &req)
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        catch { completion(.failure(error)); return }

        session.perform(req) { [weak self] data, response, error in
            if let error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard let data else {
                DispatchQueue.main.async { completion(.failure(AgentToolError.javascript("Empty Anthropic response"))) }; return
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(code) {
                let msg = ((obj?["error"] as? [String: Any])?["message"] as? String)
                    ?? String(data: data, encoding: .utf8) ?? "HTTP \(code)"
                DispatchQueue.main.async { completion(.failure(AgentToolError.javascript(msg))) }
                return
            }
            guard let self, let content = obj?["content"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion(.failure(AgentToolError.javascript("Invalid Anthropic response"))) }; return
            }
            DispatchQueue.main.async {
                guard !session.isFinished else { return }
                let calls = content.filter { ($0["type"] as? String) == "tool_use" }
                if calls.isEmpty {
                    let text = content.compactMap { item -> String? in
                        guard (item["type"] as? String) == "text" else { return nil }
                        return item["text"] as? String
                    }.joined(separator: "\n")
                    completion(.success(text.isEmpty ? "Done." : text)); return
                }
                self.executeAnthropicCalls(calls, index: 0, session: session, status: status) { results in
                    var next = messages
                    next.append(["role": "assistant", "content": content])
                    next.append(["role": "user", "content": results])
                    self.anthropicStep(messages: next, auth: auth, session: session, iteration: iteration + 1,
                                       status: status, completion: completion)
                }
            }
        }
    }

    private func executeAnthropicCalls(_ calls: [[String: Any]], index: Int,
                                       session: BrowserAgentSession, status: @escaping (String) -> Void,
                                       completion: @escaping ([[String: Any]]) -> Void,
                                       accumulated: [[String: Any]] = []) {
        guard !session.isFinished else { return }
        guard index < calls.count else { completion(accumulated); return }
        let call = calls[index]
        let name = call["name"] as? String ?? ""
        let id = call["id"] as? String ?? ""
        let args = call["input"] as? [String: Any] ?? [:]
        status("Agent: \(name.replacingOccurrences(of: "_", with: " "))")
        executeTool(name: name, args: args, session: session) { [weak self] output in
            guard let self else { return }
            let item: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": output]
            self.executeAnthropicCalls(calls, index: index + 1, session: session, status: status,
                                       completion: completion, accumulated: accumulated + [item])
        }
    }
}
