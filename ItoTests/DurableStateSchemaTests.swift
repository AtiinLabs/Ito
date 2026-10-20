import Foundation
import GRDB
import Testing
@testable import Ito

struct DurableStateSchemaTests {
    private struct TableContract {
        let columns: [String]
        let primaryKey: [String]
        let nullable: Set<String>
    }

    @Test func v6SchemaSurfaceMatchesEveryRequiredContract() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let contracts: [String: TableContract] = [
            "appPreference": .init(columns: ["key", "value"], primaryKey: ["key"], nullable: []),
            "readProgressKey": .init(
                columns: ["pluginId", "canonicalMediaId", "chapterKey", "markedAt", "provenance"],
                primaryKey: ["pluginId", "canonicalMediaId", "chapterKey"],
                nullable: ["markedAt", "provenance"]
            ),
            "readProgressNumber": .init(
                columns: ["pluginId", "canonicalMediaId", "chapterNumber", "markedAt", "provenance"],
                primaryKey: ["pluginId", "canonicalMediaId", "chapterNumber"],
                nullable: ["markedAt", "provenance"]
            ),
            "mediaReadProgress": .init(
                columns: ["pluginId", "canonicalMediaId", "lastReadChapterKey", "updatedAt", "provenance", "lastReadPosition"],
                primaryKey: ["pluginId", "canonicalMediaId"],
                nullable: ["updatedAt", "provenance", "lastReadPosition"]
            ),
            "trackerLink": .init(
                columns: ["pluginId", "canonicalMediaId", "providerId", "remoteMediaId", "updatedAt", "provenance"],
                primaryKey: ["pluginId", "canonicalMediaId", "providerId"],
                nullable: ["updatedAt", "provenance"]
            ),
            "updateBadge": .init(
                columns: ["pluginId", "canonicalMediaId", "count", "updatedAt", "provenance"],
                primaryKey: ["pluginId", "canonicalMediaId"],
                nullable: ["updatedAt", "provenance"]
            ),
            "repository": .init(columns: ["url", "lastFetched", "indexPayload"], primaryKey: ["url"], nullable: ["lastFetched", "indexPayload"]),
            "pluginMigrationAlias": .init(columns: ["foreignId", "pluginId", "updatedAt"], primaryKey: ["foreignId"], nullable: []),
            "pluginSetting": .init(columns: ["pluginId", "key", "value", "updatedAt"], primaryKey: ["pluginId", "key"], nullable: ["updatedAt"]),
            "pluginSettingMigrationAuthority": .init(
                columns: ["pluginId", "key", "sourceDomain", "sourceKey", "sourceFingerprint"],
                primaryKey: ["pluginId", "key"],
                nullable: []
            ),
            "pluginIdentityRegistry": .init(columns: ["pluginId", "manifestId", "lastSeenAt"], primaryKey: ["pluginId"], nullable: ["manifestId"]),
            "pluginIdentityAlias": .init(
                columns: ["pluginId", "aliasKind", "aliasValue", "suiteDomain", "discoverySource", "lastSeenAt"],
                primaryKey: ["pluginId", "aliasKind", "aliasValue"],
                nullable: ["suiteDomain"]
            ),
            "legacyDefaultsInbox": .init(
                columns: ["sourceDomain", "sourceKey", "valueType", "canonicalPayload", "fingerprint", "expectedElementCount", "capturedAt", "lifecycleStatus"],
                primaryKey: ["sourceDomain", "sourceKey", "fingerprint"],
                nullable: []
            ),
            "legacyDefaultsOutcome": .init(
                columns: ["sourceDomain", "sourceKey", "fingerprint", "elementPath", "disposition", "targetKind", "targetIdentity", "targetFingerprint"],
                primaryKey: ["sourceDomain", "sourceKey", "fingerprint", "elementPath", "disposition", "targetKind", "targetIdentity"],
                nullable: []
            ),
            "legacyUnscopedMediaState": .init(
                columns: ["sourceKey", "legacyMediaId", "canonicalPayload", "candidates", "fingerprint"],
                primaryKey: ["sourceKey", "legacyMediaId", "fingerprint"],
                nullable: []
            ),
            "legacyStateMigration": .init(
                columns: ["sourceDomain", "sourceKey", "fingerprint", "status", "updatedAt"],
                primaryKey: ["sourceDomain", "sourceKey", "fingerprint"],
                nullable: []
            ),
            "legacyStateArchive": .init(
                columns: ["id", "sourceDomain", "sourceKey", "contentClass", "valueType", "valuePayload", "fingerprint", "reason", "createdAt"],
                primaryKey: ["id"],
                nullable: []
            ),
            "backupMetadata": .init(columns: ["id", "formatVersion", "createdAt"], primaryKey: ["id"], nullable: []),
            "backupCapability": .init(columns: ["component", "representation"], primaryKey: ["component"], nullable: []),
            "backupRestoreJournal": .init(columns: ["operationId", "status", "reportPayload", "updatedAt"], primaryKey: ["operationId"], nullable: [])
        ]
        let preexistingTables: Set<String> = [
            "libraryCategory", "libraryItem", "itemCategoryLink", "readingHistory", "themeCache",
            "sourceMapping"
        ]

