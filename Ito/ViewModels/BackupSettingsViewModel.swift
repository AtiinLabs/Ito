import Combine
import Foundation

enum BackupSettingsAlert: Equatable, Identifiable {
    case exportFailed(String)
    case importFailed(String)
    case mergeCheckFailed(String)
    case restoreFailed(String)
    case acknowledgmentFailed(String)

    var id: String { title }

    var title: String {
        switch self {
        case .exportFailed:
            "Export Failed"
        case .importFailed:
            "Import Failed"
        case .mergeCheckFailed:
            "Merge Check Failed"
        case .restoreFailed:
            "Restore Failed"
        case .acknowledgmentFailed:
            "Acknowledgment Failed"
        }
    }

    var message: String {
        switch self {
        case .exportFailed(let message),
             .importFailed(let message),
             .mergeCheckFailed(let message),
             .restoreFailed(let message),
             .acknowledgmentFailed(let message):
            message
        }
    }
}

enum BackupImportPresentation: Equatable {
    case idle
    case fileImporter
    case restoreStrategy
    case wipeConfirmation
}

struct BackupConflictPresentation: Equatable {
    let sourceURL: URL
    var conflicts: [MergeConflict]
}

enum BackupSettingsOperationKind: Equatable {
    case export
    case mergeAnalysis
    case restore
    case refreshRetry
    case reportAcknowledgment
}

/// Screen-owned presentation state for Backup & Restore.
///
/// Cancellation only invalidates transient export/analysis presentation. Once a restore,
/// committed-refresh retry, or report acknowledgment reaches the canonical service, it is
/// allowed to finish. A stale completion may be hidden from a dismissed screen, but it is
/// never described as a rollback and cannot clear a newer operation.
@MainActor
final class BackupSettingsViewModel: ObservableObject {
    @Published private(set) var managerSnapshot: BackupSettingsManagerSnapshot
    @Published private(set) var importPresentation: BackupImportPresentation = .idle
    @Published private(set) var pendingImportURL: URL?
    @Published private(set) var conflictPresentation: BackupConflictPresentation?
    @Published private(set) var exportFileURL: URL?
    @Published private(set) var exportDefaultFilename = "ItoBackup"
    @Published private(set) var isFileExporterPresented = false
    @Published private(set) var activeRestoreReport: BackupRestoreReport?
    @Published private(set) var showsRefreshPending = false
    @Published private(set) var alert: BackupSettingsAlert?
    @Published private(set) var operationKind: BackupSettingsOperationKind?
    #if DEBUG
    @Published private(set) var restoreAttemptCompletionGeneration: UInt64 = 0
    #endif

    private struct Operation: Equatable {
        let id: UUID
        let kind: BackupSettingsOperationKind
        let presentationGeneration: UInt64
    }

    private enum CanonicalPresentation: Equatable {
        case none
        case refreshPending
        case report(BackupRestoreReport)
    }

    private let service: any BackupSettingsServing
    private let presentationLogger: any PresentationEventLogging
    private let claimCommittedRefreshRetry: @MainActor () -> Bool
    private let releaseCommittedRefreshRetry: @MainActor () -> Void
    private var activeOperation: Operation?
    /// An export whose save sheet closed before `onCompletion` reported a result. On iOS 15/16 a
    /// cancelled exporter never calls `onCompletion`, so the screen is released at dismissal and
    /// the outcome is logged when a late completion arrives, or as cancelled once the next
    /// operation starts or the screen goes away.
    private var dismissedExportOperation: Operation?
    private var operationTask: Task<Void, Never>?
    private var presentationGeneration: UInt64 = 0
    private var isPresentationActive = true
    private var finalizedLogOperations = Set<UUID>()
    private var cancellables = Set<AnyCancellable>()
    private var lastReconciledCanonicalPresentation: CanonicalPresentation
    private var canonicalPresentationNeedsReconciliation = false
    init(
        dependencies: PreparedBackupSettingsDependencies,
        presentationLogger: any PresentationEventLogging
    ) {
        service = dependencies.service
        claimCommittedRefreshRetry = dependencies.claimCommittedRefreshRetry
        releaseCommittedRefreshRetry = dependencies.releaseCommittedRefreshRetry
        self.presentationLogger = presentationLogger
        let snapshot = dependencies.service.backupSettingsSnapshot
        managerSnapshot = snapshot
        lastReconciledCanonicalPresentation = Self.canonicalPresentation(for: snapshot)
        switch lastReconciledCanonicalPresentation {
        case .none:
            activeRestoreReport = nil
            showsRefreshPending = false
        case .refreshPending:
            activeRestoreReport = nil
            showsRefreshPending = true
        case .report(let report):
            activeRestoreReport = report
            showsRefreshPending = false
        }

        dependencies.service.backupSettingsSnapshotPublisher
            .sink { [weak self] snapshot in
                self?.receiveManagerSnapshot(snapshot)
            }
            .store(in: &cancellables)
    }

