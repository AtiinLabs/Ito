import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

/// Reports a fixed authorization, streams every icon badge count it is given, and keeps the attention notifications
/// posted to it, so a test can look at what the system would show.
nonisolated final class FakeNotificationSystem: NotificationSystem, @unchecked Sendable {
    nonisolated struct Posted: Equatable {
        let identifier: String
        let title: String
        let body: String
        let threadIdentifier: String
        let payload: SubscriptionAttentionPayload
    }

    let authorized: Bool
    let iconBadgeCounts: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation
    private let lock = NSLock()
    private var delivered: [Posted] = []
    private var adds: [Posted] = []
    private var removedDelivered: [[String]] = []
    private var removedPending: [[String]] = []

    init(authorized: Bool) {
        self.authorized = authorized
        var captured: AsyncStream<Int>.Continuation?
        iconBadgeCounts = AsyncStream { captured = $0 }
        continuation = captured!
    }

    func isAuthorized() async -> Bool {
        authorized
    }

    func setIconBadgeCount(_ count: Int) async {
        continuation.yield(count)
    }

    func add(
        identifier: String, title: String, body: String, threadIdentifier: String, payload: SubscriptionAttentionPayload
    ) async throws {
        let posted = Posted(
            identifier: identifier, title: title, body: body, threadIdentifier: threadIdentifier, payload: payload
        )
        lock.withLock {
            adds.append(posted)
            // A notification with the same identifier replaces the one the system shows.
            delivered.removeAll { $0.identifier == identifier }
            delivered.append(posted)
        }
    }

    func removeDelivered(identifiers: [String]) async {
        lock.withLock {
            removedDelivered.append(identifiers)
            delivered.removeAll { identifiers.contains($0.identifier) }
        }
    }

    func removePending(identifiers: [String]) async {
        lock.withLock { removedPending.append(identifiers) }
    }

    func deliveredAttention() async -> [DeliveredAttentionNotification] {
        lock.withLock { delivered.map { DeliveredAttentionNotification(identifier: $0.identifier, payload: $0.payload) } }
    }

    /// Every `add`, in order, including the ones a later one replaced.
    var posts: [Posted] { lock.withLock { adds } }
    /// The notifications the system shows now.
    var shown: [Posted] { lock.withLock { delivered } }
    var removals: [[String]] { lock.withLock { removedDelivered } }
    var pendingRemovals: [[String]] { lock.withLock { removedPending } }
}

@MainActor
struct NotificationBadgeTests {
    @Test func theAppIconBadgeFollowsUnreadNewChapters() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let item = LibraryItem(
            id: "series",
            title: "Series",
            coverUrl: nil,
            pluginId: "plugin",
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil,
            status: nil,
            lastCheckedAt: nil,
            lastUpdatedAt: nil,
            knownChapterCount: 10,
            knownChapterCountBasis: .exactChapterKeys
        )
        try await database.dbPool.write { db in try item.insert(db) }
        let updates = UpdateManager(dbPool: database.dbPool)
        let system = FakeNotificationSystem(authorized: true)
        let notifications = NotificationManager(system: system)
        notifications.configure(updateManager: updates)
        var iconBadge = system.iconBadgeCounts.makeAsyncIterator()

        #expect(await iconBadge.next() == 0)

        _ = await updates.processUpdate(for: item) {
            UpdateManager.SuccessfulUpdate(freshCount: 12, status: nil)
        }
        #expect(await iconBadge.next() == 2)

        try await updates.clearBadge(for: MediaIdentity(pluginId: item.pluginId, itemId: item.id, mediaKind: .manga))
        #expect(await iconBadge.next() == 0)
    }
}
