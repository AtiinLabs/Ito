import Combine
import Foundation

struct BackupSettingsManagerSnapshot: Equatable {
    let isExporting: Bool
    let isRestoring: Bool
    let lastRestoreReport: BackupRestoreReport?
    let committedRefreshPendingOperationId: String?
}

@MainActor
protocol BackupSettingsServing: AnyObject {
    var backupSettingsSnapshot: BackupSettingsManagerSnapshot { get }
    var backupSettingsSnapshotPublisher: AnyPublisher<BackupSettingsManagerSnapshot, Never> { get }

    func createBackupFile() async throws -> URL
    func analyzeMerge(from url: URL) async throws -> [MergeConflict]
    func restoreBackup(
        from url: URL,
        mode: BackupRestoreMode,
        resolvedConflicts: [String: ConflictResolution]
    ) async throws -> BackupRestoreReport
    func retryCommittedRefresh() async throws
    func acknowledgeRestoreReport() async throws -> Bool
}

extension BackupManager: BackupSettingsServing {
    var backupSettingsSnapshot: BackupSettingsManagerSnapshot {
        BackupSettingsManagerSnapshot(
            isExporting: isExporting,
            isRestoring: isRestoring,
            lastRestoreReport: lastRestoreReport,
            committedRefreshPendingOperationId: committedRefreshPendingOperationId
        )
    }

    var backupSettingsSnapshotPublisher: AnyPublisher<BackupSettingsManagerSnapshot, Never> {
        Publishers.CombineLatest4(
            $isExporting,
            $isRestoring,
            $lastRestoreReport,
            $committedRefreshPendingOperationId
        )
        .map {
            BackupSettingsManagerSnapshot(
                isExporting: $0,
                isRestoring: $1,
                lastRestoreReport: $2,
                committedRefreshPendingOperationId: $3
            )
        }
        .eraseToAnyPublisher()
    }
}

@MainActor
struct PreparedBackupSettingsDependencies {
    let service: any BackupSettingsServing

    static func production(backupManager: BackupManager) -> Self {
        Self(service: backupManager)
    }

    static func unavailable() -> Self {
        Self(service: UnavailableBackupSettingsService())
    }
}

private enum BackupSettingsDependencyUnavailableError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Backup & Restore is unavailable."
    }
}

@MainActor
private final class UnavailableBackupSettingsService: BackupSettingsServing {
    let backupSettingsSnapshot = BackupSettingsManagerSnapshot(
        isExporting: false,
        isRestoring: false,
        lastRestoreReport: nil,
        committedRefreshPendingOperationId: nil
    )

    var backupSettingsSnapshotPublisher: AnyPublisher<BackupSettingsManagerSnapshot, Never> {
        Just(backupSettingsSnapshot).eraseToAnyPublisher()
    }

    func createBackupFile() async throws -> URL {
        throw BackupSettingsDependencyUnavailableError.unavailable
    }

    func analyzeMerge(from url: URL) async throws -> [MergeConflict] {
        _ = url
        throw BackupSettingsDependencyUnavailableError.unavailable
    }

    func restoreBackup(
        from url: URL,
        mode: BackupRestoreMode,
        resolvedConflicts: [String: ConflictResolution]
    ) async throws -> BackupRestoreReport {
        _ = url
        _ = mode
        _ = resolvedConflicts
        throw BackupSettingsDependencyUnavailableError.unavailable
    }

    func retryCommittedRefresh() async throws {
        throw BackupSettingsDependencyUnavailableError.unavailable
    }

    func acknowledgeRestoreReport() async throws -> Bool {
        throw BackupSettingsDependencyUnavailableError.unavailable
    }
}