    private static func canonicalPresentation(
        for snapshot: BackupSettingsManagerSnapshot
    ) -> CanonicalPresentation {
        if snapshot.committedRefreshPendingOperationId != nil {
            return .refreshPending
        }
        if let report = snapshot.lastRestoreReport {
            return .report(report)
        }
        return .none
    }

    private func receiveManagerSnapshot(_ snapshot: BackupSettingsManagerSnapshot) {
        managerSnapshot = snapshot
        let presentation = Self.canonicalPresentation(for: snapshot)
        guard presentation != lastReconciledCanonicalPresentation else { return }
        guard isPresentationActive, activeOperation == nil else {
            canonicalPresentationNeedsReconciliation = true
            return
        }
        applyCanonicalPresentation(presentation)
    }

    private func reconcileCanonicalPresentation(force: Bool) {
        let snapshot = service.backupSettingsSnapshot
        managerSnapshot = snapshot
        let presentation = Self.canonicalPresentation(for: snapshot)
        guard isPresentationActive, activeOperation == nil else {
            canonicalPresentationNeedsReconciliation = true
            return
        }
        guard force || canonicalPresentationNeedsReconciliation
            || presentation != lastReconciledCanonicalPresentation else { return }
        applyCanonicalPresentation(presentation)
    }

    private func applyCanonicalPresentation(_ presentation: CanonicalPresentation) {
        switch presentation {
        case .none:
            activeRestoreReport = nil
            showsRefreshPending = false
        case .refreshPending:
            activeRestoreReport = nil
            showsRefreshPending = true
        case .report(let report):
            activeRestoreReport = report
            showsRefreshPending = false
        }
        lastReconciledCanonicalPresentation = presentation
        canonicalPresentationNeedsReconciliation = false
    }

    deinit {
        switch activeOperation?.kind {
        case .export, .mergeAnalysis:
            operationTask?.cancel()
        case .restore, .refreshRetry, .reportAcknowledgment, .none:
            break
        }
    }

    var isFileImporterPresented: Bool {
        importPresentation == .fileImporter
    }

    var showsRestoreStrategy: Bool {
        importPresentation == .restoreStrategy
    }

    var showsWipeConfirmation: Bool {
        importPresentation == .wipeConfirmation
    }

    var showsConflictResolver: Bool {
        conflictPresentation != nil
    }

    var showsRestoreReport: Bool {
        activeRestoreReport != nil
    }

    var isOperationRunning: Bool {
        activeOperation != nil
    }

    var isBusy: Bool {
        managerSnapshot.isExporting || managerSnapshot.isRestoring || isOperationRunning
    }

    var isExportDisabled: Bool {
        isBusy || exportFileURL != nil || isFileExporterPresented
    }

    var isImportDisabled: Bool {
        isBusy || isFileImporterPresented || isFileExporterPresented
    }

    @discardableResult
    func beginExport() -> Task<Void, Never>? {
        guard exportFileURL == nil, !isFileExporterPresented,
              let operation = claimOperation(.export) else { return nil }
        let task = Task { @MainActor [weak self, service] in
            do {
                let url = try await service.createBackupFile()
                self?.publishPreparedExport(url, operation: operation)
            } catch {
                self?.publishOperationFailure(
                    error,
                    alert: .exportFailed(error.localizedDescription),
                    operation: operation
                )
            }
        }
        operationTask = task
        return task
    }

