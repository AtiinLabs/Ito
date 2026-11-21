import Combine
import Foundation
import Nuke
import UIKit
import ito_runner

struct ReaderPageImageKey: Hashable {
    private struct Header: Hashable {
        let name: String
        let value: String
    }

    private let url: URL?
    private let method: String?
    private let body: Data?
    private let cachePolicy: UInt
    private let headers: [Header]

    init(request: URLRequest) {
        url = request.url
        method = request.httpMethod
        body = request.httpBody
        cachePolicy = UInt(request.cachePolicy.rawValue)
        headers = (request.allHTTPHeaderFields ?? [:])
            .map { Header(name: $0.key.lowercased(), value: $0.value) }
            .sorted { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
    }
}

struct ReaderPageImageDescriptor {
    let pageID: String
    let request: URLRequest
    var key: ReaderPageImageKey { ReaderPageImageKey(request: request) }

    init(pageID: String, request: URLRequest) {
        self.pageID = pageID
        self.request = request
    }
}

enum ReaderImageConsumer: Equatable {
    case visible
    case prefetch
}

struct ReaderImageLease: Hashable {
    fileprivate let id: UUID
    let key: ReaderPageImageKey
}

enum ReaderPageImagePhase {
    case idle
    case loading
    case ready(UIImage)
    case failed
}

struct ReaderPageImageState {
    let phase: ReaderPageImagePhase
    let pixelSize: CGSize?
    let revision: UInt64
}

/// A subscription to one image request's state; cancelling it, or releasing it, ends it.
@MainActor
final class ReaderImageObservation {
    private var cancellation: (@MainActor @Sendable () -> Void)?

    fileprivate init(cancellation: @escaping @MainActor @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }

    deinit {
        // The last owner may release this anywhere; the session is only touched on the main actor.
        guard let cancellation else { return }
        Task { @MainActor in cancellation() }
    }
}

/// The page images of one reader: one request per URL and headers, shared by the visible page
/// and prefetch, and a failure that stays until Try Again.
///
/// A request has at most one transfer. Its purpose is fixed when that transfer starts and is never upgraded:
/// a visible reader that joins a speculative transfer keeps it under the speculative authority and raises only
/// its Nuke priority. If that transfer is refused or fails while the reader still waits, the reader gets one
/// fresh transfer under foreground authority; that fallback's failure is terminal until Try Again.
@MainActor
final class ReaderPageImageSession {
    private struct Entry {
        var request: URLRequest?
        var phase: ReaderPageImagePhase = .idle
        var pixelSize: CGSize?
        var revision: UInt64 = 0
        var leases: [UUID: ReaderImageConsumer] = [:]
        var observers: [UUID: @MainActor (ReaderPageImageState) -> Void] = [:]
        /// The transfer in flight for this request, if any. Its purpose is `taskIsPrefetch`, as it started.
        var task: ImageTask?
        var generation: UInt64 = 0
        var taskIsPrefetch = false
        var isPrefetchQueued = false
    }

    private let pipelineOverride: ImagePipeline?
    private let sourceAuthority: NetworkRequestAuthority?
    private var authorityObservation: AnyCancellable?
    private var sourceRevoked = false
    private var isSourceRevoked: Bool {
        sourceRevoked || sourceAuthority.map {
            $0.context.authorizationScope != $0.contexts.liveScope(pluginID: $0.context.sourceID)
        } == true
    }
    /// Serves `ito-offline://` pages. Without one, those requests fail and never reach the shared pipeline.
    private let offlinePipeline: ImagePipeline?
    private var entries: [ReaderPageImageKey: Entry] = [:]
    private var prefetchOrder: [ReaderPageImageKey] = []
    private var runningPrefetches = 0
    private let maximumPrefetches = 2
    /// Every started task gets a new number, unique for the session's lifetime, so a late result
    /// of a cancelled task never matches a request that was forgotten and added again.
    private var lastTaskGeneration: UInt64 = 0

    init(pipeline: ImagePipeline? = nil, offlinePipeline: ImagePipeline? = nil, sourceAuthority: NetworkRequestAuthority? = nil) {
        pipelineOverride = pipeline
        self.offlinePipeline = offlinePipeline
        self.sourceAuthority = sourceAuthority
        authorityObservation = sourceAuthority?.changes.sink { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let authority = self.sourceAuthority,
                      authority.context.authorizationScope != authority.contexts.liveScope(pluginID: authority.context.sourceID) else { return }
                self.sourceRevoked = true
                self.deactivate()
            }
        }
    }

