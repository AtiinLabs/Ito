import Foundation
import GRDB
import ito_runner

/// What one host-initiated operation is for. Built where the operation starts and handed down to
/// the runner calls it makes; every export of the operation shares `operationID` (and `batchID`).
nonisolated public struct PluginNetworkOperation: Sendable, Equatable {
    let purpose: NetworkOperationContext.Purpose
    let operationID: UUID
    var batchID: UUID?
}

/// Builds the host context for one runner export. Synchronous and lock-protected, so it can be read
/// inside any call path, including the ones that cannot await.
///
/// The authorization scope is the installation-local source/account epoch in `pluginCompletionScope`.
/// Live operations read a mirror of that table, which the store refreshes in the same commit that
/// rotates an epoch. Frozen operations (downloads, completion) pass the epoch they captured instead.
nonisolated final class PluginNetworkContexts: @unchecked Sendable {
    private let lock = NSLock()
    private var epochScopes: [String: UUID] = [:]
    /// Scopes handed out for plugins without a committed epoch. Stable until the next mirror refresh,
    /// so repeated lookups agree; never derived from credentials.
    private var ephemeralScopes: [String: UUID] = [:]

    /// The live network policy every context is stamped from.
    let policy: NetworkPolicyCenter

    init(epochs: [String: String] = [:], policy: NetworkPolicyCenter = NetworkPolicyCenter()) {
        self.policy = policy
        replaceEpochs(epochs)
    }

    /// Replaces the mirror with the committed epochs, keyed by plugin ID. Called from the commit that
    /// wrote them, so a lookup after the write returns sees the new scope.
    func replaceEpochs(_ epochs: [String: String]) {
        lock.withLock {
            epochScopes = epochs.compactMapValues(PluginNetworkScopeID.uuid(epoch:))
            ephemeralScopes = [:]
        }
    }

    /// The context for one export of `operation`. Every call gets a new `generation`. `frozenScope`,
    /// when given, is the epoch the operation captured and wins over the mirror. A frozen epoch that
    /// is not a valid epoch yields a random scope, which no grant or identity can match. The context carries
    /// the policy revision in force when it is built; a transport that sees a later revision refuses it as
    /// `policyChanged`, and the scheduler builds a new one.
    func context(
        pluginID: String,
        _ operation: PluginNetworkOperation,
        frozenScope: String? = nil
    ) -> NetworkOperationContext {
        let scope: UUID
        if let frozenScope {
            scope = PluginNetworkScopeID.uuid(epoch: frozenScope) ?? UUID()
        } else {
            scope = liveScope(pluginID: pluginID)
        }
        return NetworkOperationContext(
            purpose: operation.purpose,
            sourceID: pluginID,
            authorizationScope: scope,
            operationID: operation.operationID,
            batchID: operation.batchID,
            policyRevision: policy.revision,
            generation: UUID(),
            scopedGrant: operation.purpose == .manualBulkDownload || operation.purpose == .automaticBulkDownload
                ? operation.batchID.flatMap { policy.consentReference(forBatch: $0) } : nil
        )
    }

    /// The authorization scope of a source now, as the mirror of committed epochs has it.
    func liveScope(pluginID: String) -> UUID {
        lock.withLock {
            if let mirrored = epochScopes[pluginID] { return mirrored }
            if let ephemeral = ephemeralScopes[pluginID] { return ephemeral }
            let fresh = UUID()
            ephemeralScopes[pluginID] = fresh
            return fresh
        }
    }

    /// What the policy checks a batch's consent against: the batch, its source, and that source's scope now.
    func consentBinding(batchID: UUID, pluginID: String) -> NetworkConsentBinding {
        NetworkConsentBinding(batchID: batchID, sourceID: pluginID) { [weak self] in
            self?.liveScope(pluginID: pluginID) ?? UUID()
        }
    }
}

/// Maps a 32-character lowercase-hex epoch byte-for-byte onto a UUID.
nonisolated enum PluginNetworkScopeID {
    static func uuid(epoch: String) -> UUID? {
        guard PluginImageCacheEpoch.isValidEpoch(epoch) else { return nil }
        let characters = Array(epoch)
        let grouped = [
            String(characters[0..<8]),
            String(characters[8..<12]),
            String(characters[12..<16]),
            String(characters[16..<20]),
            String(characters[20..<32])
        ]
        return UUID(uuidString: grouped.joined(separator: "-"))
    }
}

/// Keeps the scope mirror current. It runs inside the commit that changes `pluginCompletionScope`, on
/// the writer queue, so the mirror is updated before the write that caused the change returns.
nonisolated final class PluginNetworkScopeObservation: TransactionObserver, @unchecked Sendable {
    private let contexts: PluginNetworkContexts
    private let lock = NSLock()
    private var scopeChangedInTransaction = false

    init(contexts: PluginNetworkContexts) {
        self.contexts = contexts
    }

    /// The committed epochs of every plugin that has one.
    static func epochs(in db: Database) throws -> [String: String] {
        guard try db.tableExists(PluginCompletionScope.tableName) else { return [:] }
        let rows = try Row.fetchAll(db, sql: "SELECT pluginId, epoch FROM \(PluginCompletionScope.tableName)")
        return rows.reduce(into: [String: String]()) { epochs, row in
            let pluginID: String = row["pluginId"]
            let epoch: String = row["epoch"]
            epochs[pluginID] = epoch
        }
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == PluginCompletionScope.tableName
    }

    func databaseDidChange(with event: DatabaseEvent) {
        markScopeChanged()
    }

    func databaseDidChange() {
        markScopeChanged()
    }

    func databaseDidCommit(_ db: Database) {
        lock.lock()
        let didChange = scopeChangedInTransaction
        scopeChangedInTransaction = false
        lock.unlock()
        guard didChange else { return }
        // A failed read publishes no epochs, so a stale identity is never served after a rotation.
        contexts.replaceEpochs((try? Self.epochs(in: db)) ?? [:])
    }

    func databaseDidRollback(_ db: Database) {
        lock.lock()
        scopeChangedInTransaction = false
        lock.unlock()
    }

    private func markScopeChanged() {
        lock.lock()
        scopeChangedInTransaction = true
        lock.unlock()
        stopObservingDatabaseChangesUntilNextTransaction()
    }
}
