import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    @StateObject private var viewModel: BackupSettingsViewModel
    private let makeMigrationReportViewModel: (MigrationReport) -> MigrationReportViewModel
    #if DEBUG
    @ObservedObject private var uiTestFixtures = UITestLaunchFixtureCoordinator.shared
    #endif

    init(
        viewModel: BackupSettingsViewModel,
        makeMigrationReportViewModel: @escaping (MigrationReport) -> MigrationReportViewModel
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.makeMigrationReportViewModel = makeMigrationReportViewModel
    }

    var body: some View {
        List {
            #if DEBUG
            if UITestLaunchConfiguration.current.backupWipeEnabled {
                Section("UI Test Fixture") {
                    Text(uiTestFixtures.backupFixtureState.rawValue)
                        .accessibilityIdentifier("backup-fixture-state")
                }
            }
            #endif

            Section(header: Text("Export")) {
                Button(action: { _ = viewModel.beginExport() }) {
                    HStack {
                        Label("Create Backup", systemImage: "square.and.arrow.up")
                        Spacer()
                        if viewModel.managerSnapshot.isExporting {
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isExportDisabled)
            }

            Section(
                header: Text("Import"),
                footer: Text("Restore a backup by merging it into your current library, or by replacing your library with it.")
            ) {
                Button(action: requestImport) {
                    HStack {
                        Label("Restore from Backup", systemImage: "square.and.arrow.down")
                        Spacer()
                        if viewModel.managerSnapshot.isRestoring
                            || viewModel.operationKind == .mergeAnalysis
                            || viewModel.operationKind == .restore {
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isImportDisabled)
                .disabled(uiTestRestoreUnavailable)
            }
        }
        .navigationTitle("Backup & Restore")
        .fileExporter(
            isPresented: Binding(
                get: { viewModel.isFileExporterPresented },
                set: { viewModel.setFileExporterPresented($0) }
            ),
            document: viewModel.exportFileURL.map { BackupDocument(url: $0) },
            contentType: .itoBackup,
            defaultFilename: viewModel.exportDefaultFilename,
            onCompletion: { viewModel.fileExporterDidComplete($0) }
        )
        .fileImporter(
            isPresented: Binding(
                get: { viewModel.isFileImporterPresented },
                set: { viewModel.setFileImporterPresented($0) }
            ),
            allowedContentTypes: [.itoBackup, .aidokuBackup, .paperbackBackup, .data],
            allowsMultipleSelection: false,
            onCompletion: { viewModel.fileImporterDidComplete($0) }
        )
        .confirmationDialog(
            "How would you like to restore?",
            isPresented: Binding(
                get: { viewModel.showsRestoreStrategy },
                set: { viewModel.setRestoreStrategyPresented($0) }
            ),
            titleVisibility: .visible
        ) {
            Button("Merge with Current Library") {
                _ = viewModel.chooseMergeStrategy()
            }
            Button("Wipe and Replace Library", role: .destructive) {
                viewModel.chooseWipeStrategy()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelRestoreStrategy()
            }
        } message: {
            Text("Merging adds missing items and lets you choose which version to keep when an item differs. Wiping deletes your current library and replaces it with the backup.")
        }
        .alert(
            "Wipe and Replace Library?",
            isPresented: Binding(
                get: { viewModel.showsWipeConfirmation },
                set: { viewModel.setWipeConfirmationPresented($0) }
            )
        ) {
            Button("Wipe and Replace", role: .destructive) {
                _ = viewModel.confirmWipeRestore()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelWipeConfirmation()
            }
        } message: {
            Text("This permanently deletes your current library before restoring the backup. This action cannot be undone.")
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.showsConflictResolver },
                set: { viewModel.setConflictResolverPresented($0) }
            )
        ) {
            if viewModel.conflictPresentation != nil {
                MergeResolverView(
                    conflicts: Binding(
                        get: { viewModel.conflictPresentation?.conflicts ?? [] },
                        set: { viewModel.updateConflicts($0) }
                    ),
                    onResolve: { _ = viewModel.resolveConflicts() },
                    onCancel: viewModel.cancelConflictResolution
                )
                .interactiveDismissDisabled()
            }
        }
        // While the restore report sheet is up, its content shows alerts instead: a
        // presenting view cannot present a second modal on iOS 15.
        .alert(item: Binding(
            get: { viewModel.showsRestoreReport ? nil : viewModel.alert },
            set: { if $0 == nil { viewModel.dismissAlert() } }
        ), content: makeAlert)
        .sheet(
            isPresented: Binding(
                get: { viewModel.showsRestoreReport },
                set: { viewModel.setRestoreReportPresented($0) }
            ),
            onDismiss: viewModel.restoreReportDidDismiss
        ) {
            if let report = viewModel.activeRestoreReport {
                BackupRestoreReportView(
                    report: report,
                    onAcknowledge: { _ = viewModel.acknowledgeRestoreReport() }
                )
                .interactiveDismissDisabled()
                .alert(item: Binding(
                    get: { viewModel.showsRestoreReport ? viewModel.alert : nil },
                    set: { if $0 == nil { viewModel.dismissAlert() } }
                ), content: makeAlert)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.migrationReportToResolve != nil },
                set: { if !$0 { viewModel.dismissMigrationReport() } }
            )
        ) {
            if let report = viewModel.migrationReportToResolve {
                NavigationView {
                    MigrationReportView(
                        viewModel: makeMigrationReportViewModel(report),
                        onDismiss: viewModel.dismissMigrationReport
                    )
                }
                .navigationViewStyle(.stack)
            }
        }
        .alert(
            "Restore committed; refresh pending",
            isPresented: Binding(
                get: { viewModel.showsRefreshPending },
                set: { viewModel.setRefreshPendingPresented($0) }
            )
        ) {
            Button("Retry") {
                _ = viewModel.retryCommittedRefresh()
            }
            Button("Not Now", role: .cancel) {
                viewModel.deferCommittedRefresh()
            }
        } message: {
            Text("Your restored data is saved. Refresh must finish before a report can be shown.")
        }
        .onAppear(perform: viewModel.screenDidAppear)
        .onDisappear(perform: viewModel.screenDidDisappear)
        #if DEBUG
        .onChange(of: viewModel.restoreAttemptCompletionGeneration) { _ in
            Task { await uiTestFixtures.refreshBackupFixtureState() }
        }
        #endif
    }

    private func makeAlert(_ alert: BackupSettingsAlert) -> Alert {
        Alert(
            title: Text(alert.title),
            message: Text(alert.message),
            dismissButton: .default(Text("OK"), action: viewModel.dismissAlert)
        )
    }

    private func requestImport() {
        #if DEBUG
        if UITestLaunchConfiguration.current.backupWipeEnabled {
            guard let backupURL = uiTestFixtures.backupURL else { return }
            viewModel.selectImportURL(backupURL)
            return
        }
        #endif
        viewModel.requestImport()
    }

    private var uiTestRestoreUnavailable: Bool {
        #if DEBUG
        return UITestLaunchConfiguration.current.backupWipeEnabled
            && uiTestFixtures.backupURL == nil
        #else
        return false
        #endif
    }
}

struct BackupSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            BackupSettingsView(
                viewModel: BackupSettingsViewModel(
                    dependencies: .unavailable(),
                    presentationLogger: OSLogPresentationEventLogger()
                ),
                makeMigrationReportViewModel: { MigrationReportViewModel(readOnlyReport: $0) }
            )
        }
    }
}
