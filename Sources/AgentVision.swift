import Foundation

extension BrowserAgentService {
    func visualInspect(tabID: String, question: String, session: BrowserAgentSession,
                       completion: @escaping (String) -> Void) {
        session.screenshot(id: tabID) { [weak self] result in
            guard let self, !session.isFinished else { return }
            switch result {
            case .failure(let error): completion("ERROR: \(error.localizedDescription)")
            case .success(let jpeg):
                let base64 = jpeg.base64EncodedString()
                let provider = AgentProviderKind.configured
                switch provider {
                case .openAI:
                    guard let key = self.visionAPIKey(provider) else { completion("ERROR: OpenAI credential unavailable"); return }
                    self.openAIVision(base64: base64, question: question, token: key, session: session, completion: completion)
                case .anthropic:
                    guard let key = self.visionAPIKey(provider) else { completion("ERROR: Anthropic credential unavailable"); return }
                    self.anthropicVision(base64: base64, question: question, auth: .apiKey(key), session: session, completion: completion)
                case .openAIOAuth:
                    AgentOAuthManager.shared.withValidAccessToken(for: provider) { token in
                        guard !session.isFinished else { return }
                        switch token {
                        case .success(let value): self.openAIVision(base64: base64, question: question, token: value, session: session, completion: completion)
                        case .failure(let error): completion("ERROR: \(error.localizedDescription)")
                        }
                    }
                case .anthropicOAuth:
                    AgentOAuthManager.shared.withValidAccessToken(for: provider) { token in
                        guard !session.isFinished else { return }
                        switch token {
                        case .success(let value): self.anthropicVision(base64: base64, question: question, auth: .bearer(value), session: session, completion: completion)
                        case .failure(let error): completion("ERROR: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    private func visionAPIKey(_ provider: AgentProviderKind) -> String? {
        if let value = apiKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        let name = provider.usesAnthropicProtocol ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY"
        return ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func openAIVision(base64: String, question: String, token: String,
                              session: BrowserAgentSession, completion: @escaping (String) -> Void) {
        guard let url = AgentEndpoint.openAI(Config.shared.agentBaseURL) else { completion("ERROR: Invalid OpenAI endpoint"); return }
        let prompt = question.isEmpty ? "Describe the visible browser page and identify controls relevant to the current task." : question
        let body: [String: Any] = [
            "model": Config.shared.agentModel,
            "input": [["role": "user", "content": [
                ["type": "input_image", "image_url": "data:image/jpeg;base64,\(base64)", "detail": "auto"],
                ["type": "input_text", "text": prompt]
            ]]],
            "max_output_tokens": 900,
            "store": false
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { completion("ERROR: Could not encode visual request"); return }
        request.httpBody = data
        session.perform(request) { data, response, error in
            if let error { completion("ERROR: \(error.localizedDescription)"); return }
            guard let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { completion("ERROR: Invalid visual response"); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let message = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
                completion("ERROR: Visual inspection unavailable for this model/endpoint: \(message)"); return
            }
            let output = obj["output"] as? [[String: Any]] ?? []
            var text: [String] = []
            for item in output where (item["type"] as? String) == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] where (part["type"] as? String) == "output_text" {
                    if let value = part["text"] as? String { text.append(value) }
                }
            }
            completion(text.isEmpty ? "Visual inspection returned no text." : text.joined(separator: "\n"))
        }
    }

    private func anthropicVision(base64: String, question: String, auth: AgentAnthropicAuth,
                                 session: BrowserAgentSession, completion: @escaping (String) -> Void) {
        guard let url = AgentEndpoint.anthropic(Config.shared.agentBaseURL) else { completion("ERROR: Invalid Anthropic endpoint"); return }
        let prompt = question.isEmpty ? "Describe the visible browser page and identify controls relevant to the current task." : question
        let body: [String: Any] = [
            "model": Config.shared.agentModel,
            "max_tokens": 900,
            "messages": [["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]],
                ["type": "text", "text": prompt]
            ]]]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 90
        auth.apply(to: &request)
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { completion("ERROR: Could not encode visual request"); return }
        request.httpBody = data
        session.perform(request) { data, response, error in
            if let error { completion("ERROR: \(error.localizedDescription)"); return }
            guard let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { completion("ERROR: Invalid visual response"); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let message = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
                completion("ERROR: Visual inspection unavailable for this model/endpoint: \(message)"); return
            }
            let text = (obj["content"] as? [[String: Any]] ?? []).compactMap { item -> String? in
                guard (item["type"] as? String) == "text" else { return nil }
                return item["text"] as? String
            }.joined(separator: "\n")
            completion(text.isEmpty ? "Visual inspection returned no text." : text)
        }
    }
}
