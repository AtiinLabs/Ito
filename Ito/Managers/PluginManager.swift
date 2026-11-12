import OSLog
import Foundation
import Combine
import ito_runner

public struct InstalledPlugin: Identifiable {
    public var id: String { info.id }
    public let url: URL
    public let info: PluginInfo
    public let iconData: Data?
    /// The module's interface, read without running it; nil when the module is unreadable. A plugin with no
    /// readable module stays listed and its settings stay prepared, but no gate lets it run.
    public let binary: PluginBinaryInterface?

    nonisolated public init(url: URL, info: PluginInfo, iconData: Data?, binary: PluginBinaryInterface?) {
        self.url = url
        self.info = info
        self.iconData = iconData
        self.binary = binary
    }
}

extension InstalledPlugin {
    /// Why this installed plugin can't run here, or nil when it can. The manifest's `min_app_version` comes first, so
    /// it names its version. The module is decisive after that: a module that can't be read is refused as an
    /// unsupported file, and the manifest's own `abi`/`imports` never make an unreadable module runnable. Nil means
    /// unreadable until the next scan; the archive's manifest was readable, so the plugin stays listed.
    nonisolated func compatibilityRefusal(
        supported: ClosedRange<Int> = ItoRunner.supportedABIVersions
    ) -> PluginIncompatibility? {
        if let refusal = PluginIncompatibility.appVersion(required: info.minAppVersion) {
            return refusal
        }
        guard let binary else { return .unsupportedFile }
        return PluginIncompatibility.binary(ItoRunner.compatibility(of: binary, supported: supported))
    }
}

extension PluginInfo {
    /// Each kind the plugin serves once, in declared order. A hand-edited manifest may repeat one.
    nonisolated var distinctKinds: [MediaKind] {
        var seen = Set<MediaKind>()
        return supportedKinds.filter { seen.insert($0).inserted }
    }
}

/// Host modules a runner is built with. Foreground runners get the app's modules; a download attempt
/// gets its own, so its traffic and prompts stay out of the foreground.
nonisolated struct PluginRunnerHostModules: Sendable {
    let net: any NetModule
    let webview: any WebviewModule
}

typealias DownloadRunnerLoader = @MainActor (
    _ pluginID: String,
    _ pluginURL: URL,
    _ settingsStore: PluginSettingsStore,
    _ modules: PluginRunnerHostModules,
    _ operation: PluginNetworkOperation,
    _ frozenScope: String?
) async throws -> ItoRunner

/// Reads one packaged file the way `PluginPackageReading.readInBackground(at:)` does. Tests inject their own.
typealias PluginPackageReader = @Sendable (URL) async throws -> PluginPackageReading

