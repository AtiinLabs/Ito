import Foundation
import GRDB
import Testing
@testable import Ito

@MainActor
struct BackupDurableStateTests {
    @Test func launchRecoveryIsReadOnlyUntilExactlyOnceAcknowledgment() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let report = try makeReport(operationId: "launch-ready", createdAt: 1)
        try await insert(report, status: .readyToPresent, database: database)
        let migrationCount = LockedCounter()
        let before = try await durableCounts(database)
        let journalBefore = try await journalRows(database)
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: { _ = migrationCount.increment() },
            sourceDatabaseURL: database.databaseURL
        )

        #expect(await bootstrap.prepare() == false)
        guard case .awaitingRestoreAcknowledgment(let presented) = bootstrap.state else {
            Issue.record("Expected launch to remain gated by the persisted report")
            return
        }
        #expect(presented == report)
        #expect(migrationCount.value == 0)
        #expect(try await durableCounts(database) == before)
        #expect(try await journalRows(database) == journalBefore)

        async let first = bootstrap.acknowledgeRestoreReport()
        async let second = bootstrap.acknowledgeRestoreReport()
        let results = await [first, second]

        #expect(results.filter { $0 }.count == 1)
        #expect(migrationCount.value == 1)
        #expect(bootstrap.state == .ready)
        #expect(try await journalRows(database).isEmpty)
        #expect(try await appPreferenceCount(database) == AppPreferenceCatalogEntry.allCases.count)
    }

    @Test func mixedPendingAndReadyReportsRemainOldestFirst() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let older = try makeReport(operationId: "older-pending", createdAt: 1)
        let newer = try makeReport(operationId: "newer-ready", createdAt: 2)
        try await insert(older, status: .pendingRefresh, database: database)
        try await insert(newer, status: .readyToPresent, database: database)
        let refreshCount = LockedCounter()
        let refresher = makeRefresher(database: database) {
            _ = refreshCount.increment()
        }

        _ = try await refresher.resumePendingRefreshes()
        try await refresher.refreshReadyStateForRelaunch()

        #expect(try await refresher.loadReadyToPresentReport() == older)
        #expect(try await refresher.acknowledgeReadyToPresent(operationId: older.operationId))
        #expect(try await refresher.loadReadyToPresentReport() == newer)
        #expect(try await refresher.acknowledgeReadyToPresent(operationId: newer.operationId))
        #expect(try await refresher.loadReadyToPresentReport() == nil)
        #expect(refreshCount.value == BackupRestoreRefresher.RefreshStep.allCases.count * 2)
    }

    @Test func productionPostCommitFailureAlwaysPublishesTypedPendingState() async throws {
        let target = try TestDatabase()
        defer { target.cleanup() }
        let source = try TestDatabase()
        defer { source.cleanup() }
        let backupURL = source.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("source.itobackup")
        let backupQueue = try DatabaseQueue(path: backupURL.path)
        try source.dbPool.backup(to: backupQueue)
        try backupQueue.close()
        let refresher = makeRefresher(database: target) {
            throw InjectedRefreshFailure()
        }
        let manager = BackupManager(
            dbPool: target.dbPool,
            sourceDatabaseURL: target.databaseURL,
            exportReadiness: {},
            restoreRefresher: refresher,
            pluginSecrets: PluginSecretStore(keychain: InMemoryPluginSecretKeychain())
        )

        do {
            _ = try await manager.restoreBackup(from: backupURL, mode: .merge)
            Issue.record("Expected committed-refresh-pending")
        } catch BackupRestoreError.restoreCommittedRefreshPending(let operationId) {
            #expect(manager.committedRefreshPendingOperationId == operationId)
            #expect(manager.lastRestoreReport == nil)
            let row = try await target.dbPool.read { db in
                try BackupRestoreJournalRecord.fetchOne(db, key: operationId)
            }
            #expect(row?.status == .pendingRefresh)
        } catch {
            Issue.record("Unexpected post-commit error: \(error)")
        }
    }

    @Test(arguments: [BackupRestoreMode.wipe, .merge])
    func onlyAWipeRestoreClearsPluginSecrets(mode: BackupRestoreMode) async throws {
        let target = try TestDatabase()
        defer { target.cleanup() }
        let source = try TestDatabase()
        defer { source.cleanup() }
        let backupURL = source.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("source.itobackup")
        let backupQueue = try DatabaseQueue(path: backupURL.path)
        try source.dbPool.backup(to: backupQueue)
        try backupQueue.close()
        let keychain = InMemoryPluginSecretKeychain()
        let secrets = PluginSecretStore(keychain: keychain)
        try secrets.setValue("secret", pluginID: "com.atiinlabs.komga", key: "api_key")
        let manager = BackupManager(
            dbPool: target.dbPool,
            sourceDatabaseURL: target.databaseURL,
            exportReadiness: {},
            restoreRefresher: makeRefresher(database: target),
            pluginSecrets: secrets
        )

        _ = try await manager.restoreBackup(from: backupURL, mode: mode)

        #expect(keychain.storedAccounts.isEmpty == (mode == .wipe))
    }

    @Test func inProcessDiscoveryEpochStartsOnlyAfterFinalAcknowledgment() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let first = try makeReport(operationId: "first", createdAt: 1)
        let second = try makeReport(operationId: "second", createdAt: 2)
        try await insert(first, status: .readyToPresent, database: database)
        try await insert(second, status: .readyToPresent, database: database)
        let discoveryEpochs = LockedCounter()
        let manager = BackupManager(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            exportReadiness: {},
            restoreRefresher: makeRefresher(database: database),
            pluginSecrets: PluginSecretStore(keychain: InMemoryPluginSecretKeychain()),
            onAllReportsAcknowledged: {
                _ = discoveryEpochs.increment()
            }
        )

        try await manager.loadReadyReportForPresentation()
        #expect(manager.lastRestoreReport == first)
        #expect(try await manager.acknowledgeRestoreReport())
        #expect(discoveryEpochs.value == 0)
        #expect(manager.lastRestoreReport == second)
        #expect(try await manager.acknowledgeRestoreReport())
        #expect(discoveryEpochs.value == 1)
        #expect(manager.lastRestoreReport == nil)
        #expect(try await manager.acknowledgeRestoreReport() == false)
        #expect(discoveryEpochs.value == 1)
    }

    @Test func exportRejectsCorruptPluginInstalledAfterReadinessWithoutPublishing() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginsDirectory = database.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("Plugins", isDirectory: true)
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: {},
            sourceDatabaseURL: database.databaseURL,
            installedPluginsDirectory: pluginsDirectory
        )
        #expect(await bootstrap.prepare())
        let backupManager = try #require(bootstrap.backupManager)
        let backupURLsBefore = try temporaryBackupURLs()
        try makeCorruptInstalledPlugin(in: pluginsDirectory)

        await #expect(throws: BackupExportError.incompleteMigration) {
            _ = try await backupManager.createBackupFile()
        }

        #expect(try temporaryBackupURLs() == backupURLsBefore)
        #expect(backupManager.isExporting == false)
    }

    @Test func reportEncodingRequiresStrictRepresentedComponents() throws {
        let report = try BackupRestoreReport(
            operationId: "strict",
            mode: .wipe,
            representedComponents: [.repositories],
            outcomes: [try ComponentOutcome(component: .repositories, inserted: 1)],
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let payload = try JSONEncoder().encode(report)
        var object = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        #expect(object["representedComponents"] as? [String] == ["repositories"])
        _ = try JSONDecoder().decode(BackupRestoreReport.self, from: payload)

        object.removeValue(forKey: "representedComponents")
        let missing = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BackupRestoreReport.self, from: missing)
        }

        object["representedComponents"] = []
        let mismatched = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: BackupRestoreReport.ValidationError.self) {
            try JSONDecoder().decode(BackupRestoreReport.self, from: mismatched)
        }
    }

    @Test func productionBindingsContainNoRawExportLegacyRestoreOrFalseRollbackCopy() throws {
        let backupManager = try read("Ito/Managers/BackupManager.swift")
        let backupView = try read("Ito/Views/Settings/BackupSettingsView.swift")
        let pluginManager = try read("Ito/Managers/PluginManager.swift")

        let createStart = try #require(backupManager.range(of: "public func createBackupFile()"))
        let analyzeStart = try #require(
            backupManager.range(
                of: "public func analyzeMerge",
                range: createStart.upperBound..<backupManager.endIndex
            )
        )
        let exportBody = backupManager[createStart.lowerBound..<analyzeStart.lowerBound]
        #expect(exportBody.contains("BackupExportOperation("))
        #expect(!exportBody.contains(".backup(to:"))

        let restoreStart = try #require(backupManager.range(of: "public func restoreBackup("))
        let retryStart = try #require(
            backupManager.range(
                of: "public func retryCommittedRefresh",
                range: restoreStart.upperBound..<backupManager.endIndex
            )
        )
        let restoreBody = backupManager[restoreStart.lowerBound..<retryStart.lowerBound]
        #expect(restoreBody.contains("ComponentAwareBackupRestoreOperation("))
        #expect(!restoreBody.contains("BackupMergeOperation"))
        #expect(!backupView.contains("safely reverted"))
        #expect(!backupView.contains("no changes were made"))
        #expect(!backupView.contains("Restore Successful"))

        let initializer = try #require(pluginManager.range(of: "public init(pluginSettingsStore:"))
        let getRunner = try #require(
            pluginManager.range(
                of: "public func getRunner",
                range: initializer.upperBound..<pluginManager.endIndex
            )
        )
        #expect(!pluginManager[initializer.lowerBound..<getRunner.lowerBound].contains("Task"))
    }

    private func makeRefresher(
        database: TestDatabase,
        operation: @escaping BackupRestoreRefresher.RefreshOperations.Operation = {}
    ) -> BackupRestoreRefresher {
        BackupRestoreRefresher(
            dbPool: database.dbPool,
            operations: .init(
                appSettings: operation,
                pluginIdentity: operation,
                pluginSettings: operation,
                repositories: operation,
                userImporterAliases: operation,
                library: operation,
                history: operation,
                readProgress: operation,
                trackerLinks: operation,
                updateBadges: operation,
                storage: operation,
                appearance: operation
            )
        )
    }

    private func makeReport(
        operationId: String,
        createdAt: TimeInterval
    ) throws -> BackupRestoreReport {
        try BackupRestoreReport(
            operationId: operationId,
            mode: .merge,
            outcomes: [],
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    private func insert(
        _ report: BackupRestoreReport,
        status: RestoreOperationStatus,
        database: TestDatabase
    ) async throws {
        try await database.dbPool.write { db in
            try BackupRestoreJournalRecord(
                operationId: report.operationId,
                status: status,
                reportPayload: try JSONEncoder().encode(report),
                updatedAt: report.createdAt
            ).insert(db)
        }
    }

    private func makeCorruptInstalledPlugin(in pluginsDirectory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: pluginsDirectory,
            withIntermediateDirectories: true
        )
        let pluginURL = pluginsDirectory.appendingPathComponent(
            "corrupt-\(UUID().uuidString).ito"
        )
        try Data("not an ito plugin".utf8).write(to: pluginURL)
    }

    private func temporaryBackupURLs() throws -> Set<URL> {
        Set(
            try FileManager.default.contentsOfDirectory(
                at: FileManager.default.temporaryDirectory,
                includingPropertiesForKeys: nil
            ).filter {
                $0.lastPathComponent.hasPrefix("Ito_Backup_")
                    && $0.pathExtension == "itobackup"
            }
        )
    }

    private func durableCounts(_ database: TestDatabase) async throws -> [String: Int] {
        let tables = [
            "libraryCategory", "libraryItem", "itemCategoryLink", "readingHistory",
            "appPreference", "readProgressKey", "readProgressNumber",
            "mediaReadProgress", "trackerLink", "updateBadge", "repository",
            "pluginMigrationAlias", "pluginIdentityRegistry", "pluginIdentityAlias",
            "pluginSetting", "legacyUnscopedMediaState", "legacyStateArchive"
        ]
        return try await database.dbPool.read { db in
            try Dictionary(uniqueKeysWithValues: tables.map { table in
                (table, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0)
            })
        }
    }

    private func journalRows(
        _ database: TestDatabase
    ) async throws -> [BackupRestoreJournalRecord] {
        try await database.dbPool.read { db in
            try BackupRestoreJournalRecord.order(Column("updatedAt")).fetchAll(db)
        }
    }

    private func appPreferenceCount(_ database: TestDatabase) async throws -> Int {
        try await database.dbPool.read { db in
            try AppPreference.fetchCount(db)
        }
    }

    private func read(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct InjectedRefreshFailure: Error {}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }
}
