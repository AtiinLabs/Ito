import Combine
import Foundation
import Nuke
import UIKit
import XCTest
import ito_runner
@testable import Ito

/// Held transfers: a request starts, nothing answers until the test says so. Ordering is decided by the test,
/// never by a timer.
nonisolated final class HeldHost: @unchecked Sendable {
    private let lock = NSLock()
    private var protocols: [HoldingURLProtocol] = []
    private var startHandler: (@Sendable () -> Void)?

    var requestCount: Int { lock.withLock { protocols.count } }

    func onStart(_ handler: @escaping @Sendable () -> Void) { lock.withLock { startHandler = handler } }

    fileprivate func record(_ transfer: HoldingURLProtocol) {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            protocols.append(transfer)
            return startHandler
        }
        handler?()
    }

    func respond(at index: Int = 0, status: Int, headers: [String: String] = [:], body: Data = Data()) {
        guard let transfer = lock.withLock({ index < protocols.count ? protocols[index] : nil }),
              let url = transfer.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        transfer.client?.urlProtocol(transfer, didReceive: response, cacheStoragePolicy: .notAllowed)
        transfer.client?.urlProtocol(transfer, didLoad: body)
        transfer.client?.urlProtocolDidFinishLoading(transfer)
    }

    func fail(at index: Int = 0, _ error: Error) {
        guard let transfer = lock.withLock({ index < protocols.count ? protocols[index] : nil }) else { return }
        transfer.client?.urlProtocol(transfer, didFailWithError: error)
    }
}

nonisolated final class HoldingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String: HeldHost] = [:]

    static func register(_ held: HeldHost, forHost host: String) {
        lock.withLock { hosts[host] = held }
    }

    private static func held(for request: URLRequest) -> HeldHost? {
        guard let host = request.url?.host else { return nil }
        return lock.withLock { hosts[host] }
    }

    override static func canInit(with request: URLRequest) -> Bool { held(for: request) != nil }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.held(for: request)?.record(self) }
    override func stopLoading() {}
}

private nonisolated func heldConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HoldingURLProtocol.self]
    return configuration
}

private nonisolated func registerHost() -> (host: String, held: HeldHost) {
    let host = "held-\(UUID().uuidString.lowercased()).example.invalid"
    let held = HeldHost()
    HoldingURLProtocol.register(held, forHost: host)
    return (host, held)
}

private nonisolated final class ChallengeGate: AppNetCloudflareHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppNetCloudflareResolution, Never>?
    private let entered: @Sendable () -> Void

    init(entered: @escaping @Sendable () -> Void) { self.entered = entered }

    func cachedUserAgent(for host: String) async -> String { "" }

    func resolveChallenge(for url: URL, authority: NetworkRequestAuthority?) async throws -> AppNetCloudflareResolution {
        let resolution = await withCheckedContinuation { (continuation: CheckedContinuation<AppNetCloudflareResolution, Never>) in
            lock.withLock { self.continuation = continuation }
            entered()
        }
        return resolution
    }

    func resolve(with resolution: AppNetCloudflareResolution) {
        lock.withLock { () -> CheckedContinuation<AppNetCloudflareResolution, Never>? in
            defer { continuation = nil }
            return continuation
        }?.resume(returning: resolution)
    }
}

private nonisolated struct NoChallenge: AppNetCloudflareHandling {
    func cachedUserAgent(for host: String) async -> String { "" }
    func resolveChallenge(for url: URL, authority: NetworkRequestAuthority?) async throws -> AppNetCloudflareResolution {
        throw HostNetworkPolicyOutcome.foregroundPermissionRequired
    }
}

@MainActor
final class TransportReviewBehaviorTests: XCTestCase {
    private func makeContexts(
        path: ManualNetworkPathObserver = ManualNetworkPathObserver(initial: .init(status: .satisfied))
    ) -> PluginNetworkContexts {
        let policy = NetworkPolicyCenter(path: path)
        policy.enterForeground()
        return PluginNetworkContexts(epochs: ["fixture": String(repeating: "a", count: 32)], policy: policy)
    }

