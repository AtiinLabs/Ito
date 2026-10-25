import Foundation
import GRDB
import Testing
@testable import Ito

struct BackupExportOperationTests {
    private let appDomain = "moe.itoapp.ito.tests"

    @Test func readinessFailurePublishesNothing() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let destination = try ExportDestination()
        defer { destination.cleanup() }
        let operation = BackupExportOperation(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            standardApplicationDomain: appDomain,
            readinessGate: { throw InjectedFailure.readiness }
        )

        await #expect(throws: BackupExportError.incompleteMigration) {
            try await operation.export(to: destination.url)
        }

        #expect(!FileManager.default.fileExists(atPath: destination.url.path))
        #expect(try destination.stagingArtifacts().isEmpty)
    }

    @Test func sanitizedSnapshotPreservesEveryDurableComponentAndOpaqueValues() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try populateHostileSource(database.dbPool)
        let destination = try ExportDestination()
        defer { destination.cleanup() }
        let recorder = ExportPhaseRecorder(outputURL: destination.url)
        let operation = BackupExportOperation(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            standardApplicationDomain: appDomain,
            readinessGate: {},
            clock: { Date(timeIntervalSince1970: 1_234) },
            faultHandler: { phase in recorder.record(phase) }
        )

        try await operation.export(to: destination.url)

        #expect(recorder.phases() == [
            .didCreateSnapshot,
            .didSanitize,
            .didValidate,
            .willPublish
        ])
        #expect(recorder.outputExistenceBeforePublication() == [false, false, false, false])
        #expect(FileManager.default.fileExists(atPath: destination.url.path))

        let exported = try DatabaseQueue(path: destination.url.path)
        defer { try? exported.close() }
        try await exported.read { db in
            for table in [
                "legacyDefaultsInbox",
                "legacyDefaultsOutcome",
                "legacyStateMigration",
                "pluginSettingMigrationAuthority",
                "backupRestoreJournal",
                "themeCache"
            ] {
                #expect(try rowCount(table, in: db) == 0)
            }

            let metadata = try BackupMetadataRecord.fetchAll(db)
            #expect(metadata.count == 1)
            #expect(metadata.first?.formatVersion == BackupExportOperation.currentFormatVersion)
            #expect(metadata.first?.createdAt == Date(timeIntervalSince1970: 1_234))

            let capabilities = try BackupCapabilityRecord.fetchAll(db)
            #expect(capabilities.count == BackupComponent.allCases.count)
            #expect(Set(capabilities.map(\.component)) == Set(BackupComponent.allCases))
            #expect(capabilities.allSatisfy { $0.representation == .representedNonempty })

            let pluginSecret = Data("opaque-plugin-secret".utf8)
            #expect(
                try Data.fetchOne(
                    db,
                    sql: "SELECT value FROM pluginSetting WHERE pluginId = 'plugin' AND key = ?",
                    arguments: [LegacyDefaultsSourceTuple.aniListAccessTokenKey]
                ) == pluginSecret
            )
            #expect(
                try Data.fetchOne(
                    db,
                    sql: "SELECT valuePayload FROM legacyStateArchive WHERE sourceDomain = 'plugin.domain'"
                ) == pluginSecret
            )
            #expect(
                try rowCount("legacyStateArchive", in: db) == 2
            )
            #expect(
                try rowCount("appPreference", in: db) == AppPreferenceCatalogEntry.allCases.count
            )
            #expect(
                Set(try String.fetchAll(db, sql: "SELECT key FROM appPreference"))
                    == Set(AppPreferenceCatalogEntry.allCases.map(\.rawValue))
            )
            #expect(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM appPreference WHERE key = ?",
                    arguments: [LegacyDefaultsSourceTuple.aniListAccessTokenKey]
                ) == 0
            )
        }

        let publishedBytes = try Data(contentsOf: destination.url)
        #expect(publishedBytes.range(of: Data("archive-app-managed-secret".utf8)) == nil)
        #expect(publishedBytes.range(of: Data("preference-app-managed-secret".utf8)) == nil)
        #expect(publishedBytes.range(of: Data("opaque-plugin-secret".utf8)) != nil)

        let sourceCounts = try await database.dbPool.read { db in
            [
                try rowCount("legacyDefaultsInbox", in: db),
                try rowCount("backupRestoreJournal", in: db),
                try rowCount("themeCache", in: db),
                try rowCount("legacyStateArchive", in: db),
                try rowCount("appPreference", in: db),
                try rowCount("pluginSettingMigrationAuthority", in: db)
            ]
        }
        #expect(sourceCounts == [2, 1, 1, 3, AppPreferenceCatalogEntry.allCases.count + 1, 1])
    }

    @Test func emptyScalarCatalogRefusesPublication() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let destination = try ExportDestination()
        defer { destination.cleanup() }
        let operation = BackupExportOperation(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            standardApplicationDomain: appDomain,
            readinessGate: {}
        )

        await #expect(throws: BackupExportOperation.ValidationError.invalidScalarPreferenceCatalog) {
            try await operation.export(to: destination.url)
        }

        #expect(!FileManager.default.fileExists(atPath: destination.url.path))
        #expect(try destination.stagingArtifacts().isEmpty)
    }

    @Test func partialScalarCatalogRefusesPublication() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            let entry = AppPreferenceCatalogEntry.appTheme
            try insertPreference(entry, in: db)
        }
        let destination = try ExportDestination()
        defer { destination.cleanup() }
        let operation = BackupExportOperation(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            standardApplicationDomain: appDomain,
            readinessGate: {}
        )

        await #expect(throws: BackupExportOperation.ValidationError.invalidScalarPreferenceCatalog) {
            try await operation.export(to: destination.url)
        }

        #expect(!FileManager.default.fileExists(atPath: destination.url.path))
        #expect(try destination.stagingArtifacts().isEmpty)
    }

    @Test func unknownScalarKeyRefusesPublication() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            for entry in AppPreferenceCatalogEntry.allCases
                where entry != .libraryLayoutStyle {
                try insertPreference(entry, in: db)
            }
            try db.execute(
                sql: "INSERT INTO appPreference (key, value) VALUES ('unknown', X'31')"
            )
        }
        let destination = try ExportDestination()
        defer { destination.cleanup() }
        let operation = BackupExportOperation(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            standardApplicationDomain: appDomain,
            readinessGate: {}
        )

        await #expect(throws: BackupExportOperation.ValidationError.invalidScalarPreferenceCatalog) {
            try await operation.export(to: destination.url)
        }

        #expect(!FileManager.default.fileExists(atPath: destination.url.path))
        #expect(try destination.stagingArtifacts().isEmpty)
    }

    @Test func invalidScalarValueRefusesPublication() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            try insertCompletePreferenceCatalog(in: db)
            try db.execute(
                sql: "UPDATE appPreference SET value = X'3939' WHERE key = ?",
                arguments: [AppPreferenceCatalogEntry.libraryLayoutStyle.rawValue]
            )
        }
        let destination = try ExportDestination()
        defer { destination.cleanup() }
        let operation = BackupExportOperation(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            standardApplicationDomain: appDomain,
            readinessGate: {}
        )

        await #expect(throws: BackupExportOperation.ValidationError.invalidScalarPreferenceCatalog) {
            try await operation.export(to: destination.url)
        }

        #expect(!FileManager.default.fileExists(atPath: destination.url.path))
        #expect(try destination.stagingArtifacts().isEmpty)
    }

    @Test func publicationFailureDoesNotReplaceAnExistingPublishedFile() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            try insertCompletePreferenceCatalog(in: db)
        }
        let destination = try ExportDestination()
        defer { destination.cleanup() }
        let sentinel = Data("existing-backup".utf8)
        try sentinel.write(to: destination.url)
        let operation = BackupExportOperation(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            standardApplicationDomain: appDomain,
            readinessGate: {},
            publisher: { _, _ in
                throw InjectedFailure.publication
            }
        )

        await #expect(throws: InjectedFailure.publication) {
            try await operation.export(to: destination.url)
        }

        #expect(try Data(contentsOf: destination.url) == sentinel)
        #expect(try destination.stagingArtifacts().isEmpty)
    }

    @Test func destinationSidecarsRejectPublicationAndPreserveExistingArtifacts() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let destination = try ExportDestination()
        defer { destination.cleanup() }
        let mainSentinel = Data("existing-main".utf8)
        let walSentinel = Data("existing-wal".utf8)
        try mainSentinel.write(to: destination.url)
        try walSentinel.write(to: destination.sidecarURL(suffix: "-wal"))
        let operation = BackupExportOperation(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            standardApplicationDomain: appDomain,
            readinessGate: {}
        )

        await #expect(throws: BackupExportOperation.SafetyError.destinationSidecarsPresent) {
            try await operation.export(to: destination.url)
        }

        #expect(try Data(contentsOf: destination.url) == mainSentinel)
        #expect(try Data(contentsOf: destination.sidecarURL(suffix: "-wal")) == walSentinel)
        #expect(try destination.stagingArtifacts().isEmpty)
    }

    @Test func outputCannotAliasTheLiveDatabasePath() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            try db.execute(sql: "INSERT INTO repository (url) VALUES ('https://live.example')")
        }
        let operation = BackupExportOperation(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            standardApplicationDomain: appDomain,
            readinessGate: { throw InjectedFailure.readiness }
        )

        await #expect(throws: BackupExportOperation.SafetyError.outputAliasesSourceDatabase) {
            try await operation.export(to: database.databaseURL)
        }

        let liveCount = try await database.dbPool.read { db in
            try rowCount("repository", in: db)
        }
        #expect(liveCount == 1)
    }

    @Test func outputCannotAliasTheLiveDatabaseThroughASymlink() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let aliasURL = database.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("alias.itobackup")
        try FileManager.default.createSymbolicLink(
            at: aliasURL,
            withDestinationURL: database.databaseURL
        )
        let operation = BackupExportOperation(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            standardApplicationDomain: appDomain,
            readinessGate: { throw InjectedFailure.readiness }
        )

        await #expect(throws: BackupExportOperation.SafetyError.outputAliasesSourceDatabase) {
            try await operation.export(to: aliasURL)
        }

        #expect(FileManager.default.fileExists(atPath: database.databaseURL.path))
        #expect(FileManager.default.fileExists(atPath: aliasURL.path))
    }

    private func populateHostileSource(_ dbPool: DatabasePool) throws {
        let pluginSecret = Data("opaque-plugin-secret".utf8)
        let archiveAppSecret = Data("archive-app-managed-secret".utf8)
        let preferenceAppSecret = Data("preference-app-managed-secret".utf8)
        try dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO libraryCategory (id, name, sortOrder, isSystemCategory, createdAt) VALUES ('category', 'Category', 0, 0, 0)"
            )
            try db.execute(
                sql: "INSERT INTO libraryItem (id, title, pluginId, isAnime, rawPayload) VALUES ('plugin_media', 'Media', 'plugin', 0, X'01')"
            )
            try db.execute(
                sql: "INSERT INTO itemCategoryLink (itemId, categoryId, addedAt) VALUES ('plugin_media', 'category', 0)"
            )
            try db.execute(
                sql: "INSERT INTO readingHistory (id, mediaKey, title, pluginId, mediaKind, chapterKey, readAt) VALUES ('history', 'plugin_media', 'Media', 'plugin', 'manga', 'chapter', 0)"
            )
            try db.execute(
                sql: """
                    INSERT INTO sourceMapping
                        (canonicalProvider, canonicalMediaId, mediaType, pluginId,
                         pluginMediaKey, decision, matchMethod, confidence,
                         titleSnapshot, createdAt, updatedAt)
                    VALUES
                        ('anilist', '1', 'manga', 'plugin', 'media', 'discard',
                         'none', 1, 'Rejected', 0, 0)
                    """
            )
            try insertCompletePreferenceCatalog(in: db)
            try db.execute(
                sql: "INSERT INTO appPreference (key, value) VALUES (?, ?)",
                arguments: [
                    LegacyDefaultsSourceTuple.aniListAccessTokenKey,
                    preferenceAppSecret
                ]
            )
            try db.execute(
                sql: "INSERT INTO readProgressKey (pluginId, canonicalMediaId, mediaKind, chapterKey) VALUES ('plugin', 'media', 'manga', 'chapter')"
            )
            try db.execute(
                sql: "INSERT INTO trackerLink (pluginId, canonicalMediaId, mediaKind, providerId, remoteMediaId) VALUES ('plugin', 'media', 'manga', 'anilist', '1')"
            )
            try db.execute(
                sql: "INSERT INTO updateBadge (pluginId, canonicalMediaId, mediaKind, count) VALUES ('plugin', 'media', 'manga', 2)"
            )
            try db.execute(
                sql: "INSERT INTO repository (url) VALUES ('https://example.com/index.json')"
            )
            try db.execute(
                sql: "INSERT INTO pluginIdentityRegistry (pluginId, manifestId, lastSeenAt) VALUES ('plugin', 'plugin', 0)"
            )
            try db.execute(
                sql: "INSERT INTO pluginIdentityAlias (pluginId, aliasKind, aliasValue, suiteDomain, discoverySource, lastSeenAt) VALUES ('plugin', 'manifestId', 'plugin', 'plugin.domain', 'test', 0)"
            )
            try db.execute(
                sql: "INSERT INTO pluginMigrationAlias (foreignId, pluginId, updatedAt) VALUES ('foreign', 'plugin', 0)"
            )
            try db.execute(
                sql: "INSERT INTO pluginSetting (pluginId, key, value) VALUES ('plugin', ?, ?)",
                arguments: [LegacyDefaultsSourceTuple.aniListAccessTokenKey, pluginSecret]
            )
            try db.execute(
                sql: """
                    INSERT INTO legacyDefaultsInbox
                        (sourceDomain, sourceKey, valueType, canonicalPayload, fingerprint,
                         expectedElementCount, capturedAt, lifecycleStatus)
                    VALUES ('plugin.domain', 'authority-key', 'string', X'41',
                            'authority', 1, 0, 'resolved');
                    INSERT INTO pluginSetting (pluginId, key, value)
                    VALUES ('plugin', 'authority-key', X'41');
                    INSERT INTO pluginSettingMigrationAuthority
                        (pluginId, key, sourceDomain, sourceKey, sourceFingerprint)
                    VALUES ('plugin', 'authority-key', 'plugin.domain',
                            'authority-key', 'authority')
                    """
            )
            try db.execute(
                sql: "INSERT INTO legacyUnscopedMediaState (sourceKey, legacyMediaId, canonicalPayload, candidates, fingerprint) VALUES ('progress', 'media', X'01', X'02', 'unscoped')"
            )
            try insertArchive(
                domain: appDomain,
                key: "non-secret",
                contentClass: .appNonSecret,
                payload: Data("safe-app-state".utf8),
                fingerprint: "app",
                in: db
            )
            try insertArchive(
                domain: "plugin.domain",
                key: LegacyDefaultsSourceTuple.aniListAccessTokenKey,
                contentClass: .opaquePluginState,
                payload: pluginSecret,
                fingerprint: "plugin",
                in: db
            )
            try insertArchive(
                domain: appDomain,
                key: LegacyDefaultsSourceTuple.aniListAccessTokenKey,
                contentClass: .appNonSecret,
                payload: archiveAppSecret,
                fingerprint: "credential",
                in: db
            )

            try db.execute(
                sql: "INSERT INTO legacyDefaultsInbox (sourceDomain, sourceKey, valueType, canonicalPayload, fingerprint, expectedElementCount, capturedAt, lifecycleStatus) VALUES ('domain', 'key', 'data', X'01', 'inbox', 1, 0, 'captured')"
            )
            try db.execute(
                sql: "INSERT INTO legacyDefaultsOutcome (sourceDomain, sourceKey, fingerprint, elementPath, disposition, targetKind, targetIdentity, targetFingerprint) VALUES ('domain', 'key', 'inbox', '$', 'normalized', 'kind', 'identity', 'target')"
            )
            try db.execute(
                sql: "INSERT INTO legacyStateMigration (sourceDomain, sourceKey, fingerprint, status, updatedAt) VALUES ('domain', 'key', 'inbox', 'captured', 0)"
            )
            try db.execute(
                sql: "INSERT INTO backupRestoreJournal (operationId, status, reportPayload, updatedAt) VALUES ('operation', 'pendingRefresh', X'01', 0)"
            )
            try db.execute(
                sql: "INSERT INTO themeCache (mediaKey, dominantHex, secondaryHex) VALUES ('plugin_media', '#000000', '#ffffff')"
            )
            try db.execute(
                sql: "INSERT INTO backupMetadata (id, formatVersion, createdAt) VALUES (1, 99, 0)"
            )
            try db.execute(
                sql: "INSERT INTO backupCapability (component, representation) VALUES ('libraryCore', 'representedEmpty')"
            )
        }
    }

    private func insertCompletePreferenceCatalog(in db: Database) throws {
        for entry in AppPreferenceCatalogEntry.allCases {
            try insertPreference(entry, in: db)
        }
    }

    private func insertPreference(
        _ entry: AppPreferenceCatalogEntry,
        in db: Database
    ) throws {
        try db.execute(
            sql: "INSERT INTO appPreference (key, value) VALUES (?, ?)",
            arguments: [entry.rawValue, entry.canonicalDefaultJSON]
        )
    }

    private func insertArchive(
        domain: String,
        key: String,
        contentClass: LegacyArchiveContentClass,
        payload: Data,
        fingerprint: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO legacyStateArchive
                    (sourceDomain, sourceKey, contentClass, valueType, valuePayload,
                     fingerprint, reason, createdAt)
                VALUES (?, ?, ?, 'data', ?, ?, 'test', 0)
                """,
            arguments: [domain, key, contentClass.rawValue, payload, fingerprint]
        )
    }

    private func rowCount(_ table: String, in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }
}

private enum InjectedFailure: Error, Equatable {
    case readiness
    case publication
}

private final class ExportDestination {
    let url: URL

    private let directoryURL: URL

    init() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupExportOperationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        self.directoryURL = directoryURL
        self.url = directoryURL.appendingPathComponent("backup.itobackup")
    }

    func stagingArtifacts() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".staging-") }
    }

    func sidecarURL(suffix: String) -> URL {
        URL(fileURLWithPath: url.path + suffix)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class ExportPhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let outputURL: URL
    private var recordedPhases: [BackupExportOperation.Phase] = []
    private var outputExistence: [Bool] = []

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func record(_ phase: BackupExportOperation.Phase) {
        lock.withLock {
            recordedPhases.append(phase)
            outputExistence.append(FileManager.default.fileExists(atPath: outputURL.path))
        }
    }

    func phases() -> [BackupExportOperation.Phase] {
        lock.withLock { recordedPhases }
    }

    func outputExistenceBeforePublication() -> [Bool] {
        lock.withLock { outputExistence }
    }
}
