import CryptoKit
import Foundation
import Security

/// A server certificate a source met that the device doesn't trust, waiting for the user to
/// confirm it.
nonisolated public struct PendingTrust: Equatable, Identifiable, Sendable {
    public let pluginID: String
    public let host: String
    /// Uppercase hex SHA-256 of the server's leaf certificate.
    public let fingerprint: String

    /// Includes the fingerprint, so a rotated certificate is a new confirmation, not the same one.
    public var id: String { pluginID + "\u{1F}" + host + "\u{1F}" + fingerprint }

    /// The fingerprint as people compare it: byte pairs separated by colons.
    public var displayFingerprint: String {
        let characters = Array(fingerprint)
        return stride(from: 0, to: characters.count, by: 2)
            .map { String(characters[$0..<min($0 + 2, characters.count)]) }
            .joined(separator: ":")
    }
}

nonisolated public enum PluginTrustConfirmationError: Error, Equatable, Sendable {
    case invalidIdentity
    case staleRequest
    case revoked
}

/// Certificates the user trusted for self-hosted servers, per source and host, kept in the
/// Keychain. Only a certificate the device itself rejects consults this store; a valid
/// certificate is never affected.
nonisolated public final class PluginTrustStore: @unchecked Sendable {
    public static let productionService = "moe.itoapp.ito.plugin-tls-trust"

    private let keychain: any PluginSecretKeychain
    private let lock = NSLock()
    /// Pinned fingerprints by plugin id, then host; each plugin's item is read once.
    private var cache: [String: [String: String]] = [:]
    /// The latest certificate each source was refused, until the user decides.
    private var pending: [String: PendingTrust] = [:]
    /// Sources whose pins are revoked: a failed Keychain delete keeps them blocked for this launch.
    private var blockedPlugins: Set<String> = []
    /// Set while a failed first-run cleanup may have left an earlier installation's pins behind.
    private var allTrustBlocked = false
    /// Changes whenever a source's trust changes, so transports never reuse a connection a
    /// different trust decision authenticated.
    private var generations: [String: UUID] = [:]
    /// Called, outside `lock`, whenever a source's trust generation changes.
    private var observers: [String: [UUID: @Sendable () -> Void]] = [:]

    public init(keychain: any PluginSecretKeychain = SystemPluginSecretKeychain(service: PluginTrustStore.productionService)) {
        self.keychain = keychain
    }

    public func pinnedFingerprint(pluginID: String, host: String) -> String? {
        guard !pluginID.isEmpty, let host = Self.normalizedHost(host) else { return nil }
        return lock.withLock {
            guard !allTrustBlocked, !blockedPlugins.contains(pluginID) else { return nil }
            return (try? load(pluginID))?[host]
        }
    }

    /// Trusts a fingerprint for this source and host, replacing any earlier certificate.
    public func trust(fingerprint: String, host: String, pluginID: String) throws {
        let changed = try lock.withLock {
            try save(fingerprint: fingerprint, host: host, pluginID: pluginID)
            return changeObservers(of: pluginID)
        }
        changed.forEach { $0() }
    }

    /// A confirmation only accepts the exact certificate currently waiting for this source. A
    /// late background/image challenge cannot change what a visible confirmation approves.
    public func confirm(_ request: PendingTrust) throws {
        let changed = try lock.withLock {
            guard pending[request.pluginID] == request else { throw PluginTrustConfirmationError.staleRequest }
            try save(fingerprint: request.fingerprint, host: request.host, pluginID: request.pluginID)
            pending[request.pluginID] = nil
            return changeObservers(of: request.pluginID)
        }
        changed.forEach { $0() }
    }

    /// Callers hold `lock`. Publish the cache only after the Keychain accepted the pin.
    private func save(fingerprint: String, host: String, pluginID: String) throws {
        guard !pluginID.isEmpty, let host = Self.normalizedHost(host), !fingerprint.isEmpty else {
            throw PluginTrustConfirmationError.invalidIdentity
        }
        guard !allTrustBlocked, !blockedPlugins.contains(pluginID) else { throw PluginTrustConfirmationError.revoked }
        var pins = try load(pluginID)
        pins[host] = fingerprint.uppercased()
        let status = keychain.setData(try JSONEncoder().encode(pins), account: pluginID)
        guard status == errSecSuccess else {
            cache.removeValue(forKey: pluginID)
            throw PluginSecretStoreError(status: status)
        }
        cache[pluginID] = pins
        generations[pluginID] = UUID()
    }

    /// Revokes this source's pins in memory first, so they stop authorizing connections even if
    /// the Keychain delete fails. Only an installation publication after a successful delete
    /// (`activateInstalledPlugin`) lets the source trust certificates again.
    public func removeAll(pluginID: String) throws {
        // Observers hear about the revocation even when the Keychain delete then fails.
        var changed: [@Sendable () -> Void] = []
        defer { changed.forEach { $0() } }
        try lock.withLock {
            blockedPlugins.insert(pluginID)
            generations[pluginID] = UUID()
            changed = changeObservers(of: pluginID)
            pending[pluginID] = nil
            let status = keychain.delete(account: pluginID)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                cache.removeValue(forKey: pluginID)
                throw PluginSecretStoreError(status: status)
            }
            cache[pluginID] = [:]
        }
    }

    /// A failure leaves every source's pins unusable until a later cleanup succeeds.
    public func removeEveryPlugin() throws {
        var changed: [@Sendable () -> Void] = []
        defer { changed.forEach { $0() } }
        try lock.withLock {
            allTrustBlocked = true
            generations.removeAll()
            changed = observers.values.flatMap { Array($0.values) }
            pending.removeAll()
            let status = keychain.deleteAll()
            guard status == errSecSuccess || status == errSecItemNotFound else {
                cache.removeAll()
                throw PluginSecretStoreError(status: status)
            }
            cache.removeAll()
            blockedPlugins.removeAll()
            allTrustBlocked = false
        }
    }

    public func recordPending(_ request: PendingTrust) {
        lock.withLock {
            guard !allTrustBlocked, !blockedPlugins.contains(request.pluginID) else { return }
            pending[request.pluginID] = request
        }
    }

    public func pending(pluginID: String) -> PendingTrust? {
        lock.withLock { pending[pluginID] }
    }

    public func clearPending(pluginID: String) {
        lock.withLock { pending[pluginID] = nil }
    }

    /// Lets an installed source use trust again once its earlier pins are known to be deleted.
    func activateInstalledPlugin(_ pluginID: String) {
        lock.withLock {
            if blockedPlugins.contains(pluginID), cache[pluginID]?.isEmpty == true {
                blockedPlugins.remove(pluginID)
            }
        }
    }

    /// Identifies the trust decisions a pooled connection was authenticated under. A transport
    /// starts a new session when this changes and retires the old one with its connections.
    func transportGeneration(for pluginID: String) -> UUID {
        lock.withLock { currentGeneration(for: pluginID) }
    }

    /// Calls `onChange` whenever this source's trust changes from now on, until the returned
    /// observation is cancelled or released. Also returns the generation current at
    /// registration, so a caller can tell whether trust changed since by comparing it with
    /// `transportGeneration(for:)`. `onChange` runs outside the store's lock.
    func observeTrustChanges(
        pluginID: String,
        onChange: @escaping @Sendable () -> Void
    ) -> (observation: PluginTrustObservation, generation: UUID) {
        let id = UUID()
        let registered = lock.withLock {
            observers[pluginID, default: [:]][id] = onChange
            return currentGeneration(for: pluginID)
        }
        let observation = PluginTrustObservation { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.observers[pluginID]?[id] = nil
                if self.observers[pluginID]?.isEmpty == true { self.observers[pluginID] = nil }
            }
        }
        return (observation, registered)
    }

    /// Callers hold `lock`.
    private func currentGeneration(for pluginID: String) -> UUID {
        if let generation = generations[pluginID] { return generation }
        let generation = UUID()
        generations[pluginID] = generation
        return generation
    }

    /// Callers hold `lock`.
    private func changeObservers(of pluginID: String) -> [@Sendable () -> Void] {
        observers[pluginID].map { Array($0.values) } ?? []
    }

    /// Callers hold `lock`. Unreadable/corrupt state is never cached or overwritten; reads fail
    /// closed while a write propagates the failure rather than erasing other hosts' pins.
    private func load(_ pluginID: String) throws -> [String: String] {
        if let cached = cache[pluginID] { return cached }
        let (status, data) = keychain.data(account: pluginID)
        switch status {
        case errSecSuccess:
            guard let data, let pins = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw PluginSecretStoreError(status: errSecDecode)
            }
            cache[pluginID] = pins
            return pins
        case errSecItemNotFound:
            cache[pluginID] = [:]
            return [:]
        default:
            throw PluginSecretStoreError(status: status)
        }
    }

    /// How a source's request answers a server-trust challenge. A certificate the device trusts
    /// gets default handling. Otherwise the leaf certificate is accepted only when its SHA-256
    /// matches the one the user trusted for this source and host; anything else is refused and
    /// recorded as pending so the app can offer to trust it.
    public func evaluate(
        _ challenge: URLAuthenticationChallenge,
        pluginID: String,
        recordsPending: Bool = true
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        switch evaluate(trust: trust, host: challenge.protectionSpace.host, pluginID: pluginID, recordsPending: recordsPending) {
        case .systemTrusted:
            return (.performDefaultHandling, nil)
        case .pinned:
            return (.useCredential, URLCredential(trust: trust))
        case .refused:
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    public enum Decision: Equatable, Sendable {
        case systemTrusted
        case pinned
        case refused
    }

    public func evaluate(trust: SecTrust, host: String, pluginID: String, recordsPending: Bool = true) -> Decision {
        guard !pluginID.isEmpty, let host = Self.normalizedHost(host) else { return .refused }
        if SecTrustEvaluateWithError(trust, nil) { return .systemTrusted }
        guard let fingerprint = Self.leafFingerprint(trust) else { return .refused }
        if pinnedFingerprint(pluginID: pluginID, host: host) == fingerprint { return .pinned }
        if recordsPending {
            recordPending(PendingTrust(pluginID: pluginID, host: host, fingerprint: fingerprint))
        }
        return .refused
    }

    private static func normalizedHost(_ host: String) -> String? {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// Uppercase hex SHA-256 of the DER bytes of the trust's leaf certificate.
    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

/// Ends a trust-change observation when cancelled or released. Cancelling twice is harmless.
nonisolated final class PluginTrustObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var end: (@Sendable () -> Void)?

    init(end: @escaping @Sendable () -> Void) {
        self.end = end
    }

    deinit {
        cancel()
    }

    func cancel() {
        let end = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { self.end = nil }
            return self.end
        }
        end?()
    }
}

/// Shared task-delegate trust handling. Each request owns its delegate, so a refused challenge
/// is attributed to that request, not inferred from another request's pending certificate.
nonisolated class PluginTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let pluginID: String?
    private let trustStore: PluginTrustStore?
    private let recordsPending: Bool
    private let failureLock = NSLock()
    private var refusedTrust = false

    init(pluginID: String?, trustStore: PluginTrustStore?, recordsPending: Bool = true) {
        self.pluginID = pluginID
        self.trustStore = trustStore
        self.recordsPending = recordsPending
        super.init()
    }

    var trustError: URLError? {
        failureLock.withLock { refusedTrust ? URLError(.serverCertificateUntrusted) : nil }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let pluginID, let trustStore else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let (disposition, credential) = trustStore.evaluate(challenge, pluginID: pluginID, recordsPending: recordsPending)
        if disposition == .cancelAuthenticationChallenge {
            failureLock.withLock { refusedTrust = true }
        }
        completionHandler(disposition, credential)
    }
}
