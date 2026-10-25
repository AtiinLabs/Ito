// swiftlint:disable file_length
import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

@MainActor
struct BackupRestoreOperationPhaseTests {
    private enum InjectedFailure: Error {
        case late
    }

    @Test func representedWipePreservesUnrepresentedAndRepairsHistoryPointer() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let localItem = item(id: "plugin.local_old", title: "Local")
        let history = ReadingHistoryRecord(
            id: "history",
            libraryItemId: localItem.id,
            mediaKey: localItem.id,
            title: "History",
            coverUrl: nil,
            pluginId: localItem.pluginId,
            mediaKind: localItem.effectiveType,
            chapterKey: "chapter",
            chapterTitle: nil
        )
        let setting = PluginSettingRecord(
            pluginId: "plugin.local",
            key: "setting",
            value: Data([1]),
            updatedAt: nil
        )
        try await database.dbPool.write { db in
            try localItem.insert(db)
            try history.insert(db)
            try PluginIdentityRecord(
                pluginId: "plugin.local",
                manifestId: nil,
                lastSeenAt: Date(timeIntervalSince1970: 1)
            ).insert(db)
            try setting.insert(db)
            try ThemeCacheRecord(
                mediaKey: "cache",
                dominantHex: "#000000",
                secondaryHex: "#ffffff"
            ).insert(db)
        }
        let restored = item(id: "plugin.local_new", title: "Restored")
        let backup = representedBackup(
            components: [.libraryCore],
            items: [restored]
        )

        let report = try await operation(database).restore(
            backup,
            mode: .wipe,
            operationId: "wipe"
        )

