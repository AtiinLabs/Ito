import OSLog
import Foundation
import GRDB
import Combine
import ito_runner

/// A singleton that manages the SQLite database pool and migrations.
public final class AppDatabase: Sendable {
    public static let shared: AppDatabase = {
        do {
            return try AppDatabase()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }()

    public let dbPool: DatabasePool
    public let databaseURL: URL

    #if DEBUG
    /// Launch argument that logs every SQL statement (DEBUG builds only).
    nonisolated static let traceSQLArgument = "--trace-sql"
    #endif

    private init() throws {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #if DEBUG
        let launchConfiguration = UITestLaunchConfiguration.current
        let directoryURL: URL
        if launchConfiguration.isEnabled {
            let fixtureRootURL = try UITestLaunchConfiguration.fixtureRootURL(
                fileManager: fileManager
            )
            if launchConfiguration.resetsStorage,
               fileManager.fileExists(atPath: fixtureRootURL.path) {
                try fileManager.removeItem(at: fixtureRootURL)
            }
            directoryURL = fixtureRootURL.appendingPathComponent(
                UITestLaunchConfiguration.fixtureDatabaseDirectoryName,
                isDirectory: true
            )
        } else {
            directoryURL = appSupportURL.appendingPathComponent(
                UITestLaunchConfiguration.productionDatabaseDirectoryName,
                isDirectory: true
            )
        }
        #else
        let directoryURL = appSupportURL.appendingPathComponent("Database", isDirectory: true)
        #endif

        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let databaseURL = directoryURL.appendingPathComponent("ItoLibrary.sqlite")
        self.databaseURL = databaseURL

        var configuration = Configuration()
        #if DEBUG
        // Tracing every statement floods the log; launch with --trace-sql to enable it.
        if ProcessInfo.processInfo.arguments.contains(Self.traceSQLArgument) {
            configuration.prepareDatabase { db in
                db.trace { AppLogger.database.debug("\($0)") }
            }
        }
        #endif

        dbPool = try DatabasePool(path: databaseURL.path, configuration: configuration)

        try Self.makeMigrator().migrate(dbPool)
    }

    nonisolated static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "libraryCategory") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull()
                t.column("isSystemCategory", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }

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

            try db.create(table: "itemCategoryLink") { t in
                t.column("itemId", .text).notNull().references("libraryItem", onDelete: .cascade)
                t.column("categoryId", .text).notNull().references("libraryCategory", onDelete: .cascade)
                t.column("addedAt", .datetime).notNull()
                t.primaryKey(["itemId", "categoryId"])
            }

