import Combine
import Foundation
import ito_runner

/// Immutable authority captured by the initiating host operation, not by a URL or a guest header.
/// Every decision belongs to `NetworkPolicyCenter`; this adapter only binds a request to the context that
/// started it and re-asks the policy at each admission, redirect, retry and publication point.
///
/// Source-bound authorities also check the live source/account epoch. App-owned authorities (repositories,
/// subtitles, trackers) have no source epoch and ask the policy alone.
nonisolated struct NetworkRequestAuthority: Sendable {
    /// A host-owned label, not a capability: a plugin using this ID must still validate its source epoch.
    static let appSourceID = "ito.app"
    private static let appAuthorizationScope = UUID()

    let contexts: PluginNetworkContexts
    let context: NetworkOperationContext
    private let isAppOwned: Bool

    init(contexts: PluginNetworkContexts, context: NetworkOperationContext) {
        self.contexts = contexts
        self.context = context
        isAppOwned = false
    }

    private init(appContext: NetworkOperationContext, contexts: PluginNetworkContexts) {
        self.contexts = contexts
        context = appContext
        isAppOwned = true
    }

    var changes: AnyPublisher<Void, Never> {
        contexts.policy.changes.merge(with: contexts.scopeChanges).eraseToAnyPublisher()
    }

    /// An authority for a destination the app owns, such as a repository index or a tracker API.
    static func appOwned(
        contexts: PluginNetworkContexts,
        purpose: NetworkOperationContext.Purpose,
        operationID: UUID = UUID()
    ) -> NetworkRequestAuthority {
        NetworkRequestAuthority(
            appContext: NetworkOperationContext(
                purpose: purpose, sourceID: appSourceID, authorizationScope: appAuthorizationScope,
                operationID: operationID, policyRevision: contexts.policy.revision, generation: UUID()
            ),
            contexts: contexts
        )
    }

    var intent: NetworkIntent {
        switch context.purpose {
        case .manualBulkDownload: .manualBulkDownload
        case .automaticBulkDownload: .automaticBulkDownload
        case .automaticLibraryUpdate: .automaticMetadata
        case .prefetch: .speculativePrefetch
        case .foregroundReading, .seriesMetadata, .manualCatalogRefresh, .trackerWrite,
             .sourceSetup, .interactiveSearch, .coverImage: .interactive
        }
    }

    /// Throws the typed host outcome when the request may not start or continue now.
    func check() throws {
        if !isAppOwned, context.authorizationScope != contexts.liveScope(pluginID: context.sourceID) {
            throw HostNetworkPolicyOutcome.sourceAuthorizationFailure
        }
        let policy = contexts.policy
        guard context.policyRevision == policy.revision else {
            throw HostNetworkPolicyOutcome.deferred(.policyChanged)
        }
        var binding: NetworkConsentBinding?
        if intent == .manualBulkDownload || intent == .automaticBulkDownload, let batch = context.batchID {
            let candidate = contexts.consentBinding(batchID: batch, pluginID: context.sourceID)
            if policy.hasValidConsent(
                candidate,
                reference: context.scopedGrant,
                operationID: context.operationID,
                authorizationScope: context.authorizationScope
            ) {
                binding = candidate
            }
        }
        let path = policy.observedPath ?? .unknown
        if case .wait(let deferral) = policy.decide(intent, path: path, consent: binding) {
            throw deferral.policyOutcome
        }
    }

    /// The image-specific limit is the pure policy's effective preload projection, not another settings check.
    func checkImageAdmission() throws {
        try check()
        guard intent == .speculativePrefetch else { return }
        let policy = contexts.policy
        guard policy.projection(path: policy.observedPath ?? .unknown).imagePreloadCount > 0 else {
            throw HostNetworkPolicyOutcome.deferred(.policyChanged)
        }
    }

    /// Like `check()`, and the request may also put a challenge or page in front of the user. Only an
    /// interactive operation in the foreground may; everything else is told it needs the user.
    func checkInteractive() throws {
        try check()
        guard intent == .interactive, contexts.policy.isForeground else {
            throw HostNetworkPolicyOutcome.foregroundPermissionRequired
        }
    }

    /// Whether this request would be admitted on an expensive, unconstrained path now. The system's own network
    /// flags of a transport the host cannot gate request by request are set from this.
    var admitsExpensivePath: Bool {
        admits(NetworkPathSnapshot(status: .satisfied, isExpensive: true))
    }

    /// Whether this request would be admitted on a constrained (Low Data Mode) path now.
    var admitsConstrainedPath: Bool {
        admits(NetworkPathSnapshot(status: .satisfied, isConstrained: true))
    }

    private func admits(_ path: NetworkPathSnapshot) -> Bool {
        contexts.policy.decide(intent, path: path) == .allow
    }

    /// Calls `onRevoked` with the refusal each time a live policy change stops admitting this request.
    /// Only this request's owner subscribes, so a change never reaches another operation's work.
    func observeRevocation(_ onRevoked: @escaping @Sendable (Error) -> Void) -> AnyCancellable {
        let authority = self
        return changes.sink { _ in
            do { try authority.check() } catch { onRevoked(error) }
        }
    }

    /// Runs `operation` as this request's transfer. A live policy change cancels only this transfer, and the
    /// typed refusal, not the cancellation it caused, is what the caller sees. The caller's own
    /// cancellation takes precedence over both. `refusesLateResult` is false for a mutation: a response that
    /// already arrived is the remote's real answer and is never replaced by a later refusal.
    func perform<T: Sendable>(
        refusesLateResult: Bool = true,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        try check()
        let task = Task {
            try Task.checkCancellation()
            try check()
            return try await operation()
        }
        let refusal = NetworkRequestRefusal()
        let subscription = observeRevocation { error in
            refusal.record(error)
            task.cancel()
        }
        defer { subscription.cancel() }
        return try await withTaskCancellationHandler {
            do {
                do { try check() } catch { task.cancel(); throw error }
                let result = try await task.value
                try Task.checkCancellation()
                if refusesLateResult {
                    if let recorded = refusal.first { throw recorded }
                    try check()
                }
                return result
            } catch {
                try Task.checkCancellation()
                if refusesLateResult {
                    if let recorded = refusal.first { throw recorded }
                    try check()
                }
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Where an app-owned service (repositories, subtitles, trackers) gets the live policy from. Composition sets it
/// once; until then a service has no authority and is not gated, which is only the case for tests and previews.
nonisolated final class AppNetworkAuthorityProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: PluginNetworkContexts?

    func set(_ contexts: PluginNetworkContexts) {
        lock.withLock { self.contexts = contexts }
    }

    /// A new authority for one operation of `purpose`, or nil while no policy was provided.
    func authority(purpose: NetworkOperationContext.Purpose) -> NetworkRequestAuthority? {
        lock.withLock { contexts }.map { .appOwned(contexts: $0, purpose: purpose) }
    }

    /// Throws the typed refusal when `purpose` may not use the network now. Nothing is requested before it returns,
    /// so a refusal always means the request was not sent. Without a provided policy nothing is refused.
    func admit(_ purpose: NetworkOperationContext.Purpose) throws {
        try authority(purpose: purpose)?.check()
    }
}

/// A transient path must not erase the refusal that already stopped this invocation.
private nonisolated final class NetworkRequestRefusal: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    var first: Error? { lock.withLock { error } }

    func record(_ error: Error) {
        lock.withLock {
            if self.error == nil { self.error = error }
        }
    }
}
