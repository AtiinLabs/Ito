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
            contexts: PluginNetworkContexts(policy: NetworkPolicyCenter()),
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

    // MARK: - Helpers

    private func makeLoader(
        runner: any PluginImageRunner,
        defaultLoader: any DataLoading
    ) -> PluginDataLoader {
        PluginDataLoader(
            configuration: .ephemeral,
            contexts: PluginNetworkContexts(policy: NetworkPolicyCenter()),
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
