import ito_runner
import Nuke
import XCTest
@testable import Ito

/// Passes no image through, so every `ito://` load falls back to its direct fetch. It records the purpose of
/// each resolution, which it sees on the first export of that resolution.
private final class PurposeRecordingImageRunner: PluginImageRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [NetworkOperationContext.Purpose] = []
    private let onFirstResolution: @Sendable () -> Void

    init(onFirstResolution: @escaping @Sendable () -> Void = {}) {
        self.onFirstResolution = onFirstResolution
    }

    var purposes: [NetworkOperationContext.Purpose] { lock.withLock { recorded } }

    func getImageRequest(_ locator: String, context: NetworkOperationContext) async throws -> PluginImageRequest? {
        let isFirst = lock.withLock {
            recorded.append(context.purpose)
            return recorded.count == 1
        }
        if isFirst { onFirstResolution() }
        return nil
    }

    func getImageOrigins(context: NetworkOperationContext) async throws -> [String]? { nil }

    func handleImage(_ locator: String, context: NetworkOperationContext) async throws -> Data? { nil }
}

/// The loader a pass-through or direct request reaches. It records each request it receives and completes at
/// once with `failure`, so no network is touched.
private final class MarkCapturingLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [URLRequest] = []
    private let failure: URLError?

    init(failure: URLError? = nil) {
        self.failure = failure
    }

    var requests: [URLRequest] { lock.withLock { received } }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        lock.withLock { received.append(request) }
        completion(failure)
        return NoOpCancellable()
    }
}

private final class NoOpCancellable: Cancellable, @unchecked Sendable {
    func cancel() {}
}

