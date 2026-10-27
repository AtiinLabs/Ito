import SwiftUI
import UIKit
import Nuke
import XCTest
@testable import Ito

@MainActor
final class ReaderPageImageSessionTests: XCTestCase {
    func testHostedMangaImageRetainsFailureAcrossRemountAndExplicitRetryStartsOnce() async throws {
        let host = "reader-image-session.test"
        ReaderSessionURLProtocol.reset()
        ReaderSessionURLProtocol.register(host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReaderSessionURLProtocol.self]
        let pipeline = ImagePipeline {
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let url = try XCTUnwrap(URL(string: "https://\(host)/page.png"))
        let request = URLRequest(url: url)
        let descriptor = ReaderPageImageDescriptor(pageID: "chapter-page", request: request)
        let failure = expectation(description: "first request reaches terminal failure")
        var observation: ReaderImageObservation? = session.observe(descriptor.key) { state in
            if case .failed = state.phase { failure.fulfill() }
        }

        let image = MangaImage(
            urlStr: url.absoluteString,
            headers: nil,
            session: session,
            pageID: descriptor.pageID
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIHostingController(rootView: image)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        await fulfillment(of: [failure], timeout: 5)
        XCTAssertEqual(ReaderSessionURLProtocol.requestCount(for: host), 1)

        observation?.cancel()
        observation = nil
        window.isHidden = true
        window.rootViewController = nil
        let remounted = UIHostingController(rootView: image)
        window.makeKeyAndVisible()
        window.rootViewController = remounted
        remounted.view.frame = window.bounds
        remounted.view.layoutIfNeeded()
        let retryLease = session.acquire(descriptor, consumer: .visible)
        // Remounting acquires the page again; the failure stands and nothing restarts.
        if case .failed = session.state(for: descriptor.key).phase {} else {
            XCTFail("A remounted page must keep its failure until Try Again.")
        }
        XCTAssertEqual(ReaderSessionURLProtocol.requestCount(for: host), 1)

        let retryFailure = expectation(description: "explicit retry completes as failed")
        let retryObservation = session.observe(descriptor.key) { state in
            if case .failed = state.phase, state.revision > 0 { retryFailure.fulfill() }
        }
        session.retry(descriptor)
        await fulfillment(of: [retryFailure], timeout: 5)
        XCTAssertEqual(ReaderSessionURLProtocol.requestCount(for: host), 2)
        session.release(retryLease)
        retryObservation.cancel()
        window.isHidden = true
        window.rootViewController = nil
        session.deactivate()
    }

    func testChangedEffectiveHeadersProduceDistinctRequestKeys() throws {
        let url = try XCTUnwrap(URL(string: "https://reader-image-session.test/page.png"))
        var first = URLRequest(url: url)
        first.setValue("first", forHTTPHeaderField: "Authorization")
        var changed = URLRequest(url: url)
        changed.setValue("second", forHTTPHeaderField: "Authorization")

        XCTAssertNotEqual(ReaderPageImageKey(request: first), ReaderPageImageKey(request: changed))
    }

    func testChangedHeadersStartANewAttemptAfterTheOldRequestFailed() async throws {
        let host = "reader-changed-header.test"
        ReaderSessionURLProtocol.register(host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReaderSessionURLProtocol.self]
        let pipeline = ImagePipeline {
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let url = try XCTUnwrap(URL(string: "https://\(host)/page.png"))
        var firstRequest = URLRequest(url: url)
        firstRequest.setValue("first", forHTTPHeaderField: "Authorization")
        var changedRequest = URLRequest(url: url)
        changedRequest.setValue("second", forHTTPHeaderField: "Authorization")
        let first = ReaderPageImageDescriptor(pageID: "page", request: firstRequest)
        let changed = ReaderPageImageDescriptor(pageID: "page", request: changedRequest)

        let firstFailure = expectation(description: "the old headers fail")
        let firstObservation = session.observe(first.key) { state in
            if case .failed = state.phase { firstFailure.fulfill() }
        }
        let firstLease = session.acquire(first, consumer: .visible)
        await fulfillment(of: [firstFailure], timeout: 5)

        // A plugin that refreshed its headers gets a fresh attempt, not the old failure.
        let changedFailure = expectation(description: "the refreshed headers are tried")
        let changedObservation = session.observe(changed.key) { state in
            if case .failed = state.phase { changedFailure.fulfill() }
        }
        let changedLease = session.acquire(changed, consumer: .visible)
        await fulfillment(of: [changedFailure], timeout: 5)
        XCTAssertEqual(ReaderSessionURLProtocol.requestCount(for: host), 2)
        if case .failed = session.state(for: first.key).phase {} else {
            XCTFail("The old headers' failure stays with the old request.")
        }

        session.release(firstLease)
        session.release(changedLease)
        firstObservation.cancel()
        changedObservation.cancel()
        session.deactivate()
    }

    func testPrefetchStartsAtMostTwoPipelineRequestsConcurrently() async throws {
        let starts = expectation(description: "two prefetched requests start")
        starts.expectedFulfillmentCount = 2
        let loader = PendingReaderDataLoader(started: [starts, starts])
        let pipeline = ImagePipeline {
            $0.dataLoader = loader
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let descriptors = try (0..<5).map { index in
            ReaderPageImageDescriptor(
                pageID: "prefetch-\(index)",
                request: URLRequest(url: try XCTUnwrap(URL(string: "https://pending-reader.test/\(index).png")))
            )
        }

        session.setPrefetch(descriptors)
        await fulfillment(of: [starts], timeout: 5)
        XCTAssertEqual(loader.startedCount, 2)
        session.deactivate()
        loader.finishAll(with: URLError(.cancelled))
    }

    func testVisibleCancellationReturnsToIdleInsteadOfTerminalFailure() async throws {
        let started = expectation(description: "visible image request starts")
        let loader = PendingReaderDataLoader(started: [started])
        let pipeline = ImagePipeline {
            $0.dataLoader = loader
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let descriptor = ReaderPageImageDescriptor(
            pageID: "cancelled-visible",
            request: URLRequest(url: try XCTUnwrap(URL(string: "https://pending-reader.test/cancel.png")))
        )
        let lease = session.acquire(descriptor, consumer: .visible)

        await fulfillment(of: [started], timeout: 5)
        session.release(lease)
        if case .idle = session.state(for: descriptor.key).phase {
            // Cancellation must not become the durable failed state.
        } else {
            XCTFail("A cancelled visible request must return to idle.")
        }
        session.deactivate()
        loader.finishAll(with: URLError(.cancelled))
    }

    func testClearingPrefetchKeepsSharedVisibleAttemptActive() async throws {
        let started = expectation(description: "shared request starts")
        let loader = PendingReaderDataLoader(started: [started])
        let pipeline = ImagePipeline {
            $0.dataLoader = loader
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let descriptor = ReaderPageImageDescriptor(
            pageID: "visible-prefetched",
            request: URLRequest(url: try XCTUnwrap(URL(string: "https://pending-reader.test/shared.png")))
        )

        session.setPrefetch([descriptor])
        let visibleLease = session.acquire(descriptor, consumer: .visible)
        await fulfillment(of: [started], timeout: 5)
        session.setPrefetch([])
        XCTAssertEqual(loader.startedCount, 1)
        if case .loading = session.state(for: descriptor.key).phase {
            // Removing prefetch interest leaves the visible lease's task alive.
        } else {
            XCTFail("The visible lease must keep its shared request loading.")
        }
        session.release(visibleLease)
        loader.finishAll(with: URLError(.cancelled))
        session.deactivate()
    }
    func testPrefetchFailureIsSharedWithVisibleLease() async throws {
        let host = "reader-prefetch-session.test"
        ReaderSessionURLProtocol.register(host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReaderSessionURLProtocol.self]
        let pipeline = ImagePipeline {
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let descriptor = ReaderPageImageDescriptor(
            pageID: "prefetched-page",
            request: URLRequest(url: try XCTUnwrap(URL(string: "https://\(host)/page.png")))
        )
        let failure = expectation(description: "prefetch reaches terminal failure")
        let observation = session.observe(descriptor.key) { state in
            if case .failed = state.phase { failure.fulfill() }
        }

        session.setPrefetch([descriptor])
        await fulfillment(of: [failure], timeout: 5)
        let visibleLease = session.acquire(descriptor, consumer: .visible)
        XCTAssertEqual(ReaderSessionURLProtocol.requestCount(for: host), 1)
        if case .failed = session.state(for: descriptor.key).phase {
            // A visible remount reuses the prefetch's terminal result.
        } else {
            XCTFail("The shared request failure should remain terminal.")
        }
        session.release(visibleLease)
        observation.cancel()
        session.deactivate()
    }

    func testAPageShownAgainAppearsAtOnceFromMemory() async throws {
        let images = GatedImageLoader()
        let pipeline = ImagePipeline {
            $0.dataLoader = images
            $0.imageCache = ImageCache()
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let url = try XCTUnwrap(URL(string: "https://memory-session.test/page.png"))
        let descriptor = ReaderPageImageDescriptor(pageID: "page", request: URLRequest(url: url))
        let ready = expectation(description: "the page loads")
        let observation = session.observe(descriptor.key) { state in
            if case .ready = state.phase { ready.fulfill() }
        }
        let first = session.acquire(descriptor, consumer: .visible)
        await images.waitForRequest(url)
        images.respond(url, width: 300, height: 900)
        await fulfillment(of: [ready], timeout: 5)
        observation.cancel()
        session.release(first)

        // Scrolled back: the decoded image is still in memory, so no spinner and no request.
        let second = session.acquire(descriptor, consumer: .visible)
        if case .ready = session.state(for: descriptor.key).phase {} else {
            XCTFail("A page whose image is in memory must show it at once.")
        }
        XCTAssertEqual(session.knownPixelSize(for: descriptor), CGSize(width: 300, height: 900))
        XCTAssertEqual(images.requestCount, 1)
        session.release(second)
        session.deactivate()
    }
}

private final class ReaderSessionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestsByHost: [String: Int] = [:]
    nonisolated(unsafe) private static var hosts: Set<String> = []

    static func requestCount(for host: String) -> Int {
        lock.withLock { requestsByHost[host, default: 0] }
    }

    static func reset() {
        lock.withLock {
            requestsByHost.removeAll()
            hosts.removeAll()
        }
    }

    static func register(host: String) {
        lock.withLock { hosts.insert(host) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { hosts.contains(host) }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            let host = request.url?.host ?? ""
            Self.requestsByHost[host, default: 0] += 1
        }
        client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
    }

    override func stopLoading() {}
}

private final class PendingReaderDataLoader: DataLoading, @unchecked Sendable {
    private struct Pending {
        let id: UUID
        let completion: @Sendable (Error?) -> Void
    }

    private let lock = NSLock()
    private var started: [XCTestExpectation]
    private var pending: [Pending] = []

    init(started: [XCTestExpectation]) {
        self.started = started
    }

    var startedCount: Int {
        lock.withLock { pending.count }
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        let id = UUID()
        let event = lock.withLock { () -> XCTestExpectation? in
            pending.append(Pending(id: id, completion: completion))
            return started.isEmpty ? nil : started.removeFirst()
        }
        event?.fulfill()
        return PendingReaderSubscription {}
    }

    func finish(at index: Int, with error: Error?) {
        let completion = lock.withLock { pending[index].completion }
        completion(error)
    }

    func finishAll(with error: Error?) {
        let completions = lock.withLock { pending.map(\.completion) }
        completions.forEach { $0(error) }
    }
}

private final class PendingReaderSubscription: Cancellable, @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    private let lock = NSLock()
    private var isCancelled = false

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        let shouldCancel = lock.withLock {
            guard !isCancelled else { return false }
            isCancelled = true
            return true
        }
        if shouldCancel { onCancel() }
    }
}
