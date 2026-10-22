import OSLog
import Foundation
import Combine
import Nuke

@MainActor
public class StorageManager: ObservableObject {
    @Published public private(set) var diskCacheLimitGB = AppPreferenceCatalog.diskCacheLimitGB.defaultValue

    /// Disk cache size from the last measurement; `nil` until first measured.
    @Published public private(set) var currentCacheSizeBytes: Int?

    // Maintain a reference to our custom data cache
    private var dataCache: DataCache?
    private var settingsCancellable: AnyCancellable?
    private var imagePipelineController: PluginImagePipelineController?
    private let pluginManager: PluginManager
    /// Bumped by every measurement so an older, slower one cannot overwrite a newer result.
    private var cacheSizeGeneration = 0
    private var settingsStore: AppSettingsStore?

    public init(pluginManager: PluginManager) {
        self.pluginManager = pluginManager
        setupNukePipeline()
    }

    func configure(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
        diskCacheLimitGB = settingsStore.diskCacheLimitGB
        updateCacheLimit()
        settingsCancellable = settingsStore.$diskCacheLimitGB
            .dropFirst()
            .sink { [weak self] value in
                self?.diskCacheLimitGB = value
                self?.updateCacheLimit()
            }
    }

    public func reload() throws {
        guard let settingsStore else {
            throw StorageManagerError.settingsUnavailable
        }
        diskCacheLimitGB = settingsStore.diskCacheLimitGB
        updateCacheLimit()
    }

    private func setupNukePipeline() {
        let capacityBytes = Int(diskCacheLimitGB * 1024 * 1024 * 1024)
        do {
            let cache = try DataCache(name: "com.ito.datacache")
            cache.sizeLimit = capacityBytes
            dataCache = cache
        } catch {
            AppLogger.general.error("Image disk cache is unavailable.")
        }

        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": CloudflareManager.defaultUserAgent]
        let loader = PluginDataLoader(configuration: config, pluginManager: pluginManager)
        let controller = PluginImagePipelineController(
            dataCache: dataCache,
            dataLoader: loader,
            diagnostics: NukeDiagnosticDelegate.shared
        )
        imagePipelineController = controller
        do {
            try controller.startObserving(pluginManager.pluginSettingsStore)
        } catch {
            // HTTP image loading still works, but unknown cache authority never reuses private
            // plugin images from a previous configuration.
            AppLogger.general.error("Plugin image cache metadata is unavailable; private caches are disabled.")
            controller.install(epoch: nil)
        }
    }

    private func updateCacheLimit() {
        let capacityBytes = Int(diskCacheLimitGB * 1024 * 1024 * 1024)
        dataCache?.sizeLimit = capacityBytes
    }

    /// Measures the disk cache off the main actor; walking the cache directory is disk IO.
    public func refreshCacheSize() async {
        guard let dataCache else { return }
        cacheSizeGeneration += 1
        let generation = cacheSizeGeneration
        let size = await Task.detached(priority: .utility) {
            dataCache.totalSize
        }.value
        guard generation == cacheSizeGeneration else { return }
        currentCacheSizeBytes = size
    }

    public func clearCache() async {
        ImageCache.shared.removeAll()
        imagePipelineController?.clearPluginMemoryCache()
        URLCache.shared.removeAllCachedResponses()
        guard let dataCache else { return }
        cacheSizeGeneration += 1
        let generation = cacheSizeGeneration
        // `removeAll()` only stages the deletion; `flush()` waits for it to reach disk.
        let size = await Task.detached(priority: .userInitiated) {
            dataCache.removeAll()
            dataCache.flush()
            return dataCache.totalSize
        }.value
        guard generation == cacheSizeGeneration else { return }
        currentCacheSizeBytes = size
    }

    public func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

public enum StorageManagerError: Error, Equatable {
    case settingsUnavailable
}
