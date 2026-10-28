import OSLog
import Foundation
import Combine
import ito_runner

public struct InstalledPlugin: Identifiable {
    public var id: String { info.id }
    public let url: URL
    public let info: PluginInfo
    public let iconData: Data?
}

extension PluginInfo {
    /// Each kind the plugin serves once, in declared order. A hand-edited manifest may repeat one.
    nonisolated var distinctKinds: [MediaKind] {
        var seen = Set<MediaKind>()
        return supportedKinds.filter { seen.insert($0).inserted }
    }
}

/// Manages the state of installed plugins to provide fast, synchronous O(1) lookups
/// for the UI (like RepositoriesView) without blocking the main thread parsing ZIP files.
public class PluginManager: ObservableObject {
    // Key: Plugin ID (e.g., moe.itoapp.ito.hianime)
    // Value: The parsed manifest info for that plugin
    @Published public private(set) var installedPlugins: [String: InstalledPlugin] = [:]
    @Published private(set) var installedPluginsPublicationRevision: UInt64 = 0

    private struct RunnerAuthority: Equatable {
        let publicationRevision: UInt64
        let pluginID: String
        let version: String
        let supportedKinds: Set<MediaKind>
        let fileIdentity: URL
    }

    private struct CachedRunner {
        let authority: RunnerAuthority
        let runner: ItoRunner
    }

    // Cache for loaded WASM runners
    private var runnerCache: [String: CachedRunner] = [:]
    // Dedicated cache for image runners
    private var imageRunnerCache: [String: CachedRunner] = [:]

    private struct PendingImageLoad {
        let token: UUID
        let authority: RunnerAuthority
        let task: Task<ItoRunner, Error>
    }
    private var pendingImageLoads: [String: PendingImageLoad] = [:]
    private let pluginsDirectory: URL?
    private let runnerLoader: @MainActor (
        _ pluginID: String,
        _ pluginURL: URL,
        _ settingsStore: PluginSettingsStore
    ) async throws -> ItoRunner
    public let pluginSettingsStore: PluginSettingsStore
    private weak var completionCoordinator: PluginCompletionCoordinator?

    var configuredInstalledPluginsDirectory: URL? {
        pluginsDirectory
    }

    public init(pluginSettingsStore: PluginSettingsStore, pluginsDirectory: URL? = nil) {
        self.pluginSettingsStore = pluginSettingsStore
        self.pluginsDirectory = pluginsDirectory
        runnerLoader = Self.loadRunner
    }

    init(
        pluginSettingsStore: PluginSettingsStore,
        pluginsDirectory: URL? = nil,
        runnerLoader: @escaping @MainActor (
            _ pluginID: String,
            _ pluginURL: URL,
            _ settingsStore: PluginSettingsStore
        ) async throws -> ItoRunner
    ) {
        self.pluginSettingsStore = pluginSettingsStore
        self.pluginsDirectory = pluginsDirectory
        self.runnerLoader = runnerLoader
    }

    @MainActor
    func configureCompletionDelivery(coordinator: PluginCompletionCoordinator) {
        completionCoordinator = coordinator
    }

