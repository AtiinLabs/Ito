import Combine
import Foundation
import GRDB
import OSLog
import ito_runner

public protocol DurableStateBootstrapExtension: Sendable {
    func prepare(dbPool: DatabasePool) async throws
}

public struct NoopDurableStateBootstrapExtension: DurableStateBootstrapExtension {
    public init() {}

    public func prepare(dbPool: DatabasePool) async throws {}
}

public enum DurableConsumerKind: String, CaseIterable, Sendable {
    case appearanceManager = "AppearanceManager"
    case storageManager = "StorageManager"
    case readProgressManager = "ReadProgressManager"
    case trackerManager = "TrackerManager"
    case updateManager = "UpdateManager"
    case repoManager = "RepoManager"
    case pluginManager = "PluginManager"
    case trackerCredentialLifecycle = "TrackerCredentialLifecycle"
}

public struct DurableConsumerConstructor: Sendable {
    public let kind: DurableConsumerKind
    private let operation: @MainActor @Sendable () -> Void

    public init(kind: DurableConsumerKind, operation: @escaping @MainActor @Sendable () -> Void) {
        self.kind = kind
        self.operation = operation
    }

    @MainActor
    func construct() {
        operation()
    }
}

@MainActor
public final class DurableStateBootstrap: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case preparing
        case awaitingRestoreAcknowledgment(BackupRestoreReport)
        case restoreCommittedRefreshPending(operationId: String)
        case ready
        case failed(String)
    }

    public static let shared = production()

    @Published public private(set) var state: State = .idle
    @Published public private(set) var settingsStore: AppSettingsStore?
    @Published public private(set) var pluginSettingsStore: PluginSettingsStore?
    @Published public private(set) var readProgressManager: ReadProgressManager?
    @Published public private(set) var trackerManager: TrackerManager?
    @Published public private(set) var updateManager: UpdateManager?
    @Published public private(set) var repoManager: RepoManager?
    @Published public private(set) var pluginResolver: PluginResolver?
    @Published public private(set) var libraryManager: LibraryManager?
    @Published public private(set) var pluginManager: PluginManager?
    @Published public private(set) var storageManager: StorageManager?
    @Published public private(set) var discordRPCManager: DiscordRPCManager?
    @Published public private(set) var historyManager: HistoryManager?
    @Published public private(set) var notificationManager: NotificationManager?
    @Published public private(set) var backupManager: BackupManager?
    @Published public private(set) var librarySourceRemapper: LibrarySourceRemapper?
    @Published private(set) var appScope: AppScope?

    private let migration: @MainActor @Sendable () async throws -> Void
    private let extensions: [any DurableStateBootstrapExtension]
    private let dbPool: DatabasePool
    private let scalarConsumerConfiguration: @MainActor @Sendable (AppSettingsStore) -> Void
    private let consumerConstructors: [DurableConsumerConstructor]
    private let onReady: @MainActor @Sendable () -> Void
    private let sourceDatabaseURL: URL
    private let installedPluginsDirectory: URL?
    private let runtimeDefaultsSuiteName: String?
    private let trackerKeychainService: String
    private var preparationTask: Task<Bool, Never>?
    private var sourcesPrepared = false
    private var runtime: Runtime?

    private struct Runtime {
        let settingsStore: AppSettingsStore
        let pluginSettingsStore: PluginSettingsStore
        let readProgressManager: ReadProgressManager
        let trackerManager: TrackerManager
        let updateManager: UpdateManager
        let repoManager: RepoManager
        let pluginResolver: PluginResolver
        let libraryManager: LibraryManager
        let pluginManager: PluginManager
        let storageManager: StorageManager
        let appearanceManager: AppearanceManager
        let discordRPCManager: DiscordRPCManager
        let historyManager: HistoryManager
        let notificationManager: NotificationManager
        let backupManager: BackupManager
        let librarySourceRemapper: LibrarySourceRemapper
        let restoreRefresher: BackupRestoreRefresher
        let recentSearchDefaults: UserDefaults
    }

    public init(
        dbPool: DatabasePool,
        migration: @escaping @MainActor @Sendable () async throws -> Void,
        extensions: [any DurableStateBootstrapExtension] = [],
        scalarConsumerConfiguration: @escaping @MainActor @Sendable (AppSettingsStore) -> Void = { _ in },
        consumerConstructors: [DurableConsumerConstructor] = [],
        onReady: @escaping @MainActor @Sendable () -> Void = {},
        sourceDatabaseURL: URL,
        installedPluginsDirectory: URL? = nil,
        runtimeDefaultsSuiteName: String? = nil,
        trackerKeychainService: String = "moe.itoapp.ito.tracker.oauth-token"
    ) {
        self.dbPool = dbPool
        self.migration = migration
        self.extensions = extensions
        self.scalarConsumerConfiguration = scalarConsumerConfiguration
        self.consumerConstructors = consumerConstructors
        self.onReady = onReady
        self.sourceDatabaseURL = sourceDatabaseURL
        self.installedPluginsDirectory = installedPluginsDirectory
        self.runtimeDefaultsSuiteName = runtimeDefaultsSuiteName
        self.trackerKeychainService = trackerKeychainService
    }

    public func prepare() async -> Bool {
        if state == .ready { return true }
        if case .awaitingRestoreAcknowledgment = state { return false }
        if let preparationTask { return await preparationTask.value }

        state = .preparing
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            do {
                if try await hasPendingRestoreJournalEntries() {
                    try await prepareDurableSources()
                    let runtime = self.runtime ?? makeRuntime()
                    self.runtime = runtime
                    try await recoverCommittedRestores(runtime)
                    preparationTask = nil
                    return false
                }

                if let report = try await journalAccess.loadReadyToPresentReport() {
                    state = .awaitingRestoreAcknowledgment(report)
                    preparationTask = nil
                    return false
                }

                try await prepareDurableSources()
                let runtime = self.runtime ?? makeRuntime()
                self.runtime = runtime
                try await finishOrdinaryPreparation(runtime)
                preparationTask = nil
                return true
            } catch {
                clearRuntime()
                if case BackupRestoreError.restoreCommittedRefreshPending(let operationId) = error {
                    state = .restoreCommittedRefreshPending(operationId: operationId)
                } else {
                    state = .failed(String(describing: error))
                }
                preparationTask = nil
                return false
            }
        }
        preparationTask = task
        return await task.value
    }

    public func retry() async -> Bool {
        if case .awaitingRestoreAcknowledgment = state { return false }
        return await prepare()
    }

    func retryRuntimeInvariantFailure() async -> Bool {
        guard state == .ready, !hasCompleteRuntimeDependencies else {
            return false
        }
        clearRuntime()
        state = .failed("Required runtime services were unavailable.")
        return await retry()
    }

    @discardableResult
    public func acknowledgeRestoreReport() async -> Bool {
        guard case .awaitingRestoreAcknowledgment(let report) = state else {
            return false
        }
        state = .preparing
        do {
            guard try await journalAccess.acknowledgeReadyToPresent(
                operationId: report.operationId
            ) else {
                clearRuntime()
                state = .failed("Restore report was already acknowledged.")
                return false
            }
            if try await hasPendingRestoreJournalEntries() {
                try await prepareDurableSources()
                let runtime = self.runtime ?? makeRuntime()
                self.runtime = runtime
                try await recoverCommittedRestores(runtime)
                return true
            }
            if let next = try await journalAccess.loadReadyToPresentReport() {
                state = .awaitingRestoreAcknowledgment(next)
                return true
            }
            try await prepareDurableSources()
            let runtime = self.runtime ?? makeRuntime()
            self.runtime = runtime
            try await finishOrdinaryPreparation(runtime)
            return true
        } catch {
            clearRuntime()
            if case BackupRestoreError.restoreCommittedRefreshPending(let operationId) = error {
                state = .restoreCommittedRefreshPending(operationId: operationId)
            } else {
                state = .failed(String(describing: error))
            }
            return false
        }
    }

    private var journalAccess: BackupRestoreRefresher {
        let noop: BackupRestoreRefresher.RefreshOperations.Operation = {}
        return BackupRestoreRefresher(
            dbPool: dbPool,
            operations: .init(
                appSettings: noop,
                pluginIdentity: noop,
                pluginSettings: noop,
                repositories: noop,
                userImporterAliases: noop,
                library: noop,
                history: noop,
                readProgress: noop,
                trackerLinks: noop,
                updateBadges: noop,
                storage: noop,
                appearance: noop
            )
        )
    }

    private func prepareDurableSources() async throws {
        guard !sourcesPrepared else { return }
        try await migration()
        for bootstrapExtension in extensions {
            try await bootstrapExtension.prepare(dbPool: dbPool)
        }
        sourcesPrepared = true
    }

    private func makeRuntime() -> Runtime {
        let settings = AppSettingsStore(dbPool: dbPool)
        let pluginSettings = PluginSettingsStore(dbPool: dbPool)
        let plugins: PluginManager = {
            guard let installedPluginsDirectory else {
                let plugins = PluginManager(pluginSettingsStore: pluginSettings)
                return plugins
            }
            return PluginManager(
                pluginSettingsStore: pluginSettings,
                pluginsDirectory: installedPluginsDirectory
            )
        }()
        let library = LibraryManager(dbPool: dbPool)
        let storage = StorageManager(pluginManager: plugins)
        let appearance = AppearanceManager(settingsStore: settings)
        let discord = DiscordRPCManager(libraryManager: library)
        let history = HistoryManager(dbPool: dbPool, libraryManager: library)
        let notifications = NotificationManager()
        let remapper = LibrarySourceRemapper(dbPool: dbPool)
        let updates = UpdateManager(dbPool: dbPool, pluginManager: plugins)
        let progress = ReadProgressManager(dbPool: dbPool)
        #if DEBUG
        let usernameDefaults: UserDefaults
        let legacyTokenStore: LegacyTokenStore
        if let runtimeDefaultsSuiteName {
            guard let isolatedDefaults = UserDefaults(suiteName: runtimeDefaultsSuiteName) else {
                fatalError("Failed to create isolated runtime defaults suite.")
            }
            usernameDefaults = isolatedDefaults
            legacyTokenStore = LegacyTokenStore(suiteName: runtimeDefaultsSuiteName)
        } else {
            usernameDefaults = .standard
            legacyTokenStore = LegacyTokenStore()
        }
        #else
        let usernameDefaults = UserDefaults.standard
        let legacyTokenStore = LegacyTokenStore()
        #endif
        let tracker = TrackerManager(
            dbPool: dbPool,
            credentialStore: KeychainTrackerCredentialStore(service: trackerKeychainService),
            legacyTokenStore: legacyTokenStore,
            usernameDefaults: usernameDefaults
        )
        let repositories = RepoManager(
            dbPool: dbPool,
            pluginManager: plugins,
            pluginsDirectory: installedPluginsDirectory
        )
        let resolver = PluginResolver(
            dbPool: dbPool,
            repoManager: repositories,
            installedPluginIds: { Set(plugins.installedPlugins.keys) }
        )

        updates.configure(settingsStore: settings)
        storage.configure(settingsStore: settings)
        discord.configure(settingsStore: settings)
        history.configure(settingsStore: settings)
        notifications.configure(settingsStore: settings)
        notifications.configure(updateManager: updates)
        progress.configure(updateManager: updates)

        let refresher = BackupRestoreRefresher(
            dbPool: dbPool,
            appSettings: settings,
            pluginManager: plugins,
            pluginSettings: pluginSettings,
            repoManager: repositories,
            pluginResolver: resolver,
            libraryManager: library,
            historyManager: history,
            readProgressManager: progress,
            trackerManager: tracker,
            updateManager: updates,
            storageManager: storage,
            appearanceManager: appearance
        )
        let backup = BackupManager(
            dbPool: dbPool,
            sourceDatabaseURL: sourceDatabaseURL,
            exportReadiness: { [weak self] in
                let isReady = await MainActor.run {
                    guard let self else { return false }
                    if case .ready = self.state { return true }
                    return false
                }
                guard isReady else {
                    throw BackupExportError.incompleteMigration
                }
                try await plugins.discoverAndPrepareInstalledPlugins(failOnInvalidPlugin: true)
            },
            restoreRefresher: refresher,
            onAllReportsAcknowledged: {
                try await plugins.discoverAndPrepareInstalledPlugins(failOnInvalidPlugin: true)
                try pluginSettings.reload()
                try await repositories.reload()
                try await resolver.reload()
                try await library.reload()
                try await history.reload()
                try await progress.reload()
                try await tracker.reload()
                try await updates.reload()
                try storage.reload()
                appearance.reload()
            }
        )
        backup.configure(pluginResolver: resolver)

        return Runtime(
            settingsStore: settings,
            pluginSettingsStore: pluginSettings,
            readProgressManager: progress,
            trackerManager: tracker,
            updateManager: updates,
            repoManager: repositories,
            pluginResolver: resolver,
            libraryManager: library,
            pluginManager: plugins,
            storageManager: storage,
            appearanceManager: appearance,
            discordRPCManager: discord,
            historyManager: history,
            notificationManager: notifications,
            backupManager: backup,
            librarySourceRemapper: remapper,
            restoreRefresher: refresher,
            recentSearchDefaults: usernameDefaults
        )
    }

    private func finishOrdinaryPreparation(_ runtime: Runtime) async throws {
        try await runtime.settingsStore.reload()
        scalarConsumerConfiguration(runtime.settingsStore)
        try await runtime.pluginManager.discoverAndPrepareInstalledPlugins()
        try await runtime.libraryManager.reload()
        try await runtime.historyManager.reload()
        try await runtime.updateManager.reload()
        try await runtime.readProgressManager.reload()
        try await runtime.trackerManager.reload()
        try await runtime.repoManager.reload()
        try await runtime.pluginResolver.reload()
        try runtime.storageManager.reload()
        runtime.appearanceManager.reload()
        install(runtime)
        for constructor in consumerConstructors {
            constructor.construct()
        }
        onReady()
        state = .ready
    }

    private func recoverCommittedRestores(_ runtime: Runtime) async throws {
        _ = try await runtime.restoreRefresher.resumePendingRefreshes()
        try await runtime.restoreRefresher.refreshReadyStateForRelaunch()
        guard let report = try await runtime.restoreRefresher.loadReadyToPresentReport() else {
            throw BackupRestoreJournalError.transitionConflict(operationId: "missingReadyReport")
        }
        state = .awaitingRestoreAcknowledgment(report)
    }

    private func hasPendingRestoreJournalEntries() async throws -> Bool {
        try await dbPool.read { db in
            try BackupRestoreJournalRecord
                .filter(Column("status") == RestoreOperationStatus.pendingRefresh.rawValue)
                .fetchCount(db) > 0
        }
    }

    private func install(_ runtime: Runtime) {
        settingsStore = runtime.settingsStore
        pluginSettingsStore = runtime.pluginSettingsStore
        readProgressManager = runtime.readProgressManager
        trackerManager = runtime.trackerManager
        updateManager = runtime.updateManager
        repoManager = runtime.repoManager
        pluginResolver = runtime.pluginResolver
        libraryManager = runtime.libraryManager
        pluginManager = runtime.pluginManager
        storageManager = runtime.storageManager
        discordRPCManager = runtime.discordRPCManager
        historyManager = runtime.historyManager
        notificationManager = runtime.notificationManager
        backupManager = runtime.backupManager
        librarySourceRemapper = runtime.librarySourceRemapper
        appScope = AppScope.prepared(
            pluginManager: runtime.pluginManager,
            repoManager: runtime.repoManager,
            pluginResolver: runtime.pluginResolver,
            settingsStore: runtime.settingsStore,
            trackerManager: runtime.trackerManager,
            readProgressManager: runtime.readProgressManager,
            libraryManager: runtime.libraryManager,
            historyManager: runtime.historyManager,
            updateManager: runtime.updateManager,
            backupManager: runtime.backupManager,
            librarySourceRemapper: runtime.librarySourceRemapper,
            themeManager: ThemeManager.shared,
            notificationManager: runtime.notificationManager,
            storageManager: runtime.storageManager,
            discordRPCManager: runtime.discordRPCManager,
            sourceMappingRepository: GRDBSourceMappingRepository(dbWriter: dbPool),
            discoverDetailService: DiscoverManager.shared,
            discoverDetailThemeService: ThemeManager.shared,
            recentSearchDefaults: runtime.recentSearchDefaults,
            browsePluginsDirectory: installedPluginsDirectory
        )
    }

    private func clearRuntime() {
        runtime = nil
        settingsStore = nil
        pluginSettingsStore = nil
        readProgressManager = nil
        trackerManager = nil
        updateManager = nil
        repoManager = nil
        pluginResolver = nil
        libraryManager = nil
        pluginManager = nil
        storageManager = nil
        discordRPCManager = nil
        historyManager = nil
        notificationManager = nil
        backupManager = nil
        librarySourceRemapper = nil
        appScope = nil
    }

    private var hasCompleteRuntimeDependencies: Bool {
        settingsStore != nil
            && pluginSettingsStore != nil
            && readProgressManager != nil
            && trackerManager != nil
            && updateManager != nil
            && repoManager != nil
            && pluginResolver != nil
            && libraryManager != nil
            && pluginManager != nil
            && storageManager != nil
            && discordRPCManager != nil
            && historyManager != nil
            && notificationManager != nil
            && backupManager != nil
            && librarySourceRemapper != nil
            && appScope != nil
    }

    private static func production() -> DurableStateBootstrap {
        let domainName: String
        let defaults: UserDefaults
        let launchDefaultsSuiteName: String?
        let trackerKeychainService: String
        let installedPluginsDirectory: URL?
        let extensions: [any DurableStateBootstrapExtension]
        #if DEBUG
        let launchConfiguration = UITestLaunchConfiguration.current
        if launchConfiguration.isEnabled {
            domainName = UITestLaunchConfiguration.fixtureDefaultsSuiteName
            launchDefaultsSuiteName = domainName
            trackerKeychainService = UITestLaunchConfiguration.fixtureTrackerKeychainService
            guard let fixtureDefaults = UserDefaults(suiteName: domainName) else {
                fatalError("Failed to create UI test defaults suite.")
            }
            if launchConfiguration.resetsStorage {
                fixtureDefaults.removePersistentDomain(forName: domainName)
                guard fixtureDefaults.persistentDomain(forName: domainName)?.isEmpty != false else {
                    fatalError("Failed to reset UI test defaults suite.")
                }
            }
            defaults = fixtureDefaults
            let fixtureRootURL: URL
            do {
                fixtureRootURL = try UITestLaunchConfiguration.fixtureRootURL()
            } catch {
                fatalError("Failed to locate UI test fixture storage.")
            }
            let pluginsDirectory = fixtureRootURL.appendingPathComponent(
                UITestLaunchConfiguration.fixturePluginsDirectoryName,
                isDirectory: true
            )
            installedPluginsDirectory = pluginsDirectory
            extensions = [InstalledPluginSuiteBootstrapExtension(
                pluginsDirectory: pluginsDirectory
            )]
        } else {
            domainName = Bundle.main.bundleIdentifier ?? "moe.itoapp.ito"
            defaults = .standard
            launchDefaultsSuiteName = nil
            trackerKeychainService = KeychainTrackerCredentialStore.productionService
            installedPluginsDirectory = nil
            extensions = [InstalledPluginSuiteBootstrapExtension()]
        }
        #else
        domainName = Bundle.main.bundleIdentifier ?? "moe.itoapp.ito"
        defaults = .standard
        launchDefaultsSuiteName = nil
        trackerKeychainService = KeychainTrackerCredentialStore.productionService
        installedPluginsDirectory = nil
        extensions = [InstalledPluginSuiteBootstrapExtension()]
        #endif
        let dbPool = AppDatabase.shared.dbPool
        let domain = UserDefaultsLegacyDomain(defaults: defaults, domainName: domainName)
        let migrator = LegacyDefaultsMigrator(dbPool: dbPool, domain: domain)
        return DurableStateBootstrap(
            dbPool: dbPool,
            migration: {
                try migrator.migrate()
            },
            extensions: extensions,
            scalarConsumerConfiguration: { _ in },
            sourceDatabaseURL: AppDatabase.shared.databaseURL,
            installedPluginsDirectory: installedPluginsDirectory,
            runtimeDefaultsSuiteName: launchDefaultsSuiteName,
            trackerKeychainService: trackerKeychainService
        )
    }
}