    /// A session whose page requests are bound to `pluginID`'s current source authority. Every reader of a
    /// source's images (manga, novel) is made here, so none can load source images as app-owned traffic.
    static func sourceBound(
        pluginID: String,
        contexts: PluginNetworkContexts,
        pipeline: ImagePipeline? = nil,
        offlinePipeline: ImagePipeline? = nil
    ) -> ReaderPageImageSession {
        ReaderPageImageSession(
            pipeline: pipeline,
            offlinePipeline: offlinePipeline,
            sourceAuthority: ImageRequestSourceAuthority.capture(pluginID: pluginID, contexts: contexts)
        )
    }

    private func boundRequest(_ request: URLRequest, purpose: ImageRequestPurpose) -> URLRequest {
        let marked = purpose.applied(to: request)
        guard let sourceAuthority else { return marked }
        return ImageRequestSourceAuthority.applied(
            ImageRequestSourceAuthority.withPurpose(purpose, authority: sourceAuthority), to: marked
        )
    }

    /// The pipeline for `request`. Offline copies use only the offline pipeline and never reach the
    /// network. Other requests use the injected pipeline, or the app's current one: that is replaced when
    /// plugin image settings change, so a session without an injected pipeline always reads it fresh.
    private func imagePipeline(for request: URLRequest) -> ImagePipeline? {
        if request.url?.scheme == OfflineAssetLocator.scheme {
            return offlinePipeline
        }
        return pipelineOverride ?? .shared
    }

    func state(for key: ReaderPageImageKey) -> ReaderPageImageState {
        guard let entry = entries[key] else {
            return ReaderPageImageState(phase: .idle, pixelSize: nil, revision: 0)
        }
        return snapshot(entry)
    }