    @MainActor
    func holdCompletionDelivery(for pluginID: String) async throws {
        do {
            try await pluginSettingsStore.completionStore.holdForRemoval(pluginID: pluginID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PluginCompletionRecoveryError.queueUnavailable
        }
        completionCoordinator?.cancel(for: pluginID)
    }

    @MainActor
    func purgeCompletionDelivery(for pluginID: String) async {
        do {
            try await pluginSettingsStore.completionStore.purgeRemoved(pluginID: pluginID)
        } catch {
            // The held intents stay paused and inert; a reinstall offers them for retry or discard.
            AppLogger.plugin.error("PluginManager: queued read progress of a removed source could not be cleared")
        }
    }

    /// Gets a cached ItoRunner for a plugin ID, or initializes a new one if not cached.
    @MainActor
    public func getRunner(for pluginId: String) async throws -> ItoRunner {
        guard let plugin = installedPlugins[pluginId] else {
            AppLogger.plugin.debug("🔌 [PluginManager] Plugin not found: \(pluginId)")
            throw URLError(.fileDoesNotExist) // Plugin not installed
        }
        // A plugin built for a newer Ito may call what this version doesn't provide.
        if let refusal = plugin.info.compatibilityRefusal {
            throw refusal
        }
        let authority = runnerAuthority(for: plugin)

        try pluginSettingsStore.prepare(pluginId: pluginId)
        if let cached = runnerCache[pluginId], cached.authority == authority {
            AppLogger.plugin.debug("🔌 [PluginManager] Returning cached runner for \(pluginId)")
            return cached.runner
        }
        runnerCache[pluginId] = nil

        AppLogger.plugin.debug("\("🔌 [PluginManager] Creating new runner for \(pluginId)")...")
        let runner = try await runnerLoader(pluginId, plugin.url, pluginSettingsStore)
        guard installedPlugins[pluginId].map(runnerAuthority) == authority else {
            throw PluginRunnerAuthorityError.changedDuringLoad
        }

        runnerCache[pluginId] = CachedRunner(authority: authority, runner: runner)
        AppLogger.plugin.debug("🔌 [PluginManager] Runner cached for \(pluginId)")
        return runner
    }

    /// Gets a cached ItoRunner dedicated to image loading for a plugin ID, or initializes a new one.
    /// In-flight requests for the same plugin and authority share a single pending load task.
    @MainActor
    public func getImageRunner(for pluginId: String) async throws -> ItoRunner {
        try Task.checkCancellation()
        guard let plugin = installedPlugins[pluginId] else {
            AppLogger.plugin.debug("🔌 [PluginManager] Plugin not found: \(pluginId)")
            throw URLError(.fileDoesNotExist) // Plugin not installed
        }
        // A plugin built for a newer Ito may call what this version doesn't provide.
        if let refusal = plugin.info.compatibilityRefusal {
            throw refusal
        }
        let authority = runnerAuthority(for: plugin)

        try pluginSettingsStore.prepare(pluginId: pluginId)
        if let cached = imageRunnerCache[pluginId] {
            if cached.authority == authority {
                AppLogger.plugin.debug("🔌 [PluginManager] Returning cached image runner for \(pluginId)")
                return cached.runner
            }
            imageRunnerCache[pluginId] = nil
        }

        let pendingTask: Task<ItoRunner, Error>
        if let existing = pendingImageLoads[pluginId], existing.authority == authority {
            pendingTask = existing.task
        } else {
            if let stale = pendingImageLoads.removeValue(forKey: pluginId) {
                stale.task.cancel()
            }
            let token = UUID()
            let task = Task<ItoRunner, Error> { @MainActor [weak self] () -> ItoRunner in
                guard let runnerLoader = self?.runnerLoader,
                      let settingsStore = self?.pluginSettingsStore else {
                    throw CancellationError()
                }
                do {
                    try Task.checkCancellation()
                    let runner = try await runnerLoader(pluginId, plugin.url, settingsStore)
                    try Task.checkCancellation()
                    guard let self else { throw CancellationError() }
                    guard self.pendingImageLoads[pluginId]?.token == token,
                          self.installedPlugins[pluginId].map(self.runnerAuthority) == authority else {
                        if self.pendingImageLoads[pluginId]?.token == token {
                            self.pendingImageLoads[pluginId] = nil
                        }
                        throw PluginRunnerAuthorityError.changedDuringLoad
                    }
                    self.pendingImageLoads[pluginId] = nil
                    self.imageRunnerCache[pluginId] = CachedRunner(authority: authority, runner: runner)
                    AppLogger.plugin.debug("🔌 [PluginManager] Image runner cached for \(pluginId)")
                    return runner
                } catch {
                    if let self, self.pendingImageLoads[pluginId]?.token == token {
                        self.pendingImageLoads[pluginId] = nil
                    }
                    throw error
                }
            }
            pendingImageLoads[pluginId] = PendingImageLoad(
                token: token,
                authority: authority,
                task: task
            )
            pendingTask = task
        }

        try Task.checkCancellation()
        let runner = try await pendingTask.value
        try Task.checkCancellation()
        guard installedPlugins[pluginId].map(runnerAuthority) == authority,
              imageRunnerCache[pluginId]?.runner === runner else {
            throw PluginRunnerAuthorityError.changedDuringLoad
        }
        return runner
    }

    /// Loads the plugin and gives it its settings defaults. A plugin that crashes while describing
    /// its settings is loaded again without them: that runner may be broken, but the plugin can
    /// still read, search and update.
    @MainActor
    private static func loadRunner(
        pluginID: String,
        pluginURL: URL,
        settingsStore: PluginSettingsStore
    ) async throws -> ItoRunner {
        let (runner, defaults) = try await makeRunner(pluginID: pluginID, pluginURL: pluginURL, settingsStore: settingsStore)
        let usable = try await applySchemaDefaults(
            from: { try await runner.getSettingsSurface() },
            to: defaults,
            pluginID: pluginID
        )
        if usable { return runner }
        AppLogger.plugin.error("PluginManager: \(pluginID) crashed describing its settings; loading it again without defaults")
        return try await makeRunner(pluginID: pluginID, pluginURL: pluginURL, settingsStore: settingsStore).runner
    }

    @MainActor
    private static func makeRunner(
        pluginID: String,
        pluginURL: URL,
        settingsStore: PluginSettingsStore
    ) async throws -> (runner: ItoRunner, defaults: AppDefaultsModule) {
        let runner = ItoRunner()
        let defaults = AppDefaultsModule(pluginId: pluginID, store: settingsStore)
        await runner.setNetModule(AppNetModule(pluginID: pluginID, cookieJar: settingsStore.cookies, trust: settingsStore.trust))
        await runner.setStdModule(DefaultStdModule())
        await runner.setDefaultsModule(defaults)
        await runner.setHtmlModule(DefaultHtmlModule())
        await runner.setWebviewModule(AppWebviewModule())

        AppLogger.plugin.debug("\("🔌 [PluginManager] Loading bundle for \(pluginID)")...")
        do {
            _ = try await runner.loadBundle(from: pluginURL)
        } catch ItoError.requiresNewerHost, ItoError.unsupportedABI {
            // Plugins whose manifest predates `abi`/`imports` are only found out here.
            throw PluginRequiresNewerAppError(minimumAppVersion: nil)
        }
        return (runner, defaults)
    }

    /// Injects defaults only for legacy settings; rich forms apply defaults in the SDK.
    /// Returns false after a plugin crash so the unusable runner can be discarded.
    @MainActor
    static func applySchemaDefaults(
        from readSchema: () async throws -> SettingsSurface?,
        to defaults: AppDefaultsModule,
        pluginID: String
    ) async throws -> Bool {
        do {
            let surface = try await pluginCall(readSchema)
            defaults.useSchemaDefaults(surface?.storedDefaults ?? [:])
            return true
        } catch let error as PluginCallError where error.kind == .crashed {
            return false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLogger.plugin.error("PluginManager: no settings defaults for \(pluginID); the schema couldn't be read")
            return true
        }
    }

    /// Evicts a cached runner for a plugin so the next getRunner call creates a fresh one.
    /// Also evicts the image runner cache and cancels any pending image runner load.
    /// Use this after settings changes that require the WASM module to be reloaded.
    @MainActor
    public func evictRunner(for pluginId: String) {
        if runnerCache.removeValue(forKey: pluginId) != nil {
            AppLogger.plugin.debug("🔌 [PluginManager] Evicted cached runner for \(pluginId)")
        }
        if imageRunnerCache.removeValue(forKey: pluginId) != nil {
            AppLogger.plugin.debug("🔌 [PluginManager] Evicted cached image runner for \(pluginId)")
        }
        if let pending = pendingImageLoads.removeValue(forKey: pluginId) {
            pending.task.cancel()
            AppLogger.plugin.debug("🔌 [PluginManager] Cancelled pending image runner load for \(pluginId)")
        }
    }

    /// Evicts a cached image runner for a plugin only if the currently cached runner matches the instance.
    /// This prevents a late trap callback from an old instance from evicting a newer runner or an in-flight replacement.
    @MainActor
    func evictImageRunner(for pluginId: String, matching runner: ItoRunner) {
        guard let cached = imageRunnerCache[pluginId] else { return }
        if cached.runner === runner {
            imageRunnerCache.removeValue(forKey: pluginId)
            AppLogger.plugin.debug("🔌 [PluginManager] Evicted crashed image runner for \(pluginId)")
        }
    }

    /// Scans the Application Support/Plugins directory and parses all manifests.
    @MainActor
    public func reloadInstalledPlugins() async {
        do {
            try await discoverAndPrepareInstalledPlugins(failOnInvalidPlugin: false)
        } catch {
            AppLogger.plugin.error("Failed to load installed plugins: \(error)")
        }
    }

    /// Performs strict readiness discovery, registers every installed manifest/file
    /// identity, and verifies all registered suites before publishing the cache.
    @MainActor
    public func discoverAndPrepareInstalledPlugins() async throws {
        try await discoverAndPrepareInstalledPlugins(failOnInvalidPlugin: true)
    }

    /// Performs discovery with explicit invalid-file handling.
    @MainActor
    public func discoverAndPrepareInstalledPlugins(
        failOnInvalidPlugin: Bool
    ) async throws {
        let installedPlugins = try prepareInstalledPluginsPublication(
            failOnInvalidPlugin: failOnInvalidPlugin
        )
        publishPreparedInstalledPlugins(installedPlugins)
    }

    @MainActor
    func prepareInstalledPluginsPublication(
        failOnInvalidPlugin: Bool = true
    ) throws -> [String: InstalledPlugin] {
        let scan = try scanInstalledPlugins(failOnInvalidPlugin: failOnInvalidPlugin)
        try pluginSettingsStore.prepareForDurableSnapshot(scan.discoveries)
        return scan.plugins
    }

    @MainActor
    func publishPreparedInstalledPlugins(_ installedPlugins: [String: InstalledPlugin]) {
        publishInstalledPlugins(installedPlugins)
    }

    /// Restore-only scan. This reads bundle metadata and republishes the in-memory
    /// cache without registering identities, migrating suites, or creating runners.
    @MainActor
    public func reloadAfterRestore() async throws {
        let scan = try scanInstalledPlugins(failOnInvalidPlugin: true)
        publishInstalledPlugins(scan.plugins)
    }

    @MainActor
    private func scanInstalledPlugins(
        failOnInvalidPlugin: Bool
    ) throws -> (
        plugins: [String: InstalledPlugin],
        discoveries: [PluginSettingsDiscovery]
    ) {
        let fileManager = FileManager.default
        let pluginsDir: URL
        if let pluginsDirectory {
            pluginsDir = pluginsDirectory
        } else {
            guard let appSupportDir = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw URLError(.cannotFindHost)
            }
            pluginsDir = appSupportDir.appendingPathComponent("Plugins")
        }

        guard fileManager.fileExists(atPath: pluginsDir.path) else {
            return ([:], [])
        }

        let files = try fileManager.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: nil
        )
        let itoFiles = files.filter { $0.pathExtension == "ito" }

