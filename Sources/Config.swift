import Foundation
import Darwin

/// User-editable settings, read from ~/Library/Application Support/Facet/config.json
/// Missing file => defaults. Nothing here requires a rebuild to change.
final class Config {
    static let shared = Config()

    var searchTemplate: String = "https://www.google.com/search?q=%s"
    var homepage: String = "about:blank"
    /// Minutes a background tab may sit before its web process is destroyed. 0 = never.
    var hibernateAfterMinutes: Double = 5
    /// Hibernate every background tab immediately when the OS reports memory pressure.
    var hibernateOnMemoryPressure: Bool = true
    var blockAdsAndTrackers: Bool = true
    var restoreSessionOnLaunch: Bool = true
    var showMemoryReadout: Bool = true
    var enableDeveloperTools: Bool = true

    /// App-global target. 0 disables budget enforcement.
    var memoryBudgetMB: Int = 1536

    /// Agent provider preferences. API keys are never written here; direct providers read
    /// their environment variable or an in-memory key entered in the Agent window.
    var agentEnabled: Bool = true
    /// openai | anthropic | openai_oauth | anthropic_oauth
    var agentProvider: String = "openai"
    /// Base URL or full inference endpoint. Provider adapters append /responses or /messages when needed.
    var agentBaseURL: String = "https://api.openai.com/v1"
    var agentModel: String = "gpt-5.6-luna"
    var agentMaxLiveTabs: Int = 1

    // OAuth client metadata is not secret and may be persisted. Access and refresh tokens
    // are stored only in the macOS Keychain by AgentOAuthManager. Facet intentionally
    // ships without first-party subscription client IDs; use provider-issued/approved values.
    var agentOpenAIOAuthAuthorizationURL: String = ""
    var agentOpenAIOAuthTokenURL: String = ""
    var agentOpenAIOAuthClientID: String = ""
    var agentOpenAIOAuthScopes: String = ""
    var agentAnthropicOAuthAuthorizationURL: String = ""
    var agentAnthropicOAuthTokenURL: String = ""
    var agentAnthropicOAuthClientID: String = ""
    var agentAnthropicOAuthScopes: String = ""

    static var supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Facet", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private var fileURL: URL { Config.supportDir.appendingPathComponent("config.json") }

    private init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            save()  // materialize the file so it is discoverable and editable
            return
        }
        if let v = d["searchTemplate"] as? String { searchTemplate = v }
        if let v = d["homepage"] as? String { homepage = v }
        if let v = d["hibernateAfterMinutes"] as? Double { hibernateAfterMinutes = v }
        if let v = d["hibernateOnMemoryPressure"] as? Bool { hibernateOnMemoryPressure = v }
        if let v = d["blockAdsAndTrackers"] as? Bool { blockAdsAndTrackers = v }
        if let v = d["restoreSessionOnLaunch"] as? Bool { restoreSessionOnLaunch = v }
        if let v = d["showMemoryReadout"] as? Bool { showMemoryReadout = v }
        if let v = d["enableDeveloperTools"] as? Bool { enableDeveloperTools = v }
        if let v = d["memoryBudgetMB"] as? Int { memoryBudgetMB = max(0, v) }
        if let v = d["agentEnabled"] as? Bool { agentEnabled = v }
        if let v = d["agentProvider"] as? String { agentProvider = v }
        if let v = d["agentBaseURL"] as? String { agentBaseURL = v }
        if let v = d["agentModel"] as? String { agentModel = v }
        if let v = d["agentMaxLiveTabs"] as? Int { agentMaxLiveTabs = max(1, min(4, v)) }
        if let v = d["agentOpenAIOAuthAuthorizationURL"] as? String { agentOpenAIOAuthAuthorizationURL = v }
        if let v = d["agentOpenAIOAuthTokenURL"] as? String { agentOpenAIOAuthTokenURL = v }
        if let v = d["agentOpenAIOAuthClientID"] as? String { agentOpenAIOAuthClientID = v }
        if let v = d["agentOpenAIOAuthScopes"] as? String { agentOpenAIOAuthScopes = v }
        if let v = d["agentAnthropicOAuthAuthorizationURL"] as? String { agentAnthropicOAuthAuthorizationURL = v }
        if let v = d["agentAnthropicOAuthTokenURL"] as? String { agentAnthropicOAuthTokenURL = v }
        if let v = d["agentAnthropicOAuthClientID"] as? String { agentAnthropicOAuthClientID = v }
        if let v = d["agentAnthropicOAuthScopes"] as? String { agentAnthropicOAuthScopes = v }
    }

    func save() {
        let d: [String: Any] = [
            "searchTemplate": searchTemplate,
            "homepage": homepage,
            "hibernateAfterMinutes": hibernateAfterMinutes,
            "hibernateOnMemoryPressure": hibernateOnMemoryPressure,
            "blockAdsAndTrackers": blockAdsAndTrackers,
            "restoreSessionOnLaunch": restoreSessionOnLaunch,
            "showMemoryReadout": showMemoryReadout,
            "enableDeveloperTools": enableDeveloperTools,
            "memoryBudgetMB": memoryBudgetMB,
            "agentEnabled": agentEnabled,
            "agentProvider": agentProvider,
            "agentBaseURL": agentBaseURL,
            "agentModel": agentModel,
            "agentMaxLiveTabs": agentMaxLiveTabs,
            "agentOpenAIOAuthAuthorizationURL": agentOpenAIOAuthAuthorizationURL,
            "agentOpenAIOAuthTokenURL": agentOpenAIOAuthTokenURL,
            "agentOpenAIOAuthClientID": agentOpenAIOAuthClientID,
            "agentOpenAIOAuthScopes": agentOpenAIOAuthScopes,
            "agentAnthropicOAuthAuthorizationURL": agentAnthropicOAuthAuthorizationURL,
            "agentAnthropicOAuthTokenURL": agentAnthropicOAuthTokenURL,
            "agentAnthropicOAuthClientID": agentAnthropicOAuthClientID,
            "agentAnthropicOAuthScopes": agentAnthropicOAuthScopes,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Turn whatever the user typed into something loadable: URL, bare host, or search.
    func resolve(input raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }

        if s.lowercased().hasPrefix("about:") || s.lowercased().hasPrefix("file:") { return URL(string: s) }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(),
           scheme == "http" || scheme == "https", u.host != nil { return u }

        // Parse the authority separately so query strings, fragments, IP literals, and ports work.
        if !s.contains(where: { $0.isWhitespace }),
           var parts = URLComponents(string: "https://" + s),
           let rawHost = parts.host, parts.user == nil, parts.password == nil,
           parts.port.map({ (1...65535).contains($0) }) ?? true {
            let host = rawHost.lowercased()
            let unbracketed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            var ipv4 = in_addr(), ipv6 = in6_addr()
            let isIP = unbracketed.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
            let isLocal = host == "localhost" || host.hasSuffix(".localhost")
            let isDomain = host.range(of: #"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}\.?$"#, options: .regularExpression) != nil
            if isIP || isLocal || isDomain {
                parts.scheme = (isIP || isLocal) ? "http" : "https"
                if let url = parts.url { return url }
            }
        }

        let q = s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? s
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: q))
    }
}
