import Foundation
import Combine
import Nuke
import ito_runner

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

/// A request-specific key view over one bounded cache. Rebuilding Nuke's key with a prefixed image ID
/// retains its processors and thumbnail options without allocating a separate LRU for each header set.
nonisolated private final class SourceImageMemoryCache: ImageCaching, @unchecked Sendable {
    private let cache: ImageCache
    private let key: ImageCacheKey
    private let authority: NetworkRequestAuthority?

    init(cache: ImageCache, request: ImageRequest, partition: String) {
        self.cache = cache
        authority = request.urlRequest.flatMap { ImageRequestSourceAuthority.marked(on: $0) }
        var keyed = request
        let imageID = request.userInfo[.imageIdKey] as? String ?? request.imageId ?? ""
        keyed.userInfo[.imageIdKey] = "ito-source-\(partition):\(imageID)"
        key = ImageCacheKey(request: keyed)
    }

    private var isCurrent: Bool {
        guard let authority else { return false }
        return authority.context.authorizationScope == authority.contexts.liveScope(pluginID: authority.context.sourceID)
    }

    subscript(key: ImageCacheKey) -> ImageContainer? {
        get { isCurrent ? cache[self.key] : nil }
        set { if isCurrent { cache[self.key] = newValue } }
    }

    func removeAll() { cache.removeAll() }
}

/// Immutable dependencies; the one bounded source cache is thread-safe.
nonisolated private final class PluginImageCacheDelegate: ImagePipelineDelegate, @unchecked Sendable {
    let pluginMemory: (any ImageCaching)?
    private let pluginDisk: (any DataCaching)?
    private let diagnostics: any ImagePipelineDelegate
    private let sourceMemory: ImageCache

    /// Partition the caches, not Nuke's key: its complete processor/thumbnail identity stays intact.
    private func sourcePartition(_ request: ImageRequest) -> String? {
        guard let wire = request.urlRequest else { return nil }
        return ImageRequestSourceAuthority.cachePartition(on: wire)
    }

    init(epoch: String?, dataCache: (any DataCaching)?, sourceMemory: ImageCache, diagnostics: any ImagePipelineDelegate) {
        self.sourceMemory = sourceMemory
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
        if request.url?.scheme?.lowercased() == "ito", pluginMemory == nil { return nil }
        if let partition = sourcePartition(request) {
            return SourceImageMemoryCache(cache: sourceMemory, request: request, partition: partition)
        }
        return request.url?.scheme?.lowercased() == "ito" ? pluginMemory : pipeline.configuration.imageCache
    }

    func dataCache(for request: ImageRequest, pipeline: ImagePipeline) -> (any DataCaching)? {
        if let partition = sourcePartition(request) {
            guard let underlying = request.url?.scheme?.lowercased() == "ito"
                ? pluginDisk : pipeline.configuration.dataCache else { return nil }
            return PluginEpochDataCache(underlying: underlying, epoch: partition)
        }
        return request.url?.scheme?.lowercased() == "ito" ? pluginDisk : pipeline.configuration.dataCache
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
    private let sourceMemory: ImageCache
    private var scopeObservation: AnyCancellable?

    init(
        dataCache: (any DataCaching)?,
        dataLoader: any DataLoading,
        diagnostics: any ImagePipelineDelegate,
        publish: @escaping @Sendable (ImagePipeline) -> Void = { ImagePipeline.shared = $0 },
        contexts: PluginNetworkContexts? = nil,
        sourceMemory: ImageCache = ImageCache()
    ) {
        self.dataCache = dataCache
        self.dataLoader = dataLoader
        self.diagnostics = diagnostics
        self.publish = publish
        self.sourceMemory = sourceMemory
        scopeObservation = contexts?.scopeChanges.sink { @Sendable [weak self] _ in
            self?.sourceMemory.removeAll()
        }
    }

    func startObserving(_ store: PluginSettingsStore) throws {
        observation = try store.observeImageCacheEpoch { [weak self] epoch in
            self?.install(epoch: epoch)
        }
    }

    func install(epoch: String?) {
        lock.withLock {
            guard !installed || currentEpoch != epoch else { return }
            sourceMemory.removeAll()
            let delegate = PluginImageCacheDelegate(
                epoch: epoch, dataCache: dataCache, sourceMemory: sourceMemory, diagnostics: diagnostics
            )
            let pipeline = ImagePipeline(delegate: delegate) {
                $0.dataCache = dataCache
                $0.dataLoader = dataLoader
                // URL-only coalescing can promote a speculative subscriber to a foreground transfer.
                // Keep cache sharing, but let each loader invocation retain its own immutable authority.
                $0.isTaskCoalescingEnabled = false
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
        lock.withLock {
            currentDelegate?.pluginMemory?.removeAll()
            sourceMemory.removeAll()
        }
    }
}
