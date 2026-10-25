import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

struct LibrarySourceRemapperTests {
    @Test func successfulRemapPreservesStateCategoriesHistoryAndExactScope() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let oldPluginId = "old.source"
        let newPluginId = "new.source"
        let sourceId = "series-1"
        let destinationId = "new.source_series-1"
        let untouchedId = "series-2"
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_001)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_002)
        let payload = Data([0x01, 0x02, 0x03])

        let source = LibraryItem(
            id: sourceId,
            title: "Source title",
            coverUrl: "https://example.com/cover.jpg",
            pluginId: oldPluginId,
            isAnime: false,
            pluginType: .manga,
            rawPayload: payload,
            anilistId: 42,
            status: "reading",
            lastCheckedAt: checkedAt,
            lastUpdatedAt: updatedAt,
            knownChapterCount: 17
        )
        let untouched = LibraryItem(
            id: untouchedId,
            title: "Untouched",
            coverUrl: nil,
            pluginId: oldPluginId,
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil
        )
        let categories = [
            LibraryCategory(id: "cat-1", name: "One", sortOrder: 1),
            LibraryCategory(id: "cat-2", name: "Two", sortOrder: 2)
        ]
        let importedHistory = ReadingHistoryRecord(
            id: "history-imported",
            libraryItemId: "old.source_series-1",
            mediaKey: "old.source_series-1",
            title: source.title,
            coverUrl: source.coverUrl,
            pluginId: oldPluginId,
            mediaKind: .manga,
            chapterKey: "chapter-1",
            chapterTitle: "Chapter 1"
        )
        let nativeHistory = ReadingHistoryRecord(
            id: "history-native",
            libraryItemId: sourceId,
            mediaKey: sourceId,
            title: source.title,
            coverUrl: source.coverUrl,
            pluginId: oldPluginId,
            mediaKind: .manga,
            chapterKey: "chapter-2",
            chapterTitle: "Chapter 2"
        )

        try await database.dbPool.write { db in
            for category in categories { try category.insert(db) }
            try source.insert(db)
            try untouched.insert(db)
            try ItemCategoryLink(itemId: sourceId, categoryId: "cat-1").insert(db)
            try ItemCategoryLink(itemId: sourceId, categoryId: "cat-2").insert(db)
            try importedHistory.insert(db)
            try nativeHistory.insert(db)
            try ReadProgressKeyRecord(
                pluginId: oldPluginId,
                canonicalMediaId: sourceId,
                mediaKind: .manga,
                chapterKey: "chapter-key",
                markedAt: checkedAt,
                provenance: .runtime
            ).insert(db)
            try ReadProgressNumberRecord(
                pluginId: oldPluginId,
                canonicalMediaId: sourceId,
                mediaKind: .manga,
                chapterNumber: 4.5,
                markedAt: checkedAt,
                provenance: .runtime
            ).insert(db)
            try MediaReadProgressRecord(
                pluginId: oldPluginId,
                canonicalMediaId: sourceId,
                mediaKind: .manga,
                lastReadChapterKey: "resume-key",
                updatedAt: updatedAt,
                provenance: .runtime
            ).insert(db)
            try TrackerLinkRecord(
                pluginId: oldPluginId,
                canonicalMediaId: sourceId,
                mediaKind: .manga,
                providerId: "anilist",
                remoteMediaId: "42",
                updatedAt: updatedAt,
                provenance: .runtime
            ).insert(db)
            try UpdateBadgeRecord(
                pluginId: oldPluginId,
                canonicalMediaId: sourceId,
                mediaKind: .manga,
                count: 3,
                updatedAt: updatedAt,
                provenance: .runtime
            ).insert(db)
        }

        let result = try await LibrarySourceRemapper(dbPool: database.dbPool).remap(
            oldPluginId: oldPluginId,
            newPluginId: newPluginId,
            affectedItemIds: [sourceId]
        )

        #expect(result == .init(remappedItemCount: 1, movedLinkCount: 2, movedHistoryCount: 2))
        try await database.dbPool.read { db in
            let removedSource = try LibraryItem.fetchOne(db, key: sourceId)
            let fetchedDestination = try LibraryItem.fetchOne(db, key: destinationId)
            let destination = try #require(fetchedDestination)
            let persistedUntouched = try LibraryItem.fetchOne(db, key: untouchedId)
            #expect(removedSource == nil)
            #expect(destination.title == source.title)
            #expect(destination.coverUrl == source.coverUrl)
            #expect(destination.pluginId == newPluginId)
            #expect(destination.isAnime == source.isAnime)
            #expect(destination.pluginType == source.pluginType)
            #expect(destination.rawPayload == payload)
            #expect(destination.anilistId == source.anilistId)
            #expect(destination.status == source.status)
            #expect(destination.lastCheckedAt == checkedAt)
            #expect(destination.lastUpdatedAt == updatedAt)
            #expect(destination.knownChapterCount == source.knownChapterCount)
            #expect(persistedUntouched == untouched)

            let links = try ItemCategoryLink
                .filter(ItemCategoryLink.Columns.itemId == destinationId)
                .fetchAll(db)
            #expect(Set(links.map(\.categoryId)) == Set(["cat-1", "cat-2"]))

            let histories = try ReadingHistoryRecord.order(ReadingHistoryRecord.Columns.id).fetchAll(db)
            #expect(histories.count == 2)
            #expect(histories.allSatisfy {
                $0.libraryItemId == destinationId &&
                $0.mediaKey == destinationId &&
                $0.pluginId == newPluginId
            })

            let readKey = try ReadProgressKeyRecord.fetchOne(db)
            #expect(readKey?.pluginId == newPluginId)
            #expect(readKey?.canonicalMediaId == sourceId)
            #expect(readKey?.chapterKey == "chapter-key")
            #expect(readKey?.markedAt == checkedAt)
            #expect(readKey?.provenance == .runtime)
            let readNumber = try ReadProgressNumberRecord.fetchOne(db)
            #expect(readNumber?.pluginId == newPluginId)
            #expect(readNumber?.canonicalMediaId == sourceId)
            #expect(readNumber?.chapterNumber == 4.5)
            let resume = try MediaReadProgressRecord.fetchOne(db)
            #expect(resume?.pluginId == newPluginId)
            #expect(resume?.canonicalMediaId == sourceId)
            #expect(resume?.lastReadChapterKey == "resume-key")
            let tracker = try TrackerLinkRecord.fetchOne(db)
            #expect(tracker?.pluginId == newPluginId)
            #expect(tracker?.canonicalMediaId == sourceId)
            #expect(tracker?.providerId == "anilist")
            #expect(tracker?.remoteMediaId == "42")
            let badge = try UpdateBadgeRecord.fetchOne(db)
            #expect(badge?.pluginId == newPluginId)
            #expect(badge?.canonicalMediaId == sourceId)
            #expect(badge?.count == 3)
        }
    }

    @Test func scopedDestinationCollisionRollsBackEveryTable() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let source = makeItem(id: "series", pluginId: "old")
        let category = LibraryCategory(id: "category", name: "Category", sortOrder: 0)
        let history = ReadingHistoryRecord(
            id: "history",
            libraryItemId: source.id,
            mediaKey: source.id,
            title: source.title,
            coverUrl: nil,
            pluginId: source.pluginId,
            mediaKind: .manga,
            chapterKey: "chapter",
            chapterTitle: nil
        )
        try await database.dbPool.write { db in
            try source.insert(db)
            try category.insert(db)
            try ItemCategoryLink(itemId: source.id, categoryId: category.id).insert(db)
            try history.insert(db)
            try ReadProgressKeyRecord(
                pluginId: "old",
                canonicalMediaId: "series",
                mediaKind: .manga,
                chapterKey: "chapter",
                markedAt: nil,
                provenance: .runtime
            ).insert(db)
            try ReadProgressNumberRecord(
                pluginId: "old",
                canonicalMediaId: "series",
                mediaKind: .manga,
                chapterNumber: 1,
                markedAt: nil,
                provenance: .runtime
            ).insert(db)
            try MediaReadProgressRecord(
                pluginId: "old",
                canonicalMediaId: "series",
                mediaKind: .manga,
                lastReadChapterKey: "old-resume",
                updatedAt: nil,
                provenance: .runtime
            ).insert(db)
            try MediaReadProgressRecord(
                pluginId: "new",
                canonicalMediaId: "series",
                mediaKind: .manga,
                lastReadChapterKey: "destination-resume",
                updatedAt: nil,
                provenance: .runtime
            ).insert(db)
            try TrackerLinkRecord(
                pluginId: "old",
                canonicalMediaId: "series",
                mediaKind: .manga,
                providerId: "anilist",
                remoteMediaId: "1",
                updatedAt: nil,
                provenance: .runtime
            ).insert(db)
            try UpdateBadgeRecord(
                pluginId: "old",
                canonicalMediaId: "series",
                mediaKind: .manga,
                count: 2,
                updatedAt: nil,
                provenance: .runtime
            ).insert(db)
        }
        let before = try await scopedSnapshot(database)

        do {
            _ = try await LibrarySourceRemapper(dbPool: database.dbPool).remap(
                oldPluginId: "old",
                newPluginId: "new",
                affectedItemIds: [source.id]
            )
            Issue.record("Expected scoped destination collision")
        } catch let error as LibrarySourceRemapper.RemapError {
            #expect(error == .mediaStateDestinationCollision(
                table: "mediaReadProgress",
                canonicalMediaId: "series"
            ))
        }

        #expect(try await scopedSnapshot(database) == before)
    }

    @Test func existingDestinationCollisionRollsBackEntireBatch() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let source = makeItem(id: "first", pluginId: "old")
        let later = makeItem(id: "second", pluginId: "old")
        let collision = makeItem(id: "new_second", pluginId: "new")

        try await database.dbPool.write { db in
            try source.insert(db)
            try later.insert(db)
            try collision.insert(db)
        }

        do {
            _ = try await LibrarySourceRemapper(dbPool: database.dbPool).remap(
                oldPluginId: "old",
                newPluginId: "new",
                affectedItemIds: [source.id, later.id]
            )
            Issue.record("Expected destination collision")
        } catch let error as LibrarySourceRemapper.RemapError {
            #expect(error == .destinationExists("new_second"))
        }

        try await database.dbPool.read { db in
            let persistedSource = try LibraryItem.fetchOne(db, key: source.id)
            let persistedLater = try LibraryItem.fetchOne(db, key: later.id)
            let persistedCollision = try LibraryItem.fetchOne(db, key: collision.id)
            let unexpectedDestination = try LibraryItem.fetchOne(db, key: "new_first")
            #expect(persistedSource == source)
            #expect(persistedLater == later)
            #expect(persistedCollision == collision)
            #expect(unexpectedDestination == nil)
        }
    }

    @Test func alreadyPrefixedSameSourceRemapIsTypedNoOpWithoutMutation() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let category = LibraryCategory(id: "category", name: "Category", sortOrder: 1)
        let source = makeItem(id: "same.source_series", pluginId: "same.source")
        let readAt = Date(timeIntervalSince1970: 1_700_000_003)
        let history = ReadingHistoryRecord(
            id: "history",
            libraryItemId: source.id,
            mediaKey: source.id,
            title: source.title,
            coverUrl: nil,
            pluginId: source.pluginId,
            mediaKind: .manga,
            chapterKey: "chapter",
            chapterTitle: nil,
            readAt: readAt
        )
        try await database.dbPool.write { db in
            try category.insert(db)
            try source.insert(db)
            try ItemCategoryLink(itemId: source.id, categoryId: category.id).insert(db)
            try history.insert(db)
        }

        do {
            _ = try await LibrarySourceRemapper(dbPool: database.dbPool).remap(
                oldPluginId: source.pluginId,
                newPluginId: source.pluginId,
                affectedItemIds: [source.id]
            )
            Issue.record("Expected no-op mapping")
        } catch let error as LibrarySourceRemapper.RemapError {
            #expect(error == .noOpMapping(itemId: source.id))
        }

        try await database.dbPool.read { db in
            let items = try LibraryItem.fetchAll(db)
            let link = try ItemCategoryLink.fetchOne(
                db,
                key: ["itemId": source.id, "categoryId": category.id]
            )
            let persistedHistory = try ReadingHistoryRecord.fetchOne(db, key: history.id)
            #expect(items == [source])
            #expect(link != nil)
            #expect(persistedHistory == history)
        }
    }

    @Test func intraBatchDestinationCollisionRollsBack() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let bare = makeItem(id: "series", pluginId: "old")
        let prefixed = makeItem(id: "old_series", pluginId: "old")
        try await database.dbPool.write { db in
            try bare.insert(db)
            try prefixed.insert(db)
        }

        do {
            _ = try await LibrarySourceRemapper(dbPool: database.dbPool).remap(
                oldPluginId: "old",
                newPluginId: "new",
                affectedItemIds: [bare.id, prefixed.id]
            )
            Issue.record("Expected intra-batch collision")
        } catch let error as LibrarySourceRemapper.RemapError {
            #expect(error == .intraBatchDestinationCollision(
                destinationId: "new_series",
                sourceItemIds: ["old_series", "series"]
            ))
        }

        try await database.dbPool.read { db in
            let persistedBare = try LibraryItem.fetchOne(db, key: bare.id)
            let persistedPrefixed = try LibraryItem.fetchOne(db, key: prefixed.id)
            let unexpectedDestination = try LibraryItem.fetchOne(db, key: "new_series")
            #expect(persistedBare == bare)
            #expect(persistedPrefixed == prefixed)
            #expect(unexpectedDestination == nil)
        }
    }

    @Test func aliasIsNotWrittenWhenDatabaseRemapFails() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let source = makeItem(id: "series", pluginId: "old")
        let collision = makeItem(id: "new_series", pluginId: "new")
        let aliasSpy = AliasWriterSpy()
        try await database.dbPool.write { db in
            try source.insert(db)
            try collision.insert(db)
        }

        do {
            _ = try await LibrarySourceRemapper(dbPool: database.dbPool).remapAndPersistAlias(
                foreignId: "foreign",
                oldPluginId: "old",
                newPluginId: "new",
                affectedItemIds: [source.id]
            ) { foreignId, newPluginId in
                await aliasSpy.write(foreignId: foreignId, newPluginId: newPluginId)
            }
            Issue.record("Expected destination collision")
        } catch let error as LibrarySourceRemapper.RemapError {
            #expect(error == .destinationExists("new_series"))
        }

        #expect(await aliasSpy.writes.isEmpty)
    }

    @Test func aliasIsWrittenOnceAfterDatabaseCommit() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let source = makeItem(id: "series", pluginId: "old")
        let destinationId = "new_series"
        let aliasSpy = AliasWriterSpy()
        let dbPool = database.dbPool
        try await database.dbPool.write { db in
            try source.insert(db)
        }

        let result = try await LibrarySourceRemapper(dbPool: database.dbPool).remapAndPersistAlias(
            foreignId: "foreign",
            oldPluginId: "old",
            newPluginId: "new",
            affectedItemIds: [source.id]
        ) { foreignId, newPluginId in
            let seesCommittedState = try await dbPool.read { db in
                let removedSource = try LibraryItem.fetchOne(db, key: source.id)
                let destination = try LibraryItem.fetchOne(db, key: destinationId)
                return removedSource == nil &&
                    destination?.id == destinationId &&
                    destination?.pluginId == newPluginId
            }
            await aliasSpy.write(
                foreignId: foreignId,
                newPluginId: newPluginId,
                observedCommittedState: seesCommittedState
            )
        }

        #expect(result.remappedItemCount == 1)
        let writes = await aliasSpy.writes
        #expect(writes == [
            AliasWrite(
                foreignId: "foreign",
                newPluginId: "new",
                observedCommittedState: true
            )
        ])
    }

    @Test func importedMediaIdentityUsesExactLeadingPrefixSemantics() {
        #expect(ImportedMediaIdentity.canonicalMediaId(
            itemId: "old_old_series",
            pluginId: "old",
            mediaKind: .manga
        ) == "old_series")
        #expect(ImportedMediaIdentity.canonicalMediaId(
            itemId: "prefix_old_series",
            pluginId: "old",
            mediaKind: .manga
        ) == "prefix_old_series")

        let mismatchedPluginHistory = ReadingHistoryRecord(
            id: "history",
            libraryItemId: "old_series",
            mediaKey: "old_series",
            title: "History",
            coverUrl: nil,
            pluginId: "different",
            mediaKind: .manga,
            chapterKey: "chapter",
            chapterTitle: nil
        )
        #expect(!ImportedMediaIdentity.historyIdentifiers(
            mismatchedPluginHistory,
            match: "series",
            pluginId: "old",
            mediaKind: .manga
        ))
    }

    @Test func mediaDetailRelinkMovesLibraryAndEveryScopedStateTable() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginId = "plugin"
        let sourceId = "imported-id"
        let destinationId = "canonical-id"
        let source = makeItem(id: sourceId, pluginId: pluginId)
        let category = LibraryCategory(id: "category", name: "Category", sortOrder: 1)
        let history = ReadingHistoryRecord(
            id: "history",
            libraryItemId: sourceId,
            mediaKey: sourceId,
            title: source.title,
            coverUrl: nil,
            pluginId: pluginId,
            mediaKind: .manga,
            chapterKey: "chapter",
            chapterTitle: "Chapter"
        )
        try await database.dbPool.write { db in
            try category.insert(db)
            try source.insert(db)
            try ItemCategoryLink(itemId: sourceId, categoryId: category.id).insert(db)
            try history.insert(db)
            try ReadProgressKeyRecord(
                pluginId: pluginId,
                canonicalMediaId: sourceId,
                mediaKind: .manga,
                chapterKey: "key",
                markedAt: nil,
                provenance: .runtime
            ).insert(db)
            try ReadProgressNumberRecord(
                pluginId: pluginId,
                canonicalMediaId: sourceId,
                mediaKind: .manga,
                chapterNumber: 2,
                markedAt: nil,
                provenance: .runtime
            ).insert(db)
            try MediaReadProgressRecord(
                pluginId: pluginId,
                canonicalMediaId: sourceId,
                mediaKind: .manga,
                lastReadChapterKey: "key",
                updatedAt: nil,
                provenance: .runtime
            ).insert(db)
            try TrackerLinkRecord(
                pluginId: pluginId,
                canonicalMediaId: sourceId,
                mediaKind: .manga,
                providerId: "anilist",
                remoteMediaId: "42",
                updatedAt: nil,
                provenance: .runtime
            ).insert(db)
            try UpdateBadgeRecord(
                pluginId: pluginId,
                canonicalMediaId: sourceId,
                mediaKind: .manga,
                count: 3,
                updatedAt: nil,
                provenance: .runtime
            ).insert(db)
        }

        let result = try await LibrarySourceRemapper(dbPool: database.dbPool).relink(
            pluginId: pluginId,
            mediaKind: .manga,
            possibleSourceItemIds: [sourceId],
            destinationItemId: destinationId,
            title: "Hydrated",
            coverUrl: "https://example.com/cover.jpg",
            rawPayload: Data([1, 2, 3])
        )

        #expect(result == .init(remappedItemCount: 1, movedLinkCount: 1, movedHistoryCount: 1))
        try await database.dbPool.read { db in
            #expect(try LibraryItem.fetchOne(db, key: sourceId) == nil)
            let destination = try LibraryItem.fetchOne(db, key: destinationId)
            #expect(destination?.title == "Hydrated")
            #expect(try ItemCategoryLink.fetchOne(
                db,
                key: ["itemId": destinationId, "categoryId": category.id]
            ) != nil)
            let movedHistory = try ReadingHistoryRecord.fetchOne(db, key: history.id)
            #expect(movedHistory?.libraryItemId == destinationId)
            #expect(movedHistory?.mediaKey == destinationId)
            #expect(try ReadProgressKeyRecord
                .filter(Column("canonicalMediaId") == destinationId)
                .fetchCount(db) == 1)
            #expect(try ReadProgressNumberRecord
                .filter(Column("canonicalMediaId") == destinationId)
                .fetchCount(db) == 1)
            #expect(try MediaReadProgressRecord
                .filter(Column("canonicalMediaId") == destinationId)
                .fetchCount(db) == 1)
            #expect(try TrackerLinkRecord
                .filter(Column("canonicalMediaId") == destinationId)
                .fetchCount(db) == 1)
            #expect(try UpdateBadgeRecord
                .filter(Column("canonicalMediaId") == destinationId)
                .fetchCount(db) == 1)
        }
    }

    @Test func mediaDetailRelinkScopedCollisionRollsBackEveryTable() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginId = "plugin"
        let source = makeItem(id: "source", pluginId: pluginId)
        let category = LibraryCategory(id: "category", name: "Category", sortOrder: 1)
        try await database.dbPool.write { db in
            try category.insert(db)
            try source.insert(db)
            try ItemCategoryLink(itemId: source.id, categoryId: category.id).insert(db)
            try ReadingHistoryRecord(
                id: "history",
                libraryItemId: source.id,
                mediaKey: source.id,
                title: source.title,
                coverUrl: nil,
                pluginId: pluginId,
                mediaKind: .manga,
                chapterKey: "chapter",
                chapterTitle: nil
            ).insert(db)
            for canonicalMediaId in [source.id, "destination"] {
                try TrackerLinkRecord(
                    pluginId: pluginId,
                    canonicalMediaId: canonicalMediaId,
                    mediaKind: .manga,
                    providerId: "anilist",
                    remoteMediaId: canonicalMediaId,
                    updatedAt: nil,
                    provenance: .runtime
                ).insert(db)
            }
            try ReadProgressKeyRecord(
                pluginId: pluginId,
                canonicalMediaId: source.id,
                mediaKind: .manga,
                chapterKey: "key",
                markedAt: nil,
                provenance: .runtime
            ).insert(db)
            try ReadProgressNumberRecord(
                pluginId: pluginId,
                canonicalMediaId: source.id,
                mediaKind: .manga,
                chapterNumber: 1,
                markedAt: nil,
                provenance: .runtime
            ).insert(db)
            try MediaReadProgressRecord(
                pluginId: pluginId,
                canonicalMediaId: source.id,
                mediaKind: .manga,
                lastReadChapterKey: "key",
                updatedAt: nil,
                provenance: .runtime
            ).insert(db)
            try UpdateBadgeRecord(
                pluginId: pluginId,
                canonicalMediaId: source.id,
                mediaKind: .manga,
                count: 1,
                updatedAt: nil,
                provenance: .runtime
            ).insert(db)
        }
        let before = try await scopedSnapshot(database)

        await #expect(throws: LibrarySourceRemapper.RemapError.self) {
            _ = try await LibrarySourceRemapper(dbPool: database.dbPool).relink(
                pluginId: pluginId,
                mediaKind: .manga,
                possibleSourceItemIds: [source.id],
                destinationItemId: "destination",
                title: "Destination",
                coverUrl: nil,
                rawPayload: Data()
            )
        }

        #expect(try await scopedSnapshot(database) == before)
    }

    @Test func ambiguousHistoryAssociationIsTypedAndRollsBack() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let first = makeItem(id: "first", pluginId: "old")
        let second = makeItem(id: "second", pluginId: "old")
        let history = ReadingHistoryRecord(
            id: "ambiguous",
            libraryItemId: "old_first",
            mediaKey: "old_second",
            title: "History",
            coverUrl: nil,
            pluginId: "old",
            mediaKind: .manga,
            chapterKey: "chapter",
            chapterTitle: nil
        )
        try await database.dbPool.write { db in
            try first.insert(db)
            try second.insert(db)
            try history.insert(db)
        }
        let fetchedHistoryBeforeRemap = try await database.dbPool.read { db in
            try ReadingHistoryRecord.fetchOne(db, key: history.id)
        }
        let historyBeforeRemap = try #require(fetchedHistoryBeforeRemap)

        do {
            _ = try await LibrarySourceRemapper(dbPool: database.dbPool).remap(
                oldPluginId: "old",
                newPluginId: "new",
                affectedItemIds: [first.id, second.id]
            )
            Issue.record("Expected ambiguous history association")
        } catch let error as LibrarySourceRemapper.RemapError {
            #expect(error == .ambiguousHistoryAssociation(
                historyId: history.id,
                sourceItemIds: ["first", "second"]
            ))
        }

        try await database.dbPool.read { db in
            let persistedFirst = try LibraryItem.fetchOne(db, key: first.id)
            let persistedSecond = try LibraryItem.fetchOne(db, key: second.id)
            let persistedHistory = try ReadingHistoryRecord.fetchOne(db, key: history.id)
            #expect(persistedFirst == first)
            #expect(persistedSecond == second)
            #expect(persistedHistory == historyBeforeRemap)
        }
    }

    @Test @MainActor func migrationAdapterReportsAliasFailureAfterCommittedRemap() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let source = makeItem(id: "series", pluginId: "old")
        try await database.dbPool.write { db in
            try source.insert(db)
        }

        let outcome = try await LibrarySourceRemapperMigrationAdapter(
            remapper: LibrarySourceRemapper(dbPool: database.dbPool),
            aliasWriter: { _, _ in throw AliasWriteStubFailure() }
        ).remapSource(MigrationRemapRequest(
            foreignID: "foreign",
            oldPluginID: "old",
            newPluginID: "new",
            affectedItemIDs: [source.id]
        ))

        #expect(outcome == .remappedAliasNotSaved)
        try await database.dbPool.read { db in
            let removedSource = try LibraryItem.fetchOne(db, key: source.id)
            let destination = try LibraryItem.fetchOne(db, key: "new_series")
            #expect(removedSource == nil)
            #expect(destination?.pluginId == "new")
        }
    }

    @Test @MainActor func migrationAdapterRethrowsPreCommitFailureWithoutAliasWrite() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let source = makeItem(id: "series", pluginId: "old")
        let collision = makeItem(id: "new_series", pluginId: "new")
        let aliasSpy = AliasWriterSpy()
        try await database.dbPool.write { db in
            try source.insert(db)
            try collision.insert(db)
        }

        do {
            _ = try await LibrarySourceRemapperMigrationAdapter(
                remapper: LibrarySourceRemapper(dbPool: database.dbPool),
                aliasWriter: { foreignId, newPluginId in
                    await aliasSpy.write(foreignId: foreignId, newPluginId: newPluginId)
                }
            ).remapSource(MigrationRemapRequest(
                foreignID: "foreign",
                oldPluginID: "old",
                newPluginID: "new",
                affectedItemIDs: [source.id]
            ))
            Issue.record("Expected destination collision")
        } catch let error as LibrarySourceRemapper.RemapError {
            #expect(error == .destinationExists("new_series"))
        }

        #expect(await aliasSpy.writes.isEmpty)
    }

    @Test func remapAndRelinkIsolatesByMediaKindWithoutCrosswrites() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let oldPluginId = "source.shared"
        let newPluginId = "source.migrated"
        let rawMediaId = "42"
        let mangaItemId = "source.shared\u{1F}manga\u{1F}42"
        let novelItemId = "source.shared\u{1F}novel\u{1F}42"

        let mangaItem = LibraryItem(
            id: mangaItemId,
            title: "Manga Title",
            coverUrl: nil,
            pluginId: oldPluginId,
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data([1]),
            anilistId: nil
        )
        let novelItem = LibraryItem(
            id: novelItemId,
            title: "Novel Title",
            coverUrl: nil,
            pluginId: oldPluginId,
            isAnime: false,
            pluginType: .novel,
            rawPayload: Data([2]),
            anilistId: nil
        )

        let mangaHistory = ReadingHistoryRecord(
            id: "manga-history",
            libraryItemId: mangaItemId,
            mediaKey: rawMediaId,
            title: "Manga",
            coverUrl: nil,
            pluginId: oldPluginId,
            mediaKind: .manga,
            chapterKey: "ch-manga-1",
            chapterTitle: "Chapter 1"
        )
        let novelHistory = ReadingHistoryRecord(
            id: "novel-history",
            libraryItemId: novelItemId,
            mediaKey: rawMediaId,
            title: "Novel",
            coverUrl: nil,
            pluginId: oldPluginId,
            mediaKind: .novel,
            chapterKey: "ch-novel-1",
            chapterTitle: "Chapter 1"
        )

        try await database.dbPool.write { db in
            try mangaItem.insert(db)
            try novelItem.insert(db)
            try mangaHistory.insert(db)
            try novelHistory.insert(db)
            try ReadProgressKeyRecord(
                pluginId: oldPluginId,
                canonicalMediaId: rawMediaId,
                mediaKind: .manga,
                chapterKey: "ch-manga-1",
                markedAt: nil,
                provenance: .runtime
            ).insert(db)
            try ReadProgressKeyRecord(
                pluginId: oldPluginId,
                canonicalMediaId: rawMediaId,
                mediaKind: .novel,
                chapterKey: "ch-novel-1",
                markedAt: nil,
                provenance: .runtime
            ).insert(db)
        }

        let result = try await LibrarySourceRemapper(dbPool: database.dbPool).remap(
            oldPluginId: oldPluginId,
            newPluginId: newPluginId,
            affectedItemIds: [mangaItemId]
        )
        #expect(result == .init(remappedItemCount: 1, movedLinkCount: 0, movedHistoryCount: 1))

        let expectedMangaDestId = "source.migrated\u{1F}manga\u{1F}42"
        try await database.dbPool.read { db in
            #expect(try LibraryItem.fetchOne(db, key: mangaItemId) == nil)
            #expect(try LibraryItem.fetchOne(db, key: expectedMangaDestId) != nil)

            let persistedNovel = try LibraryItem.fetchOne(db, key: novelItemId)
            #expect(persistedNovel?.pluginId == oldPluginId)

            let fetchedMangaHist = try #require(try ReadingHistoryRecord.fetchOne(db, key: "manga-history"))
            #expect(fetchedMangaHist.pluginId == newPluginId)
            #expect(fetchedMangaHist.libraryItemId == expectedMangaDestId)

            let fetchedNovelHist = try #require(try ReadingHistoryRecord.fetchOne(db, key: "novel-history"))
            #expect(fetchedNovelHist.pluginId == oldPluginId)
            #expect(fetchedNovelHist.libraryItemId == novelItemId)

            let mangaProgress = try ReadProgressKeyRecord
                .filter(Column("pluginId") == newPluginId)
                .filter(Column("mediaKind") == MediaKind.manga.rawValue)
                .fetchOne(db)
            #expect(mangaProgress != nil)

            let novelProgress = try ReadProgressKeyRecord
                .filter(Column("pluginId") == oldPluginId)
                .filter(Column("mediaKind") == MediaKind.novel.rawValue)
                .fetchOne(db)
            #expect(novelProgress != nil)
        }
    }

    private struct AliasWriteStubFailure: Error {}

    private func makeItem(id: String, pluginId: String) -> LibraryItem {
        LibraryItem(
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

    private func scopedSnapshot(_ database: TestDatabase) async throws -> RemapSnapshot {
        try await database.dbPool.read { db in
            RemapSnapshot(
                items: try LibraryItem.fetchAll(db),
                links: try ItemCategoryLink.fetchAll(db),
                history: try ReadingHistoryRecord.fetchAll(db),
                readKeys: try ReadProgressKeyRecord.fetchAll(db),
                readNumbers: try ReadProgressNumberRecord.fetchAll(db),
                resume: try MediaReadProgressRecord.fetchAll(db),
                trackerLinks: try TrackerLinkRecord.fetchAll(db),
                badges: try UpdateBadgeRecord.fetchAll(db)
            )
        }
    }
}

private struct RemapSnapshot: Equatable {
    let items: [LibraryItem]
    let links: [ItemCategoryLink]
    let history: [ReadingHistoryRecord]
    let readKeys: [ReadProgressKeyRecord]
    let readNumbers: [ReadProgressNumberRecord]
    let resume: [MediaReadProgressRecord]
    let trackerLinks: [TrackerLinkRecord]
    let badges: [UpdateBadgeRecord]
}

private struct AliasWrite: Equatable, Sendable {
    let foreignId: String
    let newPluginId: String
    let observedCommittedState: Bool
}

private actor AliasWriterSpy {
    private(set) var writes: [AliasWrite] = []

    func write(
        foreignId: String,
        newPluginId: String,
        observedCommittedState: Bool = false
    ) {
        writes.append(AliasWrite(
            foreignId: foreignId,
            newPluginId: newPluginId,
            observedCommittedState: observedCommittedState
        ))
    }
}
