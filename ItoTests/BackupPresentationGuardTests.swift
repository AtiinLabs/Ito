import Foundation
import Testing
@testable import Ito

struct BackupPresentationGuardTests {
    @MainActor
    @Test func operationOwnershipRejectsRapidDuplicatesUntilReleased() async {
        let service = BackupSettingsServiceFake()
        service.analysisResponses = [.suspended]
        let viewModel = BackupSettingsViewModel(
            dependencies: PreparedBackupSettingsDependencies(service: service),
            presentationLogger: PresentationEventCaptureSpy()
        )
        let url = URL(fileURLWithPath: "/tmp/guard.itobackup")
        viewModel.selectImportURL(url)

        let first = viewModel.chooseMergeStrategy()
        let duplicate = viewModel.chooseMergeStrategy()
        #expect(first != nil)
        #expect(duplicate == nil)
        #expect(viewModel.isOperationRunning)
        await service.waitForPending(.mergeAnalysis)
        #expect(service.analysisURLs == [url])

        service.resolveAnalysis(.success([]))
        await first?.value
        #expect(!viewModel.isOperationRunning)
        #expect(service.restoreRequests.count == 1)
    }

    @Test func productionBindingRequiresTwoWipeConfirmationsAndSynchronousGuards() throws {
        let viewSource = try read("Ito/Views/Settings/BackupSettingsView.swift")
        let viewModelSource = try read("Ito/ViewModels/BackupSettingsViewModel.swift")

        #expect(viewSource.contains("@StateObject private var viewModel: BackupSettingsViewModel"))
        let strategyDialog = try #require(
            viewSource.range(of: ".confirmationDialog(")
        )
        let wipeAlert = try #require(
            viewSource.range(
                of: "\"Wipe and Replace Library?\"",
                range: strategyDialog.upperBound..<viewSource.endIndex
            )
        )
        let strategyBody = viewSource[strategyDialog.lowerBound..<wipeAlert.lowerBound]
        #expect(strategyBody.contains("Button(\"Wipe and Replace Library\", role: .destructive)"))
        #expect(strategyBody.contains("viewModel.chooseWipeStrategy()"))
        #expect(!strategyBody.contains("confirmWipeRestore"))
        #expect(!strategyBody.contains("restoreBackup"))
        #expect(strategyBody.contains("viewModel.cancelRestoreStrategy()"))

        let conflictSheet = try #require(
            viewSource.range(
                of: ".sheet(",
                range: wipeAlert.upperBound..<viewSource.endIndex
            )
        )
        let wipeAlertBody = viewSource[wipeAlert.lowerBound..<conflictSheet.lowerBound]
        #expect(wipeAlertBody.contains("Button(\"Wipe and Replace\", role: .destructive)"))
        #expect(wipeAlertBody.contains("viewModel.confirmWipeRestore()"))
        #expect(wipeAlertBody.contains("viewModel.cancelWipeConfirmation()"))

        let firstWipeDecision = try functionBody(
            named: "func chooseWipeStrategy()",
            next: "func setWipeConfirmationPresented",
            in: viewModelSource
        )
        #expect(firstWipeDecision.contains("importPresentation = .wipeConfirmation"))
        #expect(!firstWipeDecision.contains("claimOperation"))
        #expect(!firstWipeDecision.contains("launchRestore"))
        #expect(!firstWipeDecision.contains("restoreBackup"))

        let finalWipeDecision = try functionBody(
            named: "func confirmWipeRestore()",
            next: "func chooseMergeStrategy",
            in: viewModelSource
        )
        try assertSynchronousClaimBeforeTaskLaunch(in: finalWipeDecision)
        #expect(finalWipeDecision.contains("let url = pendingImportURL"))
        #expect(finalWipeDecision.contains("mode: .wipe"))
        #expect(finalWipeDecision.contains("resolutions: [:]"))

        for (name, next) in [
            ("func beginExport()", "func setFileExporterPresented"),
            ("func chooseMergeStrategy()", "func updateConflicts"),
            ("func retryCommittedRefresh()", "func setRefreshPendingPresented"),
            ("func acknowledgeRestoreReport()", "func setRestoreReportPresented")
        ] {
            let body = try functionBody(named: name, next: next, in: viewModelSource)
            try assertSynchronousClaimBeforeTaskLaunch(in: body)
        }

        let noConflictMerge = try body(
            in: viewModelSource,
            from: "if conflicts.isEmpty {",
            through: "} else {"
        )
        #expect(noConflictMerge.contains("activeOperation = restoreOperation"))
        #expect(noConflictMerge.contains("await performRestore("))
        #expect(!noConflictMerge.contains("claimOperation"))
        #expect(!noConflictMerge.contains("launchRestore"))

        #expect(viewModelSource.contains("let sourceURL: URL"))
        #expect(viewModelSource.contains("url: presentation.sourceURL"))
        #expect(viewModelSource.contains("($0.id, $0.resolution)"))
        #expect(viewModelSource.contains("guard activeOperation == operation else { return }"))
    }

    private func assertSynchronousClaimBeforeTaskLaunch(in source: Substring) throws {
        let claim = try #require(source.range(of: "claimOperation("))
        let taskOrLaunch = source.range(of: "Task {") ?? source.range(of: "launchRestore(")
        let launch = try #require(taskOrLaunch)
        #expect(claim.lowerBound < launch.lowerBound)
    }

    private func functionBody(
        named name: String,
        next nextName: String,
        in source: String
    ) throws -> Substring {
        let start = try #require(source.range(of: name))
        let end = try #require(
            source.range(of: nextName, range: start.upperBound..<source.endIndex)
        )
        return source[start.lowerBound..<end.lowerBound]
    }

    private func body(
        in source: String,
        from startText: String,
        through endText: String
    ) throws -> Substring {
        let start = try #require(source.range(of: startText))
        let end = try #require(
            source.range(of: endText, range: start.upperBound..<source.endIndex)
        )
        return source[start.lowerBound..<end.upperBound]
    }

    private func read(_ path: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryURL = testsURL.deletingLastPathComponent()
        return try String(contentsOf: repositoryURL.appendingPathComponent(path), encoding: .utf8)
    }
}
