import Foundation
import GRDB
import Testing
import ZIPFoundation
import ito_runner
@testable import Ito

struct BackupImporterCapabilityTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func newNativeBackupFetchesEveryDurableTypedRowAndCapabilities() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let item = LibraryItem(
            id: "plugin_media",
            title: "Title",
            coverUrl: nil,
            pluginId: "plugin",
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data([1]),
            anilistId: 42
        )
        let category = LibraryCategory(
            id: "category",
            name: "Category",
            sortOrder: 0,
            createdAt: date
        )

        try await database.dbPool.write { db in
            // The backup holds only the rows seeded here, not the migrated system list.
            try db.execute(sql: "DELETE FROM libraryCategory")
            try BackupMetadataRecord(formatVersion: 1, createdAt: date).insert(db)
            for component in BackupComponent.allCases {
                try BackupCapabilityRecord(
                    component: component,
                    representation: .representedNonempty
                ).insert(db)
            }
            try category.insert(db)
            try item.insert(db)
            try ItemCategoryLink(itemId: item.id, categoryId: category.id, addedAt: date)
                .insert(db)
            try ReadingHistoryRecord(
                id: "history",
                libraryItemId: item.id,
                mediaKey: "media",
                title: "Title",
                coverUrl: nil,
                pluginId: "plugin",
                mediaKind: .manga,
                chapterKey: "chapter",
                chapterTitle: nil,
                readAt: date
            ).insert(db)
            try SourceMappingRecord(
                canonicalProvider: "anilist",
                canonicalMediaId: "42",
                mediaType: .manga,
                pluginId: "plugin",
                pluginMediaKey: "media",
                decision: .discard,
                matchMethod: .none,
                confidence: 1,
                titleSnapshot: "Rejected",
                createdAt: date,
                updatedAt: date,
                coverURLSnapshot: "https://example.com/cover.jpg",
                encodedPayload: Data([8, 9]),
                payloadVersion: 2,
                pluginVersion: "1.2.3",
                lastVerifiedAt: date.addingTimeInterval(10)
            ).insert(db)
            for entry in AppPreferenceCatalogEntry.allCases {
                try AppPreference(
                    key: entry.rawValue,
                    value: entry.canonicalDefaultJSON
                ).insert(db)
            }
            try ReadProgressKeyRecord(
                pluginId: "plugin",
                canonicalMediaId: "media",
                mediaKind: .manga,
                chapterKey: "chapter",
                markedAt: date,
                provenance: .runtime
            ).insert(db)
            try ReadProgressNumberRecord(
                pluginId: "plugin",
                canonicalMediaId: "media",
                mediaKind: .manga,
                chapterNumber: 1,
                markedAt: date,
                provenance: .runtime
            ).insert(db)
            try MediaReadProgressRecord(
                pluginId: "plugin",
                canonicalMediaId: "media",
                mediaKind: .manga,
                lastReadChapterKey: "chapter",
                updatedAt: date,
                provenance: .runtime
            ).insert(db)
            try TrackerLinkRecord(
                pluginId: "plugin",
                canonicalMediaId: "media",
                mediaKind: .manga,
                providerId: "anilist",
                remoteMediaId: "42",
                updatedAt: date,
                provenance: .runtime
            ).insert(db)
            try UpdateBadgeRecord(
                pluginId: "plugin",
                canonicalMediaId: "media",
                mediaKind: .manga,
                count: 3,
                updatedAt: date,
                provenance: .runtime
            ).insert(db)
            try RepositoryRecord(
                url: "https://example.com",
                lastFetched: date,
                indexPayload: nil
            ).insert(db)
            try PluginMigrationAliasRecord(
                foreignId: "foreign",
                pluginId: "plugin",
                updatedAt: date
            ).insert(db)
            try PluginIdentityRecord(
                pluginId: "plugin",
                manifestId: "manifest",
                lastSeenAt: date
            ).insert(db)
            try PluginIdentityAliasRecord(
                pluginId: "plugin",
                aliasKind: "suite",
                aliasValue: "plugin",
                suiteDomain: "moe.ito.runners.plugin",
                discoverySource: "test",
                lastSeenAt: date
            ).insert(db)
            try PluginSettingRecord(
                pluginId: "plugin",
                key: "anilist_access_token",
                value: Data("plugin-owned".utf8),
                updatedAt: date
            ).insert(db)
            try LegacyUnscopedMediaStateRecord(
                sourceKey: "source",
                legacyMediaId: "legacy",
                canonicalPayload: Data([3]),
                candidates: Data([4]),
                fingerprint: "unscoped"
            ).insert(db)
            try LegacyStateArchiveRecord(
                id: nil,
                sourceDomain: "moe.ito.runners.plugin",
                sourceKey: "anilist_access_token",
                contentClass: .opaquePluginState,
                valueType: "data",
                valuePayload: Data("plugin-archive".utf8),
                fingerprint: "archive",
                reason: "conflict",
                createdAt: date
            ).insert(db)
            try insertExcludedRows(in: db)
        }

        let backup = try await ItoNativeImporter(
            standardApplicationDomain: "moe.itoapp.ito"
        ).parse(url: database.databaseURL)

        #expect(backup.metadata?.formatVersion == 1)
        #expect(backup.representedComponents == BackupComponent.allCases)
        #expect(backup.categories.count == 1)
        #expect(backup.items.count == 1)
        #expect(backup.links.count == 1)
        #expect(backup.history.count == 1)
        #expect(backup.sourceMappings.count == 1)
        #expect(backup.sourceMappings[0].decision == .discard)
        #expect(backup.sourceMappings[0].matchMethod == .none)
        #expect(backup.preferences.count == AppPreferenceCatalogEntry.allCases.count)
        #expect(
            Set(backup.representedPreferenceKeys)
                == Set(AppPreferenceCatalogEntry.allCases.map(\.rawValue))
        )
        #expect(backup.readProgressKeys.count == 1)
        #expect(backup.readProgressNumbers.count == 1)
        #expect(backup.mediaReadProgress.count == 1)
        #expect(backup.trackerLinks.count == 1)
        #expect(backup.updateBadges.count == 1)
        #expect(backup.repositories.count == 1)
        #expect(backup.importerAliases.count == 1)
        #expect(backup.pluginIdentities.count == 1)
        #expect(backup.pluginIdentityAliases.count == 1)
        #expect(backup.pluginSettings.count == 1)
        #expect(backup.legacyUnscopedMediaState.count == 1)
        #expect(backup.legacyStateArchives.count == 1)
    }

    @Test func oldNativeBackupInfersRowsWithoutClaimingAbsentCatalogState() async throws {
        let fixture = try TemporaryBackupFixture(extension: "itobackup")
        defer { fixture.cleanup() }
        let repositories = [
            Repository(url: "https://example.com", lastFetched: date, index: nil)
        ]
        let repositoryPayload = try JSONEncoder().encode(repositories)

        try fixture.withDatabase { db in
            try createLegacyLibraryTables(in: db)
            try db.create(table: "appPreference") { table in
                table.primaryKey("key", .text)
                table.column("value", .blob).notNull()
            }
            try db.execute(
                sql: """
                    INSERT INTO libraryItem
                        (id, title, pluginId, isAnime, rawPayload, anilistId)
                    VALUES ('plugin_media', 'Title', 'plugin', 0, X'01', 42)
                    """
            )
            try db.execute(
                sql: "INSERT INTO appPreference (key, value) VALUES (?, ?), (?, ?)",
                arguments: [
                    "selectedTheme", Data(#""Dark""#.utf8),
                    "ito_repositories", repositoryPayload
                ]
            )
        }

        let backup = try await ItoNativeImporter().parse(url: fixture.url)

        #expect(backup.metadata == nil)
        #expect(backup.capabilities.isEmpty)
        #expect(
            backup.legacyRepresentationOverrides == [
                .libraryCore: .representedNonempty,
                .repositories: .representedNonempty
            ]
        )
        #expect(backup.preferences.map(\.key) == ["selectedTheme"])
        #expect(backup.representedPreferenceKeys == ["selectedTheme"])
        #expect(backup.representation(of: .libraryCore) == .representedNonempty)
        #expect(backup.representation(of: .scalarAppPreferences) == .representedNonempty)
        #expect(backup.representation(of: .repositories) == .representedNonempty)
        #expect(backup.representation(of: .readingHistory) == .unrepresented)
        #expect(backup.representation(of: .readProgressAndResume) == .unrepresented)
        #expect(backup.trackerLinks.count == 1)
        #expect(backup.trackerLinks[0].canonicalMediaId == "media")
        #expect(backup.trackerLinks[0].remoteMediaId == "42")
        #expect(backup.trackerLinks[0].provenance == .legacyUnknownTime)
        #expect(backup.repositories.map(\.url) == ["https://example.com"])
    }

    @Test func oldNativeExplicitEmptyRepositoriesRemainRepresented() async throws {
        let explicitEmpty = try await parseLegacyRepositoryBackup(repositories: [])
        #expect(explicitEmpty.preferences.isEmpty)
        #expect(explicitEmpty.representedPreferenceKeys.isEmpty)
        #expect(explicitEmpty.repositories.isEmpty)
        #expect(
            explicitEmpty.legacyRepresentationOverrides == [.repositories: .representedEmpty]
        )
        #expect(explicitEmpty.representation(of: .repositories) == .representedEmpty)

        let absent = try await parseLegacyRepositoryBackup(repositories: nil)
        #expect(absent.legacyRepresentationOverrides.isEmpty)
        #expect(absent.representation(of: .repositories) == .unrepresented)
    }

    @MainActor
    @Test(arguments: [BackupRestoreMode.merge, .wipe])
    func oldNativeEmptyLibraryAndHistoryTablesRemainExplicitlyRepresented(
        mode: BackupRestoreMode
    ) async throws {
        let source = try TestDatabase()
        defer { source.cleanup() }
        // An old backup with empty library tables, without the migrated system list.
        try await source.dbPool.write { db in
            try db.execute(sql: "DELETE FROM libraryCategory")
        }
        let backup = try await ItoNativeImporter().parse(url: source.databaseURL)

        #expect(backup.representation(of: .libraryCore) == .representedEmpty)
        #expect(backup.representation(of: .readingHistory) == .representedEmpty)

        let destination = try TestDatabase()
        defer { destination.cleanup() }
        let localCategory = LibraryCategory(
            id: "local-system",
            name: "Local",
            sortOrder: 0,
            isSystemCategory: true,
            createdAt: date
        )
        let localItem = LibraryItem(
            id: "plugin_media",
            title: "Local",
            coverUrl: nil,
            pluginId: "plugin",
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil
        )
        let localHistory = ReadingHistoryRecord(
            id: "local-history",
            libraryItemId: localItem.id,
            mediaKey: localItem.id,
            title: "Local",
            coverUrl: nil,
            pluginId: localItem.pluginId,
            mediaKind: localItem.effectiveType,
            chapterKey: "chapter",
            chapterTitle: nil,
            readAt: date
        )
        try await destination.dbPool.write { db in
            // The fixture's system list replaces the migrated one.
            try db.execute(sql: "DELETE FROM libraryCategory WHERE isSystemCategory = 1")
            try localCategory.insert(db)
            try localItem.insert(db)
            try ItemCategoryLink(
                itemId: localItem.id,
                categoryId: localCategory.id,
                addedAt: date
            ).insert(db)
            try localHistory.insert(db)
        }

        _ = try await restoreOperation(destination).restore(
            backup,
            mode: mode,
            operationId: "legacy-empty-\(mode.rawValue)"
        )

        let counts = try await destination.dbPool.read { db in
            (
                try LibraryCategory.fetchCount(db),
                try LibraryItem.fetchCount(db),
                try ItemCategoryLink.fetchCount(db),
                try ReadingHistoryRecord.fetchCount(db)
            )
        }
        let expectedCount = mode == .merge ? 1 : 0
        // Merge keeps the local system list; a wipe leaves a fresh one.
        #expect(counts.0 == 1)
        #expect(counts.1 == expectedCount)
        #expect(counts.2 == expectedCount)
        #expect(counts.3 == expectedCount)
    }

    @MainActor
    @Test func nativeWipePreservesDistinctHistoryIdsWithIdenticalSemantics() async throws {
        let source = try TestDatabase()
        defer { source.cleanup() }
        let first = ReadingHistoryRecord(
            id: "history-one",
            mediaKey: "media",
            title: "Title",
            coverUrl: nil,
            pluginId: "plugin",
            mediaKind: .manga,
            chapterKey: "chapter",
            chapterTitle: "Chapter",
            readAt: date
        )
        let second = ReadingHistoryRecord(
            id: "history-two",
            mediaKey: first.mediaKey,
            title: first.title,
            coverUrl: first.coverUrl,
            pluginId: first.pluginId,
            mediaKind: .manga,
            chapterKey: first.chapterKey,
            chapterTitle: first.chapterTitle,
            readAt: first.readAt
        )
        try await source.dbPool.write { db in
            try db.execute(sql: "DELETE FROM libraryCategory")
            try BackupMetadataRecord(formatVersion: 1, createdAt: date).insert(db)
            try BackupCapabilityRecord(
                component: .readingHistory,
                representation: .representedNonempty
            ).insert(db)
            try first.insert(db)
            try second.insert(db)
        }
        let backup = try await ItoNativeImporter().parse(url: source.databaseURL)

        let destination = try TestDatabase()
        defer { destination.cleanup() }
        try await destination.dbPool.write { db in
            try ReadingHistoryRecord(
                id: "local",
                mediaKey: "local",
                title: "Local",
                coverUrl: nil,
                pluginId: "plugin",
                mediaKind: .manga,
                chapterKey: "local",
                chapterTitle: nil,
                readAt: date
            ).insert(db)
        }

        let report = try await restoreOperation(destination).restore(
            backup,
            mode: .wipe,
            operationId: "distinct-history"
        )

        let outcome = try #require(
            report.outcomes.first { $0.component == .readingHistory }
        )
        #expect(outcome.replaced == 1)
        #expect(outcome.inserted == 2)
        #expect(outcome.skipped == 0)
        #expect(
            try await destination.dbPool.read { db in
                Set(try ReadingHistoryRecord.fetchAll(db).map(\.id))
            } == [first.id, second.id]
        )
    }

    @MainActor
    @Test func legacyEmptyRepositoriesDriveMergeAndWipeSemantics() async throws {
        let explicitEmpty = try await parseLegacyRepositoryBackup(repositories: [])
        let absent = try await parseLegacyRepositoryBackup(repositories: nil)
        let localRepository = RepositoryRecord(
            url: "https://example.com",
            lastFetched: date,
            indexPayload: Data([1])
        )

        let mergeDatabase = try TestDatabase()
        defer { mergeDatabase.cleanup() }
        try await mergeDatabase.dbPool.write { db in
            try localRepository.insert(db)
        }
        let mergeReport = try await restoreOperation(mergeDatabase).restore(
            explicitEmpty,
            mode: .merge,
            operationId: "legacy-empty-merge"
        )
        let mergeOutcome = try #require(
            mergeReport.outcomes.first { $0.component == .repositories }
        )
        #expect(mergeOutcome.total == 0)
        #expect(
            try await mergeDatabase.dbPool.read { db in
                try RepositoryRecord.fetchOne(db, key: localRepository.url)
            } == localRepository
        )

        let wipeDatabase = try TestDatabase()
        defer { wipeDatabase.cleanup() }
        try await wipeDatabase.dbPool.write { db in
            try localRepository.insert(db)
        }
        let wipeReport = try await restoreOperation(wipeDatabase).restore(
            explicitEmpty,
            mode: .wipe,
            operationId: "legacy-empty-wipe"
        )
        let wipeOutcome = try #require(
            wipeReport.outcomes.first { $0.component == .repositories }
        )
        #expect(wipeOutcome.replaced == 1)
        #expect(
            try await wipeDatabase.dbPool.read { db in
                try RepositoryRecord.fetchCount(db)
            } == 0
        )

        let absentDatabase = try TestDatabase()
        defer { absentDatabase.cleanup() }
        try await absentDatabase.dbPool.write { db in
            try localRepository.insert(db)
        }
        let absentReport = try await restoreOperation(absentDatabase).restore(
            absent,
            mode: .wipe,
            operationId: "legacy-absent-wipe"
        )
        #expect(!absentReport.outcomes.contains { $0.component == .repositories })
        #expect(
            try await absentDatabase.dbPool.read { db in
                try RepositoryRecord.fetchOne(db, key: localRepository.url)
            } == localRepository
        )
    }

    @Test func malformedCapabilityMetadataIsRejectedWithTypedReasons() async throws {
        let unknown = try TemporaryBackupFixture(extension: "itobackup")
        defer { unknown.cleanup() }
        try unknown.withDatabase { db in
            try createMetadataTables(in: db)
            try db.execute(
                sql: """
                    INSERT INTO backupMetadata VALUES (1, 1, 0);
                    INSERT INTO backupCapability VALUES ('futureComponent', 'representedEmpty');
                    """
            )
        }
        await #expect(
            throws: BackupPreflightError.rejected(
                .invalidCapabilityMetadata(component: nil, code: "unknownComponent")
            )
        ) {
            _ = try await ItoNativeImporter().parse(url: unknown.url)
        }

        let duplicate = try TemporaryBackupFixture(extension: "itobackup")
        defer { duplicate.cleanup() }
        try duplicate.withDatabase { db in
            try createMetadataTables(in: db)
            try db.execute(
                sql: """
                    INSERT INTO backupMetadata VALUES (1, 1, 0);
                    INSERT INTO backupCapability VALUES ('repositories', 'representedEmpty');
                    INSERT INTO backupCapability VALUES ('repositories', 'representedEmpty');
                    """
            )
        }
        await #expect(
            throws: BackupPreflightError.rejected(
                .invalidCapabilityMetadata(component: .repositories, code: "duplicate")
            )
        ) {
            _ = try await ItoNativeImporter().parse(url: duplicate.url)
        }
    }

    @Test func nativeScalarCapabilityRequiresTheCompleteClosedCatalog() async throws {
        let partial = try TestDatabase()
        defer { partial.cleanup() }
        try await partial.dbPool.write { db in
            try db.execute(sql: "DELETE FROM libraryCategory")
            try BackupMetadataRecord(formatVersion: 1, createdAt: date).insert(db)
            try BackupCapabilityRecord(
                component: .scalarAppPreferences,
                representation: .representedNonempty
            ).insert(db)
            try AppPreference(
                key: AppPreferenceCatalogEntry.appTheme.rawValue,
                value: AppPreferenceCatalogEntry.appTheme.canonicalDefaultJSON
            ).insert(db)
        }

        await #expect(
            throws: BackupPreflightError.rejected(
                .invalidCapabilityMetadata(
                    component: .scalarAppPreferences,
                    code: "incompletePreferenceCatalog"
                )
            )
        ) {
            _ = try await ItoNativeImporter().parse(url: partial.databaseURL)
        }

        let empty = try TestDatabase()
        defer { empty.cleanup() }
        try await empty.dbPool.write { db in
            try db.execute(sql: "DELETE FROM libraryCategory")
            try BackupMetadataRecord(formatVersion: 1, createdAt: date).insert(db)
            try BackupCapabilityRecord(
                component: .scalarAppPreferences,
                representation: .representedEmpty
            ).insert(db)
        }
        let emptyBackup = try await ItoNativeImporter().parse(url: empty.databaseURL)
        #expect(emptyBackup.preferences.isEmpty)
        #expect(emptyBackup.representedPreferenceKeys.isEmpty)
        #expect(emptyBackup.representation(of: .scalarAppPreferences) == .representedEmpty)
    }

    @Test func nativeCredentialArchiveIsRejectedWithoutIncludingItsValue() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            try LegacyStateArchiveRecord(
                id: nil,
                sourceDomain: "moe.itoapp.ito",
                sourceKey: "anilist_access_token",
                contentClass: .appNonSecret,
                valueType: "string",
                valuePayload: Data("never-report-this".utf8),
                fingerprint: "credential",
                reason: "invalid",
                createdAt: date
            ).insert(db)
        }

        let expected = BackupPreflightError.rejected(
            .credentialPayloadRejected(
                sourceDomain: "moe.itoapp.ito",
                sourceKey: "anilist_access_token"
            )
        )
        await #expect(throws: expected) {
            _ = try await ItoNativeImporter(
                standardApplicationDomain: "moe.itoapp.ito"
            ).parse(url: database.databaseURL)
        }
        let payload = try JSONEncoder().encode(expected)
        #expect(
            !(String(bytes: payload, encoding: .utf8) ?? "").contains("never-report-this")
        )
    }

    @MainActor
    @Test func aidokuAndPaperbackRepresentOnlyLibraryAndHistoryEvenWhenEmpty() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let repoManager = RepoManager(dbPool: database.dbPool)
        let resolver = PluginResolver(
            dbPool: database.dbPool,
            repoManager: repoManager,
            installedPluginIds: { [] }
        )

        let aidokuFixture = try TemporaryBackupFixture(extension: "json")
        defer { aidokuFixture.cleanup() }
        try Data(#"{"date":1700000000}"#.utf8).write(to: aidokuFixture.url)
        let aidoku = try await AidokuImporter(resolver: resolver).parse(url: aidokuFixture.url)
        assertForeignRepresentations(aidoku)

        let paperbackFixture = try TemporaryBackupFixture(extension: "pas4")
        defer { paperbackFixture.cleanup() }
        try makeEmptyPaperbackArchive(at: paperbackFixture.url)
        let paperback = try await PaperbackImporter(resolver: resolver).parse(
            url: paperbackFixture.url
        )
        assertForeignRepresentations(paperback)
    }

    @MainActor
    @Test func oldNativeBackupWithoutMediaKindInfersKnownAndArchivesUnknownRows() async throws {
        let fixture = try TemporaryBackupFixture(extension: "itobackup")
        defer { fixture.cleanup() }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.withDatabase { db in
            try db.create(table: "libraryItem") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("coverUrl", .text)
                t.column("pluginId", .text).notNull()
                t.column("isAnime", .boolean).notNull()
                t.column("pluginType", .text)
                t.column("rawPayload", .blob).notNull()
                t.column("anilistId", .integer)
            }
            try db.execute(
                sql: """
                    INSERT INTO libraryItem (id, title, pluginId, isAnime, pluginType, rawPayload)
                    VALUES ('known-item', 'Known', 'test.plugin', 0, 'manga', X'00')
                    """
            )
            // Create old readingHistory table WITHOUT mediaKind column
            try db.create(table: "readingHistory") { t in
                t.primaryKey("id", .text)
                t.column("libraryItemId", .text)
                t.column("mediaKey", .text).notNull()
                t.column("title", .text).notNull()
                t.column("coverUrl", .text)
                t.column("pluginId", .text).notNull()
                t.column("chapterKey", .text).notNull()
                t.column("chapterTitle", .text)
                t.column("readAt", .datetime).notNull()
            }
            // Known row linking to library item
            try db.execute(
                sql: """
                    INSERT INTO readingHistory (id, libraryItemId, mediaKey, title, pluginId, chapterKey, readAt)
                    VALUES ('known-history', 'known-item', 'known-item', 'Known', 'test.plugin', 'ch1', ?)
                    """,
                arguments: [date]
            )
            // Unknown / unprovable row
            try db.execute(
                sql: """
                    INSERT INTO readingHistory (id, libraryItemId, mediaKey, title, pluginId, chapterKey, readAt)
                    VALUES ('unknown-history', NULL, 'unknown-media', 'Unknown', 'orphan.plugin', 'ch1', ?)
                    """,
                arguments: [date]
            )
        }

        let imported = try await ItoNativeImporter().parse(url: fixture.url)
        #expect(imported.history.count == 1)
        #expect(imported.history[0].id == "known-history")
        #expect(imported.history[0].mediaKind == .manga)

        #expect(imported.legacyStateArchives.count == 1)
        #expect(imported.legacyStateArchives[0].reason == "kindUnknown")
        #expect(imported.legacyStateArchives[0].contentClass == .appNonSecret)
        #expect(imported.representation(of: .legacyStateArchive) == .representedNonempty)
    }

    @MainActor
    @Test func newBackupWithInvalidMediaKindIsRejectedStrictly() async throws {
        let fixture = try TemporaryBackupFixture(extension: "itobackup")
        defer { fixture.cleanup() }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.withDatabase { db in
            try createMetadataTables(in: db)
            try BackupMetadataRecord(formatVersion: 1, createdAt: date).insert(db)
            try BackupCapabilityRecord(component: .readingHistory, representation: .representedNonempty).insert(db)
            try db.create(table: "readingHistory") { t in
                t.primaryKey("id", .text)
                t.column("libraryItemId", .text)
                t.column("mediaKey", .text).notNull()
                t.column("title", .text).notNull()
                t.column("coverUrl", .text)
                t.column("pluginId", .text).notNull()
                t.column("mediaKind", .text).notNull()
                t.column("chapterKey", .text).notNull()
                t.column("chapterTitle", .text)
                t.column("readAt", .datetime).notNull()
            }
            try db.execute(
                sql: """
                    INSERT INTO readingHistory (id, libraryItemId, mediaKey, title, pluginId, mediaKind, chapterKey, readAt)
                    VALUES ('hist-1', NULL, 'media-1', 'Title', 'plugin', 'not_a_valid_kind', 'ch1', ?)
                    """,
                arguments: [date]
            )
        }

        await #expect(
            throws: BackupPreflightError.rejected(
                .invalidComponentData(component: .readingHistory, code: "invalidMediaKind")
            )
        ) {
            _ = try await ItoNativeImporter().parse(url: fixture.url)
        }
    }

    private func assertForeignRepresentations(_ backup: ImportedBackup) {
        #expect(backup.representedComponents == [.libraryCore, .readingHistory])
        #expect(backup.representation(of: .libraryCore) == .representedEmpty)
        #expect(backup.representation(of: .readingHistory) == .representedEmpty)
        for component in BackupComponent.allCases
        where component != .libraryCore && component != .readingHistory {
            #expect(backup.representation(of: component) == .unrepresented)
        }
    }

    private func parseLegacyRepositoryBackup(
        repositories: [Repository]?
    ) async throws -> ImportedBackup {
        let fixture = try TemporaryBackupFixture(extension: "itobackup")
        defer { fixture.cleanup() }
        let payload = try repositories.map { try JSONEncoder().encode($0) }
        try fixture.withDatabase { db in
            try db.create(table: "appPreference") { table in
                table.primaryKey("key", .text)
                table.column("value", .blob).notNull()
            }
            if let payload {
                try db.execute(
                    sql: "INSERT INTO appPreference (key, value) VALUES (?, ?)",
                    arguments: ["ito_repositories", payload]
                )
            }
        }
        return try await ItoNativeImporter().parse(url: fixture.url)
    }

    nonisolated private func restoreOperation(
        _ database: TestDatabase
    ) -> ComponentAwareBackupRestoreOperation {
        ComponentAwareBackupRestoreOperation(
            dbPool: database.dbPool,
            standardApplicationDomain: "test.app",
            operationIdProvider: { "generated" },
            now: { Date(timeIntervalSince1970: 100) }
        )
    }

    private func insertExcludedRows(in db: Database) throws {
        try ThemeCacheRecord(
            mediaKey: "media",
            dominantHex: "#000000",
            secondaryHex: "#ffffff"
        ).insert(db)
        try LegacyDefaultsInboxRecord(
            sourceDomain: "domain",
            sourceKey: "key",
            valueType: "data",
            canonicalPayload: Data([9]),
            fingerprint: "inbox",
            expectedElementCount: 0,
            capturedAt: date,
            lifecycleStatus: .resolved
        ).insert(db)
        try LegacyDefaultsOutcomeRecord(
            sourceDomain: "domain",
            sourceKey: "key",
            fingerprint: "inbox",
            elementPath: "$",
            disposition: .archived,
            targetKind: "archive",
            targetIdentity: "target",
            targetFingerprint: "target"
        ).insert(db)
        try LegacyStateMigrationRecord(
            sourceDomain: "domain",
            sourceKey: "key",
            fingerprint: "ledger",
            status: .resolved,
            updatedAt: date
        ).insert(db)
        try BackupRestoreJournalRecord(
            operationId: "operation",
            status: .readyToPresent,
            reportPayload: Data([8]),
            updatedAt: date
        ).insert(db)
    }

    private func createLegacyLibraryTables(in db: Database) throws {
        try db.create(table: "libraryCategory") { table in
            table.primaryKey("id", .text)
            table.column("name", .text).notNull()
            table.column("sortOrder", .integer).notNull()
            table.column("isSystemCategory", .boolean).notNull()
            table.column("createdAt", .datetime).notNull()
        }
        try db.create(table: "libraryItem") { table in
            table.primaryKey("id", .text)
            table.column("title", .text).notNull()
            table.column("coverUrl", .text)
            table.column("pluginId", .text).notNull()
            table.column("isAnime", .boolean).notNull()
            table.column("pluginType", .text)
            table.column("rawPayload", .blob).notNull()
            table.column("anilistId", .integer)
        }
        try db.create(table: "itemCategoryLink") { table in
            table.column("itemId", .text).notNull()
            table.column("categoryId", .text).notNull()
            table.column("addedAt", .datetime).notNull()
        }
    }

    private func createMetadataTables(in db: Database) throws {
        try db.create(table: "backupMetadata") { table in
            table.column("id", .integer)
            table.column("formatVersion", .integer)
            table.column("createdAt", .datetime)
        }
        try db.create(table: "backupCapability") { table in
            table.column("component", .text)
            table.column("representation", .text)
        }
    }

    private func makeEmptyPaperbackArchive(at url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for path in ["__LIBRARY_MANGA_V4", "__SOURCE_MANGA_V4", "__MANGA_INFO_V4"] {
            let data = Data("{}".utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count)
            ) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
    }
}

private final class TemporaryBackupFixture {
    let url: URL

    private let directory: URL

    init(extension pathExtension: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupImporterTests-\(UUID().uuidString)")
        url = directory.appendingPathComponent("fixture.\(pathExtension)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func withDatabase(_ body: (Database) throws -> Void) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write(body)
        try queue.close()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
