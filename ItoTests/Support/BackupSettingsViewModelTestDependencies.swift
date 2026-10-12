import Combine
import Foundation
@testable import Ito

enum BackupSettingsTestError: LocalizedError {
    case expected(String)

    var errorDescription: String? {
        switch self {
        case .expected(let message):
            message
        }
    }
}

@MainActor
final class BackupSettingsServiceFake: BackupSettingsServing {
    enum Operation: Equatable {
        case export
        case mergeAnalysis
        case restore
        case refreshRetry
        case reportAcknowledgment
    }

    enum Response<Value> {
        case success(Value)
        case failure(any Error)
        case suspended
    }

    struct RestoreRequest: Equatable {
        let url: URL
        let mode: BackupRestoreMode
        let resolutions: [String: ConflictResolution]
    }

    private struct Pending<Value> {
        let continuation: CheckedContinuation<Value, any Error>
    }

    private struct PendingWaiter {
        let operation: Operation
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let snapshotSubject: CurrentValueSubject<BackupSettingsManagerSnapshot, Never>
    var exportResponses: [Response<URL>] = []
    var analysisResponses: [Response<[MergeConflict]>] = []
    var restoreResponses: [Response<BackupRestoreReport>] = []
    var refreshResponses: [Response<Void>] = []
    var acknowledgmentResponses: [Response<Bool>] = []
    var reportAfterRefresh: BackupRestoreReport?
    var reportsAfterAcknowledgment: [BackupRestoreReport?] = []
    private(set) var operations: [Operation] = []
    private(set) var exportCallCount = 0
    private(set) var analysisURLs: [URL] = []
    private(set) var restoreRequests: [RestoreRequest] = []
    private(set) var refreshCallCount = 0
    private(set) var acknowledgmentCallCount = 0
    private var pendingExports: [Pending<URL>] = []
    private var pendingAnalyses: [Pending<[MergeConflict]>] = []
    private var pendingRestores: [Pending<BackupRestoreReport>] = []
    private var pendingRefreshes: [Pending<Void>] = []
    private var pendingAcknowledgments: [Pending<Bool>] = []
    private var pendingWaiters: [PendingWaiter] = []

    init(
        snapshot: BackupSettingsManagerSnapshot = BackupSettingsManagerSnapshot(
            isExporting: false,
            isRestoring: false,
            lastRestoreReport: nil,
            committedRefreshPendingOperationId: nil
        )
    ) {
        snapshotSubject = CurrentValueSubject(snapshot)
    }

    var backupSettingsSnapshot: BackupSettingsManagerSnapshot {
        snapshotSubject.value
    }

    var backupSettingsSnapshotPublisher: AnyPublisher<BackupSettingsManagerSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    func publish(_ snapshot: BackupSettingsManagerSnapshot) {
        snapshotSubject.send(snapshot)
    }

    func createBackupFile() async throws -> URL {
        operations.append(.export)
        exportCallCount += 1
        let response = exportResponses.isEmpty
            ? .success(URL(fileURLWithPath: "/tmp/default.itobackup"))
            : exportResponses.removeFirst()
        switch response {
        case .success(let url):
            return url
        case .failure(let error):
            throw error
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                pendingExports.append(Pending(continuation: continuation))
                resumeSatisfiedWaiters()
            }
        }
    }

