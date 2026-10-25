import GRDB
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class MultiKindDurableIdentityTests: XCTestCase {
    func testSavingSameKeyMangaAndNovelCreatesIndependentLibraryItems() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = LibraryManager(dbPool: database.dbPool, observationScheduler: ManualLibraryObservationScheduler())
        let mangaID = try await manager.saveMangaDurably(
            manga: Manga(key: "42", title: "Manga 42"), pluginId: "source.multi"
        )
        let novelID = try await manager.saveNovelDurably(
            novel: Novel(key: "42", title: "Novel 42"), pluginId: "source.multi"
        )
        let stored = try await database.dbPool.read { db in
            try LibraryItem.filter(Column("pluginId") == "source.multi").fetchAll(db)
        }
        XCTAssertNotEqual(mangaID, novelID)
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(Set(stored.map(\.effectiveType)), [.manga, .novel])
        XCTAssertEqual(Set(stored.map(\.title)), ["Manga 42", "Novel 42"])
    }

    func testSavedItemIDAndUnsaveForSameKeyDifferentKinds() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = LibraryManager(dbPool: database.dbPool, observationScheduler: ManualLibraryObservationScheduler())
        let mangaID = try await manager.saveMangaDurably(
            manga: Manga(key: "42", title: "Manga 42"), pluginId: "source.multi"
        )
        let novelID = try await manager.saveNovelDurably(
            novel: Novel(key: "42", title: "Novel 42"), pluginId: "source.multi"
        )

        XCTAssertEqual(manager.savedItemID(sourceItemID: "42", pluginId: "source.multi", mediaKind: .manga), mangaID)
        XCTAssertEqual(manager.savedItemID(sourceItemID: "42", pluginId: "source.multi", mediaKind: .novel), novelID)
        XCTAssertNil(manager.savedItemID(sourceItemID: "42", pluginId: "source.multi", mediaKind: .anime))

        try await manager.removeItemDurably(id: "42", pluginId: "source.multi", mediaKind: .manga)

        XCTAssertNil(manager.savedItemID(sourceItemID: "42", pluginId: "source.multi", mediaKind: .manga))
        XCTAssertEqual(manager.savedItemID(sourceItemID: "42", pluginId: "source.multi", mediaKind: .novel), novelID)

        let remaining = try await database.dbPool.read { db in
            try LibraryItem.filter(Column("pluginId") == "source.multi").fetchAll(db)
        }
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.effectiveType, .novel)
        XCTAssertEqual(remaining.first?.id, novelID)
    }

    func testReadProgressAndPositionsDistinguishSameKeyDifferentKinds() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let progressManager = ReadProgressManager(dbPool: database.dbPool)
        let mangaMedia = MediaIdentity(pluginId: "source.multi", canonicalMediaId: "42", mediaKind: .manga)
        let novelMedia = MediaIdentity(pluginId: "source.multi", canonicalMediaId: "42", mediaKind: .novel)

        let mangaContext = progressManager.captureCompletionContext(media: mangaMedia, mediaKey: "42")
        let novelContext = progressManager.captureCompletionContext(media: novelMedia, mediaKey: "42")

        XCTAssertEqual(mangaContext.mediaKey, "42")
        XCTAssertEqual(novelContext.mediaKey, "42")
        XCTAssertEqual(mangaContext.kind, .manga)
        XCTAssertEqual(novelContext.kind, .novel)

        try await progressManager.markAsRead(context: mangaContext, chapterId: "ch-1", chapterNum: 1.0)
        XCTAssertTrue(progressManager.isRead(media: mangaMedia, chapterId: "ch-1"))
        XCTAssertFalse(progressManager.isRead(media: novelMedia, chapterId: "ch-1"))

        try await progressManager.savePosition(media: mangaMedia, chapterKey: "ch-1", position: 12.0)
        try await progressManager.savePosition(media: novelMedia, chapterKey: "ch-1", position: 345.0)
        XCTAssertEqual(progressManager.savedPosition(media: mangaMedia, chapterKey: "ch-1"), 12.0)
        XCTAssertEqual(progressManager.savedPosition(media: novelMedia, chapterKey: "ch-1"), 345.0)

        let reloaded = ReadProgressManager(dbPool: database.dbPool)
        try await reloaded.reload()
        XCTAssertTrue(reloaded.isRead(media: mangaMedia, chapterId: "ch-1"))
        XCTAssertFalse(reloaded.isRead(media: novelMedia, chapterId: "ch-1"))
        XCTAssertEqual(reloaded.savedPosition(media: mangaMedia, chapterKey: "ch-1"), 12.0)
        XCTAssertEqual(reloaded.savedPosition(media: novelMedia, chapterKey: "ch-1"), 345.0)
    }

    func testTrackerLinksDistinguishSameKeyDifferentKinds() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let trackerManager = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let mangaMedia = MediaIdentity(pluginId: "source.multi", canonicalMediaId: "42", mediaKind: .manga)
        let novelMedia = MediaIdentity(pluginId: "source.multi", canonicalMediaId: "42", mediaKind: .novel)

        try await trackerManager.link(media: mangaMedia, providerId: "anilist", remoteMediaId: "manga-remote-id")
        try await trackerManager.link(media: novelMedia, providerId: "anilist", remoteMediaId: "novel-remote-id")

        XCTAssertEqual(trackerManager.trackerId(for: mangaMedia, providerId: "anilist"), "manga-remote-id")
        XCTAssertEqual(trackerManager.trackerId(for: novelMedia, providerId: "anilist"), "novel-remote-id")

        try await trackerManager.unlink(media: mangaMedia, providerId: "anilist")
        XCTAssertNil(trackerManager.trackerId(for: mangaMedia, providerId: "anilist"))
        XCTAssertEqual(trackerManager.trackerId(for: novelMedia, providerId: "anilist"), "novel-remote-id")

        let reloaded = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        try await reloaded.reload()
        XCTAssertNil(reloaded.trackerId(for: mangaMedia, providerId: "anilist"))
        XCTAssertEqual(reloaded.trackerId(for: novelMedia, providerId: "anilist"), "novel-remote-id")
    }

    func testUpdateBaselinesAndBadgesDistinguishSameKeyDifferentKinds() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let library = LibraryManager(dbPool: database.dbPool, observationScheduler: ManualLibraryObservationScheduler())
        let updates = UpdateManager(dbPool: database.dbPool)
        library.configure(updateManager: updates)

        let mangaID = try await library.saveMangaDurably(manga: Manga(key: "42", title: "Manga 42"), pluginId: "source.multi")
        let novelID = try await library.saveNovelDurably(novel: Novel(key: "42", title: "Novel 42"), pluginId: "source.multi")

        let mangaItem = try await database.dbPool.read { db in try XCTUnwrap(try LibraryItem.fetchOne(db, key: mangaID)) }
        let novelItem = try await database.dbPool.read { db in try XCTUnwrap(try LibraryItem.fetchOne(db, key: novelID)) }

        _ = await updates.processUpdate(for: mangaItem) {
            UpdateManager.SuccessfulUpdate(freshCount: 3, status: "ongoing")
        }
        _ = await updates.processUpdate(for: novelItem) {
            UpdateManager.SuccessfulUpdate(freshCount: 7, status: "ongoing")
        }

        XCTAssertEqual(updates.badgeCount(for: mangaItem.mediaIdentity), 3)
        XCTAssertEqual(updates.badgeCount(for: novelItem.mediaIdentity), 7)
        XCTAssertEqual(updates.totalBadgeCount, 10)

        try await updates.clearBadge(for: mangaItem.mediaIdentity)
        XCTAssertEqual(updates.badgeCount(for: mangaItem.mediaIdentity), 0)
        XCTAssertEqual(updates.badgeCount(for: novelItem.mediaIdentity), 7)

        let reloaded = UpdateManager(dbPool: database.dbPool)
        try await reloaded.reload()
        XCTAssertEqual(reloaded.badgeCount(for: mangaItem.mediaIdentity), 0)
        XCTAssertEqual(reloaded.badgeCount(for: novelItem.mediaIdentity), 7)

        let mangaCountBefore = try await database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: mangaID)?.knownChapterCount
        }
        try await updates.advanceBaseline(media: novelItem.mediaIdentity, knownChapterCount: 100)
        let counts = try await database.dbPool.read { db in
            (
                try LibraryItem.fetchOne(db, key: mangaID)?.knownChapterCount,
                try LibraryItem.fetchOne(db, key: novelID)?.knownChapterCount
            )
        }
        XCTAssertEqual(counts.0, mangaCountBefore)
        XCTAssertEqual(counts.1, 100)
    }

    func testSameKeyKindsSavedByTheLibraryRemapToDistinctDestinations() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let library = LibraryManager(dbPool: database.dbPool, observationScheduler: ManualLibraryObservationScheduler())
        let mangaID = try await library.saveMangaDurably(manga: Manga(key: "42", title: "Manga 42"), pluginId: "source.multi")
        let novelID = try await library.saveNovelDurably(novel: Novel(key: "42", title: "Novel 42"), pluginId: "source.multi")

        let result = try await LibrarySourceRemapper(dbPool: database.dbPool).remap(
            oldPluginId: "source.multi",
            newPluginId: "source.next",
            affectedItemIds: [mangaID, novelID]
        )

        XCTAssertEqual(result.remappedItemCount, 2)
        let remapped = try await database.dbPool.read { db in
            try LibraryItem.filter(Column("pluginId") == "source.next").fetchAll(db)
        }
        XCTAssertEqual(remapped.count, 2)
        XCTAssertEqual(Set(remapped.map(\.mediaIdentity)), [
            MediaIdentity(pluginId: "source.next", canonicalMediaId: "42", mediaKind: .manga),
            MediaIdentity(pluginId: "source.next", canonicalMediaId: "42", mediaKind: .novel)
        ])
    }

    func testRemappingIntoAnotherKindOfTheSameKeyKeepsBothSeriesRemappable() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let library = LibraryManager(dbPool: database.dbPool, observationScheduler: ManualLibraryObservationScheduler())
        _ = try await library.saveAnimeDurably(
            anime: Anime(key: "42", title: "Target Anime"), pluginId: "target"
        )
        let mangaID = try await library.saveMangaDurably(
            manga: Manga(key: "42", title: "Source Manga"), pluginId: "source"
        )
        let remapper = LibrarySourceRemapper(dbPool: database.dbPool)
        _ = try await remapper.remap(oldPluginId: "source", newPluginId: "target", affectedItemIds: [mangaID])
        let targetItems = try await database.dbPool.read { db in
            try LibraryItem.filter(Column("pluginId") == "target").fetchAll(db)
        }
        XCTAssertEqual(Set(targetItems.map(\.mediaIdentity)), [
            MediaIdentity(pluginId: "target", canonicalMediaId: "42", mediaKind: .anime),
            MediaIdentity(pluginId: "target", canonicalMediaId: "42", mediaKind: .manga)
        ])

        do {
            _ = try await remapper.remap(
                oldPluginId: "target",
                newPluginId: "final",
                affectedItemIds: targetItems.map(\.id)
            )
        } catch {
            return XCTFail("Both kinds must remain remappable: \(error)")
        }
        let finalItems = try await database.dbPool.read { db in try LibraryItem.fetchAll(db) }
        XCTAssertEqual(Set(finalItems.map(\.mediaIdentity)), [
            MediaIdentity(pluginId: "final", canonicalMediaId: "42", mediaKind: .anime),
            MediaIdentity(pluginId: "final", canonicalMediaId: "42", mediaKind: .manga)
        ])
        XCTAssertEqual(Set(finalItems.map(\.title)), ["Target Anime", "Source Manga"])
    }

    func testPreviouslyRemappedUnscopedKindsCanMoveTogetherWithoutCollision() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        // A previous remap could leave two kinds under raw and legacy ids.
        let manga = LibraryItem(
            id: "42", title: "Manga", coverUrl: nil, pluginId: "old",
            isAnime: false, pluginType: .manga,
            rawPayload: try JSONEncoder().encode(Manga(key: "42", title: "Manga")), anilistId: nil
        )
        let novel = LibraryItem(
            id: "old_42", title: "Novel", coverUrl: nil, pluginId: "old",
            isAnime: false, pluginType: .novel,
            rawPayload: try JSONEncoder().encode(Novel(key: "42", title: "Novel")), anilistId: nil
        )
        try await database.dbPool.write { db in
            try manga.insert(db)
            try novel.insert(db)
        }
        _ = try await LibrarySourceRemapper(dbPool: database.dbPool).remap(
            oldPluginId: "old", newPluginId: "new", affectedItemIds: [manga.id, novel.id]
        )
        let moved = try await database.dbPool.read { db in try LibraryItem.fetchAll(db) }
        XCTAssertEqual(Set(moved.map(\.mediaIdentity)), [
            MediaIdentity(pluginId: "new", canonicalMediaId: "42", mediaKind: .manga),
            MediaIdentity(pluginId: "new", canonicalMediaId: "42", mediaKind: .novel)
        ])
        XCTAssertEqual(moved.count, 2)
    }

    func testDestinationPrefixShapedKeysKeepTheirCanonicalIdentityAndResumeState() async throws {
        for occupiedID in ["q_q_42", "q_42"] {
            let database = try TestDatabase()
            defer { database.cleanup() }
            let source = LibraryItem(
                id: "p_q_42", title: "Source", coverUrl: nil, pluginId: "p",
                isAnime: false, pluginType: .manga,
                rawPayload: try JSONEncoder().encode(Manga(key: "q_42", title: "Source")), anilistId: nil
            )
            let occupant = LibraryItem(
                id: occupiedID, title: "Other", coverUrl: nil,
                pluginId: occupiedID == "q_42" ? "q" : "r", isAnime: false, pluginType: .manga,
                rawPayload: try JSONEncoder().encode(Manga(key: "42", title: "Other")), anilistId: nil
            )
            try await database.dbPool.write { db in
                try source.insert(db)
                try occupant.insert(db)
            }
            let progress = ReadProgressManager(dbPool: database.dbPool)
            try await progress.savePosition(
                media: MediaIdentity(pluginId: "p", canonicalMediaId: "q_42", mediaKind: .manga),
                chapterKey: "chapter", position: 12
            )
            do {
                _ = try await LibrarySourceRemapper(dbPool: database.dbPool).remap(
                    oldPluginId: "p", newPluginId: "q", affectedItemIds: [source.id]
                )
            } catch {
                return XCTFail("An unrelated occupied id must not block the typed identity: \(error)")
            }
            let moved = try await database.dbPool.read { db in
                try XCTUnwrap(try LibraryItem
                    .filter(Column("pluginId") == "q")
                    .filter(Column("title") == "Source")
                    .fetchOne(db))
            }
            XCTAssertEqual(moved.mediaIdentity, MediaIdentity(
                pluginId: "q", canonicalMediaId: "q_42", mediaKind: .manga
            ))
            let reloaded = ReadProgressManager(dbPool: database.dbPool)
            try await reloaded.reload()
            XCTAssertEqual(reloaded.savedPosition(media: moved.mediaIdentity, chapterKey: "chapter"), 12)
            let retained = try await database.dbPool.read { db in try LibraryItem.fetchOne(db, key: occupiedID) }
            XCTAssertEqual(retained, occupant)
        }
    }

    func testHistoryRecordsRealKindAndActualSavedItemID() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let library = LibraryManager(dbPool: database.dbPool, observationScheduler: ManualLibraryObservationScheduler())
        let settings = AppSettingsStore(dbPool: database.dbPool)
        try await settings.reload()
        let history = HistoryManager(dbPool: database.dbPool, libraryManager: library)
        history.configure(settingsStore: settings)

        let novelID = try await library.saveNovelDurably(novel: Novel(key: "42", title: "Novel 42"), pluginId: "source.multi")

        let mangaTask = history.recordManga(
            Manga(key: "42", title: "Manga 42"),
            chapterKey: "m-ch1",
            chapterTitle: "Chapter 1",
            pluginId: "source.multi"
        )
        let novelTask = history.recordNovel(
            Novel(key: "42", title: "Novel 42"),
            chapterKey: "n-ch1",
            chapterTitle: "Chapter 1",
            pluginId: "source.multi"
        )
        await mangaTask?.value
        await novelTask?.value

        let records = try await database.dbPool.read { db in
            try ReadingHistoryRecord.filter(Column("pluginId") == "source.multi").fetchAll(db)
        }
        XCTAssertEqual(records.count, 2)

        let mangaRecord = records.first { $0.mediaKind == .manga }
        let novelRecord = records.first { $0.mediaKind == .novel }

        XCTAssertNotNil(mangaRecord)
        XCTAssertNil(mangaRecord?.libraryItemId)
        XCTAssertEqual(mangaRecord?.mediaKey, "42")
        XCTAssertEqual(mangaRecord?.mediaKind, .manga)

        XCTAssertNotNil(novelRecord)
        XCTAssertEqual(novelRecord?.libraryItemId, novelID)
        XCTAssertEqual(novelRecord?.mediaKey, "42")
        XCTAssertEqual(novelRecord?.mediaKind, .novel)
    }
}
