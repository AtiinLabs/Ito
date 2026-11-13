import Combine
import Foundation
import GRDB
import ito_runner
@testable import Ito

/// Holds a unit of work until a test releases it. `awaitArrival` returns once the work has reached the
/// gate, so a test can act at a known point. A cancelled waiter throws `cancellationError`.
actor DownloadTestGate {
    private let cancellationError: any Error
    private var entered = false
    private var released = false
    private var arrivalWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var releaseWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelled = false
    private var cancellationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(cancellationError: any Error = CancellationError()) {
        self.cancellationError = cancellationError
    }

    /// Called by the work under test. Waits for `release()`, or throws when the task is cancelled.
    func pass() async throws {
        entered = true
        let waiters = arrivalWaiters
        arrivalWaiters = [:]
        for waiter in waiters.values {
            waiter.resume()
        }
        if released {
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: cancellationError)
                    return
                }
                releaseWaiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Waits until the work has reached the gate. A cancelled waiter returns, so a test that ends by its time
    /// limit does not hang here.
    func awaitArrival() async {
        if entered {
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                arrivalWaiters[id] = continuation
            }
        } onCancel: {
            Task { await self.dropArrivalWaiter(id) }
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters = [:]
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    /// Returns once a waiter inside `pass()` has been cancelled. It never completes by being released, so
    /// a test that expects a cancellation fails by time limit rather than by passing for the wrong reason.
    func awaitCancellation() async {
        if cancelled {
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                cancellationWaiters[id] = continuation
            }
        } onCancel: {
            Task { await self.dropCancellationWaiter(id) }
        }
    }

    /// Whether the gate was ever released.
    var wasReleased: Bool { released }

    private func dropArrivalWaiter(_ id: UUID) {
        arrivalWaiters.removeValue(forKey: id)?.resume()
    }

    private func dropCancellationWaiter(_ id: UUID) {
        cancellationWaiters.removeValue(forKey: id)?.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        cancelled = true
        let observers = cancellationWaiters
        cancellationWaiters = [:]
        for observer in observers.values {
            observer.resume()
        }
        releaseWaiters.removeValue(forKey: id)?.resume(throwing: cancellationError)
    }
}

/// Counts calls made from any thread.
nonisolated final class DownloadCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}

/// Records the host contexts a fake runner or transport received, in call order.
nonisolated final class NetworkContextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [NetworkOperationContext] = []

    var snapshot: [NetworkOperationContext] {
        lock.withLock { received }
    }

    func record(_ context: NetworkOperationContext) {
        lock.withLock { received.append(context) }
    }
}

/// The plugin-side state a scripted source exposes to a download attempt: what it lists, whether the
/// installed plugin and its trust still match, and what its hook does while listing.
nonisolated final class ScriptedSourceState: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    private var trust = 0
    private var listingHook: (@Sendable (PluginRunnerHostModules) async -> Void)?
    private var listingGate: DownloadTestGate?
    private var listedRequests: [(entry: MediaEntry, chapter: Chapter)] = []
    private var pages: [Page]
    private var replacementTarget: Chapter? = Chapter(key: "chapter-1")
    let imageRunnerCreations = DownloadCallCounter()
    let listings = DownloadCallCounter()
    let contexts = NetworkContextRecorder()

    init(pages: [Page]) {
        self.pages = pages
    }

    var publicationRevision: Int {
        lock.withLock { revision }
    }

    var trustGeneration: Int {
        lock.withLock { trust }
    }

    var currentPages: [Page] {
        lock.withLock { pages }
    }

    var currentReplacementTarget: Chapter? {
        lock.withLock { replacementTarget }
    }

    func setReplacementTarget(_ target: Chapter?) {
        lock.withLock { replacementTarget = target }
    }

    var currentListingHook: (@Sendable (PluginRunnerHostModules) async -> Void)? {
        lock.withLock { listingHook }
    }

    /// Republishes the installed plugins, as any install or refresh does. Runtimes built before this see
    /// themselves as stale; a runtime built afterwards is current again.
    func republish() {
        lock.withLock { revision += 1 }
    }

    /// Changes the source's trusted certificates. Runtimes built before this see their trust as stale.
    func changeTrust() {
        lock.withLock { trust += 1 }
    }

    func setListingHook(_ hook: @escaping @Sendable (PluginRunnerHostModules) async -> Void) {
        lock.withLock { listingHook = hook }
    }

    func setPages(_ newPages: [Page]) {
        lock.withLock { pages = newPages }
    }

    var currentListingGate: DownloadTestGate? {
        lock.withLock { listingGate }
    }

    /// Holds the listing until the test releases it. A cancelled listing fails as a plugin error.
    func setListingGate(_ gate: DownloadTestGate) {
        lock.withLock { listingGate = gate }
    }

    /// Every entry and chapter a listing was asked for, in order.
    var listedRequestsSnapshot: [(entry: MediaEntry, chapter: Chapter)] {
        lock.withLock { listedRequests }
    }

    func recordListing(entry: MediaEntry, chapter: Chapter) {
        lock.withLock { listedRequests.append((entry, chapter)) }
    }
}