        #expect(report.outcomes.map(\.component) == [.libraryCore, .readingHistory])
        // The local item and the migrated system list.
        #expect(report.outcomes[0].replaced == 2)
        #expect(report.outcomes[0].inserted == 1)
        #expect(report.outcomes[1].dependencyRepaired == 1)
        let state = try await database.dbPool.read { db in
            (
                try LibraryItem.fetchOne(db, key: localItem.id),
                try LibraryItem.fetchOne(db, key: restored.id),
                try ReadingHistoryRecord.fetchOne(db, key: history.id),
                try PluginSettingRecord.fetchOne(
                db,
                key: ["pluginId": setting.pluginId, "key": setting.key]
                ),
                try ThemeCacheRecord.fetchOne(db, key: "cache"),
                try BackupRestoreJournalRecord.fetchOne(db, key: "wipe")
            )
        }
        #expect(state.0 == nil)
        #expect(state.1 != nil)
        #expect(state.2?.libraryItemId == nil)
        #expect(state.3 == setting)
        #expect(state.4 != nil)
        let journal = try #require(state.5)
        #expect(journal.status == .pendingRefresh)
        #expect(
            try JSONDecoder().decode(
                BackupRestoreReport.self,
                from: journal.reportPayload
            ) == report
        )
    }

    @Test(arguments: [BackupRestoreMode.wipe, .merge])
    func reusedLibraryRowIdDoesNotCrossAttachRetainedHistory(
        mode: BackupRestoreMode
    ) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let reusedId = "old_media"
        let localItem = item(
            id: reusedId,
            title: "Local",
            pluginId: "old"
        )
        let history = ReadingHistoryRecord(
            id: "retained-history",
            libraryItemId: reusedId,
            mediaKey: reusedId,
            title: "Retained History",
            coverUrl: "https://old.example/cover.jpg",
            pluginId: localItem.pluginId,
            mediaKind: localItem.effectiveType,
            chapterKey: "chapter-7",
            chapterTitle: "Chapter Seven"
        )
        try await database.dbPool.write { db in
            try localItem.insert(db)
            try history.insert(db)
        }
        let persistedHistory = try #require(
            try await database.dbPool.read { db in
                try ReadingHistoryRecord.fetchOne(db, key: history.id)
            }
        )
        let replacement = item(
            id: reusedId,
            title: "Replacement",
            pluginId: "new"
        )
        let backup = representedBackup(
            components: [.libraryCore],
            items: [replacement]
        )

        let report = try await operation(database).restore(
            backup,
            mode: mode,
            operationId: "reused-id-\(mode.rawValue)",
            resolvedConflicts: [reusedId: .keepBackup]
        )

        #expect(
            report.outcomes.first(where: { $0.component == .readingHistory })?
                .dependencyRepaired == 1
        )
        let state = try await database.dbPool.read { db in
            (
                try ReadingHistoryRecord.fetchOne(db, key: history.id),
                try LibraryItem.fetchOne(db, key: reusedId)
            )
        }
        let retainedHistory = try #require(state.0)
        var expectedHistory = persistedHistory
        expectedHistory.libraryItemId = nil
        #expect(retainedHistory == expectedHistory)
        #expect(retainedHistory.libraryItemId == nil)
        #expect(state.1?.pluginId == replacement.pluginId)
        #expect(state.1?.pluginId != retainedHistory.pluginId)
    }

    @Test func mergeIsLocalWinsWithDeterministicCounts() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let localRepository = RepositoryRecord(
            url: "https://example.com/repo",
            lastFetched: Date(timeIntervalSince1970: 1),
            indexPayload: Data([1])
        )
        let localBadge = UpdateBadgeRecord(
            pluginId: "plugin",
            canonicalMediaId: "media",
            mediaKind: .manga,
            count: 4,
            updatedAt: Date(timeIntervalSince1970: 1),
            provenance: .runtime
        )
        try await database.dbPool.write { db in
            try localRepository.insert(db)
            try localBadge.insert(db)
        }
        let backup = representedBackup(
            components: [.repositories, .updateBadges],
            updateBadges: [
                UpdateBadgeRecord(
                    pluginId: "plugin",
                    canonicalMediaId: "media",
                    mediaKind: .manga,
                    count: 9,
                    updatedAt: Date(timeIntervalSince1970: 2),
                    provenance: .runtime
                ),
                UpdateBadgeRecord(
                    pluginId: "plugin",
                    canonicalMediaId: "new",
                    mediaKind: .manga,
                    count: 1,
                    updatedAt: nil,
                    provenance: .runtime
                )
            ],
            repositories: [
                RepositoryRecord(
                    url: "https://example.com/repo/index.json",
                    lastFetched: Date(timeIntervalSince1970: 2),
                    indexPayload: Data([2])
                ),
                RepositoryRecord(
                    url: "https://example.com/new/",
                    lastFetched: nil,
                    indexPayload: nil
                )
            ]
        )

        let report = try await operation(database).restore(
            backup,
            mode: .merge,
            operationId: "merge"
        )

        #expect(report.outcomes.map(\.component) == [.updateBadges, .repositories])
        #expect(report.outcomes[0].inserted == 1)
        #expect(report.outcomes[0].preservedLocal == 1)
        #expect(report.outcomes[1].inserted == 1)
        #expect(report.outcomes[1].preservedLocal == 1)
        let mergedState = try await database.dbPool.read { db in
            (
                try UpdateBadgeRecord.fetchOne(
                    db,
                    key: ["pluginId": "plugin", "canonicalMediaId": "media", "mediaKind": MediaKind.manga.rawValue]
                ),
                try RepositoryRecord.fetchOne(
                    db,
                    key: "https://example.com/repo"
                )
            )
        }
        #expect(mergedState.0?.count == 4)
        #expect(mergedState.1 == localRepository)
    }

    @Test func resolvedLibraryConflictsPreserveKeepLocalAndKeepBackupBehavior() async throws {
        let keepLocal = try TestDatabase()
        defer { keepLocal.cleanup() }
        let keepBackup = try TestDatabase()
        defer { keepBackup.cleanup() }
        try await seedConflictDatabase(keepLocal)
        try await seedConflictDatabase(keepBackup)
        let imported = item(id: "media", title: "Backup")
        let backupCategory = category("backup-category")
        let backup = representedBackup(
            components: [.libraryCore, .readingHistory],
            categories: [backupCategory],
            items: [imported],
            links: [
                ItemCategoryLink(
                    itemId: imported.id,
                    categoryId: backupCategory.id
                )
            ],
            history: [
                ReadingHistoryRecord(
                    id: "backup-history",
                    libraryItemId: imported.id,
                    mediaKey: imported.id,
                    title: "Backup",
                    coverUrl: nil,
                    pluginId: imported.pluginId,
                    mediaKind: imported.effectiveType,
                    chapterKey: "backup",
                    chapterTitle: nil
                )
            ]
        )

        _ = try await operation(keepLocal).restore(
            backup,
            mode: .merge,
            operationId: "keep-local",
            resolvedConflicts: ["plugin_media": .keepLocal]
        )
        _ = try await operation(keepBackup).restore(
            backup,
            mode: .merge,
            operationId: "keep-backup",
            resolvedConflicts: ["plugin_media": .keepBackup]
        )

        let localState = try await keepLocal.dbPool.read { db in
            (
                try LibraryItem.fetchOne(db, key: "plugin_media"),
                try ItemCategoryLink.fetchOne(
                    db,
                    key: [
                        "itemId": "plugin_media",
                        "categoryId": "local-category"
                    ]
                ),
                try ReadingHistoryRecord.fetchOne(db, key: "backup-history")
            )
        }
        let backupState = try await keepBackup.dbPool.read { db in
            (
                try LibraryItem.fetchOne(db, key: "plugin_media"),
                try ItemCategoryLink.fetchOne(
                    db,
                    key: [
                        "itemId": "plugin_media",
                        "categoryId": "backup-category"
                    ]
                ),
                try ReadingHistoryRecord.fetchOne(db, key: "backup-history")
            )
        }
        #expect(localState.0?.title == "Local")
        #expect(localState.1 != nil)
        #expect(localState.2 == nil)
        #expect(backupState.0?.title == "Backup")
        #expect(backupState.1 != nil)
        #expect(backupState.2?.mediaKey == "plugin_media")
    }

    @Test func fullPreflightRejectsBeforeMutationWithTypedReasons() async throws {
        try await assertRejected(
            representedBackup(
                components: [.libraryCore],
                capabilities: [
                    capability(.libraryCore, .representedNonempty),
                    capability(.libraryCore, .representedNonempty)
                ],
                items: [item(id: "item", title: "Item")]
            ),
            reason: .invalidCapabilityMetadata(component: .libraryCore, code: "duplicate")
        )
        try await assertRejected(
            representedBackup(
                components: [.libraryCore],
                categories: [category("category")],
                items: [item(id: "item", title: "Item")],
                links: [ItemCategoryLink(itemId: "missing", categoryId: "category")]
            ),
            reason: .invalidLibraryClosure(itemId: "missing", categoryId: "category")
        )
        try await assertRejected(
            representedBackup(
                components: [.libraryCore],
                items: [
                    item(id: "media", title: "One"),
                    item(id: "plugin_media", title: "Two")
                ]
            ),
            reason: .mediaIdentityCollision(
                pluginId: "plugin",
                canonicalMediaId: "media"
            )
        )
        try await assertRejected(
            representedBackup(
                components: [.repositories],
                items: [item(id: "unrepresented", title: "Unrepresented")]
            ),
            reason: .invalidCapabilityMetadata(
                component: .libraryCore,
                code: "unrepresentedContainsRows"
            )
        )
        try await assertRejected(
            representedBackup(
                components: [.repositories],
                pluginIdentities: [identity("unrepresented")]
            ),
            reason: .invalidCapabilityMetadata(
                component: .pluginIdentityAndAliases,
                code: "unrepresentedContainsRows"
            )
        )
        let badPayload = Data([1, 2, 3])
        try await assertRejected(
            representedBackup(
                components: [.legacyStateArchive],
                archives: [
                    LegacyStateArchiveRecord(
                        id: nil,
                        sourceDomain: "plugin",
                        sourceKey: "state",
                        contentClass: .opaquePluginState,
                        valueType: "data",
                        valuePayload: badPayload,
                        fingerprint: "not-the-digest",
                        reason: "invalid",
                        createdAt: Date(timeIntervalSince1970: 1)
                    )
                ]
            ),
            reason: .invalidKeyData(
                component: .legacyStateArchive,
                key: "state",
                code: "payloadFingerprintMismatch"
            )
        )
        try await assertRejected(
            representedBackup(
                components: [.pluginIdentityAndAliases],
                pluginIdentities: [
                    identity("one"),
                    identity("two")
                ],
                pluginIdentityAliases: [
                    suiteAlias(pluginId: "one", domain: "suite"),
                    suiteAlias(pluginId: "two", domain: "suite")
                ]
            ),
            reason: .ambiguousPluginIdentity(identity: "suite")
        )
        try await assertRejected(
            representedBackup(
                components: [.pluginSettings],
                pluginSettings: [
                    PluginSettingRecord(
                        pluginId: "missing",
                        key: "key",
                        value: Data([1]),
                        updatedAt: nil
                    )
                ]
            ),
            reason: .missingPluginIdentity(pluginId: "missing")
        )
        try await assertOrphanedRetainedState()
        try await assertRejected(
            representedBackup(
                components: [.legacyStateArchive],
                archives: [
                    archive(
                        domain: "test.app",
                        key: LegacyDefaultsSourceTuple.aniListAccessTokenKey,
                        fingerprint: "credential"
                    )
                ]
            ),
            reason: .credentialPayloadRejected(
                sourceDomain: "test.app",
                sourceKey: LegacyDefaultsSourceTuple.aniListAccessTokenKey
            ),
            standardApplicationDomain: "test.app"
        )
        try await assertRejected(
            ImportedBackup(
                preferences: [
                    AppPreference(
                        key: AppPreferenceKeys.novelFontSize,
                        value: Data(#""redacted""#.utf8)
                    )
                ]
            ),
            reason: .invalidKeyData(
                component: .scalarAppPreferences,
                key: AppPreferenceKeys.novelFontSize,
                code: "invalidValue"
            )
        )
    }

    @Test func representedEmptyLibraryWipeReplacesLocalSystemListWithAFreshOne() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM libraryCategory WHERE isSystemCategory = 1")
            try LibraryCategory(
                id: "local-system",
                name: "Local System",
                sortOrder: 0,
                isSystemCategory: true
            ).insert(db)
        }

        let report = try await operation(database).restore(
            representedBackup(components: [.libraryCore]),
            mode: .wipe,
            operationId: "empty-system-category"
        )

        let outcome = try #require(
            report.outcomes.first { $0.component == .libraryCore }
        )
        #expect(outcome.replaced == 1)
        let categories = try await database.dbPool.read { db in
            try LibraryCategory.fetchAll(db)
        }
        #expect(categories.map(\.isSystemCategory) == [true])
        #expect(categories.first?.id != "local-system")
        #expect(categories.first?.name == "Uncategorized")
    }

    @Test func restoreKeepsTheSavedReadingPositionAndMode() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let backup = ImportedBackup(
            metadata: BackupMetadataRecord(formatVersion: 1, createdAt: Date(timeIntervalSince1970: 1)),
            capabilities: [capability(.readProgressAndResume, .representedNonempty)],
            mediaReadProgress: [
                MediaReadProgressRecord(
                    pluginId: "plugin",
                    canonicalMediaId: "series",
                    mediaKind: .manga,
                    lastReadChapterKey: "chapter-4",
                    updatedAt: Date(timeIntervalSince1970: 2),
                    provenance: .runtime,
                    lastReadPosition: 17,
                    readerViewer: 4
                )
            ]
        )

        _ = try await operation(database).restore(backup, mode: .wipe, operationId: "position")

        let restored = try await database.dbPool.read { db in
            try MediaReadProgressRecord.fetchOne(db)
        }
        #expect(restored?.lastReadChapterKey == "chapter-4")
        #expect(restored?.lastReadPosition == 17)
        #expect(restored?.readerViewer == 4)
    }

    @Test func restoredSeriesWithoutAListAreFiledIntoUncategorized() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let listless = item(id: "listless", title: "Listless")

        _ = try await operation(database).restore(
            representedBackup(components: [.libraryCore], items: [listless]),
            mode: .wipe,
            operationId: "listless-series"
        )

        let state = try await database.dbPool.read { db in
            (
                try LibraryCategory.filter(Column("isSystemCategory") == true).fetchAll(db),
                try ItemCategoryLink.fetchAll(db)
            )
        }
        #expect(state.0.count == 1)
        #expect(state.1.map(\.itemId) == [listless.id])
        #expect(state.1.map(\.categoryId) == state.0.map(\.id))
    }

    @Test func representedLibraryWipeRestoresImportedSystemCategoryExactly() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let exactDate = Date(timeIntervalSince1970: 100)
        let localSystem = LibraryCategory(
            id: "local-system",
            name: "Local System",
            sortOrder: 7,
            isSystemCategory: true,
            createdAt: exactDate
        )
        let importedSystem = LibraryCategory(
            id: "imported-system",
            name: "Imported System",
            sortOrder: 1,
            isSystemCategory: true,
            createdAt: exactDate
        )
        let importedItem = item(id: "imported-item", title: "Imported")
        let importedLink = ItemCategoryLink(
            itemId: importedItem.id,
            categoryId: importedSystem.id,
            addedAt: exactDate
        )
        try await database.dbPool.write { db in
            try localSystem.insert(db)
        }

        _ = try await operation(database).restore(
            representedBackup(
                components: [.libraryCore],
                categories: [importedSystem],
                items: [importedItem],
                links: [importedLink]
            ),
            mode: .wipe,
            operationId: "replace-system-category"
        )

        let state = try await database.dbPool.read { db in
            (
                try LibraryCategory.fetchAll(db),
                try ItemCategoryLink.fetchOne(
                    db,
                    key: [
                        "itemId": importedItem.id,
                        "categoryId": importedSystem.id
                    ]
                )
            )
        }
        #expect(state.0 == [importedSystem])
        #expect(state.1 == importedLink)
    }

    @Test func wipeLibraryClosureCannotUseDeletedLocalSystemCategory() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let exactDate = Date(timeIntervalSince1970: 100)
        let localSystem = LibraryCategory(
            id: "local-system",
            name: "Local System",
            sortOrder: 0,
            isSystemCategory: true,
            createdAt: exactDate
        )
        let importedItem = item(id: "imported-item", title: "Imported")
        try await database.dbPool.write { db in
            try localSystem.insert(db)
        }
        let backup = representedBackup(
            components: [.libraryCore],
            items: [importedItem],
            links: [
                ItemCategoryLink(
                    itemId: importedItem.id,
                    categoryId: localSystem.id
                )
            ]
        )

        do {
            _ = try await operation(database).restore(
                backup,
                mode: .wipe,
                operationId: "invalid-local-system-link"
            )
            Issue.record("Expected wipe closure rejection")
        } catch let BackupPreflightError.rejected(reason) {
            #expect(
                reason == .invalidLibraryClosure(
                    itemId: importedItem.id,
                    categoryId: localSystem.id
                )
            )
        }
        #expect(try await database.dbPool.read { db in
            try LibraryCategory.fetchOne(db, key: localSystem.id) == localSystem
                && BackupRestoreJournalRecord.fetchOne(
                    db,
                    key: "invalid-local-system-link"
                ) == nil
        })
    }

    @Test func capabilityEmptyPreferencesClearOnlyTheFullCatalog() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let theme = try AppPreference(key: AppPreferenceCatalog.appTheme, value: .dark)
        let unknown = AppPreference(key: "future-key", value: Data([1]))
        try await database.dbPool.write { db in
            try theme.insert(db)
            try unknown.insert(db)
        }
        let backup = representedBackup(components: [.scalarAppPreferences])

        let report = try await operation(database).restore(
            backup,
            mode: .wipe,
            operationId: "preferences-empty"
        )

        #expect(report.outcomes[0].replaced == 1)
        let preferences = try await database.dbPool.read { db in
            (
                try AppPreference.fetchOne(db, key: theme.key),
                try AppPreference.fetchOne(db, key: unknown.key)
            )
        }
        #expect(preferences.0 == nil)
        #expect(preferences.1 == unknown)
    }

    @Test func writerSnapshotCannotChangeBetweenPreflightAndTransaction() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            try RepositoryRecord(
                url: "https://local.example",
                lastFetched: nil,
                indexPayload: nil
            ).insert(db)
        }
        let competingWriterEntered = DispatchSemaphore(value: 0)
        let dbPool = database.dbPool
        let operation = ComponentAwareBackupRestoreOperation(
            dbPool: dbPool,
            standardApplicationDomain: "test.app",
            afterPreflightBeforeTransaction: {
                DispatchQueue.global().async {
                    try? dbPool.write { db in
                        competingWriterEntered.signal()
                        try RepositoryRecord(
                            url: "https://competing.example",
                            lastFetched: nil,
                            indexPayload: nil
                        ).insert(db)
                    }
                }
                #expect(
                    competingWriterEntered.wait(
                        timeout: .now() + 0.1
                    ) == .timedOut
                )
            }
        )

        let report = try await operation.restore(
            representedBackup(components: [.repositories]),
            mode: .wipe,
            operationId: "snapshot"
        )
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                competingWriterEntered.wait()
                continuation.resume()
            }
        }

        #expect(report.outcomes[0].replaced == 1)
        #expect(try await database.dbPool.read { db in
            try RepositoryRecord.fetchOne(
                db,
                key: "https://competing.example"
            ) != nil
        })
    }

    @Test func mediaDispositionRetargetsHistoryAndTrackerLink() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let local = item(id: "plugin_media", title: "Local")
        try await database.dbPool.write { db in
            try local.insert(db)
        }
        let imported = item(id: "media", title: "Imported")
        let backup = representedBackup(
            components: [.libraryCore, .readingHistory, .trackerLinks],
            items: [imported],
            history: [
                ReadingHistoryRecord(
                    id: "history",
                    libraryItemId: imported.id,
                    mediaKey: imported.id,
                    title: "History",
                    coverUrl: nil,
                    pluginId: imported.pluginId,
                    mediaKind: imported.effectiveType,
                    chapterKey: "chapter",
                    chapterTitle: nil
                )
            ],
            trackerLinks: [
                TrackerLinkRecord(
                    pluginId: "plugin",
                    canonicalMediaId: "media",
                    mediaKind: .manga,
                    providerId: "anilist",
                    remoteMediaId: "42",
                    updatedAt: nil,
                    provenance: .legacyUnknownTime
                )
            ]
        )

        let report = try await operation(database).restore(
            backup,
            mode: .merge,
            operationId: "media",
            resolvedConflicts: [local.id: .keepBackup]
        )

        #expect(report.outcomes.first(where: { $0.component == .libraryCore })?
            .replaced == 1)
        #expect(report.outcomes.first(where: { $0.component == .trackerLinks })?
            .inserted == 1)
        let mediaState = try await database.dbPool.read { db in
            (
                try ReadingHistoryRecord.fetchOne(db, key: "history"),
                try TrackerLinkRecord.fetchOne(
                db,
                key: [
                    "pluginId": "plugin",
                    "canonicalMediaId": "media",
                    "mediaKind": MediaKind.manga.rawValue,
                    "providerId": "anilist"
                ]
                )
            )
        }
        let restoredHistory = try #require(mediaState.0)
        #expect(restoredHistory.libraryItemId == local.id)
        #expect(restoredHistory.mediaKey == local.id)
        #expect(mediaState.1?.remoteMediaId == "42")
    }

    @Test func preCapabilityAniListIdRepresentsAndSynthesizesTrackerLink() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let legacy = item(id: "media", title: "Legacy", anilistId: 73)

        let report = try await operation(database).restore(
            ImportedBackup(items: [legacy]),
            mode: .merge,
            operationId: "legacy-anilist"
        )

        #expect(report.outcomes.map(\.component) == [.libraryCore, .trackerLinks])
        #expect(report.outcomes[1].inserted == 1)
        #expect(try await database.dbPool.read { db in
            try TrackerLinkRecord.fetchOne(
                db,
                key: [
                    "pluginId": "plugin",
                    "canonicalMediaId": "media",
                    "mediaKind": MediaKind.manga.rawValue,
                    "providerId": "anilist"
                ]
            )?.remoteMediaId == "73"
        })
    }

    @Test func sourceAwareArchivesAreIdempotentAndKeepDistinctSources() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let backup = representedBackup(
            components: [.legacyStateArchive],
            archives: [
                archive(domain: "plugin.one", key: "state", fingerprint: "same"),
                archive(domain: "plugin.two", key: "state", fingerprint: "same")
            ]
        )

        let first = try await operation(database).restore(
            backup,
            mode: .merge,
            operationId: "archives-1"
        )
        let second = try await operation(database).restore(
            backup,
            mode: .merge,
            operationId: "archives-2"
        )

        #expect(first.outcomes[0].inserted == 2)
        #expect(second.outcomes[0].skipped == 2)
        #expect(try await database.dbPool.read { db in
            try LegacyStateArchiveRecord.fetchCount(db)
        } == 2)
    }

    @Test func lateFailureRollsBackEveryComponentAndJournal() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let localPreference = AppPreference(
            key: AppPreferenceKeys.appTheme,
            value: Data(#""System""#.utf8)
        )
        try await database.dbPool.write { db in
            try localPreference.insert(db)
        }
        let backup = ImportedBackup(
            preferences: [
                AppPreference(
                    key: AppPreferenceKeys.appTheme,
                    value: Data(#""Dark""#.utf8)
                )
            ],
            repositories: [
                RepositoryRecord(
                    url: "https://example.com/repo",
                    lastFetched: nil,
                    indexPayload: nil
                )
            ],
            legacyStateArchives: [
                archive(domain: "plugin", key: "state", fingerprint: "archive")
            ]
        )
        let operation = ComponentAwareBackupRestoreOperation(
            dbPool: database.dbPool,
            standardApplicationDomain: "test.app",
            lateTransactionFailure: { _ in throw InjectedFailure.late }
        )

        await #expect(throws: InjectedFailure.self) {
            try await operation.restore(
                backup,
                mode: .wipe,
                operationId: "rollback"
            )
        }
        let rollbackState = try await database.dbPool.read { db in
            (
                try AppPreference.fetchOne(db, key: AppPreferenceKeys.appTheme),
                try RepositoryRecord.fetchCount(db),
                try LegacyStateArchiveRecord.fetchCount(db),
                try BackupRestoreJournalRecord.fetchOne(db, key: "rollback")
            )
        }
        #expect(rollbackState.0 == localPreference)
        #expect(rollbackState.1 == 0)
        #expect(rollbackState.2 == 0)
        #expect(rollbackState.3 == nil)
    }

    private func assertRejected(
        _ backup: ImportedBackup,
        reason: BackupPreflightReason,
        standardApplicationDomain: String = "test.app"
    ) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let sentinel = RepositoryRecord(
            url: "https://sentinel.example",
            lastFetched: nil,
            indexPayload: nil
        )
        try await database.dbPool.write { db in
            try sentinel.insert(db)
        }

        do {
            _ = try await operation(
                database,
                standardApplicationDomain: standardApplicationDomain
            ).restore(backup, mode: .wipe, operationId: "rejected")
            Issue.record("Expected preflight rejection")
        } catch let BackupPreflightError.rejected(actual) {
            #expect(actual == reason)
        }
        let rejectedState = try await database.dbPool.read { db in
            (
                try RepositoryRecord.fetchOne(db, key: sentinel.url),
                try BackupRestoreJournalRecord.fetchOne(db, key: "rejected")
            )
        }
        #expect(rejectedState.0 == sentinel)
        #expect(rejectedState.1 == nil)
    }

    private func assertOrphanedRetainedState() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            try identity("retained").insert(db)
            try PluginSettingRecord(
                pluginId: "retained",
                key: "state",
                value: Data([1]),
                updatedAt: nil
            ).insert(db)
        }
        let backup = representedBackup(
            components: [.pluginIdentityAndAliases],
            pluginIdentities: [identity("replacement")]
        )

        do {
            _ = try await operation(database).restore(
                backup,
                mode: .wipe,
                operationId: "orphan"
            )
            Issue.record("Expected preflight rejection")
        } catch let BackupPreflightError.rejected(reason) {
            #expect(
                reason == .orphanedRetainedPluginState(
                    pluginId: "retained",
                    component: .pluginSettings
                )
            )
        }
        #expect(try await database.dbPool.read { db in
            try PluginIdentityRecord.fetchOne(db, key: "retained") != nil
                && BackupRestoreJournalRecord.fetchOne(db, key: "orphan") == nil
        })
    }

    private func seedConflictDatabase(_ database: TestDatabase) async throws {
        try await database.dbPool.write { db in
            try category("local-category").insert(db)
            try item(id: "plugin_media", title: "Local").insert(db)
            try ItemCategoryLink(
                itemId: "plugin_media",
                categoryId: "local-category"
            ).insert(db)
            try ReadingHistoryRecord(
                id: "local-history",
                libraryItemId: "plugin_media",
                mediaKey: "plugin_media",
                title: "Local",
                coverUrl: nil,
                pluginId: "plugin",
                mediaKind: .manga,
                chapterKey: "local",
                chapterTitle: nil
            ).insert(db)
        }
    }

    nonisolated private func operation(
        _ database: TestDatabase,
        standardApplicationDomain: String = "test.app"
    ) -> ComponentAwareBackupRestoreOperation {
        ComponentAwareBackupRestoreOperation(
            dbPool: database.dbPool,
            standardApplicationDomain: standardApplicationDomain,
            operationIdProvider: { "generated" },
            now: { Date(timeIntervalSince1970: 100) }
        )
    }

    nonisolated private func representedBackup(
        components: [BackupComponent],
        capabilities explicitCapabilities: [BackupCapabilityRecord]? = nil,
        categories: [LibraryCategory] = [],
        items: [LibraryItem] = [],
        links: [ItemCategoryLink] = [],
        history: [ReadingHistoryRecord] = [],
        preferences: [AppPreference] = [],
        trackerLinks: [TrackerLinkRecord] = [],
        updateBadges: [UpdateBadgeRecord] = [],
        repositories: [RepositoryRecord] = [],
        pluginIdentities: [PluginIdentityRecord] = [],
        pluginIdentityAliases: [PluginIdentityAliasRecord] = [],
        pluginSettings: [PluginSettingRecord] = [],
        archives: [LegacyStateArchiveRecord] = []
    ) -> ImportedBackup {
        let nonempty = Set(components.filter { component in
            switch component {
            case .libraryCore:
                !categories.isEmpty || !items.isEmpty || !links.isEmpty
            case .readingHistory:
                !history.isEmpty
            case .scalarAppPreferences:
                !preferences.isEmpty
            case .trackerLinks:
                !trackerLinks.isEmpty
            case .updateBadges:
                !updateBadges.isEmpty
            case .repositories:
                !repositories.isEmpty
            case .pluginIdentityAndAliases:
                !pluginIdentities.isEmpty || !pluginIdentityAliases.isEmpty
            case .pluginSettings:
                !pluginSettings.isEmpty
            case .legacyStateArchive:
                !archives.isEmpty
            default:
                false
            }
        })
        let capabilities = explicitCapabilities ?? components.map {
            capability(
                $0,
                nonempty.contains($0) ? .representedNonempty : .representedEmpty
            )
        }
        return ImportedBackup(
            metadata: BackupMetadataRecord(
                formatVersion: 1,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            capabilities: capabilities,
            categories: categories,
            items: items,
            links: links,
            history: history,
            preferences: preferences,
            trackerLinks: trackerLinks,
            updateBadges: updateBadges,
            repositories: repositories,
            pluginIdentities: pluginIdentities,
            pluginIdentityAliases: pluginIdentityAliases,
            pluginSettings: pluginSettings,
            legacyStateArchives: archives
        )
    }

    nonisolated private func capability(
        _ component: BackupComponent,
        _ representation: BackupRepresentation
    ) -> BackupCapabilityRecord {
        BackupCapabilityRecord(
            component: component,
            representation: representation
        )
    }

    nonisolated private func category(_ id: String) -> LibraryCategory {
        LibraryCategory(id: id, name: id, sortOrder: 0)
    }

    nonisolated private func item(
        id: String,
        title: String,
        anilistId: Int? = nil,
        pluginId: String = "plugin"
    ) -> LibraryItem {
        LibraryItem(
            id: id,
            title: title,
            coverUrl: nil,
            pluginId: pluginId,
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: anilistId
        )
    }

    nonisolated private func identity(_ pluginId: String) -> PluginIdentityRecord {
        PluginIdentityRecord(
            pluginId: pluginId,
            manifestId: nil,
            lastSeenAt: Date(timeIntervalSince1970: 1)
        )
    }

    nonisolated private func suiteAlias(
        pluginId: String,
        domain: String
    ) -> PluginIdentityAliasRecord {
        PluginIdentityAliasRecord(
            pluginId: pluginId,
            aliasKind: "suite",
            aliasValue: domain,
            suiteDomain: domain,
            discoverySource: "test",
            lastSeenAt: Date(timeIntervalSince1970: 1)
        )
    }

    nonisolated private func archive(
        domain: String,
        key: String,
        fingerprint: String
    ) -> LegacyStateArchiveRecord {
        let payload = Data(fingerprint.utf8)
        return LegacyStateArchiveRecord(
            id: nil,
            sourceDomain: domain,
            sourceKey: key,
            contentClass: .opaquePluginState,
            valueType: "data",
            valuePayload: payload,
            fingerprint: CanonicalPropertyListCapture.digest(payload),
            reason: "retained",
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}
