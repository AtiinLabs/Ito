import Combine
import Foundation

/// Names the batch a consent is asked for and how to read the batch's source scope now. The scope is read
/// again on every admission, so a rotated source epoch refuses at once.
nonisolated struct NetworkConsentBinding: Sendable {
    let batchID: UUID
    let sourceID: String
    let liveAuthorizationScope: @Sendable () -> UUID
}

/// The live network policy of one runtime: the configured values the settings store acknowledged, a revision
/// that advances with each change of them, and the in-memory registry of batch consents.
///
/// Configured values reach it only through `apply(_:)`, which the settings store calls after the values are
/// stored. Nothing here is persisted or exported.
///
/// A consent is a grant for one exact batch. It binds the batch ID, the source scope, the policy revision, the
/// path class generation and the foreground session it was minted in, and `hasValidConsent` checks every
/// binding on each admission. It expires when the batch is revoked, the app leaves the foreground, the path
/// class changes, the policy changes, or the source scope changes. A UUID reference to it may travel in a host
/// context, but the reference alone is never authority.
nonisolated final class NetworkPolicyCenter: @unchecked Sendable {
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
    }

    private let lock = NSLock()
    private let path: (any NetworkPathObserving)?
    private var configuration: NetworkPolicyConfiguration
    private var currentRevision: UInt64 = 1
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

    // MARK: - Configured values and revision

    var revision: UInt64 {
        lock.withLock { currentRevision }
    }

    var current: NetworkPolicyConfiguration {
        lock.withLock { configuration }
    }

    var observedPath: NetworkPathSnapshot? { path?.current }

    /// Emits the new revision after each change of the configured values. Never emits for an unchanged value.
    var revisions: AnyPublisher<UInt64, Never> {
        revisionSubject.eraseToAnyPublisher()
    }

    /// Adopts acknowledged configured values. Each changed network/prefetch configuration advances the revision
    /// and expires consent. An unrelated preference write or a reload of identical values advances nothing.
    func apply(_ newConfiguration: NetworkPolicyConfiguration) {
        let newRevision: UInt64? = lock.withLock {
            let changesDecisions = newConfiguration != configuration
            configuration = newConfiguration
            guard changesDecisions else { return nil }
            currentRevision += 1
            grants = [:]
            return currentRevision
        }
        if let newRevision {
            revisionSubject.send(newRevision)
        }
        changeSubject.send(())
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

    // MARK: - Foreground session and path class

    /// Starts the foreground session a consent can be minted in. A session already running continues.
    func enterForeground() {
        lock.withLock {
            if foregroundSession == nil { foregroundSession = UUID() }
        }
    }

    /// Ends the foreground session. Every consent was minted in one, so every consent expires.
    func enterBackground() {
        lock.withLock {
            foregroundSession = nil
            grants = [:]
        }
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
                foregroundSession: session
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
        lock.withLock { grants[batchID] = nil }
    }

    /// Ends every consent.
    func revokeAllConsent() {
        lock.withLock { grants = [:] }
    }

    var hasAnyConsent: Bool {
        lock.withLock { !grants.isEmpty }
    }
}