        try database.dbPool.read { db in
            let actualTables = Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'"
            ))
            #expect(actualTables == Set(contracts.keys).union(preexistingTables))

            for (table, contract) in contracts {
                let columns = try db.columns(in: table)
                #expect(columns.map(\.name) == contract.columns)
                #expect(primaryKeyColumns(columns) == contract.primaryKey)
                #expect(
                    Set(columns.filter { !$0.isNotNull }.map(\.name)) == contract.nullable,
                    "Nullability mismatch for \(table)"
                )
            }

            let requiredIndexes: [(String, String, [String])] = [
                ("readProgressKey", "idx_readProgressKey_media", ["pluginId", "canonicalMediaId"]),
                ("readProgressNumber", "idx_readProgressNumber_media", ["pluginId", "canonicalMediaId"]),
                ("trackerLink", "idx_trackerLink_provider", ["providerId", "remoteMediaId"]),
                ("pluginIdentityAlias", "idx_pluginIdentityAlias_suiteDomain", ["suiteDomain"]),
                ("legacyDefaultsOutcome", "idx_legacyDefaultsOutcome_inbox", ["sourceDomain", "sourceKey", "fingerprint"])
            ]
            for (table, name, columns) in requiredIndexes {
                let index = try #require(db.indexes(on: table).first { $0.name == name })
                #expect(index.columns == columns)
            }

            let aliasForeignKey = try #require(db.foreignKeys(on: "pluginIdentityAlias").first)
            #expect(aliasForeignKey.destinationTable == "pluginIdentityRegistry")
            #expect(aliasForeignKey.originColumns == ["pluginId"])
            #expect(aliasForeignKey.destinationColumns == ["pluginId"])

            let outcomeForeignKey = try #require(db.foreignKeys(on: "legacyDefaultsOutcome").first)
            #expect(outcomeForeignKey.destinationTable == "legacyDefaultsInbox")
            #expect(outcomeForeignKey.originColumns == ["sourceDomain", "sourceKey", "fingerprint"])
            #expect(outcomeForeignKey.destinationColumns == ["sourceDomain", "sourceKey", "fingerprint"])

            let authorityForeignKeys = try db.foreignKeys(on: "pluginSettingMigrationAuthority")
            #expect(authorityForeignKeys.contains {
                $0.destinationTable == "pluginSetting"
                    && $0.originColumns == ["pluginId", "key"]
                    && $0.destinationColumns == ["pluginId", "key"]
            })
            #expect(authorityForeignKeys.contains {
                $0.destinationTable == "legacyDefaultsInbox"
                    && $0.originColumns == ["sourceDomain", "sourceKey", "sourceFingerprint"]
                    && $0.destinationColumns == ["sourceDomain", "sourceKey", "fingerprint"]
            })

            #expect(try foreignKeyDeleteAction(table: "pluginIdentityAlias", in: db) == "CASCADE")
            #expect(try foreignKeyDeleteAction(table: "legacyDefaultsOutcome", in: db) == "CASCADE")
            #expect(
                try foreignKeyDeleteActions(table: "pluginSettingMigrationAuthority", in: db)
                    == Array(repeating: "CASCADE", count: 5)
            )
        }
    }

    @Test func pluginSettingMigrationAuthorityIsClearedByRuntimeWritesAndDeletes() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        try database.dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pluginSetting (pluginId, key, value) VALUES ('plugin', 'key', X'41');
                    INSERT INTO legacyDefaultsInbox
                        (sourceDomain, sourceKey, valueType, canonicalPayload, fingerprint,
                         expectedElementCount, capturedAt, lifecycleStatus)
                    VALUES ('moe.ito.runners.plugin', 'key', 'string', X'41', 'capture', 1, 0, 'resolved');
                    INSERT INTO pluginSettingMigrationAuthority
                        (pluginId, key, sourceDomain, sourceKey, sourceFingerprint)
                    VALUES ('plugin', 'key', 'moe.ito.runners.plugin', 'key', 'capture')
                    """
            )
            try db.execute(
                sql: "UPDATE pluginSetting SET value = X'41' WHERE pluginId = 'plugin' AND key = 'key'"
            )
            #expect(try PluginSettingMigrationAuthorityRecord.fetchCount(db) == 0)

            try db.execute(
                sql: """
                    INSERT INTO pluginSettingMigrationAuthority
                        (pluginId, key, sourceDomain, sourceKey, sourceFingerprint)
                    VALUES ('plugin', 'key', 'moe.ito.runners.plugin', 'key', 'capture')
                    """
            )
            try db.execute(
                sql: "DELETE FROM pluginSetting WHERE pluginId = 'plugin' AND key = 'key'"
            )
            #expect(try PluginSettingMigrationAuthorityRecord.fetchCount(db) == 0)
        }
    }

    @Test func v6PreservesV5RowsCategoryLinksAndBackfillsCompatibilityState() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v5")

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let category = LibraryCategory(id: "category", name: "Saved", sortOrder: 0, createdAt: date)
        let item = makeLibraryItem(id: "plugin.media_42", pluginId: "plugin.media", anilistId: 1234)
        let categoryLink = ItemCategoryLink(itemId: item.id, categoryId: category.id, addedAt: date)
        let history = ReadingHistoryRecord(
            id: "history", libraryItemId: item.id, mediaKey: item.id, title: item.title,
            coverUrl: nil, pluginId: item.pluginId, chapterKey: "chapter-1", chapterTitle: nil,
            readAt: date
        )
        let theme = ThemeCacheRecord(mediaKey: item.id, dominantHex: "#111111", secondaryHex: "#222222")
        let preference = AppPreference(key: "preserved", value: Data([9]))
        let sourceMapping = SourceMappingRecord(
            canonicalProvider: "anilist",
            canonicalMediaId: "1234",
            mediaType: .manga,
            pluginId: "plugin.media",
            pluginMediaKey: "42",
            decision: .autoConfirm,
            matchMethod: .exactPreferred,
            confidence: 1,
            titleSnapshot: "Preserved",
            createdAt: date,
            updatedAt: date
        )

        try dbQueue.write { db in
            try category.insert(db)
            try item.insert(db)
            try categoryLink.insert(db)
            try history.insert(db)
            try theme.insert(db)
            try preference.insert(db)
            try sourceMapping.insert(db)
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            #expect(try LibraryCategory.fetchOne(db, key: category.id) == category)
            #expect(try LibraryItem.fetchOne(db, key: item.id) == item)
            #expect(try ItemCategoryLink.fetchOne(db) == categoryLink)
            #expect(try ReadingHistoryRecord.fetchOne(db, key: history.id) == history)
            #expect(try ThemeCacheRecord.fetchOne(db, key: theme.mediaKey) == theme)
            #expect(try AppPreference.fetchOne(db, key: preference.key) == preference)

            #expect(try SourceMappingRecord.fetchOne(db) == sourceMapping)

            let link = try #require(try TrackerLinkRecord.fetchOne(db))
            #expect(link.pluginId == "plugin.media")
            #expect(link.canonicalMediaId == "42")
            #expect(link.providerId == "anilist")
            #expect(link.remoteMediaId == "1234")
            #expect(link.provenance == .legacyUnknownTime)
        }
    }

    @Test func everyApplicationTableHasAnExplicitBackupPolicy() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let applicationTables = try database.dbPool.read { db in
            Set(
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT name
                        FROM sqlite_master
                        WHERE type = 'table'
                          AND name NOT LIKE 'sqlite_%'
                          AND name != 'grdb_migrations'
                        """
                )
            )
        }
        let backupTables = Set(
            BackupExportOperation.durableTablesByComponent.values.flatMap { $0 }
        )
        let excludedTables = Set(BackupExportOperation.excludedTableReasons.keys)

        #expect(backupTables.isDisjoint(with: excludedTables))
        #expect(
            BackupExportOperation.excludedTableReasons.values.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        )
        #expect(applicationTables == backupTables.union(excludedTables))
    }

    @Test func preexistingTrackerLinkWinsLegacyAniListBackfill() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        try database.dbPool.write { db in
            try makeLibraryItem(id: "plugin_42", pluginId: "plugin", anilistId: 1234).insert(db)
            try TrackerLinkRecord(
                pluginId: "plugin", canonicalMediaId: "42", providerId: "anilist",
                remoteMediaId: "already-authoritative", updatedAt: Date(), provenance: .runtime
            ).insert(db)

            try AppDatabase.backfillLegacyAniListLinks(in: db)

            let link = try #require(try TrackerLinkRecord.fetchOne(db))
            #expect(link.remoteMediaId == "already-authoritative")
            #expect(link.provenance == .runtime)
            #expect(try TrackerLinkRecord.fetchCount(db) == 1)
        }
    }

    @Test func repositoryPreferenceDeletesOnlyAfterExactSemanticReadback() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v4")

        let index = RepoIndex(
            repoName: "Example", repoUrl: "https://example.com", description: "Repository", packages: []
        )
        let repository = Repository(
            url: "https://example.com", lastFetched: Date(timeIntervalSince1970: 123), index: index
        )
        let encoded = try JSONEncoder().encode([repository])
        try dbQueue.write { db in
            try AppPreference(key: "ito_repositories", value: encoded).insert(db)
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let stored = try #require(try RepositoryRecord.fetchOne(db, key: repository.url))
            #expect(stored.url == repository.url)
            #expect(stored.lastFetched == repository.lastFetched)
            let indexPayload = try #require(stored.indexPayload)
            #expect(try JSONDecoder().decode(RepoIndex.self, from: indexPayload) == index)
            #expect(try AppPreference.fetchOne(db, key: "ito_repositories") == nil)
        }
    }

    @Test func schemaRepositoryCompatibilityDoesNotConsumeStandardDefaultsSource() throws {
        let suiteName = "DurableStateSchemaTests.repositories.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = Repository(url: "https://standard.example")
        let payload = try JSONEncoder().encode([repository])
        defaults.set(payload, forKey: "ito_repositories")

        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v4")
        try migrator.migrate(dbQueue)

        let persistent = defaults.persistentDomain(forName: suiteName)
        #expect(persistent?["ito_repositories"] as? Data == payload)
        try dbQueue.read { db in
            let count = try RepositoryRecord.fetchCount(db)
            #expect(count == 0)
        }
    }

    @Test func repositoryReadbackMismatchRollsBackAndRetainsSource() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let index = RepoIndex(
            repoName: "Example", repoUrl: "https://example.com", description: "Repository", packages: []
        )
        let repository = Repository(
            url: "https://example.com", lastFetched: Date(timeIntervalSince1970: 123), index: index
        )
        let source = AppPreference(key: "ito_repositories", value: try JSONEncoder().encode([repository]))

        try database.dbPool.write { db in
            try source.insert(db)
            try AppDatabase.migrateLegacyRepositories(in: db) { database in
                try database.execute(sql: "UPDATE repository SET lastFetched = 999, indexPayload = X'00'")
            }

            #expect(try RepositoryRecord.fetchCount(db) == 0)
            #expect(try AppPreference.fetchOne(db, key: source.key) == source)
        }
    }

    @Test func logicalKeysUpsertWithoutMetadataDuplicates() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        try database.dbPool.write { db in
            try ReadProgressKeyRecord(
                pluginId: "plugin", canonicalMediaId: "media", chapterKey: "chapter",
                markedAt: Date(timeIntervalSince1970: 1), provenance: .runtime
            ).save(db)
            try ReadProgressKeyRecord(
                pluginId: "plugin", canonicalMediaId: "media", chapterKey: "chapter",
                markedAt: Date(timeIntervalSince1970: 2), provenance: .legacyUnknownTime
            ).save(db)
            try TrackerLinkRecord(
                pluginId: "plugin", canonicalMediaId: "media", providerId: "anilist",
                remoteMediaId: "1", updatedAt: nil, provenance: .legacyUnknownTime
            ).save(db)
            try TrackerLinkRecord(
                pluginId: "plugin", canonicalMediaId: "media", providerId: "anilist",
                remoteMediaId: "2", updatedAt: Date(), provenance: .runtime
            ).save(db)
            try UpdateBadgeRecord(
                pluginId: "plugin", canonicalMediaId: "media", count: 1,
                updatedAt: nil, provenance: .legacyUnknownTime
            ).save(db)
            try UpdateBadgeRecord(
                pluginId: "plugin", canonicalMediaId: "media", count: 4,
                updatedAt: Date(), provenance: .runtime
            ).save(db)

            #expect(try ReadProgressKeyRecord.fetchCount(db) == 1)
            #expect(try TrackerLinkRecord.fetchCount(db) == 1)
            #expect(try TrackerLinkRecord.fetchOne(db)?.remoteMediaId == "2")
            #expect(try UpdateBadgeRecord.fetchCount(db) == 1)
            #expect(try UpdateBadgeRecord.fetchOne(db)?.count == 4)
        }
    }

    @Test func everyAllowedAndInvalidSchemaValueIsEnforced() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        try database.dbPool.write { db in
            for provenance in DurableStateProvenance.allCases {
                try db.execute(
                    sql: "INSERT INTO readProgressKey (pluginId, canonicalMediaId, chapterKey, provenance) VALUES (?, ?, ?, ?)",
                    arguments: ["p", "m", provenance.rawValue, provenance.rawValue]
                )
            }
            try db.execute(sql: "INSERT INTO readProgressKey (pluginId, canonicalMediaId, chapterKey, provenance) VALUES ('p', 'm', 'null', NULL)")
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO readProgressKey (pluginId, canonicalMediaId, chapterKey, provenance) VALUES ('p', 'm', 'bad', 'imported')")
            }

            for lifecycle in LegacyInboxLifecycleStatus.allCases {
                try insertInbox(status: lifecycle.rawValue, fingerprint: lifecycle.rawValue, in: db)
            }
            #expect(throws: DatabaseError.self) {
                try insertInbox(status: "archived", fingerprint: "invalid", in: db)
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO legacyDefaultsInbox (sourceDomain, sourceKey, valueType, canonicalPayload, fingerprint, expectedElementCount, capturedAt, lifecycleStatus) VALUES ('d', 'negative', 'data', X'00', 'negative', -1, 0, 'captured')")
            }

            try insertInbox(status: "captured", fingerprint: "outcomes", in: db)
            for disposition in LegacyDefaultsDisposition.allCases {
                try db.execute(
                    sql: "INSERT INTO legacyDefaultsOutcome (sourceDomain, sourceKey, fingerprint, elementPath, disposition, targetKind, targetIdentity, targetFingerprint) VALUES ('domain', 'key', 'outcomes', ?, ?, 'kind', ?, 'target')",
                    arguments: [disposition.rawValue, disposition.rawValue, disposition.rawValue]
                )
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO legacyDefaultsOutcome (sourceDomain, sourceKey, fingerprint, elementPath, disposition, targetKind, targetIdentity, targetFingerprint) VALUES ('domain', 'key', 'outcomes', 'bad', 'discarded', 'kind', 'bad', 'target')")
            }

            for status in LegacyMigrationStatus.allCases {
                try db.execute(
                    sql: "INSERT INTO legacyStateMigration (sourceDomain, sourceKey, fingerprint, status, updatedAt) VALUES ('domain', 'key', ?, ?, 0)",
                    arguments: [status.rawValue, status.rawValue]
                )
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO legacyStateMigration (sourceDomain, sourceKey, fingerprint, status, updatedAt) VALUES ('domain', 'key', 'bad', 'failed', 0)")
            }

            for contentClass in LegacyArchiveContentClass.allCases {
                try insertArchive(contentClass: contentClass.rawValue, fingerprint: contentClass.rawValue, in: db)
            }
            #expect(throws: DatabaseError.self) {
                try insertArchive(contentClass: "credential", fingerprint: "bad", in: db)
            }

            for component in BackupComponent.allCases {
                try db.execute(
                    sql: "INSERT INTO backupCapability (component, representation) VALUES (?, 'representedEmpty')",
                    arguments: [component.rawValue]
                )
            }
            try db.execute(sql: "UPDATE backupCapability SET representation = 'representedNonempty' WHERE component = 'libraryCore'")
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO backupCapability (component, representation) VALUES ('futureComponent', 'representedEmpty')")
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "UPDATE backupCapability SET representation = 'unrepresented' WHERE component = 'libraryCore'")
            }

            for status in RestoreOperationStatus.allCases {
                try db.execute(
                    sql: "INSERT INTO backupRestoreJournal (operationId, status, reportPayload, updatedAt) VALUES (?, ?, X'00', 0)",
                    arguments: [status.rawValue, status.rawValue]
                )
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO backupRestoreJournal (operationId, status, reportPayload, updatedAt) VALUES ('bad', 'done', X'00', 0)")
            }

            try db.execute(sql: "INSERT INTO backupMetadata (id, formatVersion, createdAt) VALUES (1, 1, 0)")
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO backupMetadata (id, formatVersion, createdAt) VALUES (2, 1, 0)")
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "UPDATE backupMetadata SET formatVersion = 0 WHERE id = 1")
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO updateBadge (pluginId, canonicalMediaId, count) VALUES ('p', 'm', -1)")
            }
        }
    }

    @Test func foreignKeysCascadeAndArchiveLogicalIdentityIsUnique() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        try database.dbPool.write { db in
            try PluginIdentityRecord(pluginId: "plugin", manifestId: nil, lastSeenAt: Date()).insert(db)
            try PluginIdentityAliasRecord(
                pluginId: "plugin", aliasKind: "suite", aliasValue: "suite.plugin",
                suiteDomain: "moe.ito.runners.plugin", discoverySource: "manifest", lastSeenAt: Date()
            ).insert(db)
            try db.execute(sql: "DELETE FROM pluginIdentityRegistry WHERE pluginId = 'plugin'")
            #expect(try PluginIdentityAliasRecord.fetchCount(db) == 0)

            try insertInbox(status: "captured", fingerprint: "cascade", in: db)
            try db.execute(sql: "INSERT INTO legacyDefaultsOutcome (sourceDomain, sourceKey, fingerprint, elementPath, disposition, targetKind, targetIdentity, targetFingerprint) VALUES ('domain', 'key', 'cascade', '0', 'normalized', 'kind', 'identity', 'target')")
            try db.execute(sql: "DELETE FROM legacyDefaultsInbox WHERE fingerprint = 'cascade'")
            #expect(try LegacyDefaultsOutcomeRecord.fetchCount(db) == 0)
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO legacyDefaultsOutcome (sourceDomain, sourceKey, fingerprint, elementPath, disposition, targetKind, targetIdentity, targetFingerprint) VALUES ('missing', 'key', 'fingerprint', '0', 'normalized', 'kind', 'identity', 'target')")
            }

            try insertArchive(contentClass: "appNonSecret", fingerprint: "same", in: db)
            #expect(throws: DatabaseError.self) {
                try insertArchive(contentClass: "appNonSecret", fingerprint: "same", in: db)
            }
        }
    }

    @Test func legacyStateArchiveTypedRecordRoundTripsGeneratedIntegerID() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let record = LegacyStateArchiveRecord(
            id: nil,
            sourceDomain: "moe.itoapp.ito",
            sourceKey: "selectedTheme",
            contentClass: .appNonSecret,
            valueType: "string",
            valuePayload: Data("\"Dark\"".utf8),
            fingerprint: "archive-fingerprint",
            reason: "preserved for restore",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try database.dbPool.write { db in
            try record.insert(db)

            let fetched = try #require(try LegacyStateArchiveRecord.fetchOne(db))
            #expect(fetched.id != nil)
            #expect(fetched.id == 1)
            #expect(fetched.sourceDomain == record.sourceDomain)
            #expect(fetched.sourceKey == record.sourceKey)
            #expect(fetched.contentClass == record.contentClass)
            #expect(fetched.valueType == record.valueType)
            #expect(fetched.valuePayload == record.valuePayload)
            #expect(fetched.fingerprint == record.fingerprint)
            #expect(fetched.reason == record.reason)
            #expect(fetched.createdAt == record.createdAt)
        }
    }

    @Test func suiteAliasesAreGloballyUniqueAndMigrationStateIsMonotonic() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        try database.dbPool.write { db in
            try PluginIdentityRecord(pluginId: "one", manifestId: nil, lastSeenAt: Date()).insert(db)
            try PluginIdentityRecord(pluginId: "two", manifestId: nil, lastSeenAt: Date()).insert(db)
            try PluginIdentityAliasRecord(
                pluginId: "one", aliasKind: "suite", aliasValue: "suite.one",
                suiteDomain: "moe.ito.runners.shared", discoverySource: "manifest", lastSeenAt: Date()
            ).insert(db)
            #expect(throws: DatabaseError.self) {
                try PluginIdentityAliasRecord(
                    pluginId: "two", aliasKind: "suite", aliasValue: "suite.two",
                    suiteDomain: "moe.ito.runners.shared", discoverySource: "filename", lastSeenAt: Date()
                ).insert(db)
            }

            try insertInbox(status: "captured", fingerprint: "immutable", in: db)
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "UPDATE legacyDefaultsInbox SET canonicalPayload = X'02' WHERE fingerprint = 'immutable'")
            }

            try LegacyStateMigrationRecord(
                sourceDomain: "domain", sourceKey: "key", fingerprint: "monotonic",
                status: .cleanupVerified, updatedAt: Date()
            ).insert(db)
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "UPDATE legacyStateMigration SET status = 'captured' WHERE fingerprint = 'monotonic'")
            }
            try db.execute(sql: "UPDATE legacyStateMigration SET status = 'resolved' WHERE fingerprint = 'monotonic'")
        }
    }

    private func primaryKeyColumns(_ columns: [ColumnInfo]) -> [String] {
        columns.compactMap { column in
            column.primaryKeyIndex > 0 ? (column.primaryKeyIndex, column.name) : nil
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    private func foreignKeyDeleteAction(table: String, in db: Database) throws -> String? {
        let row = try Row.fetchOne(db, sql: "PRAGMA foreign_key_list(\(table))")
        return row?["on_delete"]
    }

    private func foreignKeyDeleteActions(table: String, in db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
            .compactMap { $0["on_delete"] as String? }
            .sorted()
    }

    private func insertInbox(status: String, fingerprint: String, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO legacyDefaultsInbox (sourceDomain, sourceKey, valueType, canonicalPayload, fingerprint, expectedElementCount, capturedAt, lifecycleStatus) VALUES ('domain', 'key', 'data', X'00', ?, 1, 0, ?)",
            arguments: [fingerprint, status]
        )
    }

    private func insertArchive(contentClass: String, fingerprint: String, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO legacyStateArchive (sourceDomain, sourceKey, contentClass, valueType, valuePayload, fingerprint, reason, createdAt) VALUES ('domain', 'key', ?, 'data', X'00', ?, 'reason', 0)",
            arguments: [contentClass, fingerprint]
        )
    }

    private func makeLibraryItem(id: String, pluginId: String, anilistId: Int?) -> LibraryItem {
        LibraryItem(
            id: id, title: "Title", coverUrl: nil, pluginId: pluginId, isAnime: false,
            pluginType: nil, rawPayload: Data([1, 2, 3]), anilistId: anilistId
        )
    }
}

