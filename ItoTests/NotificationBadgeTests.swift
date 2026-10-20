import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

/// Reports a fixed authorization and streams every icon badge count it is given.
nonisolated final class FakeNotificationSystem: NotificationSystem, @unchecked Sendable {
    let authorized: Bool
    let iconBadgeCounts: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation

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
            knownChapterCount: 10
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

        try await updates.clearBadge(for: MediaIdentity(pluginId: item.pluginId, itemId: item.id))
        #expect(await iconBadge.next() == 0)
    }
}
