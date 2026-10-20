import Foundation
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class BackupSettingsViewModelTests: XCTestCase {
    func testInitialStateReflectsCanonicalReportAndRefreshPendingState() throws {
        let report = try backupSettingsTestReport(id: "ready")
        let subject = makeSubject(
            snapshot: BackupSettingsManagerSnapshot(
                isExporting: false,
                isRestoring: false,
                lastRestoreReport: report,
                committedRefreshPendingOperationId: "pending"
            )
        )

        XCTAssertEqual(subject.viewModel.managerSnapshot.lastRestoreReport, report)
        XCTAssertNil(subject.viewModel.activeRestoreReport)
        XCTAssertFalse(subject.viewModel.showsRestoreReport)
        XCTAssertTrue(subject.viewModel.showsRefreshPending)
        XCTAssertEqual(subject.viewModel.importPresentation, .idle)
        XCTAssertFalse(subject.viewModel.isOperationRunning)
        XCTAssertNil(subject.viewModel.alert)
    }

    func testExportSuccessPresentsExporterAndCompletionCleansState() async {
        let subject = makeSubject()
        let fileURL = url("generated.itobackup")
        subject.service.exportResponses = [.success(fileURL)]

        let task = subject.viewModel.beginExport()
        await task?.value

        XCTAssertEqual(subject.service.exportCallCount, 1)
        XCTAssertEqual(subject.viewModel.exportFileURL, fileURL)
        XCTAssertEqual(subject.viewModel.exportDefaultFilename, "generated.itobackup")
        XCTAssertTrue(subject.viewModel.isFileExporterPresented)
        XCTAssertEqual(subject.viewModel.operationKind, .export)
        subject.viewModel.fileExporterDidComplete(.success(url("destination.itobackup")))
        XCTAssertNil(subject.viewModel.exportFileURL)
        XCTAssertFalse(subject.viewModel.isFileExporterPresented)
        XCTAssertFalse(subject.viewModel.isOperationRunning)
    }

    func testExportCreationFailurePresentsExistingAlert() async {
        let subject = makeSubject()
        subject.service.exportResponses = [
            .failure(BackupSettingsTestError.expected("could not create backup"))
        ]

        await subject.viewModel.beginExport()?.value

        XCTAssertEqual(subject.viewModel.alert, .exportFailed("could not create backup"))
        XCTAssertFalse(subject.viewModel.isOperationRunning)
        XCTAssertFalse(subject.viewModel.isFileExporterPresented)
    }

    func testExporterFailurePresentsExistingAlert() async {
        let subject = makeSubject()
        await subject.viewModel.beginExport()?.value

        subject.viewModel.fileExporterDidComplete(
            .failure(BackupSettingsTestError.expected("exporter rejected destination"))
        )

        XCTAssertEqual(
            subject.viewModel.alert,
            .exportFailed("exporter rejected destination")
        )
        XCTAssertFalse(subject.viewModel.isOperationRunning)
    }

    func testDuplicateExportIsSynchronouslySuppressedThroughExporterCompletion() async {
        let subject = makeSubject()
        subject.service.exportResponses = [.suspended]

        let first = subject.viewModel.beginExport()
        let duplicate = subject.viewModel.beginExport()
        XCTAssertNil(duplicate)
        await subject.service.waitForPending(.export)
        XCTAssertEqual(subject.service.exportCallCount, 1)
        subject.service.resolveExport(.success(url("one.itobackup")))
        await first?.value

        XCTAssertNil(subject.viewModel.beginExport())
        subject.viewModel.fileExporterDidComplete(.success(url("saved.itobackup")))
        XCTAssertNotNil(subject.viewModel.beginExport())
    }

    func testCancellingSaveSheetWithoutCompletionFreesScreenAndLogsCancelled() async {
        let subject = makeSubject()
        await subject.viewModel.beginExport()?.value

        // iOS 15/16 only flips isPresented on cancel and never calls onCompletion.
        subject.viewModel.setFileExporterPresented(false)

        XCTAssertNil(subject.viewModel.exportFileURL)
        XCTAssertFalse(subject.viewModel.isOperationRunning)
        XCTAssertFalse(subject.viewModel.isExportDisabled)
        XCTAssertFalse(subject.viewModel.isImportDisabled)
        XCTAssertEqual(subject.logger.events.map(\.phase), [.started])

        XCTAssertNotNil(subject.viewModel.beginExport())
        XCTAssertEqual(subject.logger.events.map(\.phase), [.started, .finished, .started])
        XCTAssertEqual(subject.logger.events[1].outcome, .cancelled)
    }

    func testCompletionAfterSheetDismissalStillReportsOutcome() async {
        let subject = makeSubject()
        await subject.viewModel.beginExport()?.value

        subject.viewModel.setFileExporterPresented(false)
        subject.viewModel.fileExporterDidComplete(
            .failure(BackupSettingsTestError.expected("exporter rejected destination"))
        )

        XCTAssertEqual(subject.viewModel.alert, .exportFailed("exporter rejected destination"))
        XCTAssertEqual(subject.logger.events.last?.outcome, .failed(.persistence))

        subject.viewModel.screenDidDisappear()
        XCTAssertEqual(subject.logger.events.map(\.phase), [.started, .finished])
    }

    func testImporterSuccessSelectsExactURLAndPresentsStrategy() {
        let subject = makeSubject()
        let selectedURL = url("selected.itobackup")

        XCTAssertTrue(subject.viewModel.requestImport())
        subject.viewModel.fileImporterDidComplete(.success([selectedURL]))

        XCTAssertEqual(subject.viewModel.pendingImportURL, selectedURL)
        XCTAssertEqual(subject.viewModel.importPresentation, .restoreStrategy)
        XCTAssertTrue(subject.viewModel.showsRestoreStrategy)
    }

    func testImporterFailurePresentsExistingAlert() {
        let subject = makeSubject()
        _ = subject.viewModel.requestImport()

        subject.viewModel.fileImporterDidComplete(
            .failure(BackupSettingsTestError.expected("picker failed"))
        )

        XCTAssertEqual(subject.viewModel.importPresentation, .idle)
        XCTAssertEqual(subject.viewModel.alert, .importFailed("picker failed"))
    }

    func testImporterResultIsSynchronouslyRejectedDuringConflictingOperation() async {
        let subject = makeSubject()
        subject.service.exportResponses = [.suspended]
        let exportTask = subject.viewModel.beginExport()
        await subject.service.waitForPending(.export)

        subject.viewModel.fileImporterDidComplete(.success([url("rejected.itobackup")]))

        XCTAssertNil(subject.viewModel.pendingImportURL)
        XCTAssertEqual(subject.viewModel.importPresentation, .idle)
        subject.service.resolveExport(.failure(BackupSettingsTestError.expected("done")))
        await exportTask?.value
    }

    func testStrategyCancelClearsPendingImportWithoutRestore() {
        let subject = makeSubject()
        subject.viewModel.selectImportURL(url("cancel.itobackup"))

        subject.viewModel.cancelRestoreStrategy()

        XCTAssertNil(subject.viewModel.pendingImportURL)
        XCTAssertEqual(subject.viewModel.importPresentation, .idle)
        XCTAssertTrue(subject.service.restoreRequests.isEmpty)
    }

    func testFirstWipeDecisionOnlyPresentsSecondConfirmation() {
        let subject = makeSubject()
        let selectedURL = url("wipe.itobackup")
        subject.viewModel.selectImportURL(selectedURL)
        subject.viewModel.setRestoreStrategyPresented(false)

        subject.viewModel.chooseWipeStrategy()

        XCTAssertEqual(subject.viewModel.importPresentation, .wipeConfirmation)
        XCTAssertEqual(subject.viewModel.pendingImportURL, selectedURL)
        XCTAssertTrue(subject.viewModel.showsWipeConfirmation)
        XCTAssertTrue(subject.service.restoreRequests.isEmpty)
        XCTAssertFalse(subject.viewModel.isOperationRunning)
    }

    func testSecondWipeConfirmationRestoresExactURLExactlyOnce() async throws {
        let subject = makeSubject()
        let selectedURL = url("wipe-exact.itobackup")
        let report = try backupSettingsTestReport(id: "wipe", mode: .wipe)
        subject.service.restoreResponses = [.success(report)]
        subject.viewModel.selectImportURL(selectedURL)
        subject.viewModel.chooseWipeStrategy()
        subject.viewModel.setWipeConfirmationPresented(false)

        let first = subject.viewModel.confirmWipeRestore()
        let duplicate = subject.viewModel.confirmWipeRestore()
        XCTAssertNil(duplicate)
        await first?.value

        XCTAssertEqual(
            subject.service.restoreRequests,
            [.init(url: selectedURL, mode: .wipe, resolutions: [:])]
        )
        XCTAssertEqual(subject.viewModel.activeRestoreReport, report)
        XCTAssertNil(subject.viewModel.pendingImportURL)
    }

    func testWipeConfirmationCancelDoesNotRestore() {
        let subject = makeSubject()
        subject.viewModel.selectImportURL(url("cancel-wipe.itobackup"))
        subject.viewModel.chooseWipeStrategy()

        subject.viewModel.cancelWipeConfirmation()

        XCTAssertNil(subject.viewModel.pendingImportURL)
        XCTAssertEqual(subject.viewModel.importPresentation, .idle)
        XCTAssertTrue(subject.service.restoreRequests.isEmpty)
    }

    func testMergeAnalysisWithoutConflictsDirectlyRestoresUnderOneClaim() async throws {
        let subject = makeSubject()
        let selectedURL = url("merge-clean.itobackup")
        let report = try backupSettingsTestReport(id: "merge-clean")
        subject.service.analysisResponses = [.success([])]
        subject.service.restoreResponses = [.success(report)]
        subject.viewModel.selectImportURL(selectedURL)

        await subject.viewModel.chooseMergeStrategy()?.value

        XCTAssertEqual(subject.service.operations, [.mergeAnalysis, .restore])
        XCTAssertEqual(subject.service.analysisURLs, [selectedURL])
        XCTAssertEqual(
            subject.service.restoreRequests,
            [.init(url: selectedURL, mode: .merge, resolutions: [:])]
        )
        XCTAssertEqual(subject.viewModel.activeRestoreReport, report)
        XCTAssertFalse(subject.viewModel.isOperationRunning)
    }

    func testMergeAnalysisWithConflictsPresentsResolverForExactURL() async {
        let subject = makeSubject()
        let selectedURL = url("merge-conflict.itobackup")
        let conflict = makeConflict(id: "conflict")
        subject.service.analysisResponses = [.success([conflict])]
        subject.viewModel.selectImportURL(selectedURL)

        await subject.viewModel.chooseMergeStrategy()?.value

        XCTAssertEqual(
            subject.viewModel.conflictPresentation,
            BackupConflictPresentation(sourceURL: selectedURL, conflicts: [conflict])
        )
        XCTAssertTrue(subject.viewModel.showsConflictResolver)
        XCTAssertTrue(subject.service.restoreRequests.isEmpty)
        XCTAssertFalse(subject.viewModel.isOperationRunning)
    }

    func testMergeAnalysisFailurePresentsExistingAlertAndReleasesClaim() async {
        let subject = makeSubject()
        subject.service.analysisResponses = [
            .failure(BackupSettingsTestError.expected("analysis failed"))
        ]
        subject.viewModel.selectImportURL(url("analysis-failure.itobackup"))

        await subject.viewModel.chooseMergeStrategy()?.value

        XCTAssertEqual(subject.viewModel.alert, .mergeCheckFailed("analysis failed"))
        XCTAssertFalse(subject.viewModel.isOperationRunning)
        XCTAssertNotNil(subject.viewModel.pendingImportURL)
    }

    func testConflictResolveBuildsIDMappingAndRestoresExactSource() async throws {
        let subject = makeSubject()
        let selectedURL = url("resolved.itobackup")
        let first = makeConflict(id: "first")
        let second = makeConflict(id: "second")
        subject.service.analysisResponses = [.success([first, second])]
        subject.service.restoreResponses = [
            .success(try backupSettingsTestReport(id: "resolved"))
        ]
        subject.viewModel.selectImportURL(selectedURL)
        await subject.viewModel.chooseMergeStrategy()?.value
        var conflicts = try XCTUnwrap(subject.viewModel.conflictPresentation?.conflicts)
        conflicts[0].resolution = .keepBackup
        conflicts[1].resolution = .keepLocal
        subject.viewModel.updateConflicts(conflicts)

        await subject.viewModel.resolveConflicts()?.value

        XCTAssertNil(subject.viewModel.conflictPresentation)
        XCTAssertEqual(
            subject.service.restoreRequests,
            [
                .init(
                    url: selectedURL,
                    mode: .merge,
                    resolutions: ["first": .keepBackup, "second": .keepLocal]
                )
            ]
        )
    }

    func testConflictCancelClearsSourceAndPendingImportWithoutRestore() async {
        let subject = makeSubject()
        subject.service.analysisResponses = [.success([makeConflict(id: "cancel")])]
        subject.viewModel.selectImportURL(url("cancel-conflict.itobackup"))
        await subject.viewModel.chooseMergeStrategy()?.value

        subject.viewModel.cancelConflictResolution()

        XCTAssertNil(subject.viewModel.conflictPresentation)
        XCTAssertNil(subject.viewModel.pendingImportURL)
        XCTAssertTrue(subject.service.restoreRequests.isEmpty)
    }

    func testDuplicateMergeAnalysisIsSynchronouslySuppressed() async {
        let subject = makeSubject()
        subject.service.analysisResponses = [.suspended]
        subject.viewModel.selectImportURL(url("merge-duplicate.itobackup"))

        let first = subject.viewModel.chooseMergeStrategy()
        let duplicate = subject.viewModel.chooseMergeStrategy()
        XCTAssertNil(duplicate)
        await subject.service.waitForPending(.mergeAnalysis)
        XCTAssertEqual(subject.service.analysisURLs.count, 1)
        subject.service.resolveAnalysis(.success([makeConflict(id: "done")]))
        await first?.value
        XCTAssertFalse(subject.viewModel.isOperationRunning)
    }

    func testRestoreFailurePresentsExistingAlertAndClearsImportState() async {
        let subject = makeSubject()
        subject.service.restoreResponses = [
            .failure(BackupSettingsTestError.expected("restore failed"))
        ]
        subject.viewModel.selectImportURL(url("restore-failure.itobackup"))
        subject.viewModel.chooseWipeStrategy()

        await subject.viewModel.confirmWipeRestore()?.value

        XCTAssertEqual(subject.viewModel.alert, .restoreFailed("restore failed"))
        XCTAssertNil(subject.viewModel.pendingImportURL)
        XCTAssertNil(subject.viewModel.conflictPresentation)
        XCTAssertFalse(subject.viewModel.isOperationRunning)
    }

    func testCommittedRefreshPendingUsesDedicatedPresentationNotRestoreFailure() async {
        let subject = makeSubject()
        subject.service.restoreResponses = [
            .failure(BackupRestoreError.restoreCommittedRefreshPending(operationId: "committed"))
        ]
        subject.viewModel.selectImportURL(url("committed.itobackup"))
        subject.viewModel.chooseWipeStrategy()

        await subject.viewModel.confirmWipeRestore()?.value

        XCTAssertTrue(subject.viewModel.showsRefreshPending)
        XCTAssertNil(subject.viewModel.alert)
        XCTAssertNil(subject.viewModel.pendingImportURL)
        XCTAssertNil(subject.viewModel.activeRestoreReport)
    }

    func testRefreshRetrySuccessPresentsAuthoritativeReadyReport() async throws {
        let report = try backupSettingsTestReport(id: "retried")
        let subject = pendingRefreshSubject()
        subject.service.reportAfterRefresh = report
        subject.service.refreshResponses = [.success(())]
        subject.viewModel.setRefreshPendingPresented(false)

        await subject.viewModel.retryCommittedRefresh()?.value

        XCTAssertEqual(subject.service.refreshCallCount, 1)
        XCTAssertEqual(subject.viewModel.activeRestoreReport, report)
        XCTAssertFalse(subject.viewModel.showsRefreshPending)
        XCTAssertFalse(subject.viewModel.isOperationRunning)
    }

    func testRefreshRetryFailureRePresentsCommittedStateWithoutRollbackAlert() async {
        let subject = pendingRefreshSubject()
        subject.service.refreshResponses = [
            .failure(BackupSettingsTestError.expected("still pending"))
        ]

        await subject.viewModel.retryCommittedRefresh()?.value

        XCTAssertTrue(subject.viewModel.showsRefreshPending)
        XCTAssertNil(subject.viewModel.alert)
        XCTAssertNil(subject.viewModel.activeRestoreReport)
        XCTAssertFalse(subject.viewModel.isOperationRunning)
    }

    func testDuplicateRefreshRetryIsSynchronouslySuppressed() async {
        let subject = pendingRefreshSubject()
        subject.service.refreshResponses = [.suspended]

        let first = subject.viewModel.retryCommittedRefresh()
        XCTAssertNil(subject.viewModel.retryCommittedRefresh())
        await subject.service.waitForPending(.refreshRetry)
        XCTAssertEqual(subject.service.refreshCallCount, 1)
        subject.service.resolveRefresh(.success(()))
        await first?.value
    }

    func testRefreshRetryOwnershipIsSharedAcrossViewModelsDuringNavigation() async throws {
        let service = BackupSettingsServiceFake(
            snapshot: BackupSettingsManagerSnapshot(
                isExporting: false,
                isRestoring: false,
                lastRestoreReport: nil,
                committedRefreshPendingOperationId: "pending"
            )
        )
        service.refreshResponses = [.suspended, .success(())]
        let dependencies = PreparedBackupSettingsDependencies(service: service)
        let logger = PresentationEventCaptureSpy()
        var firstViewModel: BackupSettingsViewModel? = BackupSettingsViewModel(
            dependencies: dependencies,
            presentationLogger: logger
        )

        let first = try XCTUnwrap(firstViewModel?.retryCommittedRefresh())
        await service.waitForPending(.refreshRetry)
        firstViewModel?.screenDidDisappear()
        firstViewModel = nil

        let replacementViewModel = BackupSettingsViewModel(
            dependencies: dependencies,
            presentationLogger: logger
        )
        XCTAssertNil(replacementViewModel.retryCommittedRefresh())
        XCTAssertFalse(replacementViewModel.isOperationRunning)
        XCTAssertEqual(service.refreshCallCount, 1)

        service.resolveRefresh(.failure(BackupSettingsTestError.expected("still pending")))
        await first.value

        let later = try XCTUnwrap(replacementViewModel.retryCommittedRefresh())
        await later.value
        XCTAssertEqual(service.refreshCallCount, 2)
    }

    func testAcknowledgmentSuccessDismissesWhenNoAuthoritativeReportRemains() async throws {
        let report = try backupSettingsTestReport(id: "acknowledge")
        let subject = reportSubject(report)
        subject.service.reportsAfterAcknowledgment = [nil]

        await subject.viewModel.acknowledgeRestoreReport()?.value

        XCTAssertEqual(subject.service.acknowledgmentCallCount, 1)
        XCTAssertNil(subject.viewModel.activeRestoreReport)
        XCTAssertFalse(subject.viewModel.showsRestoreReport)
    }

    func testAcknowledgmentFailureKeepsUnacknowledgedReportVisible() async throws {
        let report = try backupSettingsTestReport(id: "unacknowledged")
        let subject = reportSubject(report)
        subject.service.acknowledgmentResponses = [
            .failure(BackupSettingsTestError.expected("ack failed"))
        ]

        await subject.viewModel.acknowledgeRestoreReport()?.value

        XCTAssertEqual(subject.viewModel.activeRestoreReport, report)
        XCTAssertTrue(subject.viewModel.showsRestoreReport)
        XCTAssertEqual(subject.viewModel.alert, .acknowledgmentFailed("ack failed"))
    }

    func testAcknowledgmentChainsAuthoritativeReadyReports() async throws {
        let first = try backupSettingsTestReport(id: "first", createdAt: 1)
        let second = try backupSettingsTestReport(id: "second", createdAt: 2)
        let subject = reportSubject(first)
        subject.service.reportsAfterAcknowledgment = [second, nil]

        await subject.viewModel.acknowledgeRestoreReport()?.value
        XCTAssertEqual(subject.viewModel.activeRestoreReport, second)
        XCTAssertTrue(subject.viewModel.showsRestoreReport)
        await subject.viewModel.acknowledgeRestoreReport()?.value

        XCTAssertNil(subject.viewModel.activeRestoreReport)
        XCTAssertEqual(subject.service.acknowledgmentCallCount, 2)
    }

    func testDuplicateAcknowledgmentIsSynchronouslySuppressed() async throws {
        let subject = reportSubject(try backupSettingsTestReport(id: "duplicate-ack"))
        subject.service.acknowledgmentResponses = [.suspended]

        let first = subject.viewModel.acknowledgeRestoreReport()
        XCTAssertNil(subject.viewModel.acknowledgeRestoreReport())
        await subject.service.waitForPending(.reportAcknowledgment)
        XCTAssertEqual(subject.service.acknowledgmentCallCount, 1)
        subject.service.resolveAcknowledgment(.success(true))
        await first?.value
    }

    func testNonCooperativeStaleAnalysisCannotReplaceNewerPresentation() async {
        let subject = makeSubject()
        let urlA = url("a.itobackup")
        let urlB = url("b.itobackup")
        let conflictA = makeConflict(id: "a")
        let conflictB = makeConflict(id: "b")
        subject.service.analysisResponses = [.suspended, .success([conflictB])]
        subject.viewModel.selectImportURL(urlA)
        let taskA = subject.viewModel.chooseMergeStrategy()
        await subject.service.waitForPending(.mergeAnalysis)

        subject.viewModel.screenDidDisappear()
        subject.viewModel.screenDidAppear()
        subject.viewModel.selectImportURL(urlB)
        await subject.viewModel.chooseMergeStrategy()?.value
        subject.viewModel.fileImporterDidComplete(
            .failure(BackupSettingsTestError.expected("newer alert"))
        )
        subject.service.resolveAnalysis(.success([conflictA]))
        await taskA?.value

        XCTAssertEqual(subject.service.analysisURLs, [urlA, urlB])
        XCTAssertEqual(subject.viewModel.conflictPresentation?.sourceURL, urlB)
        XCTAssertEqual(subject.viewModel.conflictPresentation?.conflicts, [conflictB])
        XCTAssertEqual(subject.viewModel.alert, .importFailed("newer alert"))
        XCTAssertTrue(subject.service.restoreRequests.isEmpty)
    }

    func testDurableRestoreContinuesAfterScreenDisappearsButSuppressesStaleUI() async throws {
        let subject = makeSubject()
        let report = try backupSettingsTestReport(id: "durable", mode: .wipe)
        subject.service.restoreResponses = [.suspended]
        subject.viewModel.selectImportURL(url("durable.itobackup"))
        subject.viewModel.chooseWipeStrategy()
        let task = subject.viewModel.confirmWipeRestore()
        await subject.service.waitForPending(.restore)

        subject.viewModel.screenDidDisappear()
        subject.service.resolveRestore(.success(report))
        await task?.value

        XCTAssertEqual(subject.service.restoreRequests.count, 1)
        XCTAssertNil(subject.viewModel.activeRestoreReport)
        XCTAssertFalse(subject.viewModel.isOperationRunning)
        subject.viewModel.screenDidAppear()
        XCTAssertEqual(subject.viewModel.activeRestoreReport, report)
    }

    func testManagerBusyStateSynchronouslyDisablesAndRejectsIntents() {
        let subject = makeSubject(
            snapshot: BackupSettingsManagerSnapshot(
                isExporting: true,
                isRestoring: false,
                lastRestoreReport: nil,
                committedRefreshPendingOperationId: nil
            )
        )

        XCTAssertTrue(subject.viewModel.isBusy)
        XCTAssertTrue(subject.viewModel.isExportDisabled)
        XCTAssertTrue(subject.viewModel.isImportDisabled)
        XCTAssertNil(subject.viewModel.beginExport())
        XCTAssertFalse(subject.viewModel.requestImport())

        subject.service.publish(
            BackupSettingsManagerSnapshot(
                isExporting: false,
                isRestoring: false,
                lastRestoreReport: nil,
                committedRefreshPendingOperationId: nil
            )
        )
        XCTAssertFalse(subject.viewModel.isBusy)
        XCTAssertTrue(subject.viewModel.requestImport())
    }

    func testTypedLoggingIsCompleteAndRedactsURLsPathsAndRawErrors() async {
        let subject = makeSubject()
        let secret = "/private/secret/backup.itobackup"
        subject.service.exportResponses = [.success(URL(fileURLWithPath: secret))]

        await subject.viewModel.beginExport()?.value
        subject.viewModel.fileExporterDidComplete(
            .failure(BackupSettingsTestError.expected("raw error \(secret)"))
        )

        XCTAssertEqual(subject.logger.events.count, 2)
        XCTAssertEqual(subject.logger.events.map(\.feature), [.backupSettings, .backupSettings])
        XCTAssertEqual(subject.logger.events.map(\.kind), [.backupExport, .backupExport])
        XCTAssertEqual(subject.logger.events.map(\.phase), [.started, .finished])
        XCTAssertEqual(subject.logger.events.last?.outcome, .failed(.persistence))
        XCTAssertFalse(subject.logger.formattedMessages.joined().contains("private"))
        XCTAssertFalse(subject.logger.formattedMessages.joined().contains("itobackup"))
        XCTAssertFalse(subject.logger.formattedMessages.joined().contains("raw error"))
    }

    private struct Subject {
        let viewModel: BackupSettingsViewModel
        let service: BackupSettingsServiceFake
        let logger: PresentationEventCaptureSpy
    }

    private func makeSubject(
        snapshot: BackupSettingsManagerSnapshot = BackupSettingsManagerSnapshot(
            isExporting: false,
            isRestoring: false,
            lastRestoreReport: nil,
            committedRefreshPendingOperationId: nil
        )
    ) -> Subject {
        let service = BackupSettingsServiceFake(snapshot: snapshot)
        let logger = PresentationEventCaptureSpy()
        return Subject(
            viewModel: BackupSettingsViewModel(
                dependencies: PreparedBackupSettingsDependencies(service: service),
                presentationLogger: logger
            ),
            service: service,
            logger: logger
        )
    }

    private func pendingRefreshSubject() -> Subject {
        makeSubject(
            snapshot: BackupSettingsManagerSnapshot(
                isExporting: false,
                isRestoring: false,
                lastRestoreReport: nil,
                committedRefreshPendingOperationId: "pending"
            )
        )
    }

    private func reportSubject(_ report: BackupRestoreReport) -> Subject {
        makeSubject(
            snapshot: BackupSettingsManagerSnapshot(
                isExporting: false,
                isRestoring: false,
                lastRestoreReport: report,
                committedRefreshPendingOperationId: nil
            )
        )
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    private func makeConflict(id: String) -> MergeConflict {
        MergeConflict(
            item: LibraryItem(
                id: id,
                title: "Conflict \(id)",
                coverUrl: nil,
                pluginId: "plugin",
                isAnime: false,
                pluginType: .manga,
                rawPayload: Data(),
                anilistId: nil
            ),
            localCategoryName: "Local",
            backupCategoryName: "Backup",
            localHistoryCount: 1,
            backupHistoryCount: 2
        )
    }
}