struct AppPreferenceCatalogTests {
    private struct Fixture {
        let entry: AppPreferenceCatalogEntry
        let source: LegacyPreferenceSourceType
        let defaultJSON: String
        let accepted: [Any]
        let invalid: [Any]
    }

    @Test func allTwentyCatalogEntriesHaveExactDefaultsBridgesAndValidation() throws {
        let fixtures = catalogFixtures
        #expect(fixtures.count == 20)
        #expect(Set(fixtures.map(\.entry)) == Set(AppPreferenceCatalogEntry.allCases))

        for fixture in fixtures {
            #expect(fixture.entry.rawValue == keyName(for: fixture.entry))
            #expect(fixture.entry.acceptedSource == fixture.source)
            #expect(fixture.entry.canonicalDefaultJSON == Data(fixture.defaultJSON.utf8))
            #expect(fixture.entry.materializesDefaultWhenAbsent)
            for value in fixture.accepted {
                #expect(fixture.entry.acceptsLegacyValue(value))
            }
            for value in fixture.invalid {
                #expect(!fixture.entry.acceptsLegacyValue(value))
            }
            try assertTypedDefaultRoundTrip(fixture.entry)
        }
    }

    @Test func integerBridgesRejectUnrepresentableNonfiniteFractionalAndBooleanNumbers() {
        let adversarial: [NSNumber] = [
            NSNumber(value: Double.greatestFiniteMagnitude),
            NSNumber(value: Double(Int.min) * 2),
            NSNumber(value: Double.infinity),
            NSNumber(value: -Double.infinity),
            NSNumber(value: Double.nan),
            NSNumber(value: 4.5),
            NSNumber(value: true)
        ]

        for entry in [
            AppPreferenceCatalogEntry.libraryLayoutStyle,
            .updateInterval,
            .preloadImageCount
        ] {
            for value in adversarial {
                #expect(!entry.acceptsLegacyValue(value))
            }
        }
    }

