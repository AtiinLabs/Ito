import Foundation
import Security
@testable import Ito

/// A Keychain stand-in for plugin secrets. `failingStatus`, when set, is returned by every call.
nonisolated final class InMemoryPluginSecretKeychain: PluginSecretKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var failure: OSStatus?
    private var reads = 0

    var failingStatus: OSStatus? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    var storedAccounts: Set<String> { lock.withLock { Set(items.keys) } }
    var readCount: Int { lock.withLock { reads } }

    func data(account: String) -> (OSStatus, Data?) {
        lock.withLock {
            reads += 1
            if let failure { return (failure, nil) }
            guard let data = items[account] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }

    func setData(_ data: Data, account: String) -> OSStatus {
        lock.withLock {
            if let failure { return failure }
            items[account] = data
            return errSecSuccess
        }
    }

    func delete(account: String) -> OSStatus {
        lock.withLock {
            if let failure { return failure }
            return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    func accounts() -> (OSStatus, [String]) {
        lock.withLock {
            if let failure { return (failure, []) }
            return items.isEmpty ? (errSecItemNotFound, []) : (errSecSuccess, Array(items.keys))
        }
    }

    func deleteAll() -> OSStatus {
        lock.withLock {
            if let failure { return failure }
            let hadItems = !items.isEmpty
            items.removeAll()
            return hadItems ? errSecSuccess : errSecItemNotFound
        }
    }
}
