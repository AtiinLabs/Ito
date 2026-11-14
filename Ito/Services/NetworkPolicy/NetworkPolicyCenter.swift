import Combine
import Foundation

/// Captured by speculative work before scheduling. A revoke-and-allow sequence cannot revive that work, and a
/// change of the speculative values (image preload, adjacent chapters, novel prefetch) invalidates it. Bulk
/// consent does not move this epoch, so a speculative change never restarts a running download attempt.
nonisolated struct NetworkPrefetchEpoch: Equatable, Sendable {
    let speculativeRevision: UInt64
    let pathGeneration: UInt64
}

/// Names the batch a consent is asked for and how to read the batch's source scope now. The scope is read
/// again on every admission, so a rotated source epoch refuses at once.
nonisolated struct NetworkConsentBinding: Sendable {
    let batchID: UUID
    let sourceID: String
    let liveAuthorizationScope: @Sendable () -> UUID
}

/// The live network policy of one runtime: the configured values the settings store acknowledged, the revisions
/// that advance with the changes that matter to them, and the in-memory registry of batch consents.
///
/// Configured values reach it only through `apply(_:)`, which the settings store calls after the values are
/// stored. Nothing here is persisted or exported.
///
/// Two revisions exist because two kinds of work depend on different values:
/// - `revision` (bulk) advances only when the download mode changes. It is what consents and bulk attempts are
///   stamped with, so changing a speculative value never revokes consent or requeues a running attempt.
/// - `prefetchEpoch` advances when a speculative value changes, so speculative work captured before the change
///   stops publishing.
///
/// A consent is a grant for one exact batch. It binds the batch ID, the source scope, the bulk revision, the path
/// class generation and the foreground session it was minted in, and `hasValidConsent` checks every binding on
/// each admission. It expires when the batch is revoked, the app leaves the foreground, the path class changes,
/// the download mode changes, or the source scope changes. A UUID reference to it may travel in a host context,
/// but the reference alone is never authority.
nonisolated final class NetworkPolicyCenter: @unchecked Sendable {
    var prefetchEpoch: NetworkPrefetchEpoch {
        lock.withLock {
            NetworkPrefetchEpoch(speculativeRevision: currentSpeculativeRevision, pathGeneration: currentPathGeneration)
        }
    }

    struct Confirmation: Equatable, Sendable {
        fileprivate let revision: UInt64
        fileprivate let pathGeneration: UInt64
        fileprivate let foregroundSession: UUID
    }

    func captureConfirmation() -> Confirmation? {
        lock.withLock {
            guard let foregroundSession else { return nil }
            return Confirmation(revision: currentRevision, pathGeneration: currentPathGeneration, foregroundSession: foregroundSession)
        }
    }
    private struct Grant {
        let reference: UUID
        let batchID: UUID
        let sourceID: String
        let authorizationScope: UUID
        let policyRevision: UInt64
        let pathGeneration: UInt64
        let path: NetworkPathSnapshot
        let foregroundSession: UUID
        /// The enqueue-confirmation root is the immutable batch ID. Only scheduler-registered attempts
        /// descended from that root may use this reference; later grants never inherit this set.
        let originatingOperationID: UUID
        var allowedOperations: Set<UUID>
    }

    private let lock = NSLock()
    private let path: (any NetworkPathObserving)?
    private var configuration: NetworkPolicyConfiguration
    private var currentRevision: UInt64 = 1
    private var currentSpeculativeRevision: UInt64 = 1
    private var currentPathGeneration: UInt64 = 0
    private var lastPath: NetworkPathSnapshot?
    private var foregroundSession: UUID?
    private var grants: [UUID: Grant] = [:]
    private let revisionSubject = PassthroughSubject<UInt64, Never>()
    private let changeSubject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { changeSubject.eraseToAnyPublisher() }
    private var pathSubscription: AnyCancellable?

    /// - Parameter path: the process's one path observer. Without it no consent can be minted, because there is
    ///   no path class to bind it to.
    init(configuration: NetworkPolicyConfiguration = .defaults, path: (any NetworkPathObserving)? = nil) {
        self.configuration = configuration
        self.path = path
        if let path {
            lastPath = path.current
            pathSubscription = path.updates.sink { @Sendable [weak self] snapshot in
                self?.pathDidChange(snapshot)
            }
        }
    }

    // MARK: - Configured values and revisions

    /// The bulk revision. It advances only when the download mode changes.
    var revision: UInt64 {
        lock.withLock { currentRevision }
    }

    var current: NetworkPolicyConfiguration {
        lock.withLock { configuration }
    }

    var observedPath: NetworkPathSnapshot? { path?.current }

    /// Emits the new bulk revision after each change of the download mode. Never emits for an unchanged value.
    var revisions: AnyPublisher<UInt64, Never> {
        revisionSubject.eraseToAnyPublisher()
    }

    /// Adopts acknowledged configured values. A change of the download mode advances the bulk revision and expires
    /// every consent; a change of a speculative value advances only the prefetch epoch. Any other change, and a
    /// reload of identical values, advances nothing and publishes nothing.
    func apply(_ newConfiguration: NetworkPolicyConfiguration) {
        let outcome: (bulkRevision: UInt64?, changed: Bool) = lock.withLock {
            let previous = configuration
            guard newConfiguration != previous else { return (nil, false) }
            configuration = newConfiguration
            if newConfiguration.preloadImageCount != previous.preloadImageCount
                || newConfiguration.adjacentChapterPrefetch != previous.adjacentChapterPrefetch
                || newConfiguration.novelPrefetchChapters != previous.novelPrefetchChapters {
                currentSpeculativeRevision += 1
            }
            guard newConfiguration.downloadMode != previous.downloadMode else { return (nil, true) }
            currentRevision += 1
            grants = [:]
            return (currentRevision, true)
        }
        if let revision = outcome.bulkRevision {
            revisionSubject.send(revision)
        }
        if outcome.changed {
            changeSubject.send(())
        }
    }

    // MARK: - Decisions

    /// The decision for `intent` on `path` under the live configuration. `consent` names the batch whose
    /// consent counts; the registry validates it.
    func decide(
        _ intent: NetworkIntent,
        path snapshot: NetworkPathSnapshot,
        consent: NetworkConsentBinding? = nil
    ) -> NetworkDecision {
        let configuration = current
        let hasConsent = consent.map { hasValidConsent($0) } ?? false
        return NetworkPolicy.evaluate(intent, path: snapshot, configuration: configuration, hasBatchConsent: hasConsent)
    }

    func projection(path snapshot: NetworkPathSnapshot) -> NetworkEffectiveProjection {
        NetworkPolicy.projection(configuration: current, path: snapshot)
    }

    /// The first path the observer reports that is known. It reads the observer's replaying stream, so an unknown
    /// path is awaited rather than judged as offline, and the wait ends with the caller's task. It waits for the
    /// system's report, never for a timer. Nil when there is no observer or the wait is cancelled.
    func firstKnownPath() async -> NetworkPathSnapshot? {
        guard let path else { return nil }
        for await snapshot in path.updates.values where snapshot.status != .unknown {
            return snapshot
        }
        return nil
    }

    // MARK: - Foreground session and path class

    /// Starts the foreground session a consent can be minted in. A session already running continues.
    func enterForeground() {
        lock.withLock {
            if foregroundSession == nil { foregroundSession = UUID() }
        }
    }

    /// Ends the foreground session. Every consent was minted in one, so every consent expires.
    func enterBackground() {
        let changed = lock.withLock {
            let changed = foregroundSession != nil || !grants.isEmpty
            foregroundSession = nil
            grants = [:]
            return changed
        }
        if changed { changeSubject.send(()) }
    }

    var isForeground: Bool {
        lock.withLock { foregroundSession != nil }
    }

    var pathGeneration: UInt64 {
        lock.withLock { currentPathGeneration }
    }

    private func pathDidChange(_ snapshot: NetworkPathSnapshot) {
        let changed = lock.withLock {
            guard snapshot != lastPath else { return false }
            lastPath = snapshot
            currentPathGeneration += 1
            grants = [:]
            return true
        }
        if changed { changeSubject.send(()) }
    }

    // MARK: - Batch consent

    /// Mints the consent for one batch after the user directly confirmed it, in the foreground, on an
    /// expensive and unconstrained path while the mode asks. Returns nil, minting nothing, when any of that is
    /// not so now. At most one consent exists per batch; minting again replaces it.
    @discardableResult
    func mintBatchConsent(_ binding: NetworkConsentBinding, confirmation: Confirmation? = nil) -> UUID? {
        guard let path else { return nil }
        let snapshot = path.current
        let scope = binding.liveAuthorizationScope()
        return lock.withLock {
            guard configuration.downloadMode == .askMetered,
                  let session = foregroundSession,
                  confirmation == nil || confirmation == Confirmation(revision: currentRevision, pathGeneration: currentPathGeneration, foregroundSession: session),
                  snapshot.status == .satisfied, snapshot.isExpensive, !snapshot.isConstrained else { return nil }
            let grant = Grant(
                reference: UUID(),
                batchID: binding.batchID,
                sourceID: binding.sourceID,
                authorizationScope: scope,
                policyRevision: currentRevision,
                pathGeneration: currentPathGeneration,
                path: snapshot,
                foregroundSession: session,
                originatingOperationID: binding.batchID,
                allowedOperations: []
            )
            grants[binding.batchID] = grant
            return grant.reference
        }
    }

    /// The opaque reference a host context carries for `batchID`, if a consent exists. It says nothing about
    /// validity; every admission validates.
    func consentReference(forBatch batchID: UUID) -> UUID? {
        lock.withLock { grants[batchID]?.reference }
    }

    /// Registers a trusted scheduler attempt as a descendant of this exact confirmed batch.
    /// The returned reference is captured once by the operation, never looked up again by context creation.
    func authorizeBatchOperation(_ binding: NetworkConsentBinding, operationID: UUID) -> UUID? {
        guard hasValidConsent(binding) else { return nil }
        return lock.withLock {
            guard var grant = grants[binding.batchID], grant.originatingOperationID == binding.batchID else { return nil }
            grant.allowedOperations.insert(operationID)
            grants[binding.batchID] = grant
            return grant.reference
        }
    }

    /// Transport admission validates the request's immutable reference and lineage, not just the batch's
    /// newest grant. A nil, revoked or replaced reference cannot borrow another attempt's authorization.
    func hasValidConsent(
        _ binding: NetworkConsentBinding,
        reference: UUID?,
        operationID: UUID,
        authorizationScope: UUID
    ) -> Bool {
        guard let reference, authorizationScope == binding.liveAuthorizationScope(),
              hasValidConsent(binding) else { return false }
        return lock.withLock {
            guard let grant = grants[binding.batchID] else { return false }
            return grant.reference == reference && grant.authorizationScope == authorizationScope
                && grant.originatingOperationID == binding.batchID && grant.allowedOperations.contains(operationID)
        }
    }

    /// Whether `binding`'s batch holds a consent that is still valid on every binding, read against the path the
    /// observer reports now. A consent that is not valid is dropped, so it can never become valid again.
    func hasValidConsent(_ binding: NetworkConsentBinding) -> Bool {
        let liveScope = binding.liveAuthorizationScope()
        let observed = path?.current
        return lock.withLock {
            guard let grant = grants[binding.batchID] else { return false }
            let valid = grant.sourceID == binding.sourceID
                && grant.authorizationScope == liveScope
                && grant.policyRevision == currentRevision
                && grant.pathGeneration == currentPathGeneration
                && grant.foregroundSession == foregroundSession
                && configuration.downloadMode == .askMetered
                && observed == grant.path
            if !valid { grants[binding.batchID] = nil }
            return valid
        }
    }

    /// Ends the consent of a batch that finished or was cancelled.
    func revokeConsent(forBatch batchID: UUID) {
        let changed = lock.withLock { grants.removeValue(forKey: batchID) != nil }
        if changed { changeSubject.send(()) }
    }

    /// Ends every consent.
    func revokeAllConsent() {
        let changed = lock.withLock {
            let changed = !grants.isEmpty
            grants = [:]
            return changed
        }
        if changed { changeSubject.send(()) }
    }

    var hasAnyConsent: Bool {
        lock.withLock { !grants.isEmpty }
    }
}
