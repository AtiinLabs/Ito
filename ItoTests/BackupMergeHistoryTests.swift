import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

@MainActor
struct BackupMergeHistoryTests {
    @Test func newBareItemReceivesRemappedLinkAndPrefixedHistory() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let category = LibraryCategory(id: "backup-category", name: "Backup", sortOrder: 1)
        let item = makeItem(id: "media-1", title: "Imported")
        let readAt = Date(timeIntervalSince1970: 1_700_001_000)
        let backup = ImportedBackup(
            categories: [category],
            items: [item],
            links: [ItemCategoryLink(itemId: item.id, categoryId: category.id)],
            history: [
                makeHistory(
                    id: "history-1",
                    itemId: "test.plugin_media-1",
                    chapter: "chapter-1",
                    readAt: readAt
                )
            ]
        )

        let result = try await operation(database).restore(backup, mode: .merge)

        #expect(result == BackupMergeResult(
            insertedItemCount: 1,
            insertedHistoryCount: 1,
            skippedUnassociatedOrAmbiguousHistoryCount: 0,
            skippedByPolicyHistoryCount: 0,
            skippedDuplicateHistoryCount: 0,
            persistedTargetIdsByImportedItemId: [item.id: item.id]
        ))
        #expect(result.consideredHistoryCount == 1)
        try await database.dbPool.read { db in
            #expect(try LibraryItem.fetchOne(db, key: item.id)?.title == "Imported")
            #expect(try ItemCategoryLink.fetchOne(
                db,
                key: ["itemId": item.id, "categoryId": category.id]
            ) != nil)
            let fetchedHistory = try ReadingHistoryRecord.fetchOne(db, key: "history-1")
            let history = try #require(fetchedHistory)
            #expect(history.libraryItemId == item.id)
            #expect(history.mediaKey == item.id)
        }
    }

    @Test func mixedIdentityKeepLocalLeavesRowLinksAndHistoryUnchanged() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let localCategory = LibraryCategory(id: "local-category", name: "Local", sortOrder: 1)
        let backupCategory = LibraryCategory(id: "backup-category", name: "Backup", sortOrder: 2)
        let local = makeItem(id: "test.plugin_media-1", title: "Local")
        let imported = makeItem(id: "media-1", title: "Backup")
        let localHistory = makeHistory(id: "local-history", itemId: local.id, chapter: "local")
        let importedHistory = makeHistory(id: "backup-history", itemId: imported.id, chapter: "backup")
        try await database.dbPool.write { db in
            try localCategory.insert(db)
            try local.insert(db)
            try ItemCategoryLink(itemId: local.id, categoryId: localCategory.id).insert(db)
            try localHistory.insert(db)
        }
        let backup = ImportedBackup(
            categories: [backupCategory],
            items: [imported],
            links: [ItemCategoryLink(itemId: imported.id, categoryId: backupCategory.id)],
            history: [importedHistory]
        )

        let result = try await operation(database).restore(
            backup,
            mode: .merge,
            resolvedConflicts: [local.id: .keepLocal]
        )

        #expect(result == BackupMergeResult(
            insertedItemCount: 0,
            insertedHistoryCount: 0,
            skippedUnassociatedOrAmbiguousHistoryCount: 0,
            skippedByPolicyHistoryCount: 1,
            skippedDuplicateHistoryCount: 0,
            persistedTargetIdsByImportedItemId: [imported.id: local.id]
        ))
        try await database.dbPool.read { db in
            #expect(try LibraryItem.fetchOne(db, key: local.id)?.title == "Local")
            #expect(try LibraryItem.fetchOne(db, key: imported.id) == nil)
            let links = try ItemCategoryLink.fetchAll(db)
            #expect(links.map(\.categoryId) == [localCategory.id])
            let history = try ReadingHistoryRecord.fetchAll(db)
            #expect(history.map(\.id) == [localHistory.id])
        }
    }

    @Test func mixedIdentityKeepBackupRetainsPrimaryKeyAndAddsHistory() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let localCategory = LibraryCategory(id: "local-category", name: "Local", sortOrder: 1)
        let backupCategory = LibraryCategory(id: "backup-category", name: "Backup", sortOrder: 2)
        let local = makeItem(id: "test.plugin_media-1", title: "Local")
        let imported = makeItem(id: "media-1", title: "Backup")
        let localHistory = makeHistory(id: "local-history", itemId: local.id, chapter: "local")
        let importedHistory = makeHistory(
            id: "backup-history",
            itemId: "test.plugin_media-1",
            chapter: "backup"
        )
        try await database.dbPool.write { db in
            try localCategory.insert(db)
            try local.insert(db)
            try ItemCategoryLink(itemId: local.id, categoryId: localCategory.id).insert(db)
            try localHistory.insert(db)
        }
        let backup = ImportedBackup(
            categories: [backupCategory],
            items: [imported],
            links: [ItemCategoryLink(itemId: imported.id, categoryId: backupCategory.id)],
            history: [importedHistory]
        )

        let result = try await operation(database).restore(
            backup,
            mode: .merge,
            resolvedConflicts: [local.id: .keepBackup]
        )

        #expect(result.insertedItemCount == 0)
        #expect(result.insertedHistoryCount == 1)
        try await database.dbPool.read { db in
            #expect(try LibraryItem.fetchOne(db, key: local.id)?.title == "Backup")
            #expect(try LibraryItem.fetchOne(db, key: imported.id) == nil)
            let links = try ItemCategoryLink.fetchAll(db)
            #expect(links.map(\.itemId) == [local.id])
            #expect(links.map(\.categoryId) == [backupCategory.id])
            let history = try ReadingHistoryRecord.order(ReadingHistoryRecord.Columns.id).fetchAll(db)
            #expect(history.map(\.id) == [importedHistory.id, localHistory.id])
            #expect(history.first(where: { $0.id == importedHistory.id })?.mediaKey == local.id)
        }
    }

    @Test func ambiguousCanonicalLocalIdentityThrowsAndRollsBack() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let bare = makeItem(id: "media-1", title: "Bare")
        let prefixed = makeItem(id: "test.plugin_media-1", title: "Prefixed")
        let imported = makeItem(id: "media-1", title: "Imported")
        try await database.dbPool.write { db in
            try bare.insert(db)
            try prefixed.insert(db)
        }

        do {
            _ = try await operation(database).restore(
                ImportedBackup(
                    categories: [LibraryCategory(id: "should-rollback", name: "Rollback", sortOrder: 1)],
                    items: [imported]
                ),
                mode: .merge,
                resolvedConflicts: [bare.id: .keepBackup]
            )
            Issue.record("Expected canonical identity ambiguity")
        } catch let error as BackupMergeError {
            #expect(error == .ambiguousLocalIdentity(
                pluginId: "test.plugin",
                canonicalMediaId: "media-1",
                localItemIds: ["media-1", "test.plugin_media-1"]
            ))
        }

        try await database.dbPool.read { db in
            let items = try LibraryItem.fetchAll(db)
            let rolledBackCategory = try LibraryCategory.fetchOne(db, key: "should-rollback")
            #expect(items.count == 2)
            #expect(rolledBackCategory == nil)
        }
    }

    @Test func invalidKeepBackupReplacementCategoryRollsBackEntireRestore() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let localCategory = LibraryCategory(id: "local-category", name: "Local", sortOrder: 1)
        let backupCategory = LibraryCategory(id: "backup-category", name: "Backup", sortOrder: 2)
        let local = makeItem(id: "test.plugin_existing", title: "Local")
        let imported = makeItem(id: "existing", title: "Backup")
        let newItem = makeItem(id: "new-item", title: "New")
        let localHistory = makeHistory(id: "local-history", itemId: local.id, chapter: "local")
        let importedHistory = makeHistory(id: "imported-history", itemId: newItem.id, chapter: "imported")
        let localPreference = AppPreference(key: "local-preference", value: Data([0x01]))
        let backupPreference = AppPreference(key: "backup-preference", value: Data([0x02]))
        try await database.dbPool.write { db in
            try localCategory.insert(db)
            try local.insert(db)
            try ItemCategoryLink(itemId: local.id, categoryId: localCategory.id).insert(db)
            try localHistory.insert(db)
            try localPreference.insert(db)
        }
        let backup = ImportedBackup(
            categories: [backupCategory],
            items: [imported, newItem],
            links: [
                ItemCategoryLink(itemId: imported.id, categoryId: "missing-category"),
                ItemCategoryLink(itemId: newItem.id, categoryId: backupCategory.id)
            ],
            history: [importedHistory],
            preferences: [backupPreference]
        )

        do {
            _ = try await operation(database).restore(
                backup,
                mode: .merge,
                resolvedConflicts: [local.id: .keepBackup]
            )
            Issue.record("Expected invalid replacement category reference")
        } catch let error as BackupMergeError {
            #expect(error == .invalidReplacementCategoryReference(
                itemId: local.id,
                categoryId: "missing-category"
            ))
        }

        try await database.dbPool.read { db in
            let items = try LibraryItem.fetchAll(db)
            let links = try ItemCategoryLink.fetchAll(db)
            let history = try ReadingHistoryRecord.fetchAll(db)
            let preferences = try AppPreference.fetchAll(db)
            #expect(items == [local])
            #expect(links.count == 1)
            #expect(links.first?.itemId == local.id)
            #expect(links.first?.categoryId == localCategory.id)
            #expect(history == [localHistory])
            #expect(preferences == [localPreference])
            #expect(try LibraryCategory.fetchOne(db, key: backupCategory.id) == nil)
        }
    }

    @Test func historyClassificationUsesRequiredPrecedenceAndExactCounters() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let keepBackup = makeItem(id: "test.plugin_backup", title: "Backup local")
        let keepLocal = makeItem(id: "test.plugin_local", title: "Keep local")
        let importedBackupItem = makeItem(id: "backup", title: "Backup imported")
        let importedLocalItem = makeItem(id: "local", title: "Local imported")
        let duplicateTime = Date(timeIntervalSince1970: 1_700_002_000)
        let rereadTime = Date(timeIntervalSince1970: 1_700_002_001)
        let primaryDuplicate = makeHistory(
            id: "same-primary",
            itemId: keepBackup.id,
            chapter: "primary",
            readAt: duplicateTime
        )
        let semanticExisting = makeHistory(
            id: "semantic-existing",
            itemId: keepBackup.id,
            chapter: "semantic",
            readAt: duplicateTime
        )
        let policyExisting = makeHistory(
            id: "policy-primary",
            itemId: keepLocal.id,
            chapter: "policy",
            readAt: duplicateTime
        )
        let unrelatedExisting = makeHistory(
            id: "unrelated-existing",
            itemId: "other-media",
            chapter: "other"
        )
        try await database.dbPool.write { db in
            try keepBackup.insert(db)
            try keepLocal.insert(db)
            try primaryDuplicate.insert(db)
            try semanticExisting.insert(db)
            try policyExisting.insert(db)
            try unrelatedExisting.insert(db)
        }
        let importedHistory = [
            primaryDuplicate,
            makeHistory(
                id: "semantic-new-id",
                itemId: importedBackupItem.id,
                chapter: "semantic",
                readAt: duplicateTime
            ),
            makeHistory(
                id: "reread",
                itemId: "test.plugin_backup",
                chapter: "semantic",
                readAt: rereadTime
            ),
            policyExisting,
            makeHistory(id: "unassociated", itemId: "not-imported", chapter: "none")
        ]
        let backup = ImportedBackup(
            items: [importedBackupItem, importedLocalItem],
            history: importedHistory
        )

        let result = try await operation(database).restore(
            backup,
            mode: .merge,
            resolvedConflicts: [
                keepBackup.id: .keepBackup,
                keepLocal.id: .keepLocal
            ]
        )

        #expect(result == BackupMergeResult(
            insertedItemCount: 0,
            insertedHistoryCount: 1,
            skippedUnassociatedOrAmbiguousHistoryCount: 1,
            skippedByPolicyHistoryCount: 1,
            skippedDuplicateHistoryCount: 2,
            persistedTargetIdsByImportedItemId: [
                importedBackupItem.id: keepBackup.id,
                importedLocalItem.id: keepLocal.id
            ]
        ))
        #expect(result.consideredHistoryCount == importedHistory.count)
        try await database.dbPool.read { db in
            let ids = Set(try ReadingHistoryRecord.fetchAll(db).map(\.id))
            #expect(ids.contains("reread"))
            #expect(!ids.contains("semantic-new-id"))
            #expect(!ids.contains("unassociated"))
            #expect(ids.contains(unrelatedExisting.id))
        }
    }

    @Test func ambiguousImportedHistoryIsSkippedOnce() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let bare = makeItem(id: "media-1", title: "Bare")
        let prefixed = makeItem(id: "test.plugin_media-1", title: "Prefixed")
        let history = makeHistory(
            id: "ambiguous-history",
            itemId: "test.plugin_media-1",
            chapter: "chapter"
        )

        let result = try await operation(database).restore(
            ImportedBackup(items: [bare, prefixed], history: [history]),
            mode: .merge
        )

        #expect(result.insertedItemCount == 2)
        #expect(result.insertedHistoryCount == 0)
        #expect(result.skippedUnassociatedOrAmbiguousHistoryCount == 1)
        #expect(result.consideredHistoryCount == 1)
    }

    @Test func analysisAndRestoreUseTargetLocalIdentity() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let localCategory = LibraryCategory(id: "local-category", name: "Local", sortOrder: 1)
        let backupCategory = LibraryCategory(id: "backup-category", name: "Backup", sortOrder: 2)
        let local = makeItem(id: "test.plugin_media-1", title: "Local")
        let imported = makeItem(id: "media-1", title: "Backup")
        let history = makeHistory(
            id: "backup-history",
            itemId: "test.plugin_media-1",
            chapter: "chapter"
        )
        try await database.dbPool.write { db in
            try localCategory.insert(db)
            try local.insert(db)
            try ItemCategoryLink(itemId: local.id, categoryId: localCategory.id).insert(db)
        }
        let backup = ImportedBackup(
            categories: [backupCategory],
            items: [imported],
            links: [ItemCategoryLink(itemId: imported.id, categoryId: backupCategory.id)],
            history: [history]
        )

        let conflicts = try await operation(database).analyze(backup)
        let conflict = try #require(conflicts.first)
        #expect(conflicts.count == 1)
        #expect(conflict.id == local.id)
        #expect(conflict.backupHistoryCount == 1)

        let result = try await operation(database).restore(
            backup,
            mode: .merge,
            resolvedConflicts: [conflict.id: .keepBackup]
        )
        #expect(result.insertedHistoryCount == 1)
        #expect(try await database.dbPool.read { db in
            try ReadingHistoryRecord.fetchOne(db, key: history.id)?.mediaKey
        } == local.id)
    }

    @Test func mergeReportUsesPersistedTargetAndComposesWithExactSourceRemap() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let category = LibraryCategory(id: "local-category", name: "Local", sortOrder: 1)
        let localId = "test.plugin_media-1"
        let importedId = "media-1"
        let destinationId = "replacement.plugin_media-1"
        let checkedAt = Date(timeIntervalSince1970: 1_700_003_000)
        let updatedAt = Date(timeIntervalSince1970: 1_700_003_001)
        let local = LibraryItem(
            id: localId,
            title: "Local",
            coverUrl: "https://example.com/local.jpg",
            pluginId: "test.plugin",
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data([0x01, 0x02]),
            anilistId: 17,
            status: "reading",
            lastCheckedAt: checkedAt,
            lastUpdatedAt: updatedAt,
            knownChapterCount: 9
        )
        let untouched = makeItem(id: "test.plugin_untouched", title: "Untouched")
        let imported = makeItem(id: importedId, title: "Imported")
        let localHistory = makeHistory(id: "local-history", itemId: local.id, chapter: "local")
        try await database.dbPool.write { db in
            try category.insert(db)
            try local.insert(db)
            try untouched.insert(db)
            try ItemCategoryLink(itemId: local.id, categoryId: category.id).insert(db)
            try localHistory.insert(db)
        }
        let migrationReport = MigrationReport(
            unresolvedPlugins: [
                .init(
                    foreignId: "foreign.source",
                    resolvedId: "test.plugin",
                    confidence: 50,
                    isInstalled: true,
                    affectedItemIds: [imported.id, local.id, imported.id],
                    candidates: [(id: "replacement.plugin", score: 100)]
                )
            ],
            totalItemsImported: 1,
            totalItemsSkipped: 0
        )
        let backup = ImportedBackup(items: [imported], migrationReport: migrationReport)

        let mergeResult = try await operation(database).restore(
            backup,
            mode: .merge,
            resolvedConflicts: [local.id: .keepLocal]
        )
        let surfacedReport = try #require(mergeResult.retargetedMigrationReport(migrationReport))
        let affectedItemIds = try #require(surfacedReport.unresolvedPlugins.first?.affectedItemIds)

        #expect(mergeResult.persistedTargetIdsByImportedItemId == [imported.id: local.id])
        #expect(affectedItemIds == [local.id])
        let remapResult = try await LibrarySourceRemapper(dbPool: database.dbPool).remap(
            oldPluginId: "test.plugin",
            newPluginId: "replacement.plugin",
            affectedItemIds: affectedItemIds
        )

        #expect(remapResult == .init(remappedItemCount: 1, movedLinkCount: 1, movedHistoryCount: 1))
        try await database.dbPool.read { db in
            #expect(try LibraryItem.fetchOne(db, key: local.id) == nil)
            let persistedDestination = try LibraryItem.fetchOne(db, key: destinationId)
            let destination = try #require(persistedDestination)
            #expect(destination.title == local.title)
            #expect(destination.status == local.status)
            #expect(destination.lastCheckedAt == checkedAt)
            #expect(destination.lastUpdatedAt == updatedAt)
            #expect(destination.knownChapterCount == local.knownChapterCount)
            #expect(try LibraryItem.fetchOne(db, key: untouched.id) == untouched)
            #expect(try ItemCategoryLink.fetchOne(
                db,
                key: ["itemId": destinationId, "categoryId": category.id]
            ) != nil)
            let persistedHistory = try ReadingHistoryRecord.fetchOne(db, key: localHistory.id)
            #expect(persistedHistory?.libraryItemId == destinationId)
            #expect(persistedHistory?.mediaKey == destinationId)
            #expect(persistedHistory?.pluginId == "replacement.plugin")
        }
    }

    @Test func wipeRestoresAllBackupStateAndRetargetsImporterShapedHistory() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let oldCategory = LibraryCategory(
            id: "old-category",
            name: "Old",
            sortOrder: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let oldItem = makeItem(id: "old-item", title: "Old")
        let oldHistory = makeHistory(id: "old-history", itemId: oldItem.id, chapter: "old")
        let restoredCategory = LibraryCategory(
            id: "restored-category",
            name: "Restored",
            sortOrder: 2,
            createdAt: Date(timeIntervalSince1970: 1_700_000_002)
        )
        let restoredItem = makeItem(id: "media-restored", title: "Restored")
        let restoredHistory = makeHistory(
            id: "restored-history",
            itemId: "test.plugin_media-restored",
            chapter: "restored"
        )
        let oldPreference = AppPreference(key: "old-preference", value: Data([0x01]))
        let restoredPreference = AppPreference(key: "restored-preference", value: Data([0x02]))
        try await database.dbPool.write { db in
            try oldCategory.insert(db)
            try oldItem.insert(db)
            try ItemCategoryLink(itemId: oldItem.id, categoryId: oldCategory.id).insert(db)
            try oldHistory.insert(db)
            try oldPreference.insert(db)
        }
        let backup = ImportedBackup(
            categories: [restoredCategory],
            items: [restoredItem],
            links: [ItemCategoryLink(itemId: restoredItem.id, categoryId: restoredCategory.id)],
            history: [restoredHistory],
            preferences: [restoredPreference]
        )

        let result = try await operation(database).restore(backup, mode: .wipe)

        #expect(result.insertedItemCount == 1)
        #expect(result.insertedHistoryCount == 1)
        #expect(result.persistedTargetIdsByImportedItemId == [restoredItem.id: restoredItem.id])
        try await database.dbPool.read { db in
            #expect(try LibraryCategory.fetchOne(db, key: oldCategory.id) == nil)
            #expect(try LibraryItem.fetchOne(db, key: oldItem.id) == nil)
            #expect(try ReadingHistoryRecord.fetchOne(db, key: oldHistory.id) == nil)
            #expect(try AppPreference.fetchOne(db, key: oldPreference.key) == nil)
            #expect(try LibraryCategory.fetchOne(db, key: restoredCategory.id) == restoredCategory)
            #expect(try LibraryItem.fetchOne(db, key: restoredItem.id) == restoredItem)
            #expect(try ItemCategoryLink.fetchOne(
                db,
                key: ["itemId": restoredItem.id, "categoryId": restoredCategory.id]
            ) != nil)
            let history = try ReadingHistoryRecord.fetchOne(db, key: restoredHistory.id)
            #expect(history?.libraryItemId == restoredItem.id)
            #expect(history?.mediaKey == restoredItem.id)
            #expect(try AppPreference.fetchOne(db, key: restoredPreference.key) == restoredPreference)
        }
    }

    @Test func backupItemOfAnotherKindSavedUnderTheLocalItemsIdMergesBesideIt() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        // Each device saved its series under the bare key, as LibraryManager does.
        let mangaItem = LibraryItem(
            id: "42",
            title: "Manga 42",
            coverUrl: nil,
            pluginId: "test.plugin",
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data([1]),
            anilistId: nil
        )
        let novelItem = LibraryItem(
            id: "42",
            title: "Novel 42",
            coverUrl: nil,
            pluginId: "test.plugin",
            isAnime: false,
            pluginType: .novel,
            rawPayload: Data([2]),
            anilistId: nil
        )

        let mangaHistory = makeHistory(
            id: "manga-history",
            itemId: mangaItem.id,
            chapter: "ch-1",
            mediaKind: .manga
        )
        let novelHistory = makeHistory(
            id: "novel-history",
            itemId: novelItem.id,
            chapter: "ch-1",
            mediaKind: .novel
        )

        try await database.dbPool.write { db in
            try mangaItem.insert(db)
            try mangaHistory.insert(db)
        }

        let backup = ImportedBackup(
            categories: [],
            items: [novelItem],
            links: [],
            history: [novelHistory]
        )

        let result = try await operation(database).restore(backup, mode: .merge)
        #expect(result.insertedItemCount == 1)
        #expect(result.insertedHistoryCount == 1)
        #expect(result.skippedDuplicateHistoryCount == 0)

        let novelTargetID = "test.plugin\u{1F}novel\u{1F}42"
        try await database.dbPool.read { db in
            #expect(try LibraryItem.fetchOne(db, key: "42") == mangaItem)
            let mergedNovel = try #require(try LibraryItem.fetchOne(db, key: novelTargetID))
            #expect(mergedNovel.title == novelItem.title)
            #expect(mergedNovel.effectiveType == .novel)
            #expect(try LibraryItem.fetchCount(db) == 2)

            let histories = try ReadingHistoryRecord.fetchAll(db)
            #expect(histories.count == 2)
            #expect(try ReadingHistoryRecord.fetchOne(db, key: "manga-history") == mangaHistory)
            let mergedHistory = try #require(try ReadingHistoryRecord.fetchOne(db, key: "novel-history"))
            #expect(mergedHistory.libraryItemId == novelTargetID)
            #expect(mergedHistory.mediaKind == .novel)
        }
    }

    private func operation(_ database: TestDatabase) -> BackupMergeOperation {
        BackupMergeOperation(dbPool: database.dbPool)
    }

    private func makeItem(id: String, title: String) -> LibraryItem {
        LibraryItem(
            id: id,
            title: title,
            coverUrl: nil,
            pluginId: "test.plugin",
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil
        )
    }

    private func makeHistory(
        id: String,
        itemId: String,
        chapter: String,
        mediaKind: MediaKind = .manga,
        readAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ReadingHistoryRecord {
        ReadingHistoryRecord(
            id: id,
            libraryItemId: itemId,
            mediaKey: itemId,
            title: "History",
            coverUrl: nil,
            pluginId: "test.plugin",
            mediaKind: mediaKind,
            chapterKey: chapter,
            chapterTitle: chapter,
            readAt: readAt
        )
    }
}