/// Lists the scripted pages. It runs the hook first, with the same modules the download runtime holds.
nonisolated final class ScriptedChapterPages: ChapterPageProviding, @unchecked Sendable {
    private let state: ScriptedSourceState
    private let modules: PluginRunnerHostModules

    init(state: ScriptedSourceState, modules: PluginRunnerHostModules) {
        self.state = state
        self.modules = modules
    }

    func replacementChapter(entry: MediaEntry, key: String, context: NetworkOperationContext) async throws -> Chapter? {
        state.contexts.record(context)
        return state.currentReplacementTarget
    }

    func getChapterPages(entry: MediaEntry, chapter: Chapter, context: NetworkOperationContext) async throws -> [Page] {
        state.listings.increment()
        state.contexts.record(context)
        state.recordListing(entry: entry, chapter: chapter)
        if let hook = state.currentListingHook {
            await hook(modules)
        }
        if let gate = state.currentListingGate {
            do {
                try await gate.pass()
            } catch {
                // A plugin reports a cancelled host call as its own failure, not as a cancellation.
                throw ScriptedPluginError()
            }
        }
        return state.currentPages
    }
}

/// What a scripted plugin throws when its listing fails.
nonisolated struct ScriptedPluginError: Error {}

/// An image runner that answers every `ito://` image with JPEG bytes.
nonisolated final class ScriptedImageRunner: PluginImageRunner, @unchecked Sendable {
    private let contexts: NetworkContextRecorder

    init(contexts: NetworkContextRecorder) {
        self.contexts = contexts
    }

    func getImageRequest(_ locator: String, context: NetworkOperationContext) async throws -> PluginImageRequest? {
        contexts.record(context)
        return nil
    }

    func getImageOrigins(context: NetworkOperationContext) async throws -> [String]? {
        contexts.record(context)
        return nil
    }

    func handleImage(_ locator: String, context: NetworkOperationContext) async throws -> Data? {
        contexts.record(context)
        return OfflineStoreFixture.jpeg("ito-\(locator)")
    }
}

/// The transport under the download's net module. It records calls and answers with an empty 200.
nonisolated final class ScriptedInnerNet: NetModule, @unchecked Sendable {
    let calls = DownloadCallCounter()
    private let contexts: NetworkContextRecorder

    init(contexts: NetworkContextRecorder) {
        self.contexts = contexts
    }

    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        calls.increment()
        contexts.record(context)
        return NetResponse(status: 200, headers: [:], body: [])
    }
}

