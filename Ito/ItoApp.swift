import BackgroundTasks
import OSLog
import SwiftUI

@main
@MainActor
struct ItoApp: App {
    @StateObject private var bootstrap = DurableStateBootstrap.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The handler is MainActor-isolated in this target, so iOS must call it on the main queue;
        // with no queue it runs on a background one and fails the runtime isolation check.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "moe.itoapp.ito.refresh", using: .main) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Self.handleAppRefresh(task: refreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            BootstrapGateView(bootstrap: bootstrap)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                Task { await Self.scheduleAppRefresh(bootstrap: bootstrap) }
            case .active:
                // Notifications may have been allowed in iOS Settings since the last check.
                Task { await bootstrap.notificationManager?.checkStatus() }
            default:
                break
            }
        }
    }

    private static func scheduleAppRefresh(bootstrap: DurableStateBootstrap) async {
        guard await bootstrap.prepare() else { return }
        do {
            guard let settingsStore = bootstrap.settingsStore,
                  settingsStore.backgroundUpdatesEnabled else { return }

            let request = BGAppRefreshTaskRequest(identifier: "moe.itoapp.ito.refresh")
            request.earliestBeginDate = Date(
                timeIntervalSinceNow: TimeInterval(settingsStore.updateInterval.rawValue * 3_600)
            )
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLogger.general.error("Failed to schedule app refresh: \(error)")
        }
    }

    private static func handleAppRefresh(task: BGAppRefreshTask) {
        let completion = BackgroundTaskCompletion(task: task)
        let taskWrapper = Task { @MainActor in
            let bootstrap = DurableStateBootstrap.shared
            guard await bootstrap.prepare() else {
                completion.finish(success: false)
                return
            }

            await scheduleAppRefresh(bootstrap: bootstrap)
            guard let updateManager = bootstrap.updateManager else {
                completion.finish(success: false)
                return
            }
            let updatedItems = await updateManager.checkForUpdatesInBackground()
            if !updatedItems.isEmpty, let notificationManager = bootstrap.notificationManager {
                await notificationManager.dispatchUpdateSummary(updatedItems: updatedItems)
            }
            completion.finish(success: true)
        }

        // iOS expects the task to finish right away once it expires; a check still in a plugin
        // call cannot be waited for. Work saved so far stays saved. `@Sendable` keeps this handler
        // off the main actor, since iOS may call it on any queue.
        task.expirationHandler = { @Sendable in
            taskWrapper.cancel()
            completion.finish(success: false)
        }
    }
}

/// Reports a background task's end to iOS exactly once, whichever path ends it first.
private nonisolated final class BackgroundTaskCompletion: @unchecked Sendable {
    private let task: BGTask
    private let once = OnceFlag()

    init(task: BGTask) {
        self.task = task
    }

    func finish(success: Bool) {
        guard once.claim() else { return }
        task.setTaskCompleted(success: success)
    }
}

@MainActor
private struct BootstrapGateView: View {
    @ObservedObject var bootstrap: DurableStateBootstrap

    var body: some View {
        switch bootstrap.state {
        case .idle, .preparing:
            ProgressView("Preparing your library…")
                .task { _ = await bootstrap.prepare() }
        case .awaitingRestoreAcknowledgment(let report):
            BackupRestoreReportView(report: report) {
                Task { _ = await bootstrap.acknowledgeRestoreReport() }
            }
            .interactiveDismissDisabled()
        case .restoreCommittedRefreshPending:
            VStack(spacing: 16) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.largeTitle)
                Text("Restore committed; refresh pending")
                    .font(.headline)
                Text("Your restored data is saved. Refresh must finish before the app can continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { _ = await bootstrap.retry() }
                }
                .itoProminentButtonStyle()
            }
            .padding()
        case .ready:
            if bootstrap.hasCompleteRuntimeDependencies,
               let settingsStore = bootstrap.settingsStore,
               let trackerManager = bootstrap.trackerManager,
               let libraryManager = bootstrap.libraryManager,
               let backupManager = bootstrap.backupManager,
               let appScope = bootstrap.appScope {
                DurableApplicationView(
                    settingsStore: settingsStore,
                    trackerManager: trackerManager,
                    libraryManager: libraryManager,
                    backupManager: backupManager,
                    appScope: appScope
                )
            } else {
                BootstrapFailureView(
                    title: "Couldn’t start the app",
                    message: "Required runtime services are unavailable. Retry to prepare them again."
                ) {
                    Task { _ = await bootstrap.retryRuntimeInvariantFailure() }
                }
            }
        case .failed(let message):
            BootstrapFailureView(
                title: "Couldn’t prepare your library",
                message: message
            ) {
                Task { _ = await bootstrap.retry() }
            }
        }
    }
}

private struct BootstrapFailureView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.largeTitle)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: retry)
                .itoProminentButtonStyle()
        }
        .padding()
    }
}

@MainActor
private struct DurableApplicationView: View {
    @ObservedObject var settingsStore: AppSettingsStore
    let libraryManager: LibraryManager
    let backupManager: BackupManager
    let appScope: AppScope
    private let trackerCredentialLifecycle: TrackerCredentialLifecycle
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var didPrepareUITestFixtures = false
    #endif

    init(
        settingsStore: AppSettingsStore,
        trackerManager: TrackerManager,
        libraryManager: LibraryManager,
        backupManager: BackupManager,
        appScope: AppScope
    ) {
        self.settingsStore = settingsStore
        self.libraryManager = libraryManager
        self.backupManager = backupManager
        self.appScope = appScope
        trackerCredentialLifecycle = TrackerCredentialLifecycle(manager: trackerManager)
    }

    var body: some View {
        MainTabView(appScope: appScope)
            .preferredColorScheme(settingsStore.appTheme.colorScheme)
            .onOpenURL { url in
                appScope.router.handleRepositoryDeepLink(url)
            }
            .task {
                await trackerCredentialLifecycle.appDidLaunch()
                #if DEBUG
                if !didPrepareUITestFixtures {
                    didPrepareUITestFixtures = true
                    await UITestLaunchFixtureCoordinator.shared.prepareIfNeeded(
                        appScope: appScope,
                        backupManager: backupManager,
                        libraryManager: libraryManager
                    )
                }
                #endif
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                Task { await trackerCredentialLifecycle.appDidBecomeActive() }
            }
    }
}
