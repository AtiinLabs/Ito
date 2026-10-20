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
            let dataCache = try DataCache(name: "com.ito.datacache")
            dataCache.sizeLimit = capacityBytes
            self.dataCache = dataCache

            // Set up Nuke to use our aggressive data cache instead of URLCache
            ImagePipeline.shared = ImagePipeline(delegate: NukeDiagnosticDelegate.shared) {
                $0.dataCache = dataCache
                $0.makeImageDecoder = ItoImageDecoders.make(for:)
                let config = URLSessionConfiguration.default
                config.urlCache = nil
                config.httpAdditionalHeaders = ["User-Agent": CloudflareManager.defaultUserAgent]
                $0.dataLoader = PluginDataLoader(
                    configuration: config,
                    pluginManager: pluginManager
                )
            }
        } catch {
            AppLogger.general.error("Failed to initialize Nuke DataCache: \(error)")
            // Fallback preserves PluginDataLoader and diagnostic delegate even if DataCache fails
            let config = URLSessionConfiguration.default
            config.httpAdditionalHeaders = ["User-Agent": CloudflareManager.defaultUserAgent]
            ImagePipeline.shared = ImagePipeline(delegate: NukeDiagnosticDelegate.shared) {
                $0.makeImageDecoder = ItoImageDecoders.make(for:)
                $0.dataLoader = PluginDataLoader(
                    configuration: config,
                    pluginManager: pluginManager
                )
            }
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
