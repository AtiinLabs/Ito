import Foundation
import GRDB
import Testing
@testable import Ito

@MainActor
struct BackupRestoreRefresherTests {
    @Test func successfulRefreshRunsEveryStoreInDependencyOrderThenMarksReady() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let report = try makeReport(operationId: "success")
        try await insertJournal(report: report, status: .pendingRefresh, database: database)
        let recorder = RefreshRecorder()
        let refresher = makeRefresher(database: database, recorder: recorder)

        let refreshed = try await refresher.refreshCommittedRestore(
            operationId: report.operationId
        )

        #expect(refreshed == report)
        #expect(recorder.steps == BackupRestoreRefresher.RefreshStep.allCases)
        #expect(try await journalStatus(report.operationId, database: database) == .readyToPresent)
        #expect(try await refresher.loadReadyToPresentReport() == report)
    }

    @Test func thrownRefreshLeavesPendingAndSurfacesCommittedPendingError() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let report = try makeReport(operationId: "failure")
        try await insertJournal(report: report, status: .pendingRefresh, database: database)
        let recorder = RefreshRecorder()
        let refresher = makeRefresher(
            database: database,
            recorder: recorder,
            failingAt: .history
        )

        do {
            _ = try await refresher.refreshCommittedRestore(operationId: report.operationId)
            Issue.record("Expected refresh failure")
        } catch {
            #expect(
                error as? BackupRestoreError
                    == .restoreCommittedRefreshPending(operationId: report.operationId)
            )
        }

        #expect(
            recorder.steps == Array(
                BackupRestoreRefresher.RefreshStep.allCases.prefix(through: .history)
            )
        )
        #expect(try await journalStatus(report.operationId, database: database) == .pendingRefresh)
        #expect(try await refresher.loadReadyToPresentReport() == nil)
    }

    @Test func representedEmptyAppSettingsRefreshDoesNotMaterializeDefaults() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let report = try BackupRestoreReport(
            operationId: "empty-settings",
            mode: .wipe,
            outcomes: [try ComponentOutcome(component: .scalarAppPreferences)],
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try await insertJournal(report: report, status: .pendingRefresh, database: database)
        let settings = AppSettingsStore(dbPool: database.dbPool)
        let before = try await appPreferences(database)
        let recorder = RefreshRecorder()
        let refresher = makeRefresher(
            database: database,
            recorder: recorder,
            appSettings: {
                recorder.append(.appSettings)
                try await settings.reloadAfterRestore()
            }
        )

        _ = try await refresher.refreshCommittedRestore(operationId: report.operationId)

        #expect(before.isEmpty)
        #expect(try await appPreferences(database) == before)
        #expect(settings.libraryLayoutStyle == AppPreferenceCatalog.libraryLayoutStyle.defaultValue)
        #expect(settings.appTheme == AppPreferenceCatalog.appTheme.defaultValue)
        #expect(settings.loadIssues.isEmpty)
    }

    @Test func relaunchResumesPendingRefreshFromPersistedReportPayload() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let report = try makeReport(operationId: "resume")
        try await insertJournal(report: report, status: .pendingRefresh, database: database)
        let firstRecorder = RefreshRecorder()
        let first = makeRefresher(
            database: database,
            recorder: firstRecorder,
            failingAt: .pluginSettings
        )
        do {
            _ = try await first.refreshCommittedRestore(operationId: report.operationId)
        } catch {
            #expect(error is BackupRestoreError)
        }

        let relaunchedRecorder = RefreshRecorder()
        let relaunched = makeRefresher(database: database, recorder: relaunchedRecorder)
        let resumed = try await relaunched.resumePendingRefreshes()

        #expect(resumed == [report])
        #expect(relaunchedRecorder.steps == BackupRestoreRefresher.RefreshStep.allCases)
        #expect(try await relaunched.loadReadyToPresentReport() == report)
    }

    @Test func readyReportLoadsWithoutErasureAndAcknowledgesExactlyOnce() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let report = try makeReport(operationId: "ack")
        try await insertJournal(report: report, status: .readyToPresent, database: database)
        let refresher = makeRefresher(database: database, recorder: RefreshRecorder())

        #expect(try await refresher.loadReadyToPresentReport() == report)
        #expect(try await refresher.loadReadyToPresentReport() == report)
        #expect(try await refresher.acknowledgeReadyToPresent(operationId: report.operationId))
        #expect(try await refresher.loadReadyToPresentReport() == nil)
        #expect(
            try await refresher.acknowledgeReadyToPresent(operationId: report.operationId) == false
        )
    }

    @Test func corruptPayloadNeverRefreshesPresentsOrErasesJournalState() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let operationId = "corrupt"
        try await database.dbPool.write { db in
            try BackupRestoreJournalRecord(
                operationId: operationId,
                status: .readyToPresent,
                reportPayload: Data("not-json".utf8),
                updatedAt: Date(timeIntervalSince1970: 1)
            ).insert(db)
        }
        let recorder = RefreshRecorder()
        let refresher = makeRefresher(database: database, recorder: recorder)

        do {
            _ = try await refresher.loadReadyToPresentReport()
            Issue.record("Expected corrupt ready payload to be rejected")
        } catch {
            #expect(
                error as? BackupRestoreJournalError
                    == .corruptReportPayload(operationId: operationId)
            )
        }
        #expect(try await journalStatus(operationId, database: database) == .readyToPresent)
        do {
            _ = try await refresher.acknowledgeReadyToPresent(operationId: operationId)
            Issue.record("Expected corrupt acknowledgment payload to be rejected")
        } catch {
            #expect(
                error as? BackupRestoreJournalError
                    == .corruptReportPayload(operationId: operationId)
            )
        }
        #expect(try await journalStatus(operationId, database: database) == .readyToPresent)

        try await database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE backupRestoreJournal SET status = ? WHERE operationId = ?",
                arguments: [RestoreOperationStatus.pendingRefresh.rawValue, operationId]
            )
        }
        do {
            _ = try await refresher.resumePendingRefreshes()
            Issue.record("Expected corrupt pending payload to be rejected")
        } catch {
            #expect(
                error as? BackupRestoreJournalError
                    == .corruptReportPayload(operationId: operationId)
            )
        }
        #expect(recorder.steps.isEmpty)
        #expect(try await journalStatus(operationId, database: database) == .pendingRefresh)
    }

    @Test func missingAndMismatchedPendingRowsAreTypedAndUntouched() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let recorder = RefreshRecorder()
        let refresher = makeRefresher(database: database, recorder: recorder)

        do {
            _ = try await refresher.refreshCommittedRestore(operationId: "missing")
            Issue.record("Expected missing journal rejection")
        } catch {
            #expect(
                error as? BackupRestoreJournalError
                    == .missingRecord(operationId: "missing")
            )
        }

        let payloadReport = try makeReport(operationId: "payload-operation")
        try await insertJournal(
            report: payloadReport,
            operationId: "journal-operation",
            status: .pendingRefresh,
            database: database
        )
        do {
            _ = try await refresher.refreshCommittedRestore(operationId: "journal-operation")
            Issue.record("Expected payload identity rejection")
        } catch {
            #expect(
                error as? BackupRestoreJournalError
                    == .reportOperationMismatch(
                        operationId: "journal-operation",
                        payloadOperationId: "payload-operation"
                    )
            )
        }

        #expect(recorder.steps.isEmpty)
        #expect(
            try await journalStatus("journal-operation", database: database) == .pendingRefresh
        )
        try await database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE backupRestoreJournal SET status = ? WHERE operationId = ?",
                arguments: [
                    RestoreOperationStatus.readyToPresent.rawValue,
                    "journal-operation"
                ]
            )
        }
        do {
            _ = try await refresher.acknowledgeReadyToPresent(
                operationId: "journal-operation"
            )
            Issue.record("Expected mismatched acknowledgment payload to be rejected")
        } catch {
            #expect(
                error as? BackupRestoreJournalError
                    == .reportOperationMismatch(
                        operationId: "journal-operation",
                        payloadOperationId: "payload-operation"
                    )
            )
        }
        #expect(
            try await journalStatus("journal-operation", database: database) == .readyToPresent
        )
    }

    private func makeRefresher(
        database: TestDatabase,
        recorder: RefreshRecorder,
        failingAt: BackupRestoreRefresher.RefreshStep? = nil,
        appSettings: BackupRestoreRefresher.RefreshOperations.Operation? = nil
    ) -> BackupRestoreRefresher {
        func operation(
            _ step: BackupRestoreRefresher.RefreshStep
        ) -> BackupRestoreRefresher.RefreshOperations.Operation {
            {
                recorder.append(step)
                if step == failingAt {
                    throw InjectedRefreshFailure()
                }
            }
        }

        return BackupRestoreRefresher(
            dbPool: database.dbPool,
            operations: .init(
                appSettings: appSettings ?? operation(.appSettings),
                pluginIdentity: operation(.pluginIdentity),
                pluginSettings: operation(.pluginSettings),
                repositories: operation(.repositories),
                userImporterAliases: operation(.userImporterAliases),
                library: operation(.library),
                history: operation(.history),
                readProgress: operation(.readProgress),
                trackerLinks: operation(.trackerLinks),
                updateBadges: operation(.updateBadges),
                storage: operation(.storage),
                appearance: operation(.appearance)
            ),
            clock: { Date(timeIntervalSince1970: 2) }
        )
    }

    private func makeReport(operationId: String) throws -> BackupRestoreReport {
        try BackupRestoreReport(
            operationId: operationId,
            mode: .merge,
            outcomes: [],
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func insertJournal(
        report: BackupRestoreReport,
        operationId: String? = nil,
        status: RestoreOperationStatus,
        database: TestDatabase
    ) async throws {
        try await database.dbPool.write { db in
            try BackupRestoreJournalRecord(
                operationId: operationId ?? report.operationId,
                status: status,
                reportPayload: try JSONEncoder().encode(report),
                updatedAt: Date(timeIntervalSince1970: 1)
            ).insert(db)
        }
    }

    private func journalStatus(
        _ operationId: String,
        database: TestDatabase
    ) async throws -> RestoreOperationStatus? {
        try await database.dbPool.read { db in
            try BackupRestoreJournalRecord.fetchOne(db, key: operationId)?.status
        }
    }

    private func appPreferences(_ database: TestDatabase) async throws -> [AppPreference] {
        try await database.dbPool.read { db in
            try AppPreference.order(Column("key")).fetchAll(db)
        }
    }
}

@MainActor
private final class RefreshRecorder {
    private(set) var steps: [BackupRestoreRefresher.RefreshStep] = []

    func append(_ step: BackupRestoreRefresher.RefreshStep) {
        steps.append(step)
    }
}

private struct InjectedRefreshFailure: Error {}

private extension Array where Element == BackupRestoreRefresher.RefreshStep {
    func prefix(
        through step: BackupRestoreRefresher.RefreshStep
    ) -> ArraySlice<BackupRestoreRefresher.RefreshStep> {
        guard let index = firstIndex(of: step) else { return [] }
        return self[...index]
    }
}
