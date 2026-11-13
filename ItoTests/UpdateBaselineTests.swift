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
        try await manager.advanceBaseline(media: identity(for: item), knownChapterCount: 13)
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

    @Test func emptyAnswerKeepsTheKnownCountSoTheNextAnswerIsNotAllNew() async throws {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_001)
        let (database, manager, item) = try await makeSubject(knownCount: 12, status: "ongoing")
        defer { database.cleanup() }

        let emptyDelta = await successfulUpdate(manager, item: item, freshCount: 0, status: "completed", checkedAt: checkedAt)
        #expect(emptyDelta == 0)
        let afterEmpty = try await persistedItem(database, id: item.id)
        #expect(afterEmpty.knownChapterCount == 12)
        #expect(afterEmpty.status == "ongoing")
        #expect(afterEmpty.lastCheckedAt == checkedAt)

        let delta = await successfulUpdate(manager, item: item, freshCount: 13)
        #expect(delta == 1)
        #expect(manager.badgeCount(for: identity(for: item)) == 1)
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

    @Test func reloadPublishesBadgesOfLibrarySeriesOnly() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            // The legacy "plugin_id" form maps to the same series identity as "id".
            for (plugin, id) in [("one", "same"), ("two", "two_same")] {
                try LibraryItem(
                    id: id, title: id, coverUrl: nil, pluginId: plugin, isAnime: false, pluginType: .manga,
                    rawPayload: Data(), anilistId: nil, status: nil, lastCheckedAt: nil, lastUpdatedAt: nil,
                    knownChapterCount: 1
                ).insert(db)
            }
            for (plugin, mediaID, count) in [("one", "same", 3), ("two", "same", 5), ("one", "removed", 7)] {
                try UpdateBadgeRecord(
                    pluginId: plugin,
                    canonicalMediaId: mediaID,
                    mediaKind: .manga,
                    count: count,
                    updatedAt: nil,
                    provenance: .runtime
                ).insert(db)
            }
        }
        let manager = UpdateManager(dbPool: database.dbPool)

        try await manager.reload()

        #expect(manager.badgeCount(
            for: MediaIdentity(pluginId: "one", canonicalMediaId: "same", mediaKind: .manga)
        ) == 3)
        #expect(manager.badgeCount(
            for: MediaIdentity(pluginId: "two", canonicalMediaId: "same", mediaKind: .manga)
        ) == 5)
        // A badge left by a series no longer in the library is not counted.
        #expect(manager.totalBadgeCount == 8)
    }

    @Test func removingASeriesRemovesItsBadge() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: 10)
        defer { database.cleanup() }
        let library = LibraryManager(dbPool: database.dbPool)
        library.configure(updateManager: manager)
        #expect(await successfulUpdate(manager, item: item, freshCount: 12) == 2)

        try await library.removeItemDurably(itemID: item.id, pluginId: item.pluginId, mediaKind: item.effectiveType)

        #expect(manager.totalBadgeCount == 0)
        let badgeRows = try await database.dbPool.read { db in try UpdateBadgeRecord.fetchCount(db) }
        #expect(badgeRows == 0)
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
                    mediaKind: .manga,
                    count: -1,
                    updatedAt: nil,
                    provenance: .runtime
                ).insert(db)
            }
        }
    }

    @Test func sameKeyMangaAndNovelMaintainIndependentBadgesAndBaselines() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let library = LibraryManager(dbPool: database.dbPool)
        let updates = UpdateManager(dbPool: database.dbPool)
        library.configure(updateManager: updates)

        let mangaID = try await library.saveMangaDurably(manga: Manga(key: "series", title: "Manga Title", chapters: [Chapter(key: "one")]), pluginId: "source.multi")
        let novelID = try await library.saveNovelDurably(novel: Novel(key: "series", title: "Novel Title", chapters: [Chapter(key: "one")]), pluginId: "source.multi")

        let mangaItem = try await database.dbPool.read { db in try #require(try LibraryItem.fetchOne(db, key: mangaID)) }
        let novelItem = try await database.dbPool.read { db in try #require(try LibraryItem.fetchOne(db, key: novelID)) }

        let mangaDelta = await successfulUpdate(updates, item: mangaItem, freshCount: 5)
        let novelDelta = await successfulUpdate(updates, item: novelItem, freshCount: 2)

        #expect(mangaDelta == 4)
        #expect(novelDelta == 1)
        #expect(updates.badgeCount(for: mangaItem.mediaIdentity) == 4)
        #expect(updates.badgeCount(for: novelItem.mediaIdentity) == 1)
        #expect(updates.totalBadgeCount == 5)

        try await updates.clearBadge(for: mangaItem.mediaIdentity)
        #expect(updates.badgeCount(for: mangaItem.mediaIdentity) == 0)
        #expect(updates.badgeCount(for: novelItem.mediaIdentity) == 1)
        #expect(updates.totalBadgeCount == 1)

        let reloaded = UpdateManager(dbPool: database.dbPool)
        try await reloaded.reload()
        #expect(reloaded.badgeCount(for: mangaItem.mediaIdentity) == 0)
        #expect(reloaded.badgeCount(for: novelItem.mediaIdentity) == 1)
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

    @Test func distinctExactUploadsCountEvenWhenNumberAndGroupMatch() {
        let chapters = [
            Manga.Chapter(key: "a", chapter: 1, scanlator: "Team A"),
            Manga.Chapter(key: "b", chapter: 1, scanlator: "Team B"),
            Manga.Chapter(key: "c", chapter: 1.5),
            Manga.Chapter(key: "extra-1"),
            Manga.Chapter(key: "extra-2"),
            Manga.Chapter(key: "extra-2")
        ]

        #expect(chapters.distinctChapterCount == 5)
    }

    @Test func rawDoubleCollisionsAndLogicalMetadataNeverMergeExactKeys() {
        let raw = [1.1, Double(Float(1.1))]
        #expect(raw[0] != raw[1])
        let before = [
            Chapter(key: "part-a", chapter: raw[0], scanlator: "Same group"),
            Chapter(key: "part-b", chapter: raw[1], scanlator: "Same group")
        ]
        #expect(before[0].chapterNumber == before[1].chapterNumber)
        #expect(before.distinctChapterCount == 2)
        let after = [
            Chapter(key: "part-a", chapter: raw[0], scanlator: "Renamed", scanlatorID: "group", logicalUnitID: "unit"),
            Chapter(key: "part-b", chapter: raw[1], scanlator: "Renamed", scanlatorID: "group", logicalUnitID: "unit")
        ]
        #expect(after.distinctChapterCount == before.distinctChapterCount)
        #expect((after + [after[0]]).distinctChapterCount == 2)
    }

    @Test func byteDistinctKeysDoNotMergeThroughUnicodeNormalization() {
        #expect([Chapter(key: "\u{e9}"), Chapter(key: "e\u{301}")].distinctChapterCount == 2)
    }

    @Test(arguments: [ChapterCountBasis?.none, .some(.unknown)])
    func legacyBasisSeedsWithoutBadgeOrTimestampChanges(basis: ChapterCountBasis?) async throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let (database, manager, item) = try await makeSubject(
            knownCount: 10, lastUpdatedAt: timestamp, basis: basis
        )
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            try UpdateBadgeRecord(
                pluginId: item.pluginId, canonicalMediaId: item.mediaIdentity.canonicalMediaId,
                mediaKind: .manga, count: 3, updatedAt: timestamp, provenance: .runtime
            ).save(db)
        }
        #expect(await successfulUpdate(manager, item: item, freshCount: 20) == 0)
        let seeded = try await persistedItem(database, id: item.id)
        #expect(seeded.knownChapterCount == 20)
        #expect(seeded.knownChapterCountBasis == .exactChapterKeys)
        #expect(seeded.lastUpdatedAt == timestamp)
        #expect(manager.badgeCount(for: item.mediaIdentity) == 3)
        let badge = try await database.dbPool.read { db in try UpdateBadgeRecord.fetchAll(db).first }
        #expect(badge?.updatedAt == timestamp)
        #expect(await successfulUpdate(manager, item: item, freshCount: 21) == 1)
        #expect(manager.badgeCount(for: item.mediaIdentity) == 4)
    }

    @Test func failedAndEmptyRefreshesDoNotSeedLegacyBasis() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: nil, basis: nil)
        defer { database.cleanup() }
        #expect(await manager.processUpdate(for: item) { throw StubError.fetchFailed } == nil)
        #expect(await successfulUpdate(manager, item: item, freshCount: 0) == 0)
        let unchanged = try await persistedItem(database, id: item.id)
        #expect(unchanged.knownChapterCount == nil)
        #expect(unchanged.knownChapterCountBasis == nil)
        #expect(await successfulUpdate(manager, item: item, freshCount: 8) == 0)
        #expect(try await persistedItem(database, id: item.id).knownChapterCountBasis == .exactChapterKeys)
    }

    @Test func detailAcknowledgmentSetsBasisAndClearsBadge() async throws {
        let (database, manager, item) = try await makeSubject(knownCount: 3, basis: nil)
        defer { database.cleanup() }
        try await manager.advanceBaseline(media: item.mediaIdentity, knownChapterCount: 6)
        let acknowledged = try await persistedItem(database, id: item.id)
        #expect(acknowledged.knownChapterCount == 6)
        #expect(acknowledged.knownChapterCountBasis == .exactChapterKeys)
        #expect(await successfulUpdate(manager, item: item, freshCount: 7) == 1)
    }

    @Test func animeStillCombinesNumberedLanguagesAndCountsUnnumberedKeys() {
        let episodes = [
            Anime.Episode(key: "sub", episode: 1),
            Anime.Episode(key: "dub", episode: 1),
            Anime.Episode(key: "extra"),
            Anime.Episode(key: "extra")
        ]
        #expect(episodes.distinctChapterCount == 2)
    }

    @Test func additiveMigrationLeavesOldCountsUntypedAndUntouched() throws {
        let database = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(database, upTo: "v21")
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO libraryItem
                    (id, title, pluginId, isAnime, pluginType, rawPayload, knownChapterCount, lastUpdatedAt)
                VALUES ('old', 'Old', 'source', 0, 'manga', X'', 10, 100)
                """)
        }
        try migrator.migrate(database)
        try database.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM libraryItem WHERE id = 'old'"))
            #expect((row["knownChapterCount"] as Int?) == 10)
            #expect((row["lastUpdatedAt"] as Int?) == 100)
            #expect((row["knownChapterCountBasis"] as String?) == nil)
        }
    }

    @Test func explicitSavesOnlyEstablishExactBasisWithANonemptyCatalog() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let library = LibraryManager(dbPool: database.dbPool)
        let emptyID = try await library.saveNovelDurably(
            novel: Novel(key: "empty", title: "Empty", chapters: []), pluginId: "source"
        )
        let fullID = try await library.saveNovelDurably(
            novel: Novel(key: "full", title: "Full", chapters: [
                Chapter(key: "a", chapter: 1), Chapter(key: "b", chapter: 1)
            ]), pluginId: "source"
        )
        let empty = try await persistedItem(database, id: emptyID)
        let full = try await persistedItem(database, id: fullID)
        #expect(empty.knownChapterCountBasis == nil)
        #expect(full.knownChapterCount == 2)
        #expect(full.knownChapterCountBasis == .exactChapterKeys)
    }

    @Test func animeNilBasisRetainsItsExistingGrowthHeuristic() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let library = LibraryManager(dbPool: database.dbPool)
        let itemID = try await library.saveAnimeDurably(
            anime: Anime(key: "anime", title: "Anime"), pluginId: "source"
        )
        let item = try await persistedItem(database, id: itemID)
        let manager = UpdateManager(dbPool: database.dbPool)
        #expect(item.knownChapterCountBasis == nil)
        #expect(await successfulUpdate(manager, item: item, freshCount: 3) == 3)
        #expect(try await persistedItem(database, id: itemID).knownChapterCountBasis == nil)
    }

    private func makeSubject(
        knownCount: Int?,
        status: String? = nil,
        lastCheckedAt: Date? = nil,
        lastUpdatedAt: Date? = nil,
        basis: ChapterCountBasis? = .exactChapterKeys
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
            knownChapterCount: knownCount,
            knownChapterCountBasis: basis
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
        item.mediaIdentity
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
