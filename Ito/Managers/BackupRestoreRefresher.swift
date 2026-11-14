import Foundation
import GRDB

nonisolated public enum BackupRestoreJournalError: Error, Equatable, Sendable {
    case missingRecord(operationId: String)
    case unexpectedStatus(operationId: String, status: RestoreOperationStatus)
    case corruptReportPayload(operationId: String)
    case reportOperationMismatch(operationId: String, payloadOperationId: String)
    case transitionConflict(operationId: String)
}

@MainActor
public final class BackupRestoreRefresher {
    public enum RefreshStep: String, CaseIterable, Sendable {
        case appSettings
        case pluginIdentity
        case pluginSettings
        case repositories
        case userImporterAliases
        case library
        case history
        case readProgress
        case trackerLinks
        case updateBadges
        case storage
        case appearance
    }

    public struct RefreshOperations {
        public typealias Operation = @MainActor @Sendable () async throws -> Void

        let appSettings: Operation
        let pluginIdentity: Operation
        let pluginSettings: Operation
        let repositories: Operation
        let userImporterAliases: Operation
        let library: Operation
        let history: Operation
        let readProgress: Operation
        let trackerLinks: Operation
        let updateBadges: Operation
        let storage: Operation
        let appearance: Operation

        public init(
            appSettings: @escaping Operation,
            pluginIdentity: @escaping Operation,
            pluginSettings: @escaping Operation,
            repositories: @escaping Operation,
            userImporterAliases: @escaping Operation,
            library: @escaping Operation,
            history: @escaping Operation,
            readProgress: @escaping Operation,
            trackerLinks: @escaping Operation,
            updateBadges: @escaping Operation,
            storage: @escaping Operation,
            appearance: @escaping Operation
        ) {
            self.appSettings = appSettings
            self.pluginIdentity = pluginIdentity
            self.pluginSettings = pluginSettings
            self.repositories = repositories
            self.userImporterAliases = userImporterAliases
            self.library = library
            self.history = history
            self.readProgress = readProgress
            self.trackerLinks = trackerLinks
            self.updateBadges = updateBadges
            self.storage = storage
            self.appearance = appearance
        }

        fileprivate var ordered: [(RefreshStep, Operation)] {
            [
                (.appSettings, appSettings),
                (.pluginIdentity, pluginIdentity),
                (.pluginSettings, pluginSettings),
                (.repositories, repositories),
                (.userImporterAliases, userImporterAliases),
                (.library, library),
                (.history, history),
                (.readProgress, readProgress),
                (.trackerLinks, trackerLinks),
                (.updateBadges, updateBadges),
                (.storage, storage),
                (.appearance, appearance)
            ]
        }
    }

    private let dbPool: DatabasePool
    private let operations: RefreshOperations
    private let clock: @Sendable () -> Date

    public init(
        dbPool: DatabasePool,
        operations: RefreshOperations,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dbPool = dbPool
        self.operations = operations
        self.clock = clock
    }

    convenience init(
        dbPool: DatabasePool,
        appSettings: AppSettingsStore,
        pluginManager: PluginManager,
        pluginSettings: PluginSettingsStore,
        repoManager: RepoManager,
        pluginResolver: PluginResolver,
        libraryManager: LibraryManager,
        coverThumbnails: LibraryCoverThumbnails,
        historyManager: HistoryManager,
        readProgressManager: ReadProgressManager,
        trackerManager: TrackerManager,
        updateManager: UpdateManager,
        storageManager: StorageManager,
        appearanceManager: AppearanceManager
    ) {
        self.init(
            dbPool: dbPool,
            operations: RefreshOperations(
                appSettings: { try await appSettings.reloadAfterRestore() },
                pluginIdentity: { try await pluginManager.reloadAfterRestore() },
                pluginSettings: { try pluginSettings.reload() },
                repositories: { try await repoManager.reload() },
                userImporterAliases: { try await pluginResolver.reload() },
                library: {
                    // A restore replaces stored thumbnails behind the in-memory service's back.
                    coverThumbnails.invalidateAll()
                    try await libraryManager.reload()
                },
                history: { try await historyManager.reload() },
                readProgress: { try await readProgressManager.reload() },
                trackerLinks: { try await trackerManager.reload() },
                updateBadges: { try await updateManager.reload() },
                storage: { try storageManager.reload() },
                appearance: { appearanceManager.reload() }
            )
        )
    }