    @Test func finitePositiveNovelFontSizeHasNoUpperBound() throws {
        #expect(AppPreferenceCatalog.novelFontSize.isValid(72.1))
        #expect(AppPreferenceCatalog.novelFontSize.isValid(Double.greatestFiniteMagnitude))
        #expect(AppPreferenceCatalogEntry.novelFontSize.acceptsLegacyValue(NSNumber(value: 144.5)))
        #expect(!AppPreferenceCatalog.novelFontSize.isValid(0))
        #expect(!AppPreferenceCatalog.novelFontSize.isValid(-1))
        #expect(!AppPreferenceCatalog.novelFontSize.isValid(.infinity))

        let preference = try AppPreference(key: AppPreferenceCatalog.novelFontSize, value: 144.5)
        #expect(try preference.decodedValue(for: AppPreferenceCatalog.novelFontSize) == 144.5)
    }

    @Test func canonicalKeyNamespaceAndRawPreferenceInitializerRemainSourceCompatible() throws {
        let raw = AppPreference(key: "non-catalog-key", value: Data([1, 2, 3]))
        #expect(raw.key == "non-catalog-key")
        #expect(raw.value == Data([1, 2, 3]))
    }

    @Test func credentialExclusionIsExactSourceTuple() {
        let standardDomain = "moe.itoapp.ito"
        #expect(LegacyDefaultsSourceTuple(
            sourceDomain: standardDomain,
            sourceKey: "anilist_access_token"
        ).classification(standardApplicationDomain: standardDomain) == .appManagedCredential)
        #expect(LegacyDefaultsSourceTuple(
            sourceDomain: standardDomain,
            sourceKey: "selectedTheme"
        ).classification(standardApplicationDomain: standardDomain) == .appNonSecret)
        #expect(LegacyDefaultsSourceTuple(
            sourceDomain: "moe.ito.runners.plugin",
            sourceKey: "anilist_access_token"
        ).classification(standardApplicationDomain: standardDomain) == .opaquePluginState)
    }

    private var catalogFixtures: [Fixture] {
        let boolInvalid: [Any] = [NSNumber(value: 0), NSNumber(value: 1), "true"]
        let numericInvalid: [Any] = [NSNumber(value: true), NSNumber(value: Double.nan), "1"]
        return [
            .init(entry: .libraryLayoutStyle, source: .integerNSNumber, defaultJSON: "1", accepted: [NSNumber(value: 0), NSNumber(value: 1)], invalid: [NSNumber(value: -1), NSNumber(value: 2), NSNumber(value: 0.5), NSNumber(value: true)]),
            .init(entry: .alwaysShowCategoryPicker, source: .booleanNSNumber, defaultJSON: "false", accepted: [NSNumber(value: false), NSNumber(value: true)], invalid: boolInvalid),
            .init(entry: .backgroundUpdatesEnabled, source: .booleanNSNumber, defaultJSON: "false", accepted: [NSNumber(value: false), NSNumber(value: true)], invalid: boolInvalid),
            .init(entry: .updateInterval, source: .integerNSNumber, defaultJSON: "4", accepted: [1, 2, 4, 6, 12, 24].map(NSNumber.init(value:)), invalid: [NSNumber(value: 0), NSNumber(value: 3), NSNumber(value: 24.5), NSNumber(value: true)]),
            .init(entry: .skipCompleted, source: .booleanNSNumber, defaultJSON: "false", accepted: [NSNumber(value: false), NSNumber(value: true)], invalid: boolInvalid),
            .init(entry: .updateNotifications, source: .booleanNSNumber, defaultJSON: "true", accepted: [NSNumber(value: false), NSNumber(value: true)], invalid: boolInvalid),
            .init(entry: .wifiOnlyUpdates, source: .booleanNSNumber, defaultJSON: "false", accepted: [NSNumber(value: false), NSNumber(value: true)], invalid: boolInvalid),
            .init(entry: .discordRPCEnabled, source: .booleanNSNumber, defaultJSON: "false", accepted: [NSNumber(value: false), NSNumber(value: true)], invalid: boolInvalid),
            .init(entry: .discordRPCURL, source: .string, defaultJSON: "\"ws://127.0.0.1:3000\"", accepted: ["ws://127.0.0.1:3000", "wss://example.com/socket"], invalid: ["", "https://example.com", NSNumber(value: 1)]),
            .init(entry: .appTheme, source: .string, defaultJSON: "\"System\"", accepted: AppThemePreference.allCases.map(\.rawValue), invalid: ["system", "Blue", NSNumber(value: 1)]),
            .init(entry: .novelFontSize, source: .numericNSNumber, defaultJSON: "18", accepted: [NSNumber(value: Double.leastNonzeroMagnitude), NSNumber(value: 72.1), NSNumber(value: Double.greatestFiniteMagnitude)], invalid: numericInvalid + [NSNumber(value: 0), NSNumber(value: -1), NSNumber(value: Double.infinity)]),
            .init(entry: .novelLineSpacing, source: .numericNSNumber, defaultJSON: "8", accepted: [NSNumber(value: 0), NSNumber(value: 40), NSNumber(value: 12.5)], invalid: numericInvalid + [NSNumber(value: -0.1), NSNumber(value: 40.1)]),
            .init(entry: .novelFontFamily, source: .string, defaultJSON: "\"System\"", accepted: NovelFontPreference.allCases.map(\.rawValue), invalid: ["Unknown", "system", NSNumber(value: 1)]),
            .init(entry: .novelTheme, source: .string, defaultJSON: "\"System\"", accepted: NovelThemePreference.allCases.map(\.rawValue), invalid: ["Unknown", "system", NSNumber(value: 1)]),
            .init(entry: .novelIsPaging, source: .booleanNSNumber, defaultJSON: "false", accepted: [NSNumber(value: false), NSNumber(value: true)], invalid: boolInvalid),
            .init(entry: .novelPrefetchChapters, source: .booleanNSNumber, defaultJSON: "true", accepted: [NSNumber(value: false), NSNumber(value: true)], invalid: boolInvalid),
            .init(entry: .preloadImageCount, source: .integerNSNumber, defaultJSON: "5", accepted: [0, 3, 5, 10, 15, 20].map(NSNumber.init(value:)), invalid: [NSNumber(value: -1), NSNumber(value: 1), NSNumber(value: 20.5), NSNumber(value: true)]),
            .init(entry: .incognitoMode, source: .booleanNSNumber, defaultJSON: "false", accepted: [NSNumber(value: false), NSNumber(value: true)], invalid: boolInvalid),
            .init(entry: .autoSyncTrackersToLocal, source: .booleanNSNumber, defaultJSON: "true", accepted: [NSNumber(value: false), NSNumber(value: true)], invalid: boolInvalid),
            .init(entry: .diskCacheLimitGB, source: .numericNSNumber, defaultJSON: "10", accepted: [NSNumber(value: 1), NSNumber(value: 50)], invalid: numericInvalid + [NSNumber(value: 0), NSNumber(value: 2.5), NSNumber(value: 51)])
        ]
    }

    private func keyName(for entry: AppPreferenceCatalogEntry) -> String {
        switch entry {
        case .libraryLayoutStyle: AppPreferenceKeys.libraryLayoutStyle
        case .alwaysShowCategoryPicker: AppPreferenceKeys.alwaysShowCategoryPicker
        case .backgroundUpdatesEnabled: AppPreferenceKeys.backgroundUpdatesEnabled
        case .updateInterval: AppPreferenceKeys.updateInterval
        case .skipCompleted: AppPreferenceKeys.skipCompleted
        case .updateNotifications: AppPreferenceKeys.updateNotifications
        case .wifiOnlyUpdates: AppPreferenceKeys.wifiOnlyUpdates
        case .discordRPCEnabled: AppPreferenceKeys.discordRPCEnabled
        case .discordRPCURL: AppPreferenceKeys.discordRPCURL
        case .appTheme: AppPreferenceKeys.appTheme
        case .novelFontSize: AppPreferenceKeys.novelFontSize
        case .novelLineSpacing: AppPreferenceKeys.novelLineSpacing
        case .novelFontFamily: AppPreferenceKeys.novelFontFamily
        case .novelTheme: AppPreferenceKeys.novelTheme
        case .novelIsPaging: AppPreferenceKeys.novelIsPaging
        case .novelPrefetchChapters: AppPreferenceKeys.novelPrefetchChapters
        case .preloadImageCount: AppPreferenceKeys.preloadImageCount
        case .incognitoMode: AppPreferenceKeys.incognitoMode
        case .autoSyncTrackersToLocal: AppPreferenceKeys.autoSyncTrackersToLocal
        case .diskCacheLimitGB: AppPreferenceKeys.diskCacheLimitGB
        }
    }

    private func assertTypedDefaultRoundTrip(_ entry: AppPreferenceCatalogEntry) throws {
        switch entry {
        case .libraryLayoutStyle: try assertRoundTrip(AppPreferenceCatalog.libraryLayoutStyle)
        case .alwaysShowCategoryPicker: try assertRoundTrip(AppPreferenceCatalog.alwaysShowCategoryPicker)
        case .backgroundUpdatesEnabled: try assertRoundTrip(AppPreferenceCatalog.backgroundUpdatesEnabled)
        case .updateInterval: try assertRoundTrip(AppPreferenceCatalog.updateInterval)
        case .skipCompleted: try assertRoundTrip(AppPreferenceCatalog.skipCompleted)
        case .updateNotifications: try assertRoundTrip(AppPreferenceCatalog.updateNotifications)
        case .wifiOnlyUpdates: try assertRoundTrip(AppPreferenceCatalog.wifiOnlyUpdates)
        case .discordRPCEnabled: try assertRoundTrip(AppPreferenceCatalog.discordRPCEnabled)
        case .discordRPCURL: try assertRoundTrip(AppPreferenceCatalog.discordRPCURL)
        case .appTheme: try assertRoundTrip(AppPreferenceCatalog.appTheme)
        case .novelFontSize: try assertRoundTrip(AppPreferenceCatalog.novelFontSize)
        case .novelLineSpacing: try assertRoundTrip(AppPreferenceCatalog.novelLineSpacing)
        case .novelFontFamily: try assertRoundTrip(AppPreferenceCatalog.novelFontFamily)
        case .novelTheme: try assertRoundTrip(AppPreferenceCatalog.novelTheme)
        case .novelIsPaging: try assertRoundTrip(AppPreferenceCatalog.novelIsPaging)
        case .novelPrefetchChapters: try assertRoundTrip(AppPreferenceCatalog.novelPrefetchChapters)
        case .preloadImageCount: try assertRoundTrip(AppPreferenceCatalog.preloadImageCount)
        case .incognitoMode: try assertRoundTrip(AppPreferenceCatalog.incognitoMode)
        case .autoSyncTrackersToLocal: try assertRoundTrip(AppPreferenceCatalog.autoSyncTrackersToLocal)
        case .diskCacheLimitGB: try assertRoundTrip(AppPreferenceCatalog.diskCacheLimitGB)
        }
    }

    private func assertRoundTrip<Value: Codable & Equatable & Sendable>(_ key: AppPreferenceKey<Value>) throws {
        let preference = try AppPreference(key: key, value: key.defaultValue)
        let encodedDefault = try JSONEncoder().encode(key.defaultValue)
        #expect(preference.key == key.name)
        #expect(preference.value == encodedDefault)
        #expect(try preference.decodedValue(for: key) == key.defaultValue)
    }
}