    func analyzeMerge(from url: URL) async throws -> [MergeConflict] {
        operations.append(.mergeAnalysis)
        analysisURLs.append(url)
        let response = analysisResponses.isEmpty ? .success([]) : analysisResponses.removeFirst()
        switch response {
        case .success(let conflicts):
            return conflicts
        case .failure(let error):
            throw error
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                pendingAnalyses.append(Pending(continuation: continuation))
                resumeSatisfiedWaiters()
            }
        }
    }

    func restoreBackup(
        from url: URL,
        mode: BackupRestoreMode,
        resolvedConflicts: [String: ConflictResolution]
    ) async throws -> BackupRestoreReport {
        operations.append(.restore)
        restoreRequests.append(
            RestoreRequest(url: url, mode: mode, resolutions: resolvedConflicts)
        )
        let response = restoreResponses.isEmpty
            ? .success(try backupSettingsTestReport(id: "default", mode: mode))
            : restoreResponses.removeFirst()
        do {
            let report: BackupRestoreReport
            switch response {
            case .success(let value):
                report = value
            case .failure(let error):
                throw error
            case .suspended:
                report = try await withCheckedThrowingContinuation { continuation in
                    pendingRestores.append(Pending(continuation: continuation))
                    resumeSatisfiedWaiters()
                }
            }
            updateSnapshot(lastRestoreReport: report, pendingOperationID: nil)
            return report
        } catch BackupRestoreError.restoreCommittedRefreshPending(let operationID) {
            updateSnapshot(lastRestoreReport: nil, pendingOperationID: operationID)
            throw BackupRestoreError.restoreCommittedRefreshPending(operationId: operationID)
        }
    }

    func retryCommittedRefresh() async throws {
        operations.append(.refreshRetry)
        refreshCallCount += 1
        let response = refreshResponses.isEmpty ? .success(()) : refreshResponses.removeFirst()
        switch response {
        case .success:
            updateSnapshot(lastRestoreReport: reportAfterRefresh, pendingOperationID: nil)
        case .failure(let error):
            throw error
        case .suspended:
            try await withCheckedThrowingContinuation { continuation in
                pendingRefreshes.append(Pending(continuation: continuation))
                resumeSatisfiedWaiters()
            }
            updateSnapshot(lastRestoreReport: reportAfterRefresh, pendingOperationID: nil)
        }
    }

    func acknowledgeRestoreReport() async throws -> Bool {
        operations.append(.reportAcknowledgment)
        acknowledgmentCallCount += 1
        let response = acknowledgmentResponses.isEmpty
            ? .success(true)
            : acknowledgmentResponses.removeFirst()
        let acknowledged: Bool
        switch response {
        case .success(let value):
            acknowledged = value
        case .failure(let error):
            throw error
        case .suspended:
            acknowledged = try await withCheckedThrowingContinuation { continuation in
                pendingAcknowledgments.append(Pending(continuation: continuation))
                resumeSatisfiedWaiters()
            }
        }
        if !reportsAfterAcknowledgment.isEmpty {
            let nextReport = reportsAfterAcknowledgment.removeFirst()
            updateSnapshot(lastRestoreReport: nextReport, pendingOperationID: nil)
        }
        return acknowledged
    }

    func waitForPending(_ operation: Operation, count: Int = 1) async {
        guard pendingCount(for: operation) < count else { return }
        await withCheckedContinuation { continuation in
            pendingWaiters.append(
                PendingWaiter(operation: operation, count: count, continuation: continuation)
            )
        }
    }

    func resolveExport(_ result: Result<URL, any Error>) {
        guard !pendingExports.isEmpty else { return }
        pendingExports.removeFirst().continuation.resume(with: result)
    }

    func resolveAnalysis(_ result: Result<[MergeConflict], any Error>) {
        guard !pendingAnalyses.isEmpty else { return }
        pendingAnalyses.removeFirst().continuation.resume(with: result)
    }

    func resolveRestore(_ result: Result<BackupRestoreReport, any Error>) {
        guard !pendingRestores.isEmpty else { return }
        pendingRestores.removeFirst().continuation.resume(with: result)
    }

    func resolveRefresh(_ result: Result<Void, any Error>) {
        guard !pendingRefreshes.isEmpty else { return }
        pendingRefreshes.removeFirst().continuation.resume(with: result)
    }

    func resolveAcknowledgment(_ result: Result<Bool, any Error>) {
        guard !pendingAcknowledgments.isEmpty else { return }
        pendingAcknowledgments.removeFirst().continuation.resume(with: result)
    }

    private func updateSnapshot(
        lastRestoreReport: BackupRestoreReport?,
        pendingOperationID: String?
    ) {
        let current = snapshotSubject.value
        snapshotSubject.send(
            BackupSettingsManagerSnapshot(
                isExporting: current.isExporting,
                isRestoring: current.isRestoring,
                lastRestoreReport: lastRestoreReport,
                committedRefreshPendingOperationId: pendingOperationID
            )
        )
    }

    private func pendingCount(for operation: Operation) -> Int {
        switch operation {
        case .export:
            pendingExports.count
        case .mergeAnalysis:
            pendingAnalyses.count
        case .restore:
            pendingRestores.count
        case .refreshRetry:
            pendingRefreshes.count
        case .reportAcknowledgment:
            pendingAcknowledgments.count
        }
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [PendingWaiter] = []
        for waiter in pendingWaiters {
            if pendingCount(for: waiter.operation) >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        pendingWaiters = remaining
    }
}

func backupSettingsTestReport(
    id: String,
    mode: BackupRestoreMode = .merge,
    createdAt: TimeInterval = 1
) throws -> BackupRestoreReport {
    try BackupRestoreReport(
        operationId: id,
        mode: mode,
        outcomes: [],
        createdAt: Date(timeIntervalSince1970: createdAt)
    )
}
