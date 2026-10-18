import OSLog
import Foundation
import Combine
import Nuke

@MainActor
public class StorageManager: ObservableObject {
    @Published public private(set) var diskCacheLimitGB = AppPreferenceCatalog.diskCacheLimitGB.defaultValue

    @Published public private(set) var currentCacheSizeBytes: Int = 0

    // Maintain a reference to our custom data cache
    private var dataCache: DataCache?
    private var settingsCancellable: AnyCancellable?
    private let pluginManager: PluginManager
    private var settingsStore: AppSettingsStore?

    public init(pluginManager: PluginManager) {
        self.pluginManager = pluginManager
        setupNukePipeline()
        refreshCacheSize()
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
        refreshCacheSize()
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

    public func refreshCacheSize() {
        if let dataCache = dataCache {
            self.currentCacheSizeBytes = dataCache.totalSize
        }
    }

    public func clearCache() {
        // Clear memory cache
        ImageCache.shared.removeAll()
        // Clear disk cache
        dataCache?.removeAll()

        // Also clear URLCache just in case anything else used it
        URLCache.shared.removeAllCachedResponses()

        refreshCacheSize()
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