/// Thread-safe copy of the installed plugins' publication revision. Synchronous checks inside a
/// database transaction read it here, because the main actor is not available there.
nonisolated final class PluginPublicationRevisionMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var current: UInt64 {
        lock.withLock { value }
    }

    func store(_ revision: UInt64) {
        lock.withLock { value = revision }
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
    private let downloadRunnerLoader: DownloadRunnerLoader
    private let publicationMirror = PluginPublicationRevisionMirror()
    /// Serializes plugin-directory changes and the scans that publish the installed plugins. See
    /// `PluginDirectoryGate`.
    let directoryGate: PluginDirectoryGate
    private let packageReader: PluginPackageReader
    /// The ABI range this manager's compatibility checks accept: `ItoRunner.supportedABIVersions` in production.
    let supportedABI: ClosedRange<Int>

    var configuredInstalledPluginsDirectory: URL? {
        pluginsDirectory
    }

    public convenience init(pluginSettingsStore: PluginSettingsStore, pluginsDirectory: URL? = nil) {
        self.init(pluginSettingsStore: pluginSettingsStore, pluginsDirectory: pluginsDirectory, runnerLoader: nil)
    }

    init(
        pluginSettingsStore: PluginSettingsStore,
        pluginsDirectory: URL? = nil,
        runnerLoader: (@MainActor (
            _ pluginID: String,
            _ pluginURL: URL,
            _ settingsStore: PluginSettingsStore
        ) async throws -> ItoRunner)? = nil,
        downloadRunnerLoader: DownloadRunnerLoader? = nil,
        directoryGate: PluginDirectoryGate? = nil,
        packageReader: PluginPackageReader? = nil,
        supportedABI: ClosedRange<Int> = ItoRunner.supportedABIVersions
    ) {
        self.pluginSettingsStore = pluginSettingsStore
        self.pluginsDirectory = pluginsDirectory
        self.runnerLoader = runnerLoader ?? Self.loadRunner
        self.downloadRunnerLoader = downloadRunnerLoader ?? Self.loadDownloadRunner
        self.directoryGate = directoryGate ?? PluginDirectoryGate()
        self.supportedABI = supportedABI
        self.packageReader = packageReader ?? { url in
            try await PluginPackageReading.readInBackground(at: url, supported: supportedABI)
        }
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
        // A plugin this Ito can't run is refused before loading, whichever side has to change.
        if let refusal = plugin.compatibilityRefusal(supported: supportedABI) {
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
        // A plugin this Ito can't run is refused before loading, whichever side has to change.
        if let refusal = plugin.compatibilityRefusal(supported: supportedABI) {
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

    /// Builds the runtime for one download attempt. The runner is loaded with the attempt's modules and
    /// belongs to that attempt: it is never stored in `runnerCache` or `imageRunnerCache`, and the
    /// foreground `getRunner`/`getImageRunner` never see it.
    @MainActor
    func makeDownloadRuntime(
        for pluginId: String,
        modules: PluginRunnerHostModules,
        operation: PluginNetworkOperation,
        frozenScope: String?
    ) async throws -> DownloadPluginRuntime {
        guard let plugin = installedPlugins[pluginId] else {
            throw URLError(.fileDoesNotExist)
        }
        if let refusal = plugin.compatibilityRefusal(supported: supportedABI) {
            throw refusal
        }
        let authority = runnerAuthority(for: plugin)
        try pluginSettingsStore.prepare(pluginId: pluginId)

        let loader = downloadRunnerLoader
        let settingsStore = pluginSettingsStore
        let pluginURL = plugin.url
        // Taken with the authority, before the load: a trust change during the load must not become
        // the baseline the commit checks against.
        let trust = settingsStore.trust
        let trustGeneration = trust.transportGeneration(for: pluginId)
        let main = try await loader(pluginId, pluginURL, settingsStore, modules, operation, frozenScope)
        guard installedPlugins[pluginId].map(runnerAuthority) == authority else {
            throw PluginRunnerAuthorityError.changedDuringLoad
        }

        let mirror = publicationMirror
        let revision = authority.publicationRevision
        return DownloadPluginRuntime(
            pages: main,
            makeImageRunner: {
                try await loader(pluginId, pluginURL, settingsStore, modules, operation, frozenScope)
            },
            isPluginCurrent: { mirror.current == revision },
            isTrustCurrent: { trust.transportGeneration(for: pluginId) == trustGeneration }
        )
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
        try await load(
            pluginID: pluginID,
            pluginURL: pluginURL,
            settingsStore: settingsStore,
            operation: PluginNetworkOperation(purpose: .sourceSetup, operationID: UUID()),
            frozenScope: nil
        ) {
            PluginRunnerHostModules(
                net: AppNetModule(pluginID: pluginID, cookieJar: settingsStore.cookies, trust: settingsStore.trust),
                webview: AppWebviewModule()
            )
        }
    }

    /// Loads a runner for one download attempt with that attempt's modules. Loading and defaults match
    /// `loadRunner`; the caller owns the runner, so it is never cached here.
    @MainActor
    private static func loadDownloadRunner(
        pluginID: String,
        pluginURL: URL,
        settingsStore: PluginSettingsStore,
        modules: PluginRunnerHostModules,
        operation: PluginNetworkOperation,
        frozenScope: String?
    ) async throws -> ItoRunner {
        try await load(
            pluginID: pluginID,
            pluginURL: pluginURL,
            settingsStore: settingsStore,
            operation: operation,
            frozenScope: frozenScope
        ) { modules }
    }

    @MainActor
    private static func load(
        pluginID: String,
        pluginURL: URL,
        settingsStore: PluginSettingsStore,
        operation: PluginNetworkOperation,
        frozenScope: String?,
        makeModules: () -> PluginRunnerHostModules
    ) async throws -> ItoRunner {
        let (runner, defaults) = try await makeRunner(
            pluginID: pluginID,
            pluginURL: pluginURL,
            settingsStore: settingsStore,
            modules: makeModules()
        )
        let usable = try await applySchemaDefaults(
            from: {
                try await runner.getSettingsSurface(
                    context: settingsStore.networkContexts.context(
                        pluginID: pluginID, operation, frozenScope: frozenScope
                    )
                )
            },
            to: defaults,
            pluginID: pluginID
        )
        if usable { return runner }
        AppLogger.plugin.error("PluginManager: \(pluginID) crashed describing its settings; loading it again without defaults")
        return try await makeRunner(
            pluginID: pluginID,
            pluginURL: pluginURL,
            settingsStore: settingsStore,
            modules: makeModules()
        ).runner
    }

    @MainActor
    private static func makeRunner(
        pluginID: String,
        pluginURL: URL,
        settingsStore: PluginSettingsStore,
        modules: PluginRunnerHostModules
    ) async throws -> (runner: ItoRunner, defaults: AppDefaultsModule) {
        let runner = ItoRunner()
        let defaults = AppDefaultsModule(pluginId: pluginID, store: settingsStore)
        await runner.setNetModule(modules.net)
        await runner.setStdModule(DefaultStdModule())
        await runner.setDefaultsModule(defaults)
        await runner.setHtmlModule(DefaultHtmlModule())
        await runner.setWebviewModule(modules.webview)

        AppLogger.plugin.debug("\("🔌 [PluginManager] Loading bundle for \(pluginID)")...")
        do {
            _ = try await runner.loadBundle(from: pluginURL)
        } catch let error as ItoError {
            // A module built for another ABI, or needing a host function this Ito lacks, is refused here, once the
            // runner has read its ABI. The direction comes from the error.
            if let refusal = PluginIncompatibility.loading(error) {
                throw refusal
            }
            throw error
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

    /// Evicts the cached foreground runner only when it is the instance that failed. A crash reported late by an
    /// older instance must never evict the newer runner that replaced it; the comparison is by instance, as for
    /// `evictImageRunner`, so it cannot match a different runner.
    @MainActor
    func retireRunner(for pluginId: String, matching runner: ItoRunner) {
        guard let cached = runnerCache[pluginId], cached.runner === runner else { return }
        runnerCache.removeValue(forKey: pluginId)
        AppLogger.plugin.debug("🔌 [PluginManager] Retired crashed runner for \(pluginId)")
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

    /// Scans the Application Support/Plugins directory and parses all manifests. Acquires the directory gate;
    /// a failure is logged, not thrown.
    @MainActor
    public func reloadInstalledPlugins() async {
        do {
            try await withPluginDirectoryLease { lease in
                await reloadInstalledPluginsLocked(lease)
            }
        } catch {
            AppLogger.plugin.error("Failed to load installed plugins: \(error)")
        }
    }

    /// Performs strict readiness discovery, registers every installed manifest/file identity, and verifies all
    /// registered suites before publishing the cache. Acquires the directory gate.
    @MainActor
    public func discoverAndPrepareInstalledPlugins() async throws {
        try await discoverAndPrepareInstalledPlugins(failOnInvalidPlugin: true)
    }

    /// Performs discovery with explicit invalid-file handling. Acquires the directory gate; gate-held code calls
    /// `discoverAndPrepareInstalledPluginsLocked` instead.
    @MainActor
    public func discoverAndPrepareInstalledPlugins(failOnInvalidPlugin: Bool) async throws {
        try await withPluginDirectoryLease { lease in
            try await discoverAndPrepareInstalledPluginsLocked(failOnInvalidPlugin: failOnInvalidPlugin, lease)
        }
    }

    /// Runs `operation` holding the plugin directory gate. Gate-held functions take the lease it passes.
    @MainActor
    func withPluginDirectoryLease<Value>(
        _ operation: (PluginDirectoryLease) async throws -> Value
    ) async throws -> Value {
        try await directoryGate.withLease(operation)
    }

    /// Gate-held. Scans, prepares the settings identities, then publishes. Requires the directory gate.
    @MainActor
    func discoverAndPrepareInstalledPluginsLocked(
        failOnInvalidPlugin: Bool,
        _ lease: PluginDirectoryLease
    ) async throws {
        let installedPlugins = try await prepareInstalledPluginsPublicationLocked(
            failOnInvalidPlugin: failOnInvalidPlugin,
            lease
        )
        publishPreparedInstalledPluginsLocked(installedPlugins, lease)
    }

    /// Gate-held. Non-strict scan and publish that logs a failure. Used after a directory change has already
    /// happened, so the published state matches the disk. Requires the directory gate.
    @MainActor
    func reloadInstalledPluginsLocked(_ lease: PluginDirectoryLease) async {
        do {
            try await discoverAndPrepareInstalledPluginsLocked(failOnInvalidPlugin: false, lease)
        } catch {
            AppLogger.plugin.error("Failed to load installed plugins: \(error)")
        }
    }

    /// Gate-held. Scans and prepares settings identities without publishing. Requires the directory gate.
    @MainActor
    func prepareInstalledPluginsPublicationLocked(
        failOnInvalidPlugin: Bool,
        _ lease: PluginDirectoryLease
    ) async throws -> [String: InstalledPlugin] {
        let scan = try await scanInstalledPluginsLocked(failOnInvalidPlugin: failOnInvalidPlugin, lease)
        try pluginSettingsStore.prepareForDurableSnapshot(scan.discoveries)
        return scan.plugins
    }

    /// Restore-only scan. This reads bundle metadata and republishes the in-memory cache without registering
    /// identities, migrating suites, or creating runners. Acquires the directory gate.
    @MainActor
    public func reloadAfterRestore() async throws {
        try await withPluginDirectoryLease { lease in
            let scan = try await scanInstalledPluginsLocked(failOnInvalidPlugin: true, lease)
            publishPreparedInstalledPluginsLocked(scan.plugins, lease)
        }
    }

    /// Gate-held. Lists the plugin files and reads each once. A file that is gone by the time it is read counts as
    /// absent, in strict and non-strict discovery alike: whoever removed it publishes its own state. Requires the
    /// directory gate.
    @MainActor
    private func scanInstalledPluginsLocked(
        failOnInvalidPlugin: Bool,
        _ lease: PluginDirectoryLease
    ) async throws -> (
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

        for url in itoFiles {
            let reading: PluginPackageReading
            do {
                reading = try await packageReader(url)
            } catch where !fileManager.fileExists(atPath: url.path) {
                continue
            } catch {
                if failOnInvalidPlugin {
                    throw error
                }
                AppLogger.plugin.error(
                    "Failed to extract plugin info for \(url.lastPathComponent): \(error)"
                )
                continue
            }
            let filenameId = url.deletingPathExtension().lastPathComponent
            discoveries.append(
                PluginSettingsDiscovery(
                    pluginId: reading.manifest.info.id,
                    manifestId: reading.manifest.info.id,
                    filenameId: filenameId,
                    source: "installedFileScan"
                )
            )
            newCache[reading.manifest.info.id] = InstalledPlugin(
                url: url,
                info: reading.manifest.info,
                iconData: reading.icon,
                binary: reading.binary
            )
        }

        return (newCache, discoveries)
    }

    /// Gate-held. Publishes a prepared set of installed plugins, evicts the runners it invalidates, and activates
    /// trust for the plugins it lists. Requires the directory gate.
    @MainActor
    func publishPreparedInstalledPluginsLocked(
        _ newCache: [String: InstalledPlugin],
        _ lease: PluginDirectoryLease
    ) {
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
        publicationMirror.store(installedPluginsPublicationRevision)
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