    func setFileExporterPresented(_ isPresented: Bool) {
        guard let operation = activeOperation, operation.kind == .export else { return }
        isFileExporterPresented = isPresented
        guard !isPresented else { return }
        exportFileURL = nil
        dismissedExportOperation = operation
        activeOperation = nil
        operationKind = nil
        operationTask = nil
    }

    func fileExporterDidComplete(_ result: Result<URL, Error>) {
        let operation: Operation
        if let active = activeOperation, active.kind == .export {
            operation = active
            exportFileURL = nil
            isFileExporterPresented = false
            activeOperation = nil
            operationKind = nil
            operationTask = nil
        } else if let dismissed = dismissedExportOperation {
            operation = dismissed
        } else {
            return
        }
        dismissedExportOperation = nil
        switch result {
        case .success:
            logFinishedOnce(operation, outcome: .succeeded)
        case .failure(let error):
            alert = .exportFailed(error.localizedDescription)
            logFinishedOnce(operation, outcome: .failed(.persistence))
        }
    }

    private func finishDismissedExportAsCancelled() {
        guard let operation = dismissedExportOperation else { return }
        dismissedExportOperation = nil
        logFinishedOnce(operation, outcome: .cancelled)
    }

    @discardableResult
    func requestImport() -> Bool {
        guard canPresentFileUI,
              importPresentation == .idle,
              conflictPresentation == nil,
              activeRestoreReport == nil,
              !showsRefreshPending else { return false }
        importPresentation = .fileImporter
        return true
    }

    func setFileImporterPresented(_ isPresented: Bool) {
        if isPresented {
            _ = requestImport()
        } else if importPresentation == .fileImporter {
            importPresentation = .idle
        }
    }

    func fileImporterDidComplete(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                importPresentation = .idle
                return
            }
            if !selectImportURL(url) {
                importPresentation = .idle
            }
        case .failure(let error):
            importPresentation = .idle
            alert = .importFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func selectImportURL(_ url: URL) -> Bool {
        guard canPresentFileUI,
              importPresentation == .idle || importPresentation == .fileImporter,
              conflictPresentation == nil,
              activeRestoreReport == nil,
              !showsRefreshPending else { return false }
        pendingImportURL = url
        importPresentation = .restoreStrategy
        return true
    }

    func setRestoreStrategyPresented(_ isPresented: Bool) {
        // SwiftUI writes `false` before invoking a confirmation-dialog button action.
        // Explicit actions own every dismissal so that write cannot consume the selection.
        guard isPresented, pendingImportURL != nil else { return }
        importPresentation = .restoreStrategy
    }

    func cancelRestoreStrategy() {
        guard importPresentation == .restoreStrategy else { return }
        importPresentation = .idle
        pendingImportURL = nil
    }

    func chooseWipeStrategy() {
        guard importPresentation == .restoreStrategy,
              pendingImportURL != nil,
              activeOperation == nil else { return }
        importPresentation = .wipeConfirmation
    }

    func setWipeConfirmationPresented(_ isPresented: Bool) {
        // SwiftUI writes `false` before invoking an alert button action.
        guard isPresented, pendingImportURL != nil else { return }
        importPresentation = .wipeConfirmation
    }

    func cancelWipeConfirmation() {
        guard importPresentation == .wipeConfirmation else { return }
        importPresentation = .idle
        pendingImportURL = nil
    }

    @discardableResult
    func confirmWipeRestore() -> Task<Void, Never>? {
        guard importPresentation == .wipeConfirmation,
              let url = pendingImportURL,
              let operation = claimOperation(.restore) else { return nil }
        importPresentation = .idle
        return launchRestore(
            url: url,
            mode: .wipe,
            resolutions: [:],
            operation: operation
        )
    }