    private func sourceContext(_ contexts: PluginNetworkContexts, _ purpose: NetworkOperationContext.Purpose = .foregroundReading) -> NetworkOperationContext {
        contexts.context(pluginID: "fixture", PluginNetworkOperation(purpose: purpose, operationID: UUID()))
    }

    // MARK: - Late refusal: reads are replaced, writes keep the remote's answer

    func testPluginHTTPReplacesALateReadAndKeepsEveryOtherMethodsResponse() async throws {
        for (method, isRead) in [("GET", true), ("HEAD", true), ("OPTIONS", true), ("POST", false), ("PUT", false), ("PROPFIND", false)] {
            let path = ManualNetworkPathObserver(initial: .init(status: .satisfied))
            let contexts = makeContexts(path: path)
            let (host, held) = registerHost()
            let started = expectation(description: "\(method) transfer started")
            held.onStart { started.fulfill() }
            let module = AppNetModule(
                configuration: heldConfiguration(), cloudflare: NoChallenge(), retryLogger: OSLogAppNetRetryLogger(),
                pluginID: "fixture", cookieJar: PluginCookieJar(keychain: InMemoryPluginSecretKeychain()), contexts: contexts
            )
            let context = sourceContext(contexts)
            let request = NetRequest(url: "https://\(host)/x", method: method, headers: [:], body: nil)
            let task = Task { try await module.fetch(request: request, context: context) }
            await fulfillment(of: [started], timeout: 5)
            path.set(.init(status: .unsatisfied))
            if !isRead { held.respond(status: 200, body: Data("remote".utf8)) }
            let result = await task.result
            if isRead {
                XCTAssertThrowsError(try result.get(), method) { XCTAssertEqual($0 as? HostNetworkPolicyOutcome, .deferred(.offline)) }
            } else {
                XCTAssertEqual(try result.get().status, 200, method)
            }
        }
    }