    /// The image's decoded size if this session or the image pipeline's memory cache knows it,
    /// without starting a request.
    func knownPixelSize(for descriptor: ReaderPageImageDescriptor) -> CGSize? {
        if let size = entries[descriptor.key]?.pixelSize { return size }
        guard let pipeline = imagePipeline(for: descriptor.request) else { return nil }
        let request = ImageRequest(urlRequest: boundRequest(descriptor.request, purpose: .foregroundReading))
        guard let image = pipeline.cache.cachedImage(for: request, caches: [.memory])?.image else { return nil }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    func acquire(_ descriptor: ReaderPageImageDescriptor, consumer: ReaderImageConsumer) -> ReaderImageLease {
        let key = descriptor.key
        var entry = entries[key] ?? Entry(request: descriptor.request)
        entry.request = descriptor.request
        let id = UUID()
        entry.leases[id] = consumer
        if consumer == .visible, entry.isPrefetchQueued {
            entry.isPrefetchQueued = false
            prefetchOrder.removeAll { $0 == key }
        }
        entries[key] = entry
        if consumer == .visible, entry.task != nil {
            // The page's transfer is already under way, so the reader joins it: no second request and no
            // cancellation. A speculative transfer keeps its speculative authority; `fail` gives this reader one
            // foreground attempt if that transfer is refused while this lease remains.
            updatePriority(for: key)
        }
        if case .idle = entry.phase {
            switch consumer {
            case .visible: start(key)
            case .prefetch: enqueuePrefetch(key)
            }
        }
        return ReaderImageLease(id: id, key: key)
    }

    func release(_ lease: ReaderImageLease) {
        guard var entry = entries[lease.key], let consumer = entry.leases.removeValue(forKey: lease.id) else { return }
        var shouldPublish = false
        if consumer == .visible, !entry.leases.values.contains(.visible), case .ready = entry.phase {
            entry.phase = .idle
            shouldPublish = true
        }
        if entry.leases.isEmpty, entry.isPrefetchQueued {
            prefetchOrder.removeAll { $0 == lease.key }
            entry.isPrefetchQueued = false
        }
        if entry.leases.isEmpty, let task = entry.task {
            entry.generation &+= 1
            if entry.taskIsPrefetch { runningPrefetches = max(0, runningPrefetches - 1) }
            task.cancel()
            entry.task = nil
            entry.taskIsPrefetch = false
            if case .loading = entry.phase { entry.phase = .idle }
            shouldPublish = true
        }
        entries[lease.key] = entry
        // A transfer that outlives its last visible reader keeps running for its prefetch lease, at low priority.
        if consumer == .visible { updatePriority(for: lease.key) }
        if shouldPublish { publish(lease.key) }
        startQueuedPrefetches()
    }

    func observe(_ key: ReaderPageImageKey, handler: @escaping @MainActor (ReaderPageImageState) -> Void) -> ReaderImageObservation {
        var entry = entries[key] ?? Entry(request: nil)
        let id = UUID()
        entry.observers[id] = handler
        entries[key] = entry
        return ReaderImageObservation { [weak self] in
            self?.entries[key]?.observers.removeValue(forKey: id)
        }
    }

    func setPrefetch(_ descriptors: [ReaderPageImageDescriptor]) {
        let desired = Set(descriptors.map(\.key))
        let staleKeys = entries.compactMap { key, entry in
            entry.leases.values.contains(.prefetch) && !desired.contains(key) ? key : nil
        }
        for key in staleKeys {
            guard let entry = entries[key] else { continue }
            let ids = entry.leases.compactMap { $0.value == .prefetch ? $0.key : nil }
            ids.forEach { release(ReaderImageLease(id: $0, key: key)) }
        }
        var submitted = Set<ReaderPageImageKey>()
        for descriptor in descriptors where submitted.insert(descriptor.key).inserted {
            guard !(entries[descriptor.key]?.leases.values.contains(.prefetch) ?? false) else { continue }
            _ = acquire(descriptor, consumer: .prefetch)
        }
    }

    func retry(_ descriptor: ReaderPageImageDescriptor) {
        let key = descriptor.key
        guard var entry = entries[key] else { return }
        guard case .failed = entry.phase else { return }
        entry.phase = .idle
        entry.pixelSize = nil
        entry.request = descriptor.request
        entries[key] = entry
        if entry.leases.values.contains(.visible) {
            start(key)
        } else if !entry.leases.isEmpty {
            enqueuePrefetch(key)
        } else {
            publish(key)
        }
    }

    func retainRequests(_ keys: Set<ReaderPageImageKey>) {
        for key in Array(entries.keys) where !keys.contains(key) {
            guard var entry = entries.removeValue(forKey: key) else { continue }
            entry.generation &+= 1
            if entry.taskIsPrefetch { runningPrefetches = max(0, runningPrefetches - 1) }
            entry.task?.cancel()
            prefetchOrder.removeAll { $0 == key }
        }
        startQueuedPrefetches()
    }

    func deactivate() {
        for key in Array(entries.keys) {
            guard var entry = entries[key] else { continue }
            entry.generation &+= 1
            entry.task?.cancel()
            entry.task = nil
            entry.taskIsPrefetch = false
            entry.leases.removeAll()
            entry.observers.removeAll()
            entry.isPrefetchQueued = false
            if case .loading = entry.phase { entry.phase = .idle }
            if case .ready = entry.phase { entry.phase = .idle }
            entries[key] = entry
            publish(key)
        }
        prefetchOrder.removeAll()
        runningPrefetches = 0
    }

    /// Sets the transfer's Nuke priority from its readers: a visible reader raises it, and work that only
    /// speculative readers want is lowered. The authority of the transfer is not changed.
    private func updatePriority(for key: ReaderPageImageKey) {
        guard let entry = entries[key], let task = entry.task else { return }
        task.priority = entry.leases.values.contains(.visible) ? .high : .low
    }

    private func start(_ key: ReaderPageImageKey) {
        guard !isSourceRevoked, var entry = entries[key], entry.task == nil, let request = entry.request else { return }
        if case .failed = entry.phase { return }
        entry.isPrefetchQueued = false
        prefetchOrder.removeAll { $0 == key }
        guard let pipeline = imagePipeline(for: request) else {
            // An offline page without an offline pipeline cannot load; it fails like any other load.
            entry.phase = .failed
            entries[key] = entry
            publish(key)
            return
        }
        // The request starts for the consumers present now: a visible lease makes it a foreground read, and
        // otherwise it is a prefetch. The mark is in memory only; it never changes the key or the cache identity.
        let countsAsPrefetch = !entry.leases.values.contains(where: { $0 == .visible })
        let purpose: ImageRequestPurpose = countsAsPrefetch ? .prefetch : .foregroundReading
        var imageRequest = ImageRequest(urlRequest: boundRequest(request, purpose: purpose))
        imageRequest.priority = countsAsPrefetch ? .low : .high
        // An image still in memory needs no request: a page shown again appears at once, and a
        // prefetch that precedes the page's view does not turn that into a spinner.
        if let image = pipeline.cache.cachedImage(for: imageRequest, caches: [.memory])?.image {
            entry.phase = entry.leases.values.contains(.visible) ? .ready(image) : .idle
            entry.pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            entries[key] = entry
            publish(key)
            return
        }
        lastTaskGeneration &+= 1
        entry.generation = lastTaskGeneration
        let generation = lastTaskGeneration
        entry.phase = .loading
        if countsAsPrefetch { runningPrefetches += 1 }
        entry.taskIsPrefetch = countsAsPrefetch
        entries[key] = entry
        let task = pipeline.imageTask(with: imageRequest)
        entries[key]?.task = task
        publish(key)
        Task { [weak self] in
            do {
                let response = try await task.response
                self?.complete(key, generation: generation, response: response)
            } catch {
                self?.fail(key, generation: generation)
            }
        }
    }

    private func complete(_ key: ReaderPageImageKey, generation: UInt64, response: ImageResponse) {
        guard !isSourceRevoked, var entry = entries[key], entry.generation == generation else { startQueuedPrefetches(); return }
        if entry.taskIsPrefetch { runningPrefetches = max(0, runningPrefetches - 1) }
        entry.task = nil
        entry.taskIsPrefetch = false
        let image = response.image
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
            entry.pixelSize = size
            entry.phase = entry.leases.values.contains(where: { $0 == .visible }) ? .ready(image) : .idle
        } else {
            entry.phase = .failed
        }
        entries[key] = entry
        publish(key)
        startQueuedPrefetches()
    }