    @discardableResult
    func chooseMergeStrategy() -> Task<Void, Never>? {
        guard importPresentation == .restoreStrategy,
              let url = pendingImportURL,
              let operation = claimOperation(.mergeAnalysis) else { return nil }
        importPresentation = .idle
        let task = Task { @MainActor [weak self, service] in
            do {
                let conflicts = try await service.analyzeMerge(from: url)
                await self?.publishMergeAnalysis(
                    conflicts,
                    url: url,
                    operation: operation,
                    service: service
                )
            } catch {
                self?.publishOperationFailure(
                    error,
                    alert: .mergeCheckFailed(error.localizedDescription),
                    operation: operation
                )
            }
        }
        operationTask = task
        return task
    }

    func updateConflicts(_ conflicts: [MergeConflict]) {
        guard var presentation = conflictPresentation else { return }
        presentation.conflicts = conflicts
        conflictPresentation = presentation
    }

    @discardableResult
    func resolveConflicts() -> Task<Void, Never>? {
        guard let presentation = conflictPresentation,
              let operation = claimOperation(.restore) else { return nil }
        let resolutions = Dictionary(
            uniqueKeysWithValues: presentation.conflicts.map { ($0.id, $0.resolution) }
        )
        conflictPresentation = nil
        return launchRestore(
            url: presentation.sourceURL,
            mode: .merge,
            resolutions: resolutions,
            operation: operation
        )
    }

    func cancelConflictResolution() {
        guard conflictPresentation != nil, activeOperation == nil else { return }
        conflictPresentation = nil
        pendingImportURL = nil
    }

    func setConflictResolverPresented(_ isPresented: Bool) {
        guard !isPresented, conflictPresentation != nil else { return }
        cancelConflictResolution()
    }

    @discardableResult
    func retryCommittedRefresh() -> Task<Void, Never>? {
        guard showsRefreshPending,
              let operation = claimOperation(
                  .refreshRetry,
                  admissionClaim: claimCommittedRefreshRetry
              ) else { return nil }
        showsRefreshPending = false
        let releaseCommittedRefreshRetry = releaseCommittedRefreshRetry
        let task = Task { @MainActor [weak self, service, releaseCommittedRefreshRetry] in
            defer { releaseCommittedRefreshRetry() }
            do {
                try await service.retryCommittedRefresh()
                self?.publishRefreshSuccess(
                    report: service.backupSettingsSnapshot.lastRestoreReport,
                    operation: operation
                )
            } catch {
                self?.publishRefreshFailure(operation: operation)
            }
        }
        operationTask = task
        return task
    }

    func setRefreshPendingPresented(_ isPresented: Bool) {
        // Retry and Not Now own dismissal; preserve state until their action runs.
        guard isPresented else { return }
        showsRefreshPending = true
    }

    func deferCommittedRefresh() {
        showsRefreshPending = false
    }

    @discardableResult
    func acknowledgeRestoreReport() -> Task<Void, Never>? {
        guard activeRestoreReport != nil,
              let operation = claimOperation(.reportAcknowledgment) else { return nil }
        let task = Task { @MainActor [weak self, service] in
            do {
                _ = try await service.acknowledgeRestoreReport()
                self?.publishAcknowledgmentSuccess(
                    nextReport: service.backupSettingsSnapshot.lastRestoreReport,
                    operation: operation
                )
            } catch {
                self?.publishOperationFailure(
                    error,
                    alert: .acknowledgmentFailed(error.localizedDescription),
                    operation: operation
                )
            }
        }
        operationTask = task
        return task
    }

    func setRestoreReportPresented(_ isPresented: Bool) {
        guard !isPresented, activeRestoreReport == nil else { return }
    }

    func dismissAlert() {
        alert = nil
    }

    func screenDidAppear() {
        isPresentationActive = true
        managerSnapshot = service.backupSettingsSnapshot
        reconcileCanonicalPresentation(force: activeOperation == nil)
    }

