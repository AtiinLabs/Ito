import Foundation
import Security

/// Keychain operations for plugin secrets, scoped to one Keychain service.
nonisolated public protocol PluginSecretKeychain: Sendable {
    func data(account: String) -> (OSStatus, Data?)
    /// Adds the item or replaces the value of an existing one.
    func setData(_ data: Data, account: String) -> OSStatus
    func delete(account: String) -> OSStatus
    func accounts() -> (OSStatus, [String])
    func deleteAll() -> OSStatus
}

nonisolated public struct SystemPluginSecretKeychain: PluginSecretKeychain {
    private let service: String

    public init(service: String = PluginSecretStore.productionService) {
        self.service = service
    }

    public func data(account: String) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func setData(_ data: Data, account: String) -> OSStatus {
        let status = SecItemUpdate(
            [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        guard status == errSecItemNotFound else { return status }
        return SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data
        ] as CFDictionary, nil)
    }

    public func delete(account: String) -> OSStatus {
        SecItemDelete(
            [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary
        )
    }

    public func accounts() -> (OSStatus, [String]) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll
        ] as CFDictionary, &result)
        let items = result as? [[String: Any]] ?? []
        return (status, items.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    public func deleteAll() -> OSStatus {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }
}

nonisolated public struct PluginSecretStoreError: Error, Equatable, LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        "The Keychain could not save the change (status \(status))."
    }
}

/// Values of plugin `Setting.secret` fields: API keys, passwords. They live in the Keychain and never
/// in the database, so backups don't carry them. Plugins read them through `defaults::get`, which
/// checks this store before the plain settings.
nonisolated public final class PluginSecretStore: @unchecked Sendable {
    public static let productionService = "moe.itoapp.ito.plugin-secret"
    /// The Keychain service of credentials plugins store themselves (`defaults::set_secret`).
    public static let tokenService = "moe.itoapp.ito.plugin-tokens"

    private let keychain: any PluginSecretKeychain
    private let lock = NSLock()
    private var beforeMutationHook: (@Sendable (String?) throws -> Void)?
    /// Values and known-missing entries by Keychain account. Plugins read settings on every call,
    /// image loads included, so each secret is read from the Keychain once.
    private var cache: [String: String?] = [:]

    public init(keychain: any PluginSecretKeychain = SystemPluginSecretKeychain()) {
        self.keychain = keychain
    }

    internal func configureBeforeMutation(_ hook: @escaping @Sendable (String?) throws -> Void) {
        lock.lock()
        defer { lock.unlock() }
        beforeMutationHook = hook
    }

    public func value(pluginID: String, key: String) -> String? {
        let account = Self.account(pluginID: pluginID, key: key)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[account] { return cached }
        let (status, data) = keychain.data(account: account)
        switch status {
        case errSecSuccess:
            let value = data.flatMap { String(data: $0, encoding: .utf8) }
            cache[account] = value
            return value
        case errSecItemNotFound:
            cache[account] = .some(nil)
            return nil
        default:
            // Typically a locked device during a background launch: unreadable now, not missing.
            return nil
        }
    }

    public func setValue(_ value: String, pluginID: String, key: String) throws {
        let account = Self.account(pluginID: pluginID, key: key)
        lock.lock()
        defer { lock.unlock() }
        try beforeMutationHook?(pluginID)
        let status = keychain.setData(Data(value.utf8), account: account)
        guard status == errSecSuccess else {
            cache.removeValue(forKey: account)
            throw PluginSecretStoreError(status: status)
        }
        cache[account] = value
    }

    public func removeValue(pluginID: String, key: String) throws {
        let account = Self.account(pluginID: pluginID, key: key)
        lock.lock()
        defer { lock.unlock() }
        try beforeMutationHook?(pluginID)
        let status = keychain.delete(account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            cache.removeValue(forKey: account)
            throw PluginSecretStoreError(status: status)
        }
        cache[account] = .some(nil)
    }

    /// Removes every secret of one plugin, for example when the user deletes the plugin.
    public func removeAll(pluginID: String) throws {
        let prefix = Self.account(pluginID: pluginID, key: "")
        lock.lock()
        defer { lock.unlock() }
        try beforeMutationHook?(pluginID)
        let (status, accounts) = keychain.accounts()
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PluginSecretStoreError(status: status)
        }
        for account in accounts where account.hasPrefix(prefix) {
            let deleteStatus = keychain.delete(account: account)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw PluginSecretStoreError(status: deleteStatus)
            }
        }
        for account in cache.keys where account.hasPrefix(prefix) {
            cache[account] = .some(nil)
        }
    }

    /// Removes every plugin secret.
    public func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try beforeMutationHook?(nil)
        let status = keychain.deleteAll()
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PluginSecretStoreError(status: status)
        }
        cache.removeAll()
    }

    internal func withConfigurationLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Holds the same lock as secret mutation while the caller captures its database scope/settings.
    internal func withSnapshot<T>(pluginID: String, _ body: ([String: String]) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let prefix = Self.account(pluginID: pluginID, key: "")
        let (status, accounts) = keychain.accounts()
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PluginSecretStoreError(status: status)
        }
        var values: [String: String] = [:]
        for account in accounts where account.hasPrefix(prefix) {
            let (readStatus, data) = keychain.data(account: account)
            if readStatus == errSecItemNotFound { continue }
            guard readStatus == errSecSuccess else { throw PluginSecretStoreError(status: readStatus) }
            guard let data, let value = String(data: data, encoding: .utf8) else {
                throw PluginSecretStoreError(status: errSecDecode)
            }
            values[String(account.dropFirst(prefix.count))] = value
        }
        return try body(values)
    }

    /// Plugin ids and setting ids never contain the unit separator.
    static func account(pluginID: String, key: String) -> String {
        "\(pluginID)\u{1F}\(key)"
    }
}
