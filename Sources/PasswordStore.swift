import Foundation
import Security
import LocalAuthentication

/// One saved website login. The password is present only when explicitly read for autofill
/// or after the user authenticates to reveal it.
struct SavedLogin: Equatable {
    var host: String
    var username: String
    var password: String
    /// When it was last saved or updated, for choosing which login to offer first.
    var updated: Date = Date()
}

/// Where saved logins actually live. The real backend is the macOS Keychain; tests install
/// an in-memory one so they never touch the user's Keychain.
protocol PasswordBackend: AnyObject {
    func all() -> [SavedLogin]
    func password(host: String, username: String) -> String?
    func set(_ login: SavedLogin)
    func remove(host: String, username: String)
}

/// Saved website logins, Chrome's password manager done natively. Passwords are kept only in
/// the macOS Keychain, never in Facet's plain-text config or any file Facet writes. Facet
/// does not sync them and never logs a password value.
final class PasswordStore {
    static let shared = PasswordStore()
    private var backend: PasswordBackend = KeychainPasswordBackend()

    private init() {}

    /// Swap in a throwaway in-memory store. Tests call this so the real Keychain is untouched.
    func installTestBackend() { backend = InMemoryPasswordBackend() }

    /// Logins and site settings key sites the same way, so m.site.com and www.site.com share
    /// one login, as they share a zoom level.
    static func key(for host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func key(for url: URL?) -> String? { key(for: url?.host) }

    /// Usernames saved for a site, newest first, without their passwords.
    func logins(for url: URL?) -> [SavedLogin] {
        guard let site = Self.key(for: url) else { return [] }
        return backend.all().filter { $0.host == site }.sorted { $0.updated > $1.updated }
    }

    /// The password for one saved login, read from the Keychain only when autofilling or
    /// revealing. Returns nil if it is gone.
    func password(for url: URL?, username: String) -> String? {
        guard let site = Self.key(for: url) else { return nil }
        return backend.password(host: site, username: username)
    }

    /// Every saved login, by site then username, for the manager. Passwords are left blank
    /// until revealed.
    func allLogins() -> [SavedLogin] {
        backend.all().map { SavedLogin(host: $0.host, username: $0.username, password: "", updated: $0.updated) }
            .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    func isSaved(url: URL?, username: String) -> Bool {
        guard let site = Self.key(for: url) else { return false }
        return backend.all().contains { $0.host == site && $0.username == username }
    }

    @discardableResult
    func save(url: URL?, username: String, password: String) -> Bool {
        guard let site = Self.key(for: url), !password.isEmpty else { return false }
        backend.set(SavedLogin(host: site, username: username, password: password, updated: Date()))
        NotificationCenter.default.post(name: .facetPasswordsChanged, object: nil)
        return true
    }

    /// Saves a login keyed by a bare host, for importing from another browser.
    @discardableResult
    func saveImported(host: String, username: String, password: String, updated: Date) -> Bool {
        guard let site = Self.key(for: host), !password.isEmpty else { return false }
        // Keep whichever copy is newer when the same login is imported twice.
        if let existing = backend.all().first(where: { $0.host == site && $0.username == username }),
           existing.updated >= updated, backend.password(host: site, username: username) == password { return false }
        backend.set(SavedLogin(host: site, username: username, password: password, updated: updated))
        return true
    }

    func remove(host: String, username: String) {
        backend.remove(host: host, username: username)
        NotificationCenter.default.post(name: .facetPasswordsChanged, object: nil)
    }

    // MARK: - Decisions (pure, so they are testable without a page)

    enum SaveDecision: Equatable { case ignore, save, update }

    /// What to do when a login is submitted: nothing if it is already saved unchanged, update
    /// if the password for a known username changed, otherwise offer to save.
    func decision(url: URL?, username: String, password: String) -> SaveDecision {
        guard Self.key(for: url) != nil, !password.isEmpty, !username.isEmpty else { return .ignore }
        guard isSaved(url: url, username: username) else { return .save }
        return self.password(for: url, username: username) == password ? .ignore : .update
    }

    /// Reveal/copy guard: ask macOS to confirm the user (Touch ID or password) before a stored
    /// password is shown. Without biometrics/local auth available it still asks for the login
    /// password. Falls open only when no authentication is possible at all.
    func authenticateToReveal(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(true); return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

extension Notification.Name {
    static let facetPasswordsChanged = Notification.Name("FacetPasswordsChanged")
}

/// macOS Keychain storage, namespaced to Facet so enumeration never returns other apps'
/// items. Accessible only when the Mac is unlocked, and never synced to iCloud.
final class KeychainPasswordBackend: PasswordBackend {
    private let service = "com.facet.browser.passwords"

    /// account = "<host>\n<username>"; a host never contains a newline, so the split is safe.
    private func account(_ host: String, _ username: String) -> String { "\(host)\n\(username)" }
    private func split(_ account: String) -> (host: String, username: String)? {
        guard let i = account.firstIndex(of: "\n") else { return nil }
        return (String(account[..<i]), String(account[account.index(after: i)...]))
    }

    func all() -> [SavedLogin] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String, let parts = split(account) else { return nil }
            let updated = (item[kSecAttrModificationDate as String] as? Date) ?? .distantPast
            return SavedLogin(host: parts.host, username: parts.username, password: "", updated: updated)
        }
    }

    func password(host: String, username: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host, username),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ login: SavedLogin) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(login.host, login.username),
        ]
        let data = Data(login.password.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrLabel as String] = "Facet \u{2014} \(login.host)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func remove(host: String, username: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host, username),
        ] as CFDictionary)
    }
}

/// Test-only store. Holds logins in memory for the life of the process, never the Keychain.
final class InMemoryPasswordBackend: PasswordBackend {
    private var items: [String: SavedLogin] = [:]
    private func key(_ host: String, _ username: String) -> String { "\(host)\n\(username)" }
    func all() -> [SavedLogin] { Array(items.values) }
    func password(host: String, username: String) -> String? { items[key(host, username)]?.password }
    func set(_ login: SavedLogin) { items[key(login.host, login.username)] = login }
    func remove(host: String, username: String) { items[key(host, username)] = nil }
}
