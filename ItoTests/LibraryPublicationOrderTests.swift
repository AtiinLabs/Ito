import GRDB
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class LibraryPublicationOrderTests: XCTestCase {
    func testDurableAnimeAndNovelSavesReturnWithCommittedAuthoritativeState() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let uncategorized = makeCategory(
            id: "uncategorized",
            name: "Uncategorized",
            sortOrder: 0,
            isSystem: true
        )
        try await database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM libraryCategory WHERE isSystemCategory = 1")
            try uncategorized.insert(db)
        }
        let scheduler = ManualLibraryObservationScheduler()
        let manager = LibraryManager(
            dbPool: database.dbPool,
            observationScheduler: scheduler
        )

        let animeID = try await manager.saveAnimeDurably(
            anime: Anime(key: "anime", title: "Anime"),
            pluginId: "plugin.test"
        )
        let novelID = try await manager.saveNovelDurably(
            novel: Novel(key: "novel", title: "Novel"),
            pluginId: "plugin.test"
        )

        let persisted = try await database.dbPool.read { db in
            try LibraryItem.order(Column("id")).fetchAll(db)
        }
        XCTAssertEqual([animeID, novelID], ["anime", "novel"])
        XCTAssertEqual(persisted.map(\.id), ["anime", "novel"])
        XCTAssertEqual(manager.items.map(\.id).sorted(), ["anime", "novel"])
        XCTAssertTrue(isSaved("anime", manager: manager))
        XCTAssertTrue(isSaved("novel", manager: manager))
        XCTAssertEqual(linkPairs(manager.links), ["anime|uncategorized", "novel|uncategorized"])
    }

    func testStalePreRemoveObservationCannotRestoreCommittedRemoval() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let uncategorized = makeCategory(
            id: "uncategorized",
            name: "Uncategorized",
            sortOrder: 0,
            isSystem: true
        )
        try await database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM libraryCategory WHERE isSystemCategory = 1")
            try uncategorized.insert(db)
        }
        let scheduler = ManualLibraryObservationScheduler()
        let manager = LibraryManager(
            dbPool: database.dbPool,
            observationScheduler: scheduler
        )
        _ = try await manager.saveMangaDurably(
            manga: Manga(key: "remove-me", title: "Original"),
            pluginId: "plugin.test"
        )
        let saveObservation = await scheduler.nextPublication()
        saveObservation.run()
        let preRemoveMarker = makeItem(id: "pre-remove-marker")
        try await database.dbPool.write { db in
            try preRemoveMarker.insert(db)
        }
        let stalePreRemovePublication = await scheduler.nextPublication()

        try await manager.removeItemDurably(id: "remove-me", pluginId: "plugin.test")

        let stored = try await database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: "remove-me")
        }
        XCTAssertNil(stored)
        XCTAssertFalse(manager.items.contains { $0.id == "remove-me" })
        XCTAssertFalse(isSaved("remove-me", manager: manager))
        XCTAssertFalse(manager.links.contains { $0.itemId == "remove-me" })
        stalePreRemovePublication.run()
        XCTAssertFalse(manager.items.contains { $0.id == "remove-me" })
        XCTAssertFalse(isSaved("remove-me", manager: manager))
        XCTAssertFalse(manager.links.contains { $0.itemId == "remove-me" })
    }

    func testLaterExternalCommitsStillPublishAfterDurableSaveAndRemove() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let uncategorized = makeCategory(
            id: "uncategorized",
            name: "Uncategorized",
            sortOrder: 0,
            isSystem: true
        )
        try await database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM libraryCategory WHERE isSystemCategory = 1")
            try uncategorized.insert(db)
        }
        let scheduler = ManualLibraryObservationScheduler()
        let manager = LibraryManager(
            dbPool: database.dbPool,
            observationScheduler: scheduler
        )
        _ = try await manager.saveMangaDurably(
            manga: Manga(key: "durable", title: "Durable"),
            pluginId: "plugin.test"
        )
        let saveObservation = await scheduler.nextPublication()
        saveObservation.run()

        let external = makeItem(id: "external")
        try await database.dbPool.write { db in
            try external.insert(db)
        }
        let externalInsert = await scheduler.nextPublication()
        externalInsert.run()
        XCTAssertTrue(manager.items.contains { $0.id == external.id })

        try await database.dbPool.write { db in
            try external.delete(db)
        }
        let externalDelete = await scheduler.nextPublication()
        externalDelete.run()
        XCTAssertFalse(manager.items.contains { $0.id == external.id })

        try await manager.removeItemDurably(id: "durable", pluginId: "plugin.test")
        let removeObservation = await scheduler.nextPublication()
        removeObservation.run()
        XCTAssertFalse(isSaved("durable", manager: manager))

        let restored = makeItem(id: "durable", pluginId: "plugin.test")
        try await database.dbPool.write { db in
            try restored.insert(db)
            try ItemCategoryLink(
                itemId: restored.id,
                categoryId: uncategorized.id
            ).insert(db)
        }
        let externalRestore = await scheduler.nextPublication()
        externalRestore.run()
        XCTAssertTrue(isSaved("durable", manager: manager))
        XCTAssertTrue(manager.links.contains {
            $0.itemId == restored.id && $0.categoryId == uncategorized.id
        })

        let externalCategory = makeCategory(
            id: "external-category",
            name: "External",
            sortOrder: 1
        )
        try await database.dbPool.write { db in
            try externalCategory.insert(db)
            try ItemCategoryLink(
                itemId: restored.id,
                categoryId: externalCategory.id
            ).insert(db)
            try ItemCategoryLink.deleteOne(
                db,
                key: ["itemId": restored.id, "categoryId": uncategorized.id]
            )
        }
        let externalOrganization = await scheduler.nextPublication()
        externalOrganization.run()
        XCTAssertTrue(manager.categories.contains { $0.id == externalCategory.id })
        XCTAssertEqual(linkPairs(manager.links), ["durable|external-category"])
    }

    func testStaleCategoryAndLinkObservationCannotOverwriteDurableOrganization() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let uncategorized = makeCategory(
            id: "uncategorized",
            name: "Uncategorized",
            sortOrder: 0,
            isSystem: true
        )
        let item = makeItem(id: "organized")
        try await database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM libraryCategory WHERE isSystemCategory = 1")
            try uncategorized.insert(db)
            try item.insert(db)
            try ItemCategoryLink(
                itemId: item.id,
                categoryId: uncategorized.id
            ).insert(db)
        }
        let scheduler = ManualLibraryObservationScheduler()
        let manager = LibraryManager(
            dbPool: database.dbPool,
            observationScheduler: scheduler
        )
        let olderCategory = makeCategory(
            id: "older-category",
            name: "Older",
            sortOrder: 1
        )
        try await database.dbPool.write { db in
            try olderCategory.insert(db)
            try ItemCategoryLink(
                itemId: item.id,
                categoryId: olderCategory.id
            ).insert(db)
            try ItemCategoryLink.deleteOne(
                db,
                key: ["itemId": item.id, "categoryId": uncategorized.id]
            )
        }
        let staleOrganizationPublication = await scheduler.nextPublication()

        let newCategoryID = try await manager.createCategoryAndAssignDurably(
            name: "Newer",
            itemID: item.id
        )
        let persisted = try await database.dbPool.read { db in
            (
                try LibraryCategory.order(Column("sortOrder")).fetchAll(db),
                try LibraryItem.order(Column("title")).fetchAll(db),
                try ItemCategoryLink.fetchAll(db)
            )
        }
        XCTAssertTrue(manager.categories.contains { $0.id == newCategoryID })
        XCTAssertEqual(manager.categories, persisted.0)
        XCTAssertEqual(manager.items, persisted.1)
        XCTAssertEqual(linkPairs(manager.links), linkPairs(persisted.2))
        staleOrganizationPublication.run()
        XCTAssertEqual(manager.categories, persisted.0)
        XCTAssertEqual(manager.items, persisted.1)
        XCTAssertEqual(linkPairs(manager.links), linkPairs(persisted.2))
    }

    func testRolledBackSaveDoesNotPublishOrBlockLaterExternalObservation() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let scheduler = ManualLibraryObservationScheduler()
        let manager = LibraryManager(
            dbPool: database.dbPool,
            observationScheduler: scheduler
        )
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_library_publication_save
                AFTER INSERT ON libraryItem
                BEGIN
                    SELECT RAISE(ROLLBACK, 'forced rollback');
                END
                """)
        }

        do {
            _ = try await manager.saveAnimeDurably(
                anime: Anime(key: "rolled-back", title: "Rolled Back"),
                pluginId: "plugin.test"
            )
            XCTFail("Expected durable save rollback")
        } catch {}

        let stored = try await database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: "rolled-back")
        }
        XCTAssertNil(stored)
        XCTAssertFalse(manager.items.contains { $0.id == "rolled-back" })
        XCTAssertEqual(scheduler.queuedCount, 0)

        let external = makeItem(id: "external-after-rollback")
        try await database.dbPool.write { db in
            try db.execute(sql: "DROP TRIGGER reject_library_publication_save")
            try external.insert(db)
        }
        let externalPublication = await scheduler.nextPublication()
        externalPublication.run()
        XCTAssertEqual(manager.items.map(\.id), [external.id])
    }

    func testSeriesAreOrderedByTitleIgnoringCaseAndComparingNumbers() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let items = ["Zeta", "the Knight", "Volume 10", "Volume 2"].map { makeItem(id: $0) }
        try await database.dbPool.write { db in
            for item in items {
                try item.insert(db)
            }
        }

        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()

        XCTAssertEqual(manager.items.map(\.title), ["the Knight", "Volume 2", "Volume 10", "Zeta"])
    }

    private func makeItem(
        id: String,
        pluginId: String = "plugin.external"
    ) -> Ito.LibraryItem {
        Ito.LibraryItem(
            id: id,
            title: id,
            coverUrl: nil,
            pluginId: pluginId,
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil
        )
    }

    private func makeCategory(
        id: String,
        name: String,
        sortOrder: Int,
        isSystem: Bool = false
    ) -> LibraryCategory {
        LibraryCategory(
            id: id,
            name: name,
            sortOrder: sortOrder,
            isSystemCategory: isSystem,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func isSaved(_ id: String, manager: LibraryManager) -> Bool {
        manager.state.isSaved(
            media: MediaIdentity(pluginId: "plugin.test", itemId: id),
            sourceItemID: id
        )
    }

    private func linkPairs(_ links: [ItemCategoryLink]) -> Set<String> {
        Set(links.map { "\($0.itemId)|\($0.categoryId)" })
    }
}

nonisolated final class ManualLibraryObservationScheduler:
    ValueObservationMainActorScheduler, @unchecked Sendable {
    nonisolated struct ScheduledPublication: @unchecked Sendable {
        let action: @MainActor () -> Void

        @MainActor
        func run() {
            action()
        }
    }

    private let lock = NSLock()
    private var publications: [ScheduledPublication] = []
    private var continuations: [CheckedContinuation<ScheduledPublication, Never>] = []

    var queuedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return publications.count
    }

    func immediateInitialValue() -> Bool { true }

    func scheduleOnMainActor(_ action: @escaping @MainActor () -> Void) {
        let publication = ScheduledPublication(action: action)
        lock.lock()
        if continuations.isEmpty {
            publications.append(publication)
            lock.unlock()
        } else {
            let continuation = continuations.removeFirst()
            lock.unlock()
            continuation.resume(returning: publication)
        }
    }

    func nextPublication() async -> ScheduledPublication {
        await withCheckedContinuation { continuation in
            lock.lock()
            if publications.isEmpty {
                continuations.append(continuation)
                lock.unlock()
            } else {
                let publication = publications.removeFirst()
                lock.unlock()
                continuation.resume(returning: publication)
            }
        }
    }
}
