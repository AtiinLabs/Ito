import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

@MainActor
struct UpdateBaselineTests {
    @Test func newChaptersAddUpUntilTheSeriesIsOpened() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: 10)
        defer { database.cleanup() }
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_100)

        let firstDelta = await successfulUpdate(
            manager,
            item: item,
            freshCount: 12,
            checkedAt: checkedAt
        )
        #expect(firstDelta == 2)
        #expect(manager.badgeCount(for: identity(for: item)) == 2)
        let firstPersisted = try await persistedItem(database, id: item.id)
        #expect(firstPersisted.knownChapterCount == 12)
        #expect(firstPersisted.status == "updated")
        #expect(firstPersisted.lastCheckedAt == checkedAt)
        #expect(firstPersisted.lastUpdatedAt == checkedAt)

        // A later check with nothing new keeps the unread badge.
        #expect(await successfulUpdate(manager, item: item, freshCount: 12) == 0)
        #expect(manager.badgeCount(for: identity(for: item)) == 2)

        // More new chapters add to it.
        #expect(await successfulUpdate(manager, item: item, freshCount: 13) == 1)
        #expect(manager.badgeCount(for: identity(for: item)) == 3)

        // Opening the series clears it.
        try await manager.advanceBaseline(for: item.id, media: identity(for: item), knownChapterCount: 13)
        #expect(manager.badgeCount(for: identity(for: item)) == 0)
        let reloaded = UpdateManager(dbPool: database.dbPool)
        try await reloaded.reload()
        #expect(reloaded.badgeCount(for: identity(for: item)) == 0)
    }

    @Test func latestPersistedBaselineWinsOverStaleInput() async throws {
        let (database, manager, staleItem) = try await makeSubject(knownCount: 10)
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            let fetchedLatest = try LibraryItem.fetchOne(db, key: staleItem.id)
            var latest = try #require(fetchedLatest)
            latest.knownChapterCount = 11
            try latest.update(db)
        }

        let delta = await successfulUpdate(manager, item: staleItem, freshCount: 12)

        #expect(delta == 1)
        #expect(manager.badgeCount(for: identity(for: staleItem)) == 1)
        #expect(try await persistedItem(database, id: staleItem.id).knownChapterCount == 12)
    }

    @Test func nilBaselineInitializesSilently() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: nil)
        defer { database.cleanup() }

        let delta = await successfulUpdate(manager, item: item, freshCount: 12)

        #expect(delta == 0)
        #expect(manager.badgeCount(for: identity(for: item)) == 0)
        #expect(try await persistedItem(database, id: item.id).knownChapterCount == 12)
    }

    @Test func lowerCountBecomesBaselineForNextIncrease() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: 12)
        defer { database.cleanup() }

        let decreaseDelta = await successfulUpdate(manager, item: item, freshCount: 10)
        #expect(decreaseDelta == 0)
        #expect(try await persistedItem(database, id: item.id).knownChapterCount == 10)

        let increaseDelta = await successfulUpdate(manager, item: item, freshCount: 11)
        #expect(increaseDelta == 1)
        #expect(manager.badgeCount(for: identity(for: item)) == 1)
        #expect(try await persistedItem(database, id: item.id).knownChapterCount == 11)
    }

    @Test func failedFetchRecordsOnlyTheAttemptTime() async throws {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_001)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_002)
        let attemptedAt = Date(timeIntervalSince1970: 1_700_003_600)
        let (database, manager, item) = try await makeSubject(
            knownCount: 10,
            status: "ongoing",
            lastCheckedAt: checkedAt,
            lastUpdatedAt: updatedAt
        )
        defer { database.cleanup() }

        let delta = await manager.processUpdate(for: item, checkedAt: attemptedAt) {
            throw StubError.fetchFailed
        }

        #expect(delta == nil)
        #expect(manager.badgeCount(for: identity(for: item)) == 0)
        let persisted = try await persistedItem(database, id: item.id)
        #expect(persisted.knownChapterCount == 10)
        #expect(persisted.status == "ongoing")
        #expect(persisted.lastCheckedAt == attemptedAt)
        #expect(persisted.lastUpdatedAt == updatedAt)
    }

    @Test func itemDeletedDuringFetchIsNotRecreatedAndHasNoBadge() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: 10)
        defer { database.cleanup() }
        #expect(await successfulUpdate(manager, item: item, freshCount: 12) == 2)
        #expect(manager.badgeCount(for: identity(for: item)) == 2)
        try await database.dbPool.write { db in
            _ = try LibraryItem.deleteOne(db, key: item.id)
        }

        let delta = await successfulUpdate(manager, item: item, freshCount: 13)

        #expect(delta == nil)
        #expect(manager.badgeCount(for: identity(for: item)) == 0)
        let deleted = try await database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: item.id)
        }
        #expect(deleted == nil)
        let reloaded = UpdateManager(dbPool: database.dbPool)
        try await reloaded.reload()
        #expect(reloaded.badgeCount(for: identity(for: item)) == 0)
        let badgeRowCount = try await database.dbPool.read { db in
            try UpdateBadgeRecord.fetchCount(db)
        }
        #expect(badgeRowCount == 0)
    }

    @Test func reloadPublishesPersistedScopedBadges() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            try UpdateBadgeRecord(
                pluginId: "one",
                canonicalMediaId: "same",
                count: 3,
                updatedAt: nil,
                provenance: .runtime
            ).insert(db)
            try UpdateBadgeRecord(
                pluginId: "two",
                canonicalMediaId: "same",
                count: 5,
                updatedAt: nil,
                provenance: .runtime
            ).insert(db)
        }
        let manager = UpdateManager(dbPool: database.dbPool)

        try await manager.reload()

        #expect(manager.badgeCount(
            for: MediaIdentity(pluginId: "one", canonicalMediaId: "same")
        ) == 3)
        #expect(manager.badgeCount(
            for: MediaIdentity(pluginId: "two", canonicalMediaId: "same")
        ) == 5)
        #expect(manager.totalBadgeCount == 8)
    }

    @Test func clearCommitsBeforePublishing() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: 10)
        defer { database.cleanup() }
        #expect(await successfulUpdate(manager, item: item, freshCount: 12) == 2)

        try await manager.clearBadge(for: identity(for: item))

        #expect(manager.badgeCount(for: identity(for: item)) == 0)
        try await database.dbPool.read { db in
            let count = try UpdateBadgeRecord.fetchCount(db)
            #expect(count == 0)
        }
    }

    @Test func databaseRejectsNegativeBadgeCount() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        await #expect(throws: (any Error).self) {
            try await database.dbPool.write { db in
                try UpdateBadgeRecord(
                    pluginId: "plugin",
                    canonicalMediaId: "media",
                    count: -1,
                    updatedAt: nil,
                    provenance: .runtime
                ).insert(db)
            }
        }
    }

    @Test func repeatedBadgeUpdatesKeepOneLogicalRow() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: 10)
        defer { database.cleanup() }
        #expect(await successfulUpdate(manager, item: item, freshCount: 12) == 2)
        #expect(await successfulUpdate(manager, item: item, freshCount: 14) == 2)

        try await database.dbPool.read { db in
            let records = try UpdateBadgeRecord.fetchAll(db)
            #expect(records.count == 1)
            #expect(records.single?.count == 4)
        }
    }

    @Test func badgeWriteFailureRollsBackLibraryAndPublishedBadge() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: 10)
        defer { database.cleanup() }
        #expect(await successfulUpdate(manager, item: item, freshCount: 12) == 2)
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_badge_update
                BEFORE UPDATE ON updateBadge
                BEGIN
                    SELECT RAISE(ABORT, 'injected badge failure');
                END
                """)
        }

        let delta = await successfulUpdate(manager, item: item, freshCount: 15)

        #expect(delta == nil)
        #expect(manager.badgeCount(for: identity(for: item)) == 2)
        #expect(try await persistedItem(database, id: item.id).knownChapterCount == 12)
        try await database.dbPool.read { db in
            let records = try UpdateBadgeRecord.fetchAll(db)
            #expect(records.count == 1)
            #expect(records.single?.count == 2)
        }
    }

    @Test func scanlationsOfOneChapterCountOnceAndUnnumberedChaptersCountByKey() {
        let chapters = [
            Manga.Chapter(key: "a", chapter: 1, scanlator: "Team A"),
            Manga.Chapter(key: "b", chapter: 1, scanlator: "Team B"),
            Manga.Chapter(key: "c", chapter: 1.5),
            Manga.Chapter(key: "extra-1"),
            Manga.Chapter(key: "extra-2"),
            Manga.Chapter(key: "extra-2")
        ]

        #expect(chapters.distinctChapterCount == 4)
    }

    private func makeSubject(
        knownCount: Int?,
        status: String? = nil,
        lastCheckedAt: Date? = nil,
        lastUpdatedAt: Date? = nil
    ) async throws -> (TestDatabase, UpdateManager, LibraryItem) {
        let database = try TestDatabase()
        let item = LibraryItem(
            id: "update-item",
            title: "Update Item",
            coverUrl: nil,
            pluginId: "test.plugin",
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil,
            status: status,
            lastCheckedAt: lastCheckedAt,
            lastUpdatedAt: lastUpdatedAt,
            knownChapterCount: knownCount
        )
        try await database.dbPool.write { db in
            try item.insert(db)
        }
        return (
            database,
            UpdateManager(dbPool: database.dbPool),
            item
        )
    }

    private func identity(for item: LibraryItem) -> MediaIdentity {
        MediaIdentity(pluginId: item.pluginId, itemId: item.id)
    }

    private func successfulUpdate(
        _ manager: UpdateManager,
        item: LibraryItem,
        freshCount: Int,
        status: String? = "updated",
        checkedAt: Date = Date()
    ) async -> Int? {
        await manager.processUpdate(for: item, checkedAt: checkedAt) {
            UpdateManager.SuccessfulUpdate(freshCount: freshCount, status: status)
        }
    }

    private func persistedItem(_ database: TestDatabase, id: String) async throws -> LibraryItem {
        try await database.dbPool.read { db in
            let fetchedItem = try LibraryItem.fetchOne(db, key: id)
            return try #require(fetchedItem)
        }
    }
}

private enum StubError: Error {
    case fetchFailed
}

private extension Collection {
    var single: Element? {
        count == 1 ? first : nil
    }
}
