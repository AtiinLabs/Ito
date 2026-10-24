import Foundation

/// One `URLSession`, and so one connection pool, per source and trust generation. A connection a
/// source authenticated with a pinned certificate is never reused for another source, nor after
/// that source's pins change or are revoked.
///
/// A session replaced by a trust change is invalidated only once no caller still holds it: a
/// session must never be asked for a task after invalidation.
nonisolated final class PluginSessionPool: @unchecked Sendable {
    private final class Lease {
        let session: URLSession
        let generation: UUID?
        var users = 0
        var retired = false

        init(session: URLSession, generation: UUID?) {
            self.session = session
            self.generation = generation
        }
    }

    private let configuration: URLSessionConfiguration
    private let trust: PluginTrustStore?
    private let lock = NSLock()
    private var current: [String: Lease] = [:]

    init(configuration: URLSessionConfiguration, trust: PluginTrustStore?) {
        self.configuration = configuration
        self.trust = trust
    }

    deinit {
        for lease in current.values {
            lease.session.invalidateAndCancel()
        }
    }

    /// Runs `body` with the session for this source's current trust. Without a source or a trust
    /// store there is no pin to isolate, but sessions are still kept per source.
    func withSession<T>(for pluginID: String?, _ body: (URLSession) async throws -> T) async rethrows -> T {
        let lease = acquire(pluginID ?? "")
        defer { release(lease) }
        return try await body(lease.session)
    }

    private func acquire(_ pluginID: String) -> Lease {
        lock.withLock {
            // Read under this lock so a slow caller can't retire a newer session.
            let generation = pluginID.isEmpty ? nil : trust?.transportGeneration(for: pluginID)
            if let lease = current[pluginID], lease.generation == generation {
                lease.users += 1
                return lease
            }
            if let old = current[pluginID] {
                old.retired = true
                if old.users == 0 { old.session.finishTasksAndInvalidate() }
            }
            let lease = Lease(session: URLSession(configuration: configuration), generation: generation)
            lease.users = 1
            current[pluginID] = lease
            return lease
        }
    }

    private func release(_ lease: Lease) {
        lock.withLock {
            lease.users -= 1
            // Transfers already started finish; the retired pool takes no new requests.
            if lease.retired, lease.users == 0 { lease.session.finishTasksAndInvalidate() }
        }
    }
}