enum InstalledPluginSuiteDiscoveryError: Error, LocalizedError {
    case metadataExtractionFailed(filename: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .metadataExtractionFailed(let filename, let reason):
            "Could not read installed plugin metadata for \(filename): \(reason)"
        }
    }
}

struct InstalledPluginSuiteBootstrapExtension: DurableStateBootstrapExtension {
    typealias ExtractDiscovery = @MainActor @Sendable (URL) throws -> PluginSettingsDiscovery

    private let pluginsDirectory: URL?
    private let extractDiscovery: ExtractDiscovery

    init(
        pluginsDirectory: URL? = nil,
        extractDiscovery: @escaping ExtractDiscovery = Self.extractDiscovery(from:)
    ) {
        self.pluginsDirectory = pluginsDirectory
        self.extractDiscovery = extractDiscovery
    }

    func prepare(dbPool: DatabasePool) async throws {
        let fileManager = FileManager.default
        let pluginsDirectory = try pluginsDirectory ?? Self.defaultPluginsDirectory(fileManager)
        var discoveries: [PluginSettingsDiscovery] = []
        if fileManager.fileExists(atPath: pluginsDirectory.path) {
            let pluginURLs = try fileManager.contentsOfDirectory(
                at: pluginsDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "ito" }
            for url in pluginURLs {
                do {
                    discoveries.append(try extractDiscovery(url))
                } catch {
                    throw InstalledPluginSuiteDiscoveryError.metadataExtractionFailed(
                        filename: url.lastPathComponent,
                        reason: String(describing: error)
                    )
                }
            }
        }
        try PluginSettingsStore(dbPool: dbPool).prepareForDurableSnapshot(discoveries)
    }

    private static func defaultPluginsDirectory(_ fileManager: FileManager) throws -> URL {
        guard let appSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw URLError(.cannotFindHost)
        }
        return appSupportDirectory.appendingPathComponent("Plugins")
    }

    private static func extractDiscovery(from url: URL) throws -> PluginSettingsDiscovery {
        let extracted = try ItoRunner.extractPluginInfo(from: url)
        return PluginSettingsDiscovery(
            pluginId: extracted.manifest.info.id,
            manifestId: extracted.manifest.info.id,
            filenameId: url.deletingPathExtension().lastPathComponent,
            source: "installedFileScan"
        )
    }
}
