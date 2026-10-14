import AppKit
import CryptoKit
import Foundation
import Security

struct AgentOAuthConfiguration {
    let authorizationURL: String
    let tokenURL: String
    let clientID: String
    let scopes: String
    let redirectURI = "facet://oauth/callback"

    var isComplete: Bool {
        !authorizationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !tokenURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct AgentOAuthToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var tokenType: String
    var expiresAt: Date?

    var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 90
    }
}

/// Standards-based OAuth 2.0 Authorization Code + PKCE client for native macOS use.
/// Facet does not embed or imitate first-party Codex/Claude OAuth client IDs.
final class AgentOAuthManager {
    static let shared = AgentOAuthManager()

    private struct Pending {
        let provider: AgentProviderKind
        let config: AgentOAuthConfiguration
        let state: String
        let verifier: String
        let completion: (Result<Void, Error>) -> Void
    }

    private let keychainService = "com.facet.browser.agent.oauth"
    private var pending: Pending?

    private init() {}

    func configuration(for provider: AgentProviderKind) -> AgentOAuthConfiguration? {
        switch provider {
        case .openAIOAuth:
            return AgentOAuthConfiguration(
                authorizationURL: Config.shared.agentOpenAIOAuthAuthorizationURL,
                tokenURL: Config.shared.agentOpenAIOAuthTokenURL,
                clientID: Config.shared.agentOpenAIOAuthClientID,
                scopes: Config.shared.agentOpenAIOAuthScopes)
        case .anthropicOAuth:
            return AgentOAuthConfiguration(
                authorizationURL: Config.shared.agentAnthropicOAuthAuthorizationURL,
                tokenURL: Config.shared.agentAnthropicOAuthTokenURL,
                clientID: Config.shared.agentAnthropicOAuthClientID,
                scopes: Config.shared.agentAnthropicOAuthScopes)
        default:
            return nil
        }
    }

    func isConnected(_ provider: AgentProviderKind) -> Bool { loadToken(provider) != nil }

    func disconnect(_ provider: AgentProviderKind) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }

    func beginLogin(provider: AgentProviderKind, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let config = configuration(for: provider), config.isComplete else {
            completion(.failure(AgentToolError.invalidArgument("OAuth client configuration is incomplete")))
            return
        }
        guard pending == nil else {
            completion(.failure(AgentToolError.invalidArgument("An OAuth login is already in progress")))
            return
        }
        guard let authBase = URL(string: config.authorizationURL) else {
            completion(.failure(AgentToolError.invalidArgument("Invalid OAuth authorization URL")))
            return
        }
        let verifier = Self.randomURLSafe(bytes: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(bytes: 24)
        var comps = URLComponents(url: authBase, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        if !config.scopes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "scope", value: config.scopes))
        }
        comps?.queryItems = items
        guard let url = comps?.url else {
            completion(.failure(AgentToolError.invalidArgument("Could not construct OAuth authorization URL")))
            return
        }
        pending = Pending(provider: provider, config: config, state: state, verifier: verifier, completion: completion)
        NSWorkspace.shared.open(url)
    }

    /// Returns true when the URL belongs to Facet's OAuth callback and was consumed.
    func handleCallback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "facet", url.host?.lowercased() == "oauth",
              url.path == "/callback" else { return false }
        guard let pending else { return true }
        self.pending = nil
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        if let error = value("error") {
            let desc = value("error_description") ?? error
            pending.completion(.failure(AgentToolError.javascript("OAuth authorization failed: \(desc)")))
            return true
        }
        guard value("state") == pending.state, let code = value("code"), !code.isEmpty else {
            pending.completion(.failure(AgentToolError.javascript("OAuth callback state/code was invalid")))
            return true
        }
        exchangeCode(code, pending: pending)
        return true
    }

    func withValidAccessToken(for provider: AgentProviderKind, completion: @escaping (Result<String, Error>) -> Void) {
        guard let token = loadToken(provider) else {
            completion(.failure(AgentToolError.invalidArgument("OAuth is not connected")))
            return
        }
        if token.needsRefresh, let refresh = token.refreshToken, !refresh.isEmpty {
            refreshToken(refresh, provider: provider, old: token, completion: completion)
        } else {
            completion(.success(token.accessToken))
        }
    }

    private func exchangeCode(_ code: String, pending: Pending) {
        let params = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": pending.config.redirectURI,
            "client_id": pending.config.clientID,
            "code_verifier": pending.verifier
        ]
        tokenRequest(urlString: pending.config.tokenURL, params: params) { result in
            switch result {
            case .failure(let error): pending.completion(.failure(error))
            case .success(let token):
                do { try self.saveToken(token, provider: pending.provider); pending.completion(.success(())) }
                catch { pending.completion(.failure(error)) }
            }
        }
    }

    private func refreshToken(_ refresh: String, provider: AgentProviderKind, old: AgentOAuthToken,
                              completion: @escaping (Result<String, Error>) -> Void) {
        guard let config = configuration(for: provider), config.isComplete else {
            completion(.failure(AgentToolError.invalidArgument("OAuth client configuration is incomplete")))
            return
        }
        let params = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": config.clientID
        ]
        tokenRequest(urlString: config.tokenURL, params: params) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(var token):
                if token.refreshToken == nil { token.refreshToken = old.refreshToken }
                do { try self.saveToken(token, provider: provider); completion(.success(token.accessToken)) }
                catch { completion(.failure(error)) }
            }
        }
    }

    private func tokenRequest(urlString: String, params: [String: String],
                              completion: @escaping (Result<AgentOAuthToken, Error>) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure(AgentToolError.invalidArgument("Invalid OAuth token URL"))); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncode(params).data(using: .utf8)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard let data else { DispatchQueue.main.async { completion(.failure(AgentToolError.javascript("Empty OAuth token response"))) }; return }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code), let access = obj?["access_token"] as? String, !access.isEmpty else {
                let message = (obj?["error_description"] as? String) ?? (obj?["error"] as? String) ?? String(data: data, encoding: .utf8) ?? "HTTP \(code)"
                DispatchQueue.main.async { completion(.failure(AgentToolError.javascript("OAuth token exchange failed: \(message)"))) }
                return
            }
            let expiresAt: Date?
            if let seconds = obj?["expires_in"] as? Double { expiresAt = Date().addingTimeInterval(seconds) }
            else if let seconds = obj?["expires_in"] as? Int { expiresAt = Date().addingTimeInterval(TimeInterval(seconds)) }
            else { expiresAt = nil }
            let token = AgentOAuthToken(accessToken: access, refreshToken: obj?["refresh_token"] as? String,
                                        tokenType: obj?["token_type"] as? String ?? "Bearer", expiresAt: expiresAt)
            DispatchQueue.main.async { completion(.success(token)) }
        }.resume()
    }

    private func saveToken(_ token: AgentOAuthToken, provider: AgentProviderKind) throws {
        let data = try JSONEncoder().encode(token)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider.rawValue
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AgentToolError.javascript("Could not save OAuth token to Keychain (\(status))") }
    }

    private func loadToken(_ provider: AgentProviderKind) -> AgentOAuthToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AgentOAuthToken.self, from: data)
    }

    private static func randomURLSafe(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, bytes, raw.baseAddress!)
        }
        return base64URL(data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ params: [String: String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return params.sorted(by: { $0.key < $1.key }).map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