            try db.create(index: "idx_link_categoryId", on: "itemCategoryLink", columns: ["categoryId"])
        }

        // MARK: - v2: Smart Updates + Reading History
        migrator.registerMigration("v2") { db in
            // Add update tracking columns to libraryItem
            try db.alter(table: "libraryItem") { t in
                t.add(column: "status", .text)
                t.add(column: "lastCheckedAt", .datetime)
                t.add(column: "lastUpdatedAt", .datetime)
                t.add(column: "knownChapterCount", .integer)
            }

            // Create reading history table (no FK — history works for unsaved series)
            try db.create(table: "readingHistory") { t in
                t.primaryKey("id", .text)
                t.column("libraryItemId", .text) // nullable, no FK
                t.column("mediaKey", .text).notNull()
                t.column("title", .text).notNull()
                t.column("coverUrl", .text)
                t.column("pluginId", .text).notNull()
                t.column("chapterKey", .text).notNull()
                t.column("chapterTitle", .text)
                t.column("readAt", .datetime).notNull()
            }

            try db.create(index: "idx_history_mediaKey_readAt", on: "readingHistory", columns: ["mediaKey", "readAt"])
        }

        // MARK: - v3: Theme Cache
        migrator.registerMigration("v3") { db in
            try db.create(table: "themeCache") { t in
                t.primaryKey("mediaKey", .text)
                t.column("dominantHex", .text).notNull()
                t.column("secondaryHex", .text).notNull()
            }
        }

        // MARK: - v4: App Preferences Key-Value Store
        migrator.registerMigration("v4") { db in
            try db.create(table: "appPreference") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob).notNull()
            }
        }

        // MARK: - v5: Source Mapping
        migrator.registerMigration("v5") { db in
            try db.create(table: "sourceMapping") { t in
                t.column("canonicalProvider", .text).notNull()
                t.column("canonicalMediaId", .text).notNull()
                t.column("mediaType", .text).notNull()
                t.column("pluginId", .text).notNull()
                t.column("pluginMediaKey", .text).notNull()

                t.column("decision", .text).notNull()
                t.column("matchMethod", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("titleSnapshot", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()

                t.column("coverURLSnapshot", .text)
                t.column("encodedPayload", .blob)
                t.column("payloadVersion", .integer)
                t.column("pluginVersion", .text)
                t.column("lastVerifiedAt", .datetime)

                t.primaryKey(["canonicalProvider", "canonicalMediaId", "mediaType", "pluginId", "pluginMediaKey"])

                t.check(sql: "mediaType IN ('manga', 'anime')")
            }

            try db.create(index: "idx_sourceMapping_canonical", on: "sourceMapping", columns: ["canonicalProvider", "canonicalMediaId", "mediaType", "decision"])
            try db.create(index: "idx_sourceMapping_plugin", on: "sourceMapping", columns: ["pluginId", "pluginMediaKey"])
        }

        // MARK: - v6: Durable State Contracts
        migrator.registerMigration("v6") { db in
            try db.create(table: "readProgressKey") { t in
                t.column("pluginId", .text).notNull()
                t.column("canonicalMediaId", .text).notNull()
                t.column("chapterKey", .text).notNull()
                t.column("markedAt", .datetime)
                t.column("provenance", .text)
                t.primaryKey(["pluginId", "canonicalMediaId", "chapterKey"])
                t.check(sql: "provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')")
            }

            try db.create(table: "readProgressNumber") { t in
                t.column("pluginId", .text).notNull()
                t.column("canonicalMediaId", .text).notNull()
                t.column("chapterNumber", .double).notNull()
                t.column("markedAt", .datetime)
                t.column("provenance", .text)
                t.primaryKey(["pluginId", "canonicalMediaId", "chapterNumber"])
                t.check(sql: "provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')")
            }

            try db.create(table: "mediaReadProgress") { t in
                t.column("pluginId", .text).notNull()
                t.column("canonicalMediaId", .text).notNull()
                t.column("lastReadChapterKey", .text).notNull()
                t.column("updatedAt", .datetime)
                t.column("provenance", .text)
                t.primaryKey(["pluginId", "canonicalMediaId"])
                t.check(sql: "provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')")
            }

            try db.create(table: "trackerLink") { t in
                t.column("pluginId", .text).notNull()
                t.column("canonicalMediaId", .text).notNull()
                t.column("providerId", .text).notNull()
                t.column("remoteMediaId", .text).notNull()
                t.column("updatedAt", .datetime)
                t.column("provenance", .text)
                t.primaryKey(["pluginId", "canonicalMediaId", "providerId"])
                t.check(sql: "provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')")
            }

            try db.create(table: "updateBadge") { t in
                t.column("pluginId", .text).notNull()
                t.column("canonicalMediaId", .text).notNull()
                t.column("count", .integer).notNull().check { $0 >= 0 }
                t.column("updatedAt", .datetime)
                t.column("provenance", .text)
                t.primaryKey(["pluginId", "canonicalMediaId"])
                t.check(sql: "provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')")
            }

            try db.create(table: "repository") { t in
                t.primaryKey("url", .text)
                t.column("lastFetched", .datetime)
                t.column("indexPayload", .blob)
            }

            try db.create(table: "pluginMigrationAlias") { t in
                t.primaryKey("foreignId", .text)
                t.column("pluginId", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "pluginSetting") { t in
                t.column("pluginId", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .blob).notNull()
                t.column("updatedAt", .datetime)
                t.primaryKey(["pluginId", "key"])
            }

            try db.create(table: "pluginIdentityRegistry") { t in
                t.primaryKey("pluginId", .text)
                t.column("manifestId", .text)
                t.column("lastSeenAt", .datetime).notNull()
            }

            try db.create(table: "pluginIdentityAlias") { t in
                t.column("pluginId", .text).notNull()
                    .references("pluginIdentityRegistry", onDelete: .cascade)
                t.column("aliasKind", .text).notNull()
                t.column("aliasValue", .text).notNull()
                t.column("suiteDomain", .text)
                t.column("discoverySource", .text).notNull()
                t.column("lastSeenAt", .datetime).notNull()
                t.primaryKey(["pluginId", "aliasKind", "aliasValue"])
                t.uniqueKey(["suiteDomain"])
            }

            try db.create(table: "legacyDefaultsInbox") { t in
                t.column("sourceDomain", .text).notNull()
                t.column("sourceKey", .text).notNull()
                t.column("valueType", .text).notNull()
                t.column("canonicalPayload", .blob).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("expectedElementCount", .integer).notNull().check { $0 >= 0 }
                t.column("capturedAt", .datetime).notNull()
                t.column("lifecycleStatus", .text).notNull()
                t.primaryKey(["sourceDomain", "sourceKey", "fingerprint"])
                t.check(sql: "lifecycleStatus IN ('captured', 'resolved')")
            }

            try db.execute(sql: """
                CREATE TRIGGER legacyDefaultsInbox_immutablePayload
                BEFORE UPDATE OF sourceDomain, sourceKey, valueType, canonicalPayload, fingerprint, expectedElementCount
                ON legacyDefaultsInbox
                BEGIN
                    SELECT RAISE(ABORT, 'legacyDefaultsInbox canonical capture is immutable');
                END
                """)

            try db.create(table: "legacyDefaultsOutcome") { t in
                t.column("sourceDomain", .text).notNull()
                t.column("sourceKey", .text).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("elementPath", .text).notNull()
                t.column("disposition", .text).notNull()
                t.column("targetKind", .text).notNull()
                t.column("targetIdentity", .text).notNull()
                t.column("targetFingerprint", .text).notNull()
                t.primaryKey([
                    "sourceDomain", "sourceKey", "fingerprint", "elementPath",
                    "disposition", "targetKind", "targetIdentity"
                ])
                t.foreignKey(
                    ["sourceDomain", "sourceKey", "fingerprint"],
                    references: "legacyDefaultsInbox",
                    onDelete: .cascade
                )
                t.check(sql: "disposition IN ('normalized', 'archived', 'unscoped')")
            }

            try db.create(table: "legacyUnscopedMediaState") { t in
                t.column("sourceKey", .text).notNull()
                t.column("legacyMediaId", .text).notNull()
                t.column("canonicalPayload", .blob).notNull()
                t.column("candidates", .blob).notNull()
                t.column("fingerprint", .text).notNull()
                t.primaryKey(["sourceKey", "legacyMediaId", "fingerprint"])
            }

            try db.create(table: "legacyStateMigration") { t in
                t.column("sourceDomain", .text).notNull()
                t.column("sourceKey", .text).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("status", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["sourceDomain", "sourceKey", "fingerprint"])
                t.check(sql: "status IN ('captured', 'cleanupPending', 'cleanupVerified', 'resolved')")
            }

            try db.execute(sql: """
                CREATE TRIGGER legacyStateMigration_monotonicStatus
                BEFORE UPDATE OF status ON legacyStateMigration
                WHEN CASE OLD.status
                    WHEN 'captured' THEN 0
                    WHEN 'cleanupPending' THEN 1
                    WHEN 'cleanupVerified' THEN 2
                    WHEN 'resolved' THEN 3
                END > CASE NEW.status
                    WHEN 'captured' THEN 0
                    WHEN 'cleanupPending' THEN 1
                    WHEN 'cleanupVerified' THEN 2
                    WHEN 'resolved' THEN 3
                END
                BEGIN
                    SELECT RAISE(ABORT, 'legacyStateMigration status cannot regress');
                END
                """)

            try db.create(table: "legacyStateArchive") { t in
                t.column("id", .integer).notNull().primaryKey(autoincrement: true)
                t.column("sourceDomain", .text).notNull()
                t.column("sourceKey", .text).notNull()
                t.column("contentClass", .text).notNull()
                t.column("valueType", .text).notNull()
                t.column("valuePayload", .blob).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("reason", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["sourceDomain", "sourceKey", "contentClass", "valueType", "fingerprint"])
                t.check(sql: "contentClass IN ('appNonSecret', 'opaquePluginState')")
            }

            try db.create(table: "backupMetadata") { t in
                t.column("id", .integer).notNull().primaryKey().check { $0 == 1 }
                t.column("formatVersion", .integer).notNull().check { $0 > 0 }
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "backupCapability") { t in
                t.primaryKey("component", .text)
                t.column("representation", .text).notNull()
                t.check(sql: "component IN ('libraryCore', 'readingHistory', 'scalarAppPreferences', 'readProgressAndResume', 'trackerLinks', 'updateBadges', 'repositories', 'userImporterAliases', 'pluginIdentityAndAliases', 'pluginSettings', 'legacyUnscopedMediaState', 'legacyStateArchive')")
                t.check(sql: "representation IN ('representedEmpty', 'representedNonempty')")
            }

            try db.create(table: "backupRestoreJournal") { t in
                t.primaryKey("operationId", .text)
                t.column("status", .text).notNull()
                t.column("reportPayload", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.check(sql: "status IN ('pendingRefresh', 'readyToPresent')")
            }

            try backfillLegacyAniListLinks(in: db)
            // v4 compatibility only: this transforms an already-durable database row.
            // Standard-domain UserDefaults capture/removal belongs exclusively to
            // LegacyDefaultsMigrator after schema migration.
            try migrateLegacyRepositories(in: db)

            try db.create(index: "idx_readProgressKey_media", on: "readProgressKey", columns: ["pluginId", "canonicalMediaId"])
            try db.create(index: "idx_readProgressNumber_media", on: "readProgressNumber", columns: ["pluginId", "canonicalMediaId"])
            try db.create(index: "idx_trackerLink_provider", on: "trackerLink", columns: ["providerId", "remoteMediaId"])
            try db.create(index: "idx_pluginIdentityAlias_suiteDomain", on: "pluginIdentityAlias", columns: ["suiteDomain"])
            try db.create(index: "idx_legacyDefaultsOutcome_inbox", on: "legacyDefaultsOutcome", columns: ["sourceDomain", "sourceKey", "fingerprint"])
        }

        // MARK: - v7: Installation-local Plugin Migration Authority
        migrator.registerMigration("v7") { db in
            try db.create(table: "pluginSettingMigrationAuthority") { t in
                t.column("pluginId", .text).notNull()
                t.column("key", .text).notNull()
                t.column("sourceDomain", .text).notNull()
                t.column("sourceKey", .text).notNull()
                t.column("sourceFingerprint", .text).notNull()
                t.primaryKey(["pluginId", "key"])
                t.foreignKey(
                    ["pluginId", "key"],
                    references: "pluginSetting",
                    onDelete: .cascade
                )
                t.foreignKey(
                    ["sourceDomain", "sourceKey", "sourceFingerprint"],
                    references: "legacyDefaultsInbox",
                    columns: ["sourceDomain", "sourceKey", "fingerprint"],
                    onDelete: .cascade
                )
            }

            try db.execute(sql: """
                CREATE TRIGGER pluginSetting_clearMigrationAuthority
                AFTER UPDATE ON pluginSetting
                BEGIN
                    DELETE FROM pluginSettingMigrationAuthority
                    WHERE pluginId = NEW.pluginId AND key = NEW.key;
                END
                """)
        }

        // MARK: - v8: Source Mapping Backup Capability
        migrator.registerMigration("v8") { db in
            try db.execute(
                sql: "ALTER TABLE backupCapability RENAME TO backupCapability_v7"
            )
            try db.create(table: "backupCapability") { t in
                t.primaryKey("component", .text)
                t.column("representation", .text).notNull()
                t.check(sql: "component IN ('libraryCore', 'readingHistory', 'sourceMappings', 'scalarAppPreferences', 'readProgressAndResume', 'trackerLinks', 'updateBadges', 'repositories', 'userImporterAliases', 'pluginIdentityAndAliases', 'pluginSettings', 'legacyUnscopedMediaState', 'legacyStateArchive')")
                t.check(sql: "representation IN ('representedEmpty', 'representedNonempty')")
            }
            try db.execute(
                sql: """
                    INSERT INTO backupCapability (component, representation)
                    SELECT component, representation
                    FROM backupCapability_v7
                    """
            )
            try db.drop(table: "backupCapability_v7")
        }

        // MARK: - v9: Uncategorized System List
        // Installs that started after the GRDB move never got the system list, so their
        // series belonged to no list and disappeared from search and the sectioned layout.
        migrator.registerMigration("v9") { db in
            try ensureSystemCategory(in: db)
        }

        // MARK: - v10: Reading Position
        // Where the reader was inside `lastReadChapterKey`: a page index for manga, a character
        // offset for novels, seconds for video. Null when unknown, such as rows written before v10.
        migrator.registerMigration("v10") { db in
            try db.alter(table: "mediaReadProgress") { t in
                t.add(column: "lastReadPosition", .double)
            }
        }

        // MARK: - v11: Reading Mode
        // The manga reading mode chosen for the series (`Manga.Viewer` raw value). Null means
        // the series' own default.
        migrator.registerMigration("v11") { db in
            try db.alter(table: "mediaReadProgress") { t in
                t.add(column: "readerViewer", .integer)
            }
        }

        // MARK: - v12: First-run setup marker
        // One row once this database's one-time setup has run (see FirstRunSetupBootstrapExtension).
        migrator.registerMigration("v12") { db in
            try db.create(table: "firstRunSetup") { t in
                t.column("id", .integer).notNull().primaryKey().check { $0 == 1 }
                t.column("completedAt", .datetime).notNull()
            }
        }

        // MARK: - v13: Plugin image cache epoch
        // App-private singleton epoch row rotated on plugin setting/credential changes.
        migrator.registerMigration("v13") { db in
            try db.create(table: "pluginImageCacheEpoch") { t in
                t.column("id", .integer).notNull().primaryKey().check { $0 == 1 }
                t.column("epoch", .text).notNull()
            }
            try db.execute(sql: """
                INSERT INTO pluginImageCacheEpoch (id, epoch)
                VALUES (1, lower(hex(randomblob(16))))
                """)
            try db.execute(sql: """
                CREATE TRIGGER pluginSetting_after_insert_rotate_epoch
                AFTER INSERT ON pluginSetting
                BEGIN
                    INSERT INTO pluginImageCacheEpoch (id, epoch)
                    VALUES (1, lower(hex(randomblob(16))))
                    ON CONFLICT(id) DO UPDATE SET epoch = lower(hex(randomblob(16)));
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER pluginSetting_after_delete_rotate_epoch
                AFTER DELETE ON pluginSetting
                BEGIN
                    INSERT INTO pluginImageCacheEpoch (id, epoch)
                    VALUES (1, lower(hex(randomblob(16))))
                    ON CONFLICT(id) DO UPDATE SET epoch = lower(hex(randomblob(16)));
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER pluginSetting_after_update_rotate_epoch
                AFTER UPDATE ON pluginSetting
                WHEN OLD.value IS NOT NEW.value
                  OR OLD.pluginId IS NOT NEW.pluginId
                  OR OLD.key IS NOT NEW.key
                BEGIN
                    INSERT INTO pluginImageCacheEpoch (id, epoch)
                    VALUES (1, lower(hex(randomblob(16))))
                    ON CONFLICT(id) DO UPDATE SET epoch = lower(hex(randomblob(16)));
                END
                """)
        }

        // MARK: - v14: Account-bound plugin completion delivery
        migrator.registerMigration("v14") { db in
            try PluginCompletionSchema.create(in: db)
        }

        // MARK: - v15: Kind-aware durable media identity
        migrator.registerMigration("v15") { db in
            try migrateKindAwareDurableIdentity(in: db)
        }

        registerMultiKindSourceMappingMigration(&migrator)
        return migrator
    }

    nonisolated private static func registerMultiKindSourceMappingMigration(_ migrator: inout DatabaseMigrator) {
        // MARK: - v16: Multi-kind source mappings
        migrator.registerMigration("v16") { db in
            try db.execute(sql: "ALTER TABLE sourceMapping RENAME TO sourceMapping_v15")
            try db.create(table: "sourceMapping") { t in
                t.column("canonicalProvider", .text).notNull()
                t.column("canonicalMediaId", .text).notNull()
                t.column("mediaType", .text).notNull()
                t.column("pluginId", .text).notNull()
                t.column("pluginMediaKey", .text).notNull()

                t.column("decision", .text).notNull()
                t.column("matchMethod", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("titleSnapshot", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()

                t.column("coverURLSnapshot", .text)
                t.column("encodedPayload", .blob)
                t.column("payloadVersion", .integer)
                t.column("pluginVersion", .text)
                t.column("lastVerifiedAt", .datetime)

                t.primaryKey(["canonicalProvider", "canonicalMediaId", "mediaType", "pluginId", "pluginMediaKey"])

                t.check(sql: "mediaType IN ('manga', 'anime', 'novel')")
            }
            try db.execute(sql: """
                INSERT INTO sourceMapping (
                    canonicalProvider,
                    canonicalMediaId,
                    mediaType,
                    pluginId,
                    pluginMediaKey,
                    decision,
                    matchMethod,
                    confidence,
                    titleSnapshot,
                    createdAt,
                    updatedAt,
                    coverURLSnapshot,
                    encodedPayload,
                    payloadVersion,
                    pluginVersion,
                    lastVerifiedAt
                )
                SELECT
                    canonicalProvider,
                    canonicalMediaId,
                    mediaType,
                    pluginId,
                    pluginMediaKey,
                    decision,
                    matchMethod,
                    confidence,
                    titleSnapshot,
                    createdAt,
                    updatedAt,
                    coverURLSnapshot,
                    encodedPayload,
                    payloadVersion,
                    pluginVersion,
                    lastVerifiedAt
                FROM sourceMapping_v15
                """)
            try db.drop(table: "sourceMapping_v15")
            try db.create(
                index: "idx_sourceMapping_canonical",
                on: "sourceMapping",
                columns: ["canonicalProvider", "canonicalMediaId", "mediaType", "decision"]
            )
            try db.create(
                index: "idx_sourceMapping_plugin",
                on: "sourceMapping",
                columns: ["pluginId", "pluginMediaKey"]
            )
        }
    }

    /// Makes sure the "Uncategorized" system list exists and holds every series that is in no list.
    nonisolated static func ensureSystemCategory(in db: Database) throws {
        let existingID = try String.fetchOne(
            db,
            sql: "SELECT id FROM libraryCategory WHERE isSystemCategory = 1 ORDER BY sortOrder LIMIT 1"
        )
        let systemID: String
        if let existingID {
            systemID = existingID
        } else {
            systemID = UUID().uuidString
            try db.execute(
                sql: """
                    INSERT INTO libraryCategory (id, name, sortOrder, isSystemCategory, createdAt)
                    VALUES (?, 'Uncategorized', 0, 1, ?)
                    """,
                arguments: [systemID, Date()]
            )
        }
        try db.execute(
            sql: """
                INSERT INTO itemCategoryLink (itemId, categoryId, addedAt)
                SELECT id, ?, ? FROM libraryItem
                WHERE id NOT IN (SELECT itemId FROM itemCategoryLink)
                """,
            arguments: [systemID, Date()]
        )
    }

    nonisolated static func backfillLegacyAniListLinks(in db: Database) throws {
        // `libraryItem.anilistId` is compatibility input only. A preexisting scoped
        // link is authoritative and wins because the logical key uses INSERT OR IGNORE.
        try db.execute(sql: """
            INSERT OR IGNORE INTO trackerLink
                (pluginId, canonicalMediaId, providerId, remoteMediaId, updatedAt, provenance)
            SELECT
                pluginId,
                CASE
                    WHEN substr(id, 1, length(pluginId) + 1) = pluginId || '_'
                    THEN substr(id, length(pluginId) + 2)
                    ELSE id
                END,
                'anilist',
                CAST(anilistId AS TEXT),
                NULL,
                'legacyUnknownTime'
            FROM libraryItem
            WHERE anilistId IS NOT NULL
            """)
    }

    nonisolated static func migrateLegacyRepositories(
        in db: Database,
        beforeReadback: ((Database) throws -> Void)? = nil
    ) throws {
        guard let preference = try AppPreference.fetchOne(db, key: "ito_repositories"),
              let repositories = try? JSONDecoder().decode([Repository].self, from: preference.value),
              Set(repositories.map(\.url)).count == repositories.count else {
            return
        }

        let expectedRecords = try repositories.map { repository in
            RepositoryRecord(
                url: repository.url,
                lastFetched: repository.lastFetched,
                indexPayload: try repository.index.map { try JSONEncoder().encode($0) }
            )
        }.sorted { $0.url < $1.url }

        var verified = false
        try db.inSavepoint {
            for record in expectedRecords {
                try record.insert(db)
            }

            try beforeReadback?(db)
            let storedRecords = try RepositoryRecord.fetchAll(db).sorted { $0.url < $1.url }
            verified = storedRecords == expectedRecords
            return verified ? .commit : .rollback
        }

        if verified {
            _ = try AppPreference.deleteOne(db, key: "ito_repositories")
        }
    }

    nonisolated static func migrateKindAwareDurableIdentity(
        in db: Database,
        capturedAt: Date = Date()
    ) throws {
        let resolver = try LegacyMediaKindResolver(db: db)

        // 1. readProgressKey
        if try db.tableExists("readProgressKey") {
            try db.execute(sql: """
                CREATE TABLE readProgressKey_v15 (
                    pluginId TEXT NOT NULL,
                    canonicalMediaId TEXT NOT NULL,
                    mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga', 'novel', 'anime')),
                    chapterKey TEXT NOT NULL,
                    markedAt DATETIME,
                    provenance TEXT CHECK(provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')),
                    PRIMARY KEY (pluginId, mediaKind, canonicalMediaId, chapterKey)
                );
                """)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM readProgressKey")
            for row in rows {
                let kind: MediaKind?
                if row.hasColumn("mediaKind"),
                   let raw = row["mediaKind"] as String?,
                   let parsed = MediaKind(rawValue: raw) {
                    kind = parsed
                } else if let pluginId = row["pluginId"] as String?,
                          let canonicalMediaId = row["canonicalMediaId"] as String? {
                    kind = resolver.resolve(pluginID: pluginId, canonicalMediaID: canonicalMediaId)
                } else {
                    kind = nil
                }

                if let kind {
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO readProgressKey_v15
                                (pluginId, canonicalMediaId, mediaKind, chapterKey, markedAt, provenance)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            row["pluginId"] as String,
                            row["canonicalMediaId"] as String,
                            kind.rawValue,
                            row["chapterKey"] as String,
                            row["markedAt"] as Date?,
                            row["provenance"] as String?
                        ]
                    )
                } else {
                    let archive = try LegacyMediaKindResolver.archiveRecord(table: "readProgressKey", row: row, capturedAt: capturedAt)
                    try archive.insert(db, onConflict: .ignore)
                }
            }
            try db.execute(sql: "DROP TABLE readProgressKey")
            try db.execute(sql: "ALTER TABLE readProgressKey_v15 RENAME TO readProgressKey")
            try db.create(index: "idx_readProgressKey_media", on: "readProgressKey", columns: ["pluginId", "mediaKind", "canonicalMediaId"])
        } else {
            try db.create(table: "readProgressKey") { t in
                t.column("pluginId", .text).notNull()
                t.column("canonicalMediaId", .text).notNull()
                t.column("mediaKind", .text).notNull().check(sql: "mediaKind IN ('manga', 'novel', 'anime')")
                t.column("chapterKey", .text).notNull()
                t.column("markedAt", .datetime)
                t.column("provenance", .text)
                t.primaryKey(["pluginId", "mediaKind", "canonicalMediaId", "chapterKey"])
                t.check(sql: "provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')")
            }
            try db.create(index: "idx_readProgressKey_media", on: "readProgressKey", columns: ["pluginId", "mediaKind", "canonicalMediaId"])
        }

        // 2. readProgressNumber
        if try db.tableExists("readProgressNumber") {
            try db.execute(sql: """
                CREATE TABLE readProgressNumber_v15 (
                    pluginId TEXT NOT NULL,
                    canonicalMediaId TEXT NOT NULL,
                    mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga', 'novel', 'anime')),
                    chapterNumber REAL NOT NULL,
                    markedAt DATETIME,
                    provenance TEXT CHECK(provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')),
                    PRIMARY KEY (pluginId, mediaKind, canonicalMediaId, chapterNumber)
                );
                """)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM readProgressNumber")
            for row in rows {
                let kind: MediaKind?
                if row.hasColumn("mediaKind"),
                   let raw = row["mediaKind"] as String?,
                   let parsed = MediaKind(rawValue: raw) {
                    kind = parsed
                } else if let pluginId = row["pluginId"] as String?,
                          let canonicalMediaId = row["canonicalMediaId"] as String? {
                    kind = resolver.resolve(pluginID: pluginId, canonicalMediaID: canonicalMediaId)
                } else {
                    kind = nil
                }

                if let kind {
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO readProgressNumber_v15
                                (pluginId, canonicalMediaId, mediaKind, chapterNumber, markedAt, provenance)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            row["pluginId"] as String,
                            row["canonicalMediaId"] as String,
                            kind.rawValue,
                            row["chapterNumber"] as Double,
                            row["markedAt"] as Date?,
                            row["provenance"] as String?
                        ]
                    )
                } else {
                    let archive = try LegacyMediaKindResolver.archiveRecord(table: "readProgressNumber", row: row, capturedAt: capturedAt)
                    try archive.insert(db, onConflict: .ignore)
                }
            }
            try db.execute(sql: "DROP TABLE readProgressNumber")
            try db.execute(sql: "ALTER TABLE readProgressNumber_v15 RENAME TO readProgressNumber")
            try db.create(index: "idx_readProgressNumber_media", on: "readProgressNumber", columns: ["pluginId", "mediaKind", "canonicalMediaId"])
        } else {
            try db.create(table: "readProgressNumber") { t in
                t.column("pluginId", .text).notNull()
                t.column("canonicalMediaId", .text).notNull()
                t.column("mediaKind", .text).notNull().check(sql: "mediaKind IN ('manga', 'novel', 'anime')")
                t.column("chapterNumber", .double).notNull()
                t.column("markedAt", .datetime)
                t.column("provenance", .text)
                t.primaryKey(["pluginId", "mediaKind", "canonicalMediaId", "chapterNumber"])
                t.check(sql: "provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')")
            }
            try db.create(index: "idx_readProgressNumber_media", on: "readProgressNumber", columns: ["pluginId", "mediaKind", "canonicalMediaId"])
        }

        // 3. mediaReadProgress
        if try db.tableExists("mediaReadProgress") {
            try db.execute(sql: """
                CREATE TABLE mediaReadProgress_v15 (
                    pluginId TEXT NOT NULL,
                    canonicalMediaId TEXT NOT NULL,
                    mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga', 'novel', 'anime')),
                    lastReadChapterKey TEXT NOT NULL,
                    updatedAt DATETIME,
                    provenance TEXT CHECK(provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')),
                    lastReadPosition REAL,
                    readerViewer INTEGER,
                    PRIMARY KEY (pluginId, mediaKind, canonicalMediaId)
                );
                """)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM mediaReadProgress")
            for row in rows {
                let kind: MediaKind?
                if row.hasColumn("mediaKind"),
                   let raw = row["mediaKind"] as String?,
                   let parsed = MediaKind(rawValue: raw) {
                    kind = parsed
                } else if let pluginId = row["pluginId"] as String?,
                          let canonicalMediaId = row["canonicalMediaId"] as String? {
                    kind = resolver.resolve(pluginID: pluginId, canonicalMediaID: canonicalMediaId)
                } else {
                    kind = nil
                }

                if let kind {
                    let lastReadPos: Double? = row.hasColumn("lastReadPosition") ? row["lastReadPosition"] : nil
                    let readerViewer: Int? = row.hasColumn("readerViewer") ? row["readerViewer"] : nil
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO mediaReadProgress_v15
                                (pluginId, canonicalMediaId, mediaKind, lastReadChapterKey, updatedAt, provenance, lastReadPosition, readerViewer)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            row["pluginId"] as String,
                            row["canonicalMediaId"] as String,
                            kind.rawValue,
                            row["lastReadChapterKey"] as String,
                            row["updatedAt"] as Date?,
                            row["provenance"] as String?,
                            lastReadPos,
                            readerViewer
                        ]
                    )
                } else {
                    let archive = try LegacyMediaKindResolver.archiveRecord(table: "mediaReadProgress", row: row, capturedAt: capturedAt)
                    try archive.insert(db, onConflict: .ignore)
                }
            }
            try db.execute(sql: "DROP TABLE mediaReadProgress")
            try db.execute(sql: "ALTER TABLE mediaReadProgress_v15 RENAME TO mediaReadProgress")
        } else {
            try db.create(table: "mediaReadProgress") { t in
                t.column("pluginId", .text).notNull()
                t.column("canonicalMediaId", .text).notNull()
                t.column("mediaKind", .text).notNull().check(sql: "mediaKind IN ('manga', 'novel', 'anime')")
                t.column("lastReadChapterKey", .text).notNull()
                t.column("updatedAt", .datetime)
                t.column("provenance", .text)
                t.column("lastReadPosition", .double)
                t.column("readerViewer", .integer)
                t.primaryKey(["pluginId", "mediaKind", "canonicalMediaId"])
                t.check(sql: "provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')")
            }
        }

        // 4. trackerLink
        if try db.tableExists("trackerLink") {
            try db.execute(sql: """
                CREATE TABLE trackerLink_v15 (
                    pluginId TEXT NOT NULL,
                    canonicalMediaId TEXT NOT NULL,
                    mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga', 'novel', 'anime')),
                    providerId TEXT NOT NULL,
                    remoteMediaId TEXT NOT NULL,
                    updatedAt DATETIME,
                    provenance TEXT CHECK(provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')),
                    PRIMARY KEY (pluginId, mediaKind, canonicalMediaId, providerId)
                );
                """)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM trackerLink")
            for row in rows {
                let kind: MediaKind?
                if row.hasColumn("mediaKind"),
                   let raw = row["mediaKind"] as String?,
                   let parsed = MediaKind(rawValue: raw) {
                    kind = parsed
                } else if let pluginId = row["pluginId"] as String?,
                          let canonicalMediaId = row["canonicalMediaId"] as String? {
                    kind = resolver.resolve(pluginID: pluginId, canonicalMediaID: canonicalMediaId)
                } else {
                    kind = nil
                }

                if let kind {
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO trackerLink_v15
                                (pluginId, canonicalMediaId, mediaKind, providerId, remoteMediaId, updatedAt, provenance)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            row["pluginId"] as String,
                            row["canonicalMediaId"] as String,
                            kind.rawValue,
                            row["providerId"] as String,
                            row["remoteMediaId"] as String,
                            row["updatedAt"] as Date?,
                            row["provenance"] as String?
                        ]
                    )
                } else {
                    let archive = try LegacyMediaKindResolver.archiveRecord(table: "trackerLink", row: row, capturedAt: capturedAt)
                    try archive.insert(db, onConflict: .ignore)
                }
            }
            try db.execute(sql: "DROP TABLE trackerLink")
            try db.execute(sql: "ALTER TABLE trackerLink_v15 RENAME TO trackerLink")
            try db.create(index: "idx_trackerLink_provider", on: "trackerLink", columns: ["providerId", "remoteMediaId"])
        } else {
            try db.create(table: "trackerLink") { t in
                t.column("pluginId", .text).notNull()
                t.column("canonicalMediaId", .text).notNull()
                t.column("mediaKind", .text).notNull().check(sql: "mediaKind IN ('manga', 'novel', 'anime')")
                t.column("providerId", .text).notNull()
                t.column("remoteMediaId", .text).notNull()
                t.column("updatedAt", .datetime)
                t.column("provenance", .text)
                t.primaryKey(["pluginId", "mediaKind", "canonicalMediaId", "providerId"])
                t.check(sql: "provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')")
            }
            try db.create(index: "idx_trackerLink_provider", on: "trackerLink", columns: ["providerId", "remoteMediaId"])
        }

        // 5. updateBadge
        if try db.tableExists("updateBadge") {
            try db.execute(sql: """
                CREATE TABLE updateBadge_v15 (
                    pluginId TEXT NOT NULL,
                    canonicalMediaId TEXT NOT NULL,
                    mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga', 'novel', 'anime')),
                    count INTEGER NOT NULL CHECK(count >= 0),
                    updatedAt DATETIME,
                    provenance TEXT CHECK(provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')),
                    PRIMARY KEY (pluginId, mediaKind, canonicalMediaId)
                );
                """)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM updateBadge")
            for row in rows {
                let kind: MediaKind?
                if row.hasColumn("mediaKind"),
                    let raw = row["mediaKind"] as String?,
                    let parsed = MediaKind(rawValue: raw) {
                    kind = parsed
                } else if let pluginId = row["pluginId"] as String?,
                          let canonicalMediaId = row["canonicalMediaId"] as String? {
                    kind = resolver.resolve(pluginID: pluginId, canonicalMediaID: canonicalMediaId)
                } else {
                    kind = nil
                }

                if let kind {
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO updateBadge_v15
                                (pluginId, canonicalMediaId, mediaKind, count, updatedAt, provenance)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            row["pluginId"] as String,
                            row["canonicalMediaId"] as String,
                            kind.rawValue,
                            row["count"] as Int,
                            row["updatedAt"] as Date?,
                            row["provenance"] as String?
                        ]
                    )
                } else {
                    let archive = try LegacyMediaKindResolver.archiveRecord(table: "updateBadge", row: row, capturedAt: capturedAt)
                    try archive.insert(db, onConflict: .ignore)
                }
            }
            try db.execute(sql: "DROP TABLE updateBadge")
            try db.execute(sql: "ALTER TABLE updateBadge_v15 RENAME TO updateBadge")
        } else {
            try db.create(table: "updateBadge") { t in
                t.column("pluginId", .text).notNull()
                t.column("canonicalMediaId", .text).notNull()
                t.column("mediaKind", .text).notNull().check(sql: "mediaKind IN ('manga', 'novel', 'anime')")
                t.column("count", .integer).notNull().check { $0 >= 0 }
                t.column("updatedAt", .datetime)
                t.column("provenance", .text)
                t.primaryKey(["pluginId", "mediaKind", "canonicalMediaId"])
                t.check(sql: "provenance IS NULL OR provenance IN ('runtime', 'legacyUnknownTime')")
            }
        }

        // 6. readingHistory
        if try db.tableExists("readingHistory") {
            try db.execute(sql: """
                CREATE TABLE readingHistory_v15 (
                    id TEXT PRIMARY KEY NOT NULL,
                    libraryItemId TEXT,
                    mediaKey TEXT NOT NULL,
                    title TEXT NOT NULL,
                    coverUrl TEXT,
                    pluginId TEXT NOT NULL,
                    mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga', 'novel', 'anime')),
                    chapterKey TEXT NOT NULL,
                    chapterTitle TEXT,
                    readAt DATETIME NOT NULL
                );
                """)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM readingHistory")
            for row in rows {
                let kind = resolver.resolveHistory(row)
                if let kind {
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO readingHistory_v15
                                (id, libraryItemId, mediaKey, title, coverUrl, pluginId, mediaKind, chapterKey, chapterTitle, readAt)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            row["id"] as String,
                            row.hasColumn("libraryItemId") ? (row["libraryItemId"] as String?) : nil,
                            row["mediaKey"] as String,
                            row["title"] as String,
                            row.hasColumn("coverUrl") ? (row["coverUrl"] as String?) : nil,
                            row["pluginId"] as String,
                            kind.rawValue,
                            row["chapterKey"] as String,
                            row.hasColumn("chapterTitle") ? (row["chapterTitle"] as String?) : nil,
                            row["readAt"] as Date
                        ]
                    )
                } else {
                    let archive = try LegacyMediaKindResolver.archiveRecord(table: "readingHistory", row: row, capturedAt: capturedAt)
                    try archive.insert(db, onConflict: .ignore)
                }
            }
            try db.execute(sql: "DROP TABLE readingHistory")
            try db.execute(sql: "ALTER TABLE readingHistory_v15 RENAME TO readingHistory")
            try db.create(index: "idx_history_mediaKey_readAt", on: "readingHistory", columns: ["mediaKey", "readAt"])
            try db.create(index: "idx_history_media_kind", on: "readingHistory", columns: ["pluginId", "mediaKind", "mediaKey"])
        } else {
            try db.create(table: "readingHistory") { t in
                t.primaryKey("id", .text)
                t.column("libraryItemId", .text)
                t.column("mediaKey", .text).notNull()
                t.column("title", .text).notNull()
                t.column("coverUrl", .text)
                t.column("pluginId", .text).notNull()
                t.column("mediaKind", .text).notNull().check(sql: "mediaKind IN ('manga', 'novel', 'anime')")
                t.column("chapterKey", .text).notNull()
                t.column("chapterTitle", .text)
                t.column("readAt", .datetime).notNull()
            }
            try db.create(index: "idx_history_mediaKey_readAt", on: "readingHistory", columns: ["mediaKey", "readAt"])
            try db.create(index: "idx_history_media_kind", on: "readingHistory", columns: ["pluginId", "mediaKind", "mediaKey"])
        }
    }
}