    func screenDidDisappear() {
        isPresentationActive = false
        presentationGeneration &+= 1
        finishDismissedExportAsCancelled()
        guard let operation = activeOperation else { return }
        switch operation.kind {
        case .export:
            operationTask?.cancel()
            exportFileURL = nil
            isFileExporterPresented = false
            finishOperation(operation, outcome: .cancelled)
        case .mergeAnalysis:
            operationTask?.cancel()
            pendingImportURL = nil
            finishOperation(operation, outcome: .cancelled)
        case .restore, .refreshRetry, .reportAcknowledgment:
            break
        }
    }

    private var canPresentFileUI: Bool {
        isPresentationActive
            && activeOperation == nil
            && !managerSnapshot.isExporting
            && !managerSnapshot.isRestoring
            && exportFileURL == nil
            && !isFileExporterPresented
    }

    private func claimOperation(
        _ kind: BackupSettingsOperationKind,
        admissionClaim: (@MainActor () -> Bool)? = nil
    ) -> Operation? {
        guard isPresentationActive,
              activeOperation == nil,
              !managerSnapshot.isExporting,
              !managerSnapshot.isRestoring,
              admissionClaim?() ?? true else { return nil }
        finishDismissedExportAsCancelled()
        let operation = Operation(
            id: UUID(),
            kind: kind,
            presentationGeneration: presentationGeneration
        )
        activeOperation = operation
        operationKind = kind
        presentationLogger.log(
            .started(
                feature: .backupSettings,
                kind: presentationEventKind(for: kind),
                operationID: operation.id
            )
        )
        return operation
    }

    private func publishPreparedExport(_ url: URL, operation: Operation) {
        guard canPublishTransient(operation) else {
            finishStaleOperation(operation)
            return
        }
        exportFileURL = url
        exportDefaultFilename = url.lastPathComponent
        isFileExporterPresented = true
        if activeOperation == operation {
            operationTask = nil
        }
    }

    private func publishMergeAnalysis(
        _ conflicts: [MergeConflict],
        url: URL,
        operation: Operation,
        service: any BackupSettingsServing
    ) async {
        guard canPublishTransient(operation) else {
            finishStaleOperation(operation)
            return
        }
        if conflicts.isEmpty {
            logFinishedOnce(operation, outcome: .succeeded)
            let restoreOperation = Operation(
                id: UUID(),
                kind: .restore,
                presentationGeneration: operation.presentationGeneration
            )
            activeOperation = restoreOperation
            operationKind = .restore
            presentationLogger.log(
                .started(
                    feature: .backupSettings,
                    kind: .backupRestore,
                    operationID: restoreOperation.id
                )
            )
            await performRestore(
                url: url,
                mode: .merge,
                resolutions: [:],
                operation: restoreOperation,
                service: service
            )
        } else {
            conflictPresentation = BackupConflictPresentation(
                sourceURL: url,
                conflicts: conflicts
            )
            finishOperation(operation, outcome: .succeeded)
        }
    }

    private func launchRestore(
        url: URL,
        mode: BackupRestoreMode,
        resolutions: [String: ConflictResolution],
        operation: Operation
    ) -> Task<Void, Never> {
        let task = Task { @MainActor [weak self, service] in
            guard let self else { return }
            await self.performRestore(
                url: url,
                mode: mode,
                resolutions: resolutions,
                operation: operation,
                service: service
            )
        }
        operationTask = task
        return task
    }

    private func performRestore(
        url: URL,
        mode: BackupRestoreMode,
        resolutions: [String: ConflictResolution],
        operation: Operation,
        service: any BackupSettingsServing
    ) async {
        do {
            _ = try await service.restoreBackup(
                from: url,
                mode: mode,
                resolvedConflicts: resolutions
            )
            guard activeOperation == operation else {
                finishStaleOperation(operation)
                return
            }
            conflictPresentation = nil
            pendingImportURL = nil
            finishDurableOperation(operation, outcome: .succeeded)
        } catch BackupRestoreError.restoreCommittedRefreshPending {
            guard activeOperation == operation else {
                finishStaleOperation(operation)
                return
            }
            conflictPresentation = nil
            pendingImportURL = nil
            finishDurableOperation(operation, outcome: .partiallySucceeded(.persistence))
        } catch {
            guard activeOperation == operation else {
                finishStaleOperation(operation)
                return
            }
            if canPublishTransient(operation) {
                alert = .restoreFailed(error.localizedDescription)
            }
            conflictPresentation = nil
            pendingImportURL = nil
            finishDurableOperation(
                operation,
                outcome: error is CancellationError ? .cancelled : .failed(.persistence)
            )
        }
        #if DEBUG
        restoreAttemptCompletionGeneration &+= 1
        #endif
    }

