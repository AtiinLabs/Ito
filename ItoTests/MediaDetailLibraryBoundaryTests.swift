import GRDB
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class MediaDetailLibraryBoundaryTests: XCTestCase {
    func testDurableSaveCommitsBeforeReturningSuccessAndPublishesSnapshot() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let uncategorized = LibraryCategory(
            id: "uncategorized",
            name: "Uncategorized",
            sortOrder: 0,
            isSystemCategory: true,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let preSaveItem = LibraryItem(
            id: "pre-save",
            title: "Pre-save",
            coverUrl: nil,
            pluginId: "plugin.test",
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil
        )
        try await database.dbPool.write { db in
            // The fixture's system list replaces the migrated one.
            try db.execute(sql: "DELETE FROM libraryCategory WHERE isSystemCategory = 1")
            try uncategorized.insert(db)
            try preSaveItem.insert(db)
        }
        let scheduler = ManualLibraryObservationScheduler()
        let manager = LibraryManager(
            dbPool: database.dbPool,
            observationScheduler: scheduler
        )
        XCTAssertEqual(manager.categories, [uncategorized])
        XCTAssertEqual(manager.items, [preSaveItem])
        XCTAssertTrue(manager.links.isEmpty)
        try await database.dbPool.write { db in
            try preSaveItem.delete(db)
        }
        let stalePreSavePublication = await scheduler.nextPublication()
        let preSaveCount = try await database.dbPool.read(LibraryItem.fetchCount)
        XCTAssertEqual(preSaveCount, 0)
        let media = Manga(key: "m1", title: "Manga")

        let durableItemID = try await manager.saveMangaDurably(
            manga: media,
            pluginId: "plugin.test"
        )

        XCTAssertEqual(durableItemID, "m1")
        let stored = try await database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: "m1")
        }
        XCTAssertEqual(stored?.pluginId, "plugin.test")
        XCTAssertTrue(manager.items.contains { $0.id == "m1" && $0.pluginId == "plugin.test" })
        XCTAssertEqual(manager.links.map(\.itemId), ["m1"])
        XCTAssertEqual(manager.links.map(\.categoryId), [uncategorized.id])
        stalePreSavePublication.run()
        XCTAssertTrue(manager.items.contains { $0.id == "m1" && $0.pluginId == "plugin.test" })
        XCTAssertEqual(manager.categories, [uncategorized])
        XCTAssertEqual(manager.links.map(\.itemId), ["m1"])
        XCTAssertEqual(manager.links.map(\.categoryId), [uncategorized.id])
        XCTAssertTrue(
            manager.state.isSaved(
                media: MediaIdentity(pluginId: "plugin.test", itemId: "m1", mediaKind: .manga),
                sourceItemID: "m1"
            )
        )
    }

    func testDurableSaveFailureDoesNotPublishFalseSuccess() async throws {
        let database = try TestDatabase()
        let manager = LibraryManager(dbPool: database.dbPool)
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_media_detail_save
                BEFORE INSERT ON libraryItem
                BEGIN
                    SELECT RAISE(ABORT, 'forced save failure');
                END
                """)
        }

        do {
            try await manager.saveAnimeDurably(
                anime: Anime(key: "a1", title: "Anime"),
                pluginId: "plugin.test"
            )
            XCTFail("Expected durable save failure")
        } catch {}

        let count = try await database.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM libraryItem") ?? 0
        }
        XCTAssertEqual(count, 0)
        XCTAssertFalse(manager.items.contains { $0.id == "a1" })
        XCTAssertFalse(
            manager.state.isSaved(
                media: MediaIdentity(pluginId: "plugin.test", itemId: "a1", mediaKind: .anime),
                sourceItemID: "a1"
            )
        )
    }

    func testDurableSaveUsesCompatiblePrefixedIdentityWhenAnotherPluginOwnsRawKey() async throws {
        let database = try TestDatabase()
        let manager = LibraryManager(dbPool: database.dbPool)
        _ = try await manager.saveMangaDurably(
            manga: Manga(key: "shared", title: "First"),
            pluginId: "plugin.first"
        )

        let durableItemID = try await manager.saveMangaDurably(
            manga: Manga(key: "shared", title: "Second"),
            pluginId: "plugin.second"
        )

        XCTAssertEqual(durableItemID, "plugin.second_shared")
        let stored = try await database.dbPool.read { db in
            try LibraryItem.order(Column("id")).fetchAll(db)
        }
        XCTAssertEqual(stored.map(\.id), ["plugin.second_shared", "shared"])
        XCTAssertTrue(
            manager.state.isSaved(
                media: MediaIdentity(pluginId: "plugin.second", itemId: "shared", mediaKind: .manga),
                sourceItemID: "shared"
            )
        )
    }

    func testDurableUnsaveCommitsBeforeReturningAndPublishesSnapshot() async throws {
        let database = try TestDatabase()
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.saveNovelDurably(
            novel: Novel(key: "n1", title: "Novel"),
            pluginId: "plugin.test"
        )

        try await manager.removeItemDurably(id: "n1", pluginId: "plugin.test", mediaKind: .novel)

        let stored = try await database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: "n1")
        }
        XCTAssertNil(stored)
        XCTAssertFalse(manager.items.contains { $0.id == "n1" })
    }

    func testDurableUnsaveFailurePreservesDatabaseAndPublishedState() async throws {
        let database = try TestDatabase()
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.saveMangaDurably(
            manga: Manga(key: "m1", title: "Manga"),
            pluginId: "plugin.test"
        )
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_media_detail_unsave
                BEFORE DELETE ON libraryItem
                BEGIN
                    SELECT RAISE(ABORT, 'forced unsave failure');
                END
                """)
        }

        do {
            try await manager.removeItemDurably(id: "m1", pluginId: "plugin.test", mediaKind: .manga)
            XCTFail("Expected durable unsave failure")
        } catch {}

        let stored = try await database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: "m1")
        }
        XCTAssertEqual(stored?.pluginId, "plugin.test")
        XCTAssertTrue(manager.items.contains { $0.id == "m1" })
    }
}