    public func refreshCommittedRestore(operationId: String) async throws -> BackupRestoreReport {
        let record = try await journalRecord(operationId: operationId)
        guard record.status == .pendingRefresh else {
            throw BackupRestoreJournalError.unexpectedStatus(
                operationId: operationId,
                status: record.status
            )
        }
        let report = try decodeReport(from: record)

        do {
            for (_, operation) in operations.ordered {
                try await operation()
            }
        } catch {
            throw BackupRestoreError.restoreCommittedRefreshPending(operationId: operationId)
        }
        do {
            try await markReady(record)
        } catch let error as BackupRestoreJournalError {
            throw error
        } catch {
            throw BackupRestoreError.restoreCommittedRefreshPending(operationId: operationId)
        }
        return report
    }

    @discardableResult
    public func resumePendingRefreshes() async throws -> [BackupRestoreReport] {
        let operationIds = try await dbPool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT operationId
                    FROM backupRestoreJournal
                    WHERE status = ?
                    ORDER BY updatedAt, operationId
                    """,
                arguments: [RestoreOperationStatus.pendingRefresh.rawValue]
            )
        }

        var reports: [BackupRestoreReport] = []
        for operationId in operationIds {
            reports.append(try await refreshCommittedRestore(operationId: operationId))
        }
        return reports
    }

    public func loadReadyToPresentReport() async throws -> BackupRestoreReport? {
        let record = try await dbPool.read { db in
            try BackupRestoreJournalRecord.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM backupRestoreJournal
                    WHERE status = ?
                    ORDER BY updatedAt, operationId
                    LIMIT 1
                    """,
                arguments: [RestoreOperationStatus.readyToPresent.rawValue]
            )
        }
        return try record.map(decodeReport(from:))
    }

    /// A ready row may have been produced by a previous process. Rebuild every
    /// read-only cache in the new process before the oldest report is presented.
    public func refreshReadyStateForRelaunch() async throws {
        let records = try await dbPool.read { db in
            try BackupRestoreJournalRecord
                .filter(Column("status") == RestoreOperationStatus.readyToPresent.rawValue)
                .order(Column("updatedAt"), Column("operationId"))
                .fetchAll(db)
        }
        guard !records.isEmpty else { return }
        for record in records {
            _ = try decodeReport(from: record)
        }
        do {
            for (_, operation) in operations.ordered {
                try await operation()
            }
        } catch {
            throw BackupRestoreError.restoreCommittedRefreshPending(
                operationId: records[0].operationId
            )
        }
    }

    @discardableResult
    public func acknowledgeReadyToPresent(operationId: String) async throws -> Bool {
        guard let record = try await dbPool.read({ db in
            try BackupRestoreJournalRecord.fetchOne(db, key: operationId)
        }) else {
            return false
        }
        guard record.status == .readyToPresent else {
            throw BackupRestoreJournalError.unexpectedStatus(
                operationId: operationId,
                status: record.status
            )
        }
        _ = try decodeReport(from: record)

        return try await dbPool.write { db in
            guard let current = try BackupRestoreJournalRecord.fetchOne(
                db,
                key: operationId
            ) else {
                return false
            }
            guard current.status == .readyToPresent else {
                throw BackupRestoreJournalError.unexpectedStatus(
                    operationId: operationId,
                    status: current.status
                )
            }
            guard current.reportPayload == record.reportPayload else {
                throw BackupRestoreJournalError.transitionConflict(
                    operationId: operationId
                )
            }
            return try BackupRestoreJournalRecord.deleteOne(db, key: operationId)
        }
    }

    private func journalRecord(operationId: String) async throws -> BackupRestoreJournalRecord {
        guard let record = try await dbPool.read({ db in
            try BackupRestoreJournalRecord.fetchOne(db, key: operationId)
        }) else {
            throw BackupRestoreJournalError.missingRecord(operationId: operationId)
        }
        return record
    }

    private func decodeReport(
        from record: BackupRestoreJournalRecord
    ) throws -> BackupRestoreReport {
        let report: BackupRestoreReport
        do {
            report = try JSONDecoder().decode(
                BackupRestoreReport.self,
                from: record.reportPayload
            )
        } catch {
            throw BackupRestoreJournalError.corruptReportPayload(
                operationId: record.operationId
            )
        }
        guard report.operationId == record.operationId else {
            throw BackupRestoreJournalError.reportOperationMismatch(
                operationId: record.operationId,
                payloadOperationId: report.operationId
            )
        }
        return report
    }

    private func markReady(_ pendingRecord: BackupRestoreJournalRecord) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE backupRestoreJournal
                    SET status = ?
                    WHERE operationId = ?
                      AND status = ?
                      AND reportPayload = ?
                    """,
                arguments: [
                    RestoreOperationStatus.readyToPresent.rawValue,
                    pendingRecord.operationId,
                    RestoreOperationStatus.pendingRefresh.rawValue,
                    pendingRecord.reportPayload
                ]
            )
            guard db.changesCount == 1 else {
                throw BackupRestoreJournalError.transitionConflict(
                    operationId: pendingRecord.operationId
                )
            }
        }
    }
}