    func testAppOwnedTransportUsesTheSameReadAllowlistAndKeepsTimeoutsAsURLErrors() async throws {
        for (method, isRead) in [("GET", true), ("POST", false), ("PROPFIND", false)] {
            let path = ManualNetworkPathObserver(initial: .init(status: .satisfied))
            let contexts = makeContexts(path: path)
            let (host, held) = registerHost()
            let started = expectation(description: "\(method) started")
            held.onStart { started.fulfill() }
            let session = URLSession(configuration: heldConfiguration())
            defer { session.invalidateAndCancel() }
            let transport = PolicyHTTPTransport(
                session: session, authority: .appOwned(contexts: contexts, purpose: .manualCatalogRefresh)
            )
            var request = URLRequest(url: try XCTUnwrap(URL(string: "https://\(host)/x")))
            request.httpMethod = method
            let task = Task { try await transport.data(for: request) }
            await fulfillment(of: [started], timeout: 5)
            path.set(.init(status: .unsatisfied))
            if !isRead { held.respond(status: 204) }
            let result = await task.result
            if isRead {
                XCTAssertThrowsError(try result.get(), method) { XCTAssertEqual($0 as? HostNetworkPolicyOutcome, .deferred(.offline)) }
            } else {
                XCTAssertEqual((try result.get().1 as? HTTPURLResponse)?.statusCode, 204, method)
            }
        }
        let (host, held) = registerHost()
        let started = expectation(description: "timeout transfer started")
        held.onStart { started.fulfill() }
        let session = URLSession(configuration: heldConfiguration())
        defer { session.invalidateAndCancel() }
        let transport = PolicyHTTPTransport(
            session: session, authority: .appOwned(contexts: makeContexts(), purpose: .manualCatalogRefresh)
        )
        let task = Task { try await transport.data(for: URLRequest(url: try XCTUnwrap(URL(string: "https://\(host)/x")))) }
        await fulfillment(of: [started], timeout: 5)
        held.fail(URLError(.timedOut))
        do {
            _ = try await task.value
            XCTFail("A timed out transfer must fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut, "App-owned timeouts keep the system's localized error")
            XCTAssertNil(error as? ItoError)
        }
    }

    // MARK: - Challenge cookies against Clear Site Data and cancellation

    func testChallengeCookiesAreDroppedAfterClearOrCancellationAndNothingIsRetried() async throws {
        for cancelsInstead in [false, true] {
            let contexts = makeContexts()
            let (host, held) = registerHost()
            let transferStarted = expectation(description: "first transfer started")
            held.onStart { transferStarted.fulfill() }
            let challengeEntered = expectation(description: "challenge entered")
            let gate = ChallengeGate { challengeEntered.fulfill() }
            let jar = PluginCookieJar(keychain: InMemoryPluginSecretKeychain())
            let module = AppNetModule(
                configuration: heldConfiguration(), cloudflare: gate, retryLogger: OSLogAppNetRetryLogger(),
                pluginID: "fixture", cookieJar: jar, contexts: contexts
            )
            let context = sourceContext(contexts)
            let url = try XCTUnwrap(URL(string: "https://\(host)/x"))
            let task = Task { try await module.fetch(request: NetRequest(url: url.absoluteString, method: "GET", headers: [:], body: nil), context: context) }
            await fulfillment(of: [transferStarted], timeout: 5)
            held.respond(status: 403, headers: ["cf-mitigated": "challenge"])
            await fulfillment(of: [challengeEntered], timeout: 5)
            if cancelsInstead { task.cancel() } else { try jar.removeEveryPlugin() }
            let cookie = try XCTUnwrap(HTTPCookie(properties: [
                .domain: host, .path: "/", .name: "cf_clearance", .value: "token", .secure: "TRUE", .originURL: url
            ]))
            gate.resolve(with: AppNetCloudflareResolution(userAgent: "agent", cookies: [cookie]))
            do {
                _ = try await task.value
                XCTFail("A superseded challenge must not complete the fetch")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(held.requestCount, 1, "The superseded challenge must not retry")
            XCTAssertTrue(jar.cookies(pluginID: "fixture", for: url).isEmpty)
        }
    }

    func testDeletingOnePluginInvalidatesItsInFlightCookieWrites() throws {
        let jar = PluginCookieJar(keychain: InMemoryPluginSecretKeychain())
        let url = try XCTUnwrap(URL(string: "https://cookies.example.invalid/"))
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "cookies.example.invalid", .path: "/", .name: "s", .value: "v", .originURL: url
        ]))
        let captured = jar.captureWriteGeneration()
        try jar.removeAll(pluginID: "fixture")
        XCTAssertFalse(try jar.store([cookie], pluginID: "fixture", ifCurrent: captured))
        XCTAssertTrue(jar.cookies(pluginID: "fixture", for: url).isEmpty)
        XCTAssertTrue(try jar.store([cookie], pluginID: "fixture", ifCurrent: jar.captureWriteGeneration()))
    }

    // MARK: - Tracker re-admission

    func testAniListReadmitsBeforeWritingAfterAPreReadAndSendsNoMutationWhenAdmissionWasLost() async throws {
        for losesPath in [false, true] {
            let path = ManualNetworkPathObserver(initial: .init(status: .satisfied))
            let contexts = makeContexts(path: path)
            let provider = AppNetworkAuthorityProvider()
            provider.set(contexts)
            AniListAdmissionProtocol.reset { if losesPath { path.set(.init(status: .unsatisfied)) } }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AniListAdmissionProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let suite = "TransportReviewBehaviorTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let tracker = AnilistTracker(
                credentialRepository: AniListCredentialRepository(
                    secureStore: FakeTrackerCredentialStore(initialToken: "fixture-token"), legacyStore: FakeLegacyTokenStore()
                ),
                usernameDefaults: defaults, session: session, authorities: provider
            )
            _ = try await tracker.bootstrapCredentials()
            if losesPath {
                do {
                    try await tracker.updateProgress(mediaId: "42", progress: 7, status: nil)
                    XCTFail("A write after the admission was lost must be refused")
                } catch {
                    XCTAssertEqual(error as? HostNetworkPolicyOutcome, .deferred(.offline))
                }
                XCTAssertEqual(AniListAdmissionProtocol.mutations, 0)
            } else {
                try await tracker.updateProgress(mediaId: "42", progress: 7, status: nil)
                XCTAssertEqual(AniListAdmissionProtocol.mutations, 1)
            }
            XCTAssertEqual(AniListAdmissionProtocol.reads, 1)
        }
    }

    // MARK: - Source image transport and caches

    func testSourceImageTransfersUseACookieAndCacheIsolatedSessionChosenByAppOwnership() throws {
        let loader = PolicyDataLoader(configuration: .default)
        let contexts = makeContexts()
        let source = NetworkRequestAuthority(contexts: contexts, context: sourceContext(contexts))
        // A plugin cannot reach the app-owned session by naming itself like the app.
        let impostor = NetworkRequestAuthority(
            contexts: contexts,
            context: contexts.context(pluginID: NetworkRequestAuthority.appSourceID, PluginNetworkOperation(purpose: .coverImage, operationID: UUID()))
        )
        let app = NetworkRequestAuthority.appOwned(contexts: contexts, purpose: .manualCatalogRefresh)
        XCTAssertTrue(loader.transportSession(for: source) === loader.sourceSession)
        XCTAssertTrue(loader.transportSession(for: impostor) === loader.sourceSession)
        XCTAssertTrue(loader.transportSession(for: app) === loader.session)
        let configuration = loader.sourceSession.configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNotNil(loader.session.configuration.httpCookieStorage)
    }

    func testSourceImagesShareOneBoundedMemoryCacheClearedByClearCacheAndScopeRotation() throws {
        let contexts = PluginNetworkContexts(
            epochs: ["A": String(repeating: "a", count: 32), "B": String(repeating: "b", count: 32)],
            policy: NetworkPolicyCenter(path: ManualNetworkPathObserver(initial: .init(status: .satisfied)))
        )
        let sourceMemory = ImageCache()
        let recorder = PipelineCapture()
        let controller = PluginImagePipelineController(
            dataCache: nil, dataLoader: DataLoader(configuration: .ephemeral), diagnostics: NukeDiagnosticDelegate(),
            publish: { recorder.set($0) }, contexts: contexts, sourceMemory: sourceMemory
        )
        controller.install(epoch: String(repeating: "d", count: 32))
        let pipeline = try XCTUnwrap(recorder.pipeline)
        let url = try XCTUnwrap(URL(string: "https://shared.example/cover"))
        let requests = SourceCoverRequests(contexts: contexts)
        let a = try XCTUnwrap(requests.request(url, pluginID: "A"))
        let b = try XCTUnwrap(requests.request(url, pluginID: "B"))
        var withHeader = try XCTUnwrap(a.urlRequest)
        withHeader.setValue("https://reader.example/", forHTTPHeaderField: "Referer")
        let headered = ImageRequest(urlRequest: withHeader)
        let image = ImageContainer(image: UIImage())
        for request in [a, b, headered] { pipeline.cache.storeCachedImage(image, for: request, caches: [.memory]) }
        XCTAssertEqual(sourceMemory.totalCount, 3, "Partitions are keys in one cache, not one cache each")
        XCTAssertNotNil(pipeline.cache.cachedImage(for: a, caches: [.memory]))
        XCTAssertNil(pipeline.cache.cachedImage(for: ImageRequest(url: url), caches: [.memory]))

        controller.clearPluginMemoryCache()
        XCTAssertEqual(sourceMemory.totalCount, 0)
        XCTAssertNil(pipeline.cache.cachedImage(for: a, caches: [.memory]))

        pipeline.cache.storeCachedImage(image, for: a, caches: [.memory])
        DispatchQueue.global().sync {
            contexts.replaceEpochs(["A": String(repeating: "c", count: 32), "B": String(repeating: "b", count: 32)])
        }
        XCTAssertEqual(sourceMemory.totalCount, 0, "A rotated scope drops the old account's decoded images")
    }

    func testEverySourceReaderSessionIsBoundToItsSourceAuthority() async throws {
        let contexts = makeContexts()
        let started = expectation(description: "bound request started")
        let cancelled = expectation(description: "rotation cancels the bound request")
        let loader = HeldAuthorityLoader(onStart: { started.fulfill() }, onCancel: { cancelled.fulfill() })
        let pipeline = ImagePipeline { $0.dataLoader = loader; $0.imageCache = nil; $0.dataCache = nil }
        let session = ReaderPageImageSession.sourceBound(pluginID: "fixture", contexts: contexts, pipeline: pipeline)
        defer { session.deactivate() }
        let descriptor = ReaderPageImageDescriptor(pageID: "novel", request: URLRequest(url: try XCTUnwrap(URL(string: "https://fixture.invalid/novel.png"))))
        _ = session.acquire(descriptor, consumer: .visible)
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(loader.sourceIDs, ["fixture"])
        DispatchQueue.global().async { contexts.replaceEpochs(["fixture": String(repeating: "b", count: 32)]) }
        await fulfillment(of: [cancelled], timeout: 5)
    }

    // MARK: - Video messages

    func testVideoShowsTheRefusalNotAGenericFailureBeforeAndDuringPlayback() async {
        let outcomes: [HostNetworkPolicyOutcome] = [
            .deferred(.offline), .deferred(.expensivePath), .deferred(.constrainedPath), .deferred(.policyChanged),
            .sourceAuthorizationFailure, .foregroundPermissionRequired, .hardUserBlocked
        ]
        for outcome in outcomes {
            let subject = makeVideoPlayerSubject()
            subject.streamLoader.responses = [.success([video("first")])]
            subject.playback.enqueue(.refused(outcome), for: "first")
            subject.viewModel.start()
            await subject.viewModel.waitForAllOperationsForTesting()
            XCTAssertEqual(subject.viewModel.loadPhase, .failure(VideoPlayerViewModel.message(for: outcome)))
            XCTAssertTrue(subject.playback.activatedPreparationIDs.isEmpty)
        }
        let subject = makeVideoPlayerSubject()
        subject.streamLoader.responses = [.success([video("first")])]
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.playback.activatedPreparationIDs, ["first"])
        subject.playback.emitNetworkRefusal(.sourceAuthorizationFailure)
        XCTAssertEqual(subject.viewModel.loadPhase, .failure(VideoPlayerViewModel.message(for: HostNetworkPolicyOutcome.sourceAuthorizationFailure)))
    }
}

