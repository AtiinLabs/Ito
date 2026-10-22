import Foundation
import Nuke

/// Uses Nuke's complete keys (including processors and thumbnail options) inside one opaque
/// configuration partition. Old requests retain their old wrapper when settings change.
nonisolated final class PluginEpochDataCache: DataCaching {
    private let underlying: any DataCaching
    private let prefix: String

    init(underlying: any DataCaching, epoch: String) {
        self.underlying = underlying
        self.prefix = "ito-image-\(epoch):"
    }

    func cachedData(for key: String) -> Data? { underlying.cachedData(for: prefix + key) }
    func containsData(for key: String) -> Bool { underlying.containsData(for: prefix + key) }
    func storeData(_ data: Data, for key: String) { underlying.storeData(data, for: prefix + key) }
    func removeData(for key: String) { underlying.removeData(for: prefix + key) }
    func removeAll() { underlying.removeAll() }
}

nonisolated private final class PluginImageCacheDelegate: ImagePipelineDelegate {
    let pluginMemory: (any ImageCaching)?
    private let pluginDisk: (any DataCaching)?
    private let diagnostics: any ImagePipelineDelegate

    init(epoch: String?, dataCache: (any DataCaching)?, diagnostics: any ImagePipelineDelegate) {
        self.diagnostics = diagnostics
        if let epoch, PluginImageCacheEpoch.isValidEpoch(epoch) {
            pluginMemory = ImageCache()
            pluginDisk = dataCache.map { PluginEpochDataCache(underlying: $0, epoch: epoch) }
        } else {
            // Missing/corrupt metadata must never select an old or unpartitioned plugin cache.
            pluginMemory = nil
            pluginDisk = nil
        }
    }

    func imageCache(for request: ImageRequest, pipeline: ImagePipeline) -> (any ImageCaching)? {
        request.url?.scheme?.lowercased() == "ito" ? pluginMemory : pipeline.configuration.imageCache
    }

    func dataCache(for request: ImageRequest, pipeline: ImagePipeline) -> (any DataCaching)? {
        request.url?.scheme?.lowercased() == "ito" ? pluginDisk : pipeline.configuration.dataCache
    }

    func imageTask(_ task: ImageTask, didReceiveEvent event: ImageTask.Event, pipeline: ImagePipeline) {
        diagnostics.imageTask(task, didReceiveEvent: event, pipeline: pipeline)
    }
}

/// Publishes a new pipeline synchronously with committed configuration changes. The observer
/// callback runs on the database writer: it never touches the Keychain or starts a transaction.
/// Immutable delegates keep late responses confined to their original account/server partition.
nonisolated final class PluginImagePipelineController: @unchecked Sendable {
    private let dataCache: (any DataCaching)?
    private let dataLoader: any DataLoading
    private let diagnostics: any ImagePipelineDelegate
    private let publish: @Sendable (ImagePipeline) -> Void
    private let lock = NSLock()
    private var installed = false
    private var currentEpoch: String?
    private var currentDelegate: PluginImageCacheDelegate?
    private var observation: PluginImageCacheEpochObservation?

    init(
        dataCache: (any DataCaching)?,
        dataLoader: any DataLoading,
        diagnostics: any ImagePipelineDelegate,
        publish: @escaping @Sendable (ImagePipeline) -> Void = { ImagePipeline.shared = $0 }
    ) {
        self.dataCache = dataCache
        self.dataLoader = dataLoader
        self.diagnostics = diagnostics
        self.publish = publish
    }

    func startObserving(_ store: PluginSettingsStore) throws {
        observation = try store.observeImageCacheEpoch { [weak self] epoch in
            self?.install(epoch: epoch)
        }
    }

    func install(epoch: String?) {
        lock.withLock {
            guard !installed || currentEpoch != epoch else { return }
            let delegate = PluginImageCacheDelegate(epoch: epoch, dataCache: dataCache, diagnostics: diagnostics)
            let pipeline = ImagePipeline(delegate: delegate) {
                $0.dataCache = dataCache
                $0.dataLoader = dataLoader
                $0.makeImageDecoder = ItoImageDecoders.make(for:)
            }
            currentDelegate?.pluginMemory?.removeAll()
            currentDelegate = delegate
            currentEpoch = epoch
            installed = true
            publish(pipeline)
        }
    }

    func clearPluginMemoryCache() {
        lock.withLock { currentDelegate?.pluginMemory?.removeAll() }
    }
}
