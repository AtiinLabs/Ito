import Foundation

/// Proof that the holder is inside a `PluginDirectoryGate` operation. Functions that change the plugin directory, or
/// scan and publish the installed plugins, take a lease, so they can only run inside such an operation. Only the
/// gate creates leases in production; a lease is valid only while its operation runs. Test support may create one to
/// seed published state before a test starts any directory operation. Nothing in the compiler stops other code from
/// creating a lease, so keeping that to the gate and to tests is a convention.
nonisolated struct PluginDirectoryLease: Sendable {
    /// Identifies the operation this lease belongs to, so the gate can tell a request made inside that operation from
    /// one made by an unrelated task.
    let id = UUID()
}

/// Raised when an operation asks for the gate while the operation that holds it is the one making the request. Waiting
/// would deadlock, so the request fails instead.
nonisolated enum PluginDirectoryGateError: Error, Equatable, Sendable {
    case reentrantAcquire
}

/// FIFO gate for the plugin directory. Each change to the directory, and each scan that publishes the installed
/// plugins, runs as one operation inside `withLease`, so operations never interleave: a scan can't read a file another
/// operation is removing, and trust revoked by a deletion can't be reactivated by a scan that started before it.
/// Operations run in the order they asked for the gate.
///
/// Gate-held code calls only lease-taking (`…Locked`) functions. The public entry points acquire the gate, so calling
/// one from inside the operation that holds it would wait for itself; that throws
/// `PluginDirectoryGateError.reentrantAcquire` instead of deadlocking.
///
/// Re-entry is judged per holder. Task-local values are copied into every `Task {}` created inside an operation, so a
/// task created inside a lease carries that lease's ID even after the lease has ended. Such a task compares the ID it
/// inherited with the ID of the operation that holds the gate now. Only an equal ID means re-entry. A task that runs
/// after its lease ended therefore waits its turn like any other request.
///
/// Limits: a request cancelled while queued still waits its turn before it throws `CancellationError`. Every gated
/// operation finishes, so that wait is bounded. The gate is per instance; production has one, owned by `PluginManager`.
@MainActor
final class PluginDirectoryGate {
    /// The ID of the lease of the operation the current task runs inside, if any.
    @TaskLocal private static var inheritedLeaseID: UUID?

    /// Called when an operation starts waiting for the gate. Tests use it to see that an operation queued behind
    /// another instead of running alongside it; production code leaves it empty.
    private let onWaiting: @MainActor () -> Void
    /// The ID of the lease that holds the gate, or nil when the gate is free.
    private var activeLeaseID: UUID?
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    init(onWaiting: @escaping @MainActor () -> Void = {}) {
        self.onWaiting = onWaiting
    }

    /// Runs `operation` holding the gate, then releases it, even when the operation throws. A task cancelled while
    /// waiting throws `CancellationError` without running the operation.
    func withLease<Value>(_ operation: (PluginDirectoryLease) async throws -> Value) async throws -> Value {
        if let inherited = Self.inheritedLeaseID, inherited == activeLeaseID {
            throw PluginDirectoryGateError.reentrantAcquire
        }
        let lease = PluginDirectoryLease()
        await acquire(for: lease.id)
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
        do {
            let value = try await Self.$inheritedLeaseID.withValue(lease.id) {
                try await operation(lease)
            }
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire(for id: UUID) async {
        guard activeLeaseID != nil else {
            activeLeaseID = id
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((id: id, continuation: continuation))
            onWaiting()
        }
    }

    /// Hands the gate to the longest waiting operation, or frees it when none waits.
    private func release() {
        guard !waiters.isEmpty else {
            activeLeaseID = nil
            return
        }
        let next = waiters.removeFirst()
        activeLeaseID = next.id
        next.continuation.resume()
    }
}