private nonisolated final class PipelineCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var held: ImagePipeline?
    var pipeline: ImagePipeline? { lock.withLock { held } }
    func set(_ pipeline: ImagePipeline) { lock.withLock { held = pipeline } }
}

private nonisolated final class HeldAuthorityLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    private let onStart: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void
    var sourceIDs: [String] { lock.withLock { ids } }

    init(onStart: @escaping @Sendable () -> Void, onCancel: @escaping @Sendable () -> Void) {
        self.onStart = onStart
        self.onCancel = onCancel
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Nuke.Cancellable {
        if let authority = ImageRequestSourceAuthority.marked(on: request) {
            lock.withLock { ids.append(authority.context.sourceID) }
        }
        onStart()
        return HeldAuthorityCancellation(onCancel)
    }
}

private nonisolated final class HeldAuthorityCancellation: Nuke.Cancellable, @unchecked Sendable {
    private let action: @Sendable () -> Void
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    func cancel() { action() }
}

/// Answers AniList's pre-read with an older progress, after running a hook that may revoke admission.
private nonisolated final class AniListAdmissionProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var readHook: (() -> Void)?
    nonisolated(unsafe) private static var readCount = 0
    nonisolated(unsafe) private static var mutationCount = 0

    static var reads: Int { lock.withLock { readCount } }
    static var mutations: Int { lock.withLock { mutationCount } }

    static func reset(onRead: @escaping () -> Void) {
        lock.withLock { readHook = onRead; readCount = 0; mutationCount = 0 }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let query = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["query"] as? String ?? ""
        let body: String
        if query.contains("SaveMediaListEntry") {
            Self.lock.withLock { Self.mutationCount += 1 }
            body = "{\"data\":{\"SaveMediaListEntry\":{\"id\":1,\"mediaId\":42,\"score\":0,\"progress\":7,\"status\":\"CURRENT\"}}}"
        } else {
            let hook = Self.lock.withLock { () -> (() -> Void)? in
                Self.readCount += 1
                return Self.readHook
            }
            hook?()
            body = "{\"data\":{\"MediaList\":{\"id\":1,\"mediaId\":42,\"score\":0,\"progress\":3,\"status\":\"CURRENT\"}}}"
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { return data }
            data.append(buffer, count: count)
        }
    }
}