/// Asset transfers the tests script. Every direct request is recorded in order. A gate set for a URL
/// holds that transfer until the test releases it. A response set for a URL replaces the default JPEG.
nonisolated final class ScriptedAssetFetcher: DirectAssetFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var directURLs: [String] = []
    private var gates: [String: DownloadTestGate] = [:]
    private var responses: [String: FetchedAsset] = [:]
    let pluginRequests = DownloadCallCounter()

    var requestedURLs: [String] {
        lock.withLock { directURLs }
    }

    /// A gate for one URL. A cancelled transfer behind it throws `URLError(.cancelled)`, as URLSession does.
    func gate(for url: String) -> DownloadTestGate {
        let gate = DownloadTestGate(cancellationError: URLError(.cancelled))
        lock.withLock { gates[url] = gate }
        return gate
    }

    func setResponse(_ asset: FetchedAsset, for url: String) {
        lock.withLock { responses[url] = asset }
    }

    func fetchDirect(_ request: URLRequest) async throws -> FetchedAsset {
        let key = request.url?.absoluteString ?? ""
        let (gate, response) = lock.withLock { () -> (DownloadTestGate?, FetchedAsset?) in
            directURLs.append(key)
            return (gates[key], responses[key])
        }
        if let gate {
            try await gate.pass()
        }
        return response ?? .data(OfflineStoreFixture.jpeg(key))
    }

    func fetchPluginImage(
        url: URL,
        headers: [String: String]?,
        allowedOrigins: [String],
        pluginID: String
    ) async throws -> FetchedAsset {
        pluginRequests.increment()
        return .data(OfflineStoreFixture.jpeg(url.absoluteString))
    }
}

/// Builds the runtime for each attempt from one scripted source. `isInstalled` false makes the plugin
/// unavailable, as an uninstalled or refused source is.
@MainActor
final class ScriptedRuntimeProvider: DownloadRuntimeProviding {
    let source: ScriptedSourceState
    var isInstalled = true
    private(set) var runtimeRequests = 0
    /// The operation and frozen source epoch each runtime was requested with.
    private(set) var operations: [PluginNetworkOperation] = []
    private(set) var frozenScopes: [String?] = []

    init(source: ScriptedSourceState) {
        self.source = source
    }

    /// Holds the next runtime load until the test releases it, as a slow plugin load does.
    var loadGate: DownloadTestGate?

    func makeDownloadRuntime(
        for pluginId: String,
        modules: PluginRunnerHostModules,
        operation: PluginNetworkOperation,
        frozenScope: String?
    ) async throws -> DownloadPluginRuntime {
        runtimeRequests += 1
        operations.append(operation)
        frozenScopes.append(frozenScope)
        // Captured before the load, as the production runtime captures its authority.
        let source = source
        let revision = source.publicationRevision
        let trust = source.trustGeneration
        if let gate = loadGate {
            loadGate = nil
            try await gate.pass()
        }
        guard isInstalled else {
            throw URLError(.fileDoesNotExist)
        }
        // Production rejects a load that a republish overtook.
        guard source.publicationRevision == revision else {
            throw PluginRunnerAuthorityError.changedDuringLoad
        }
        return DownloadPluginRuntime(
            pages: ScriptedChapterPages(state: source, modules: modules),
            makeImageRunner: {
                source.imageRunnerCreations.increment()
                return ScriptedImageRunner(contexts: source.contexts)
            },
            isPluginCurrent: { source.publicationRevision == revision },
            isTrustCurrent: { source.trustGeneration == trust }
        )
    }
}

/// A store, a coordinator and a center over one migrated database, with every external edge scripted:
/// the network path, protected data, the source's epoch, its pages, and asset transfers.
@MainActor
final class DownloadWorkerFixture {
    static let plugin = "plugin.test"

    let offline: OfflineStoreFixture
    let store: OfflineChapterStore
    let path: ManualNetworkPathObserver
    let fetcher: ScriptedAssetFetcher
    let source: ScriptedSourceState
    let runtimes: ScriptedRuntimeProvider
    let inner: ScriptedInnerNet
    let progress: DownloadProgressBoard
    let protectedEvents = PassthroughSubject<Void, Never>()
    /// The host contexts every scripted export of this fixture records through.
    let networkContexts = PluginNetworkContexts()
    let coordinator: DownloadQueueCoordinator
    let center: DownloadCenter