        var newCache: [String: InstalledPlugin] = [:]
        var discoveries: [PluginSettingsDiscovery] = []

        // We use static extraction to avoid loading WASM into memory just to read metadata
        for url in itoFiles {
            do {
                let extracted = try ItoRunner.extractPluginInfo(from: url)
                let filenameId = url.deletingPathExtension().lastPathComponent
                discoveries.append(
                    PluginSettingsDiscovery(
                        pluginId: extracted.manifest.info.id,
                        manifestId: extracted.manifest.info.id,
                        filenameId: filenameId,
                        source: "installedFileScan"
                    )
                )
                newCache[extracted.manifest.info.id] = InstalledPlugin(
                    url: url,
                    info: extracted.manifest.info,
                    iconData: extracted.icon
                )
            } catch {
                if failOnInvalidPlugin {
                    throw error
                }
                AppLogger.plugin.error(
                    "Failed to extract plugin info for \(url.lastPathComponent): \(error)"
                )
            }
        }

        return (newCache, discoveries)
    }

    @MainActor
    private func publishInstalledPlugins(_ newCache: [String: InstalledPlugin]) {
        installedPlugins = newCache

        // Evict any cached runners whose plugin was removed or updated,
        // so the next getRunner call loads the fresh WASM binary.
        let validIds = Set(newCache.keys)
        for cachedId in runnerCache.keys {
            if !validIds.contains(cachedId) {
                runnerCache.removeValue(forKey: cachedId)
                AppLogger.plugin.debug(
                    "🔌 [PluginManager] Evicted removed plugin runner: \(cachedId)"
                )
            }
        }
        // Also evict ALL runners to pick up updated .ito files
        runnerCache.removeAll()
        imageRunnerCache.removeAll()
        for (_, pending) in pendingImageLoads {
            pending.task.cancel()
        }
        pendingImageLoads.removeAll()
        // A source removed in this launch trusts certificates again only once reinstalled.
        for pluginID in newCache.keys {
            pluginSettingsStore.trust.activateInstalledPlugin(pluginID)
        }
        installedPluginsPublicationRevision &+= 1
        AppLogger.plugin.debug(
            "🔌 [PluginManager] Cleared runner cache (\(newCache.count) plugins loaded)"
        )
    }

    private func runnerAuthority(for plugin: InstalledPlugin) -> RunnerAuthority {
        RunnerAuthority(
            publicationRevision: installedPluginsPublicationRevision,
            pluginID: plugin.id,
            version: plugin.info.version,
            supportedKinds: Set(plugin.info.supportedKinds),
            fileIdentity: plugin.url.standardizedFileURL
        )
    }
}

enum PluginRunnerAuthorityError: Error, Equatable {
    case changedDuringLoad
}