    private func fail(_ key: ReaderPageImageKey, generation: UInt64) {
        guard var entry = entries[key], entry.generation == generation else { startQueuedPrefetches(); return }
        let wasSpeculative = entry.taskIsPrefetch
        if wasSpeculative { runningPrefetches = max(0, runningPrefetches - 1) }
        entry.task = nil
        entry.taskIsPrefetch = false
        // A speculative transfer that was refused or failed while a reader still waits for the page is not the
        // page's answer. That reader gets one attempt under foreground authority, derived from the same frozen
        // source scope. Revocation is checked now: a changed source never starts the fallback. A transfer ended
        // by release, deactivation or retention already failed the generation check above.
        if wasSpeculative, entry.leases.values.contains(.visible), !isSourceRevoked {
            entry.phase = .idle
            entries[key] = entry
            start(key)
            startQueuedPrefetches()
            return
        }
        // A foreground failure is terminal until an explicit retry. A speculative one with no reader is silent,
        // and the entry stays startable so a later foreground read is admitted on its own authority.
        if entry.leases.values.contains(.visible) { entry.phase = .failed } else { entry.phase = .idle }
        entries[key] = entry
        publish(key)
        startQueuedPrefetches()
    }

    private func enqueuePrefetch(_ key: ReaderPageImageKey) {
        guard var entry = entries[key], entry.task == nil else { return }
        if case .failed = entry.phase { return }
        guard !entry.isPrefetchQueued else { return }
        entry.isPrefetchQueued = true
        entries[key] = entry
        prefetchOrder.append(key)
        startQueuedPrefetches()
    }

    private func startQueuedPrefetches() {
        while runningPrefetches < maximumPrefetches, let key = prefetchOrder.first {
            prefetchOrder.removeFirst()
            guard var entry = entries[key], entry.isPrefetchQueued,
                  entry.leases.values.contains(where: { $0 == .prefetch }) else { continue }
            entry.isPrefetchQueued = false
            entries[key] = entry
            start(key)
        }
    }

    private func publish(_ key: ReaderPageImageKey) {
        guard var entry = entries[key] else { return }
        entry.revision &+= 1
        entries[key] = entry
        let value = snapshot(entry)
        // An observer may cancel others while being notified; those are not called.
        for id in Array(entry.observers.keys) {
            entries[key]?.observers[id]?(value)
        }
    }

    private func snapshot(_ entry: Entry) -> ReaderPageImageState {
        ReaderPageImageState(phase: entry.phase, pixelSize: entry.pixelSize, revision: entry.revision)
    }
}