    static let defaultPages: [Page] = [
        Page(index: 0, content: .url("https://img.test/1.jpg")),
        Page(index: 1, content: .url("https://img.test/2.jpg")),
        Page(index: 2, content: .url("https://img.test/3.jpg"))
    ]

    init(pages: [Page] = DownloadWorkerFixture.defaultPages) throws {
        offline = try OfflineStoreFixture()
        store = offline.makeStore()
        path = ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied))
        fetcher = ScriptedAssetFetcher()
        source = ScriptedSourceState(pages: pages)
        runtimes = ScriptedRuntimeProvider(source: source)
        inner = ScriptedInnerNet(contexts: source.contexts)
        progress = DownloadProgressBoard()

        let database = offline.database.dbPool
        let captureEpoch: @Sendable (String) throws -> String = { pluginID in
            let epoch = try database.read { db in
                try PluginCompletionScope.current(pluginID: pluginID, in: db)
            }
            guard let epoch else { throw OfflineStoreFixtureError.notQueued }
            return epoch
        }
        let transport = self.inner
        coordinator = DownloadQueueCoordinator(
            store: store,
            runtimes: runtimes,
            makeModules: { _, gate, recorder in
                PluginRunnerHostModules(
                    net: DownloadNetModule(inner: transport, gate: gate, recorder: recorder),
                    webview: DownloadWebviewModule(recorder: recorder)
                )
            },
            path: path,
            protectedData: offline.protectedData,
            protectedDataBecameAvailable: protectedEvents.eraseToAnyPublisher(),
            fetcher: fetcher,
            contexts: networkContexts,
            progress: progress
        )
        center = DownloadCenter(
            dbPool: database,
            store: store,
            coordinator: coordinator,
            progress: progress,
            captureEpoch: captureEpoch
        )
    }

    /// Reconciles, then starts the worker, as the foreground does after launch.
    func startWorker() async {
        await coordinator.reconcile()
        coordinator.start()
    }

    func enqueue(chapterKey: String = "chapter-1", paywalled: Bool? = nil, reconcileFirst: Bool = true) async -> DownloadEnqueueOutcome {
        if reconcileFirst {
            await coordinator.reconcile()
        }
        return await center.enqueue(
            pluginID: Self.plugin,
            mediaKind: .manga,
            canonicalMediaId: "series-1",
            entry: .manga(Manga(key: "series-1", title: "Series One")),
            chapter: Chapter(
                key: chapterKey,
                title: "Chapter",
                url: "https://source.test/read/\(chapterKey)?token=signed-secret",
                paywalled: paywalled
            ),
            seriesTitle: "Series One"
        )
    }

    /// The single queued job for the test edition, or nil once it has left the queue.
    func job(chapterKey: String = "chapter-1") async throws -> DownloadJobRecord? {
        try await store.jobs().first { $0.chapterKey == chapterKey }
    }

    func copy(chapterKey: String = "chapter-1") async throws -> DownloadedChapterRecord? {
        try await store.verifiedEdition(for: OfflineChapterEdition(
            pluginId: Self.plugin,
            mediaKind: .manga,
            canonicalMediaId: "series-1",
            chapterKey: chapterKey
        ))
    }

    func edition(chapterKey: String = "chapter-1") -> OfflineChapterEdition {
        OfflineChapterEdition(
            pluginId: Self.plugin,
            mediaKind: .manga,
            canonicalMediaId: "series-1",
            chapterKey: chapterKey
        )
    }

    /// Rotates the source's epoch in the database, as a settings or credential change does.
    func rotateEpoch() throws {
        try offline.rotateEpoch(to: OfflineStoreFixture.rotatedEpoch)
    }
}