    private func publishRefreshSuccess(
        report: BackupRestoreReport?,
        operation: Operation
    ) {
        _ = report
        guard activeOperation == operation else {
            finishStaleOperation(operation)
            return
        }
        finishDurableOperation(operation, outcome: .succeeded)
    }

    private func publishRefreshFailure(operation: Operation) {
        guard activeOperation == operation else {
            finishStaleOperation(operation)
            return
        }
        finishDurableOperation(operation, outcome: .failed(.persistence))
    }

    private func publishAcknowledgmentSuccess(
        nextReport: BackupRestoreReport?,
        operation: Operation
    ) {
        _ = nextReport
        guard activeOperation == operation else {
            finishStaleOperation(operation)
            return
        }
        finishDurableOperation(operation, outcome: .succeeded)
    }

    private func publishOperationFailure(
        _ error: Error,
        alert: BackupSettingsAlert,
        operation: Operation
    ) {
        if operation.kind == .reportAcknowledgment {
            guard activeOperation == operation else {
                finishStaleOperation(operation)
                return
            }
            if canPublishTransient(operation) {
                self.alert = alert
            }
            finishDurableOperation(
                operation,
                outcome: error is CancellationError ? .cancelled : .failed(.persistence)
            )
            return
        }
        guard canPublishTransient(operation) else {
            finishStaleOperation(operation)
            return
        }
        self.alert = alert
        finishOperation(
            operation,
            outcome: error is CancellationError ? .cancelled : .failed(.persistence)
        )
    }

    private func canPublishTransient(_ operation: Operation) -> Bool {
        activeOperation == operation
            && operation.presentationGeneration == presentationGeneration
            && isPresentationActive
    }

    private func finishDurableOperation(
        _ operation: Operation,
        outcome: PresentationEventOutcome
    ) {
        guard activeOperation == operation else {
            logFinishedOnce(operation, outcome: .ignoredStale)
            return
        }
        logFinishedOnce(operation, outcome: outcome)
        activeOperation = nil
        operationKind = nil
        operationTask = nil
        if isPresentationActive {
            reconcileCanonicalPresentation(force: true)
        } else {
            canonicalPresentationNeedsReconciliation = true
        }
    }

    private func finishStaleOperation(_ operation: Operation) {
        logFinishedOnce(operation, outcome: .ignoredStale)
        guard activeOperation == operation else { return }
        activeOperation = nil
        operationKind = nil
        operationTask = nil
    }

    private func finishOperation(
        _ operation: Operation,
        outcome: PresentationEventOutcome
    ) {
        guard activeOperation == operation else { return }
        logFinishedOnce(operation, outcome: outcome)
        activeOperation = nil
        operationKind = nil
        operationTask = nil
    }

    private func logFinishedOnce(
        _ operation: Operation,
        outcome: PresentationEventOutcome
    ) {
        guard finalizedLogOperations.insert(operation.id).inserted else { return }
        presentationLogger.log(
            .finished(
                feature: .backupSettings,
                kind: presentationEventKind(for: operation.kind),
                operationID: operation.id,
                outcome: outcome
            )
        )
    }

    private func presentationEventKind(
        for kind: BackupSettingsOperationKind
    ) -> PresentationEventKind {
        switch kind {
        case .export:
            .backupExport
        case .mergeAnalysis:
            .backupMergeAnalysis
        case .restore:
            .backupRestore
        case .refreshRetry:
            .backupRefresh
        case .reportAcknowledgment:
            .backupReportAcknowledgment
        }
    }
}