/// A real URLSession route: it records the purpose mark each request carries when it reaches the protocol,
/// then answers 200 with an empty body.
private final class PurposeProbeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var marksByHost: [String: [String?]] = [:]
    private static let hostSuffix = ".marker-probe.test"

    static func marks(forHost host: String) -> [String?] {
        lock.withLock { marksByHost[host, default: []] }
    }

    static func reset() {
        lock.withLock { marksByHost.removeAll() }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurposeProbeURLProtocol.self]
        return configuration
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(hostSuffix) == true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let mark = ImageRequestPurpose.marked(on: request)?.rawValue
        Self.lock.withLock { Self.marksByHost[host, default: []].append(mark) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class ImageRequestPurposeTests: XCTestCase {
    override func tearDown() {
        PurposeProbeURLProtocol.reset()
        super.tearDown()
    }

    func testAVisiblePageReachesTheLoaderAsForegroundReading() async throws {
        let answered = expectation(description: "the visible page's resolution is answered")
        let runner = PurposeRecordingImageRunner { answered.fulfill() }
        let loader = makeLoader(runner: runner, defaultLoader: MarkCapturingLoader(failure: URLError(.cannotConnectToHost)))
        let pipeline = makePipeline(loader: loader)
        let url = try XCTUnwrap(URL(string: "ito://fixture.plugin/https://reader-marks.example/visible.png"))
        let descriptor = ReaderPageImageDescriptor(
            pageID: "visible",
            request: NukeMangaReaderImagePrefetcher.urlRequest(url: url, headers: nil)
        )
        let session = ReaderPageImageSession(pipeline: pipeline)

        let lease = session.acquire(descriptor, consumer: .visible)
        await fulfillment(of: [answered], timeout: 10)

        XCTAssertEqual(runner.purposes, [.foregroundReading])
        session.release(lease)
        session.deactivate()
    }

    func testAPreloadReachesTheLoaderAsPrefetch() async throws {
        let answered = expectation(description: "the preloaded page's resolution is answered")
        let runner = PurposeRecordingImageRunner { answered.fulfill() }
        let loader = makeLoader(runner: runner, defaultLoader: MarkCapturingLoader(failure: URLError(.cannotConnectToHost)))
        let pipeline = makePipeline(loader: loader)
        let url = try XCTUnwrap(URL(string: "ito://fixture.plugin/https://reader-marks.example/preload.png"))
        let prefetcher = NukeMangaReaderImagePrefetcher(session: ReaderPageImageSession(pipeline: pipeline))

        prefetcher.prefetch([Page(index: 0, content: .url(url.absoluteString))])
        await fulfillment(of: [answered], timeout: 10)

        XCTAssertEqual(runner.purposes, [.prefetch])
        prefetcher.stopPrefetching()
    }

    func testAnUnmarkedItoRequestIsACoverImage() async throws {
        let runner = PurposeRecordingImageRunner()
        let capture = MarkCapturingLoader()
        let loader = makeLoader(runner: runner, defaultLoader: capture)
        let url = try XCTUnwrap(URL(string: "ito://fixture.plugin/https://images.example/cover.jpg"))

        await load(loader, URLRequest(url: url))

        XCTAssertEqual(runner.purposes, [.coverImage])
        XCTAssertEqual(capture.requests.map(\.url), [URL(string: "https://images.example/cover.jpg")])
    }

    func testTheMarkIsStrippedFromBothFetchesAndEveryOtherFieldIsKept() async throws {
        let runner = PurposeRecordingImageRunner()
        let capture = MarkCapturingLoader()
        let loader = makeLoader(runner: runner, defaultLoader: capture)
        let realURL = try XCTUnwrap(URL(string: "https://images.example/page.png"))
        let pluginURL = try XCTUnwrap(URL(string: "ito://fixture.plugin/https://images.example/page.png"))

        // The plain pass-through, as a reader sends for an image that is not a plugin's.
        await load(loader, ImageRequestPurpose.foregroundReading.applied(to: makePageRequest(realURL)))
        // The direct fetch, after the plugin resolves its `ito://` image to the real URL.
        await load(loader, ImageRequestPurpose.prefetch.applied(to: makePageRequest(pluginURL)))

        let received = capture.requests
        XCTAssertEqual(received.count, 2)
        for request in received {
            XCTAssertNil(ImageRequestPurpose.marked(on: request), "The network loader must not receive the purpose mark.")
            XCTAssertEqual(request.url, realURL)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://reader.example/")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.timeoutInterval, 12)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertFalse(request.allowsCellularAccess)
            XCTAssertEqual(request.networkServiceType, .responsiveData)
        }
    }

    func testTheMarkNeverReachesURLSessionsProtocol() async throws {
        let controlURL = try XCTUnwrap(URL(string: "https://control.marker-probe.test/control.png"))
        let passURL = try XCTUnwrap(URL(string: "https://pass.marker-probe.test/page.png"))
        let pluginURL = try XCTUnwrap(URL(string: "ito://fixture.plugin/https://direct.marker-probe.test/cover.png"))
        let session = DataLoader(configuration: PurposeProbeURLProtocol.configuration())
        let loader = PluginDataLoader(
            configuration: PurposeProbeURLProtocol.configuration(),
            contexts: PluginNetworkContexts(),
            runnerProvider: { _ in PurposeRecordingImageRunner() }
        )

        // Control: a mark on a request sent straight to URLSession does reach the protocol. Only then does the
        // absence below prove anything.
        await load(session, ImageRequestPurpose.prefetch.applied(to: URLRequest(url: controlURL)))
        await load(loader, ImageRequestPurpose.foregroundReading.applied(to: URLRequest(url: passURL)))
        await load(loader, ImageRequestPurpose.foregroundReading.applied(to: URLRequest(url: pluginURL)))

        XCTAssertEqual(PurposeProbeURLProtocol.marks(forHost: "control.marker-probe.test"), ["prefetch"])
        let unmarked: [String?] = [nil]
        XCTAssertEqual(PurposeProbeURLProtocol.marks(forHost: "pass.marker-probe.test"), unmarked)
        XCTAssertEqual(PurposeProbeURLProtocol.marks(forHost: "direct.marker-probe.test"), unmarked)
    }

    func testMarkingLeavesTheReaderKeyAndNukeIdentityUnchanged() throws {
        let url = try XCTUnwrap(URL(string: "https://images.example/identity.png"))
        var plain = URLRequest(url: url)
        plain.setValue("https://reader.example/", forHTTPHeaderField: "Referer")
        let marked = ImageRequestPurpose.foregroundReading.applied(to: plain)

        XCTAssertEqual(ReaderPageImageKey(request: marked), ReaderPageImageKey(request: plain))
        XCTAssertEqual(ImageRequest(urlRequest: marked).imageId, ImageRequest(urlRequest: plain).imageId)
    }

    func testPlainHTTPSourceEpochRevokesOnlyItsOwnHeldTransferAndStripsBothMarks() async throws {
        let contexts = PluginNetworkContexts(
            epochs: ["A": String(repeating: "a", count: 32), "B": String(repeating: "b", count: 32)],
            policy: NetworkPolicyCenter(path: ManualNetworkPathObserver(initial: .init(status: .satisfied)))
        )
        let held = AuthorityHeldImageLoader()
        let loader = PluginDataLoader(
            configuration: .ephemeral, contexts: contexts, defaultLoader: held,
            runnerProvider: { _ in PurposeRecordingImageRunner() }
        )
        let url = try XCTUnwrap(URL(string: "https://images.example/same.png"))
        let request = URLRequest(url: url)
        let a = ImageRequestSourceAuthority.capture(pluginID: "A", contexts: contexts)
        let b = ImageRequestSourceAuthority.capture(pluginID: "B", contexts: contexts)
        let refused = expectation(description: "A is refused")
        let bDone = expectation(description: "B completes")
        let appDone = expectation(description: "App completes")
        let aLoad = loader.loadData(
            with: ImageRequestSourceAuthority.applied(
                ImageRequestSourceAuthority.withPurpose(.foregroundReading, authority: a),
                to: ImageRequestPurpose.foregroundReading.applied(to: request)
            ),
            didReceiveData: { _, _ in XCTFail("Revoked A published bytes") },
            completion: { error in
                XCTAssertEqual(error as? HostNetworkPolicyOutcome, .sourceAuthorizationFailure)
                refused.fulfill()
            }
        )
        let bLoad = loader.loadData(
            with: ImageRequestSourceAuthority.applied(b, to: request),
            didReceiveData: { _, _ in },
            completion: { error in XCTAssertNil(error); bDone.fulfill() }
        )
        let appLoad = loader.loadData(
            with: request, didReceiveData: { _, _ in },
            completion: { error in XCTAssertNil(error); appDone.fulfill() }
        )
        XCTAssertEqual(held.requests.count, 3)
        XCTAssertEqual(held.authorities.map(\.context.sourceID), ["A", "B", NetworkRequestAuthority.appSourceID])
        for wire in held.requests {
            XCTAssertNil(ImageRequestPurpose.marked(on: wire))
            XCTAssertNil(ImageRequestSourceAuthority.marked(on: wire))
            XCTAssertEqual(wire.url, url)
        }
        contexts.replaceEpochs(["A": String(repeating: "c", count: 32), "B": String(repeating: "b", count: 32)])
        await fulfillment(of: [refused], timeout: 5)
        XCTAssertEqual(held.cancelled, [0])
        held.finishAll()
        await fulfillment(of: [bDone, appDone], timeout: 5)
        withExtendedLifetime((aLoad, bLoad, appLoad)) {}
    }

    func testReaderPlainHTTPPagesKeepFrozenSourceOperationAndPurpose() async throws {
        let contexts = PluginNetworkContexts(
            epochs: ["A": String(repeating: "a", count: 32)],
            policy: NetworkPolicyCenter(path: ManualNetworkPathObserver(initial: .init(status: .satisfied)))
        )
        let held = AuthorityHeldImageLoader()
        let loader = PluginDataLoader(
            configuration: .ephemeral, contexts: contexts, defaultLoader: held,
            runnerProvider: { _ in PurposeRecordingImageRunner() }
        )
        let started = expectation(description: "Visible and two prefetches start")
        started.expectedFulfillmentCount = 3
        held.onStart = { started.fulfill() }
        let authority = ImageRequestSourceAuthority.capture(pluginID: "A", contexts: contexts)
        let session = ReaderPageImageSession(pipeline: makePipeline(loader: loader), sourceAuthority: authority)
        func descriptor(_ index: Int) -> ReaderPageImageDescriptor {
            ReaderPageImageDescriptor(pageID: String(index), request: URLRequest(url: URL(string: "https://pages.example/\(index)")!))
        }
        let visible = session.acquire(descriptor(0), consumer: .visible)
        session.setPrefetch([descriptor(1), descriptor(2), descriptor(3)])
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(Set(held.authorities.map(\.context.sourceID)), ["A"])
        XCTAssertEqual(Set(held.authorities.map(\.context.operationID)), [authority.context.operationID])
        XCTAssertEqual(held.authorities.filter { $0.context.purpose == .foregroundReading }.count, 1)
        XCTAssertEqual(held.authorities.filter { $0.context.purpose == .prefetch }.count, 2)
        contexts.replaceEpochs(["A": String(repeating: "b", count: 32)])
        held.finishAll()
        session.release(visible)
        session.deactivate()
        XCTAssertEqual(held.requests.count, 3, "The old session cannot start its queued fourth page")
    }

    func testFrozenItoDirectRewriteDoesNotBorrowTheNewSourceEpoch() async throws {
        let contexts = PluginNetworkContexts(
            epochs: ["A": String(repeating: "a", count: 32)],
            policy: NetworkPolicyCenter(path: ManualNetworkPathObserver(initial: .init(status: .satisfied)))
        )
        let authority = ImageRequestSourceAuthority.capture(pluginID: "A", contexts: contexts)
        let held = AuthorityHeldImageLoader()
        let started = expectation(description: "Direct rewrite starts")
        held.onStart = { started.fulfill() }
        let done = expectation(description: "Frozen direct transfer refused")
        let loader = PluginDataLoader(
            configuration: .ephemeral, contexts: contexts, defaultLoader: held,
            runnerProvider: { _ in PurposeRecordingImageRunner() }
        )
        let request = ImageRequestSourceAuthority.applied(authority, to: URLRequest(
            url: try XCTUnwrap(URL(string: "ito://A/https://images.example/direct.png"))
        ))
        let load = loader.loadData(with: request, didReceiveData: { _, _ in XCTFail("Old direct transfer published") }) { error in
            XCTAssertEqual(error as? HostNetworkPolicyOutcome, .sourceAuthorizationFailure)
            done.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(held.authorities.first?.context.authorizationScope, authority.context.authorizationScope)
        XCTAssertNil(held.requests.first.flatMap { ImageRequestSourceAuthority.marked(on: $0) })
        contexts.replaceEpochs(["A": String(repeating: "b", count: 32)])
        held.finishAll()
        await fulfillment(of: [done], timeout: 5)
        withExtendedLifetime(load) {}
    }

    func testStalePlainHTTPAuthorityIsRefusedBeforeWireForEveryImagePurpose() async throws {
        let contexts = PluginNetworkContexts(
            epochs: ["A": String(repeating: "a", count: 32)],
            policy: NetworkPolicyCenter(path: ManualNetworkPathObserver(initial: .init(status: .satisfied)))
        )
        let original = ImageRequestSourceAuthority.capture(pluginID: "A", contexts: contexts)
        contexts.replaceEpochs(["A": String(repeating: "b", count: 32)])
        let held = AuthorityHeldImageLoader()
        let loader = PluginDataLoader(
            configuration: .ephemeral, contexts: contexts, defaultLoader: held,
            runnerProvider: { _ in PurposeRecordingImageRunner() }
        )
        for purpose in [nil, .foregroundReading, .prefetch] as [ImageRequestPurpose?] {
            let refused = expectation(description: "Stale image refused")
            let authority = purpose.map { ImageRequestSourceAuthority.withPurpose($0, authority: original) } ?? original
            let request = ImageRequestSourceAuthority.applied(
                authority, to: URLRequest(url: URL(string: "https://images.example/stale.png")!)
            )
            let load = loader.loadData(with: request, didReceiveData: { _, _ in XCTFail("Stale image delivered") }) { error in
                XCTAssertEqual(error as? HostNetworkPolicyOutcome, .sourceAuthorizationFailure)
                refused.fulfill()
            }
            await fulfillment(of: [refused], timeout: 5)
            withExtendedLifetime(load) {}
        }
        XCTAssertTrue(held.requests.isEmpty)
        XCTAssertNil(SourceCoverRequests(contexts: nil).request(URL(string: "https://images.example/cover"), pluginID: "A"))
    }

    // MARK: - Helpers

    private func makeLoader(
        runner: any PluginImageRunner,
        defaultLoader: any DataLoading
    ) -> PluginDataLoader {
        PluginDataLoader(
            configuration: .ephemeral,
            contexts: PluginNetworkContexts(policy: NetworkPolicyCenter(path: ManualNetworkPathObserver(initial: .init(status: .satisfied)))),
            defaultLoader: defaultLoader,
            runnerProvider: { _ in runner }
        )
    }

    private func makePipeline(loader: any DataLoading) -> ImagePipeline {
        ImagePipeline {
            $0.dataLoader = loader
            $0.imageCache = nil
            $0.dataCache = nil
        }
    }

    private func makePageRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("https://reader.example/", forHTTPHeaderField: "Referer")
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.allowsCellularAccess = false
        request.networkServiceType = .responsiveData
        return request
    }

    /// Waits for the loader's single completion, the only event the test needs.
    private func load(_ loader: any DataLoading, _ request: URLRequest) async {
        await withCheckedContinuation { continuation in
            _ = loader.loadData(with: request, didReceiveData: { _, _ in }, completion: { _ in continuation.resume() })
        }
    }
}

/// Deliberately answers even cancelled work, exercising the host's late-publication guard.
private final class AuthorityHeldImageLoader: AuthorizedDataLoading, @unchecked Sendable {
    private struct Pending {
        let request: URLRequest
        let authority: NetworkRequestAuthority
        let receive: @Sendable (Data, URLResponse) -> Void
        let complete: @Sendable (Error?) -> Void
    }
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var cancellations: Set<Int> = []
    var onStart: (@Sendable () -> Void)?
    var requests: [URLRequest] { lock.withLock { pending.map(\.request) } }
    var authorities: [NetworkRequestAuthority] { lock.withLock { pending.map(\.authority) } }
    var cancelled: Set<Int> { lock.withLock { cancellations } }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        XCTFail("Source transfer lost its authority")
        completion(URLError(.cancelled))
        return NoOpCancellable()
    }

    func loadData(
        with request: URLRequest, authority: NetworkRequestAuthority,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        let index = lock.withLock {
            pending.append(Pending(request: request, authority: authority, receive: didReceiveData, complete: completion))
            return pending.count - 1
        }
        onStart?()
        return AuthorityHeldCancellation { [weak self] in
            _ = self?.lock.withLock { self?.cancellations.insert(index) }
        }
    }

    func finishAll() {
        let snapshot = lock.withLock { pending }
        for entry in snapshot {
            let data = Data([1])
            entry.receive(data, URLResponse(url: entry.request.url!, mimeType: "image/png", expectedContentLength: 1, textEncodingName: nil))
            entry.complete(nil)
        }
    }
}

private final class AuthorityHeldCancellation: Cancellable {
    private let action: @Sendable () -> Void
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    func cancel() { action() }
}
