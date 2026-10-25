import Foundation
import Nuke
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class PluginDataLoaderNativeTests: XCTestCase {
    override func tearDown() {
        PluginImageTransportTestURLProtocol.reset()
        super.tearDown()
    }

    func testNativeResolutionDownloadsOutsideTheByteHandler() async throws {
        let target = try XCTUnwrap(URL(string: "https://images.example/cover"))
        PluginImageTransportTestURLProtocol.registerHandler(for: target) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "fixture-private-key")
            return (HTTPURLResponse(url: target, statusCode: 200, httpVersion: nil, headerFields: [:])!, Data([1, 2, 3]))
        }
        let runner = NativeImageRunner(
            request: PluginImageRequest(url: target.absoluteString, headers: ["X-API-Key": "fixture-private-key"]),
            origins: ["https://images.example"]
        )
        let result = await load(runner)

        XCTAssertNil(result.error)
        XCTAssertEqual(result.data, Data([1, 2, 3]))
        XCTAssertEqual(result.completions, 1)
        let calls = await runner.legacyCalls
        XCTAssertEqual(calls, 0)
    }

    func testExplicitResolutionRefusalNeverFallsBackToImageBytes() async {
        let runner = NativeImageRunner(refusal: PluginCallError(kind: .reported, message: "Refused image"))
        let result = await load(runner)

        XCTAssertEqual(result.error as? PluginCallError, PluginCallError(kind: .reported, message: "Refused image"))
        XCTAssertTrue(result.data.isEmpty)
        let calls = await runner.legacyCalls
        XCTAssertEqual(calls, 0)
    }

    func testAnUndeclaredNativeDestinationFailsBeforeSendingOrFallingBack() async {
        let runner = NativeImageRunner(
            request: PluginImageRequest(url: "https://unapproved.example/cover", headers: ["X-Private": "secret"]),
            origins: ["https://images.example"]
        )
        let result = await load(runner)

        XCTAssertEqual(result.error as? PluginImageTransportError, .unpermittedOrigin)
        XCTAssertTrue(result.data.isEmpty)
        let calls = await runner.legacyCalls
        XCTAssertEqual(calls, 0)
    }

    func testUnsupportedResolutionStillUsesLegacyImageTransforms() async {
        let runner = NativeImageRunner()
        let result = await load(runner)

        XCTAssertNil(result.error)
        XCTAssertEqual(result.data, Data([9, 8]))
        let calls = await runner.legacyCalls
        XCTAssertEqual(calls, 1)
    }

    func testTwoNativeLoadsEnterTransportBeforeEitherCompletes() async throws {
        let target = try XCTUnwrap(URL(string: "https://images.example/pending"))
        let started = expectation(description: "Both native requests started")
        started.expectedFulfillmentCount = 2
        let stopped = expectation(description: "Both requests cancelled")
        stopped.expectedFulfillmentCount = 2
        PluginImageTransportTestURLProtocol.registerPendingRoute(
            for: target,
            onStart: { started.fulfill() },
            onStop: { stopped.fulfill() }
        )
        let runner = NativeImageRunner(
            request: PluginImageRequest(url: target.absoluteString),
            origins: ["https://images.example"]
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PluginImageTransportTestURLProtocol.self]
        let loader = PluginDataLoader(configuration: config, runnerProvider: { _ in runner })
        let completed = expectation(description: "Both loaders finish cancellation")
        completed.expectedFulfillmentCount = 2
        let capture = NativeImageCapture()
        let subscriptions = ["first", "second"].map { path in
            loader.loadData(
                with: URLRequest(url: URL(string: "ito://fixture.plugin/api/v1/\(path)")!),
                didReceiveData: { data, _ in capture.append(data) },
                completion: { error in
                    capture.complete(error)
                    completed.fulfill()
                }
            )
        }
        await fulfillment(of: [started], timeout: 5)
        subscriptions.forEach { $0.cancel() }
        await fulfillment(of: [stopped, completed], timeout: 5)
        XCTAssertTrue(capture.data.isEmpty)
        XCTAssertEqual(capture.completions, 2)
        XCTAssertEqual((capture.error as? URLError)?.code, .cancelled)
        let legacyCalls = await runner.legacyCalls
        XCTAssertEqual(legacyCalls, 0)
    }

    func testCancellationAfterANoncooperativeLegacyCallAlwaysCompletesWithoutData() async {
        for handledData in [Data([9, 8]), nil] {
            let started = expectation(description: "Legacy handler entered")
            let done = expectation(description: "Cancelled image completed")
            let runner = DelayedLegacyImageRunner(didStart: { started.fulfill() })
            let loader = PluginDataLoader(configuration: .ephemeral, runnerProvider: { _ in runner })
            let capture = NativeImageCapture()
            let request = URLRequest(url: URL(string: "ito://fixture.plugin/https://images.example/cover")!)
            let subscription = loader.loadData(with: request, didReceiveData: { data, _ in
                capture.append(data)
            }, completion: { error in
                capture.complete(error)
                done.fulfill()
            })
            await fulfillment(of: [started], timeout: 5)
            subscription.cancel()
            await runner.resume(returning: handledData)
            await fulfillment(of: [done], timeout: 5)

            XCTAssertTrue(capture.data.isEmpty)
            XCTAssertEqual(capture.completions, 1)
            XCTAssertEqual((capture.error as? URLError)?.code, .cancelled)
        }
    }

    func testCrashedImageRunnerIsEvictedSoNextImageRequestSucceedsWithHealthyReplacement() async {
        await assertCrashRecovery(crashOnLegacy: true)
        await assertCrashRecovery(crashOnLegacy: false)
    }

    private func assertCrashRecovery(crashOnLegacy: Bool) async {
        let crashedRunner = CrashingImageRunner(
            crashOnDescriptor: !crashOnLegacy,
            crashOnLegacy: crashOnLegacy
        )
        let healthyRunner = NativeImageRunner()

        let cache = TestImageRunnerCache(initialRunner: crashedRunner)
        let loader = PluginDataLoader(
            configuration: .ephemeral,
            runnerProvider: { pluginId in
                await cache.runner(for: pluginId)
            },
            runnerEvictor: { pluginId, runner in
                await cache.evict(pluginId: pluginId, matching: runner)
            }
        )

        // First request uses the crashing runner
        let capture1 = NativeImageCapture()
        let done1 = expectation(description: "First request completed")
        let sub1 = loader.loadData(
            with: URLRequest(url: URL(string: "ito://fixture.plugin/cover1")!),
            didReceiveData: { data, _ in capture1.append(data) },
            completion: { error in
                capture1.complete(error)
                done1.fulfill()
            }
        )
        await fulfillment(of: [done1], timeout: 5)
        withExtendedLifetime(sub1) {}

        XCTAssertTrue(capture1.data.isEmpty)
        XCTAssertEqual(capture1.completions, 1)
        XCTAssertEqual(capture1.error as? PluginCallError, PluginCallError(kind: .crashed, message: "The source stopped unexpectedly. Try again."))

        // Cache should have had its runner evicted
        let currentRunnerAfterCrash = await cache.currentRunner
        XCTAssertNil(currentRunnerAfterCrash, "Crashing runner must be evicted from cache")
        let evictions = await cache.evictionCount
        XCTAssertEqual(evictions, 1)

        // Supply healthy replacement into the cache for next request
        await cache.setReplacement(healthyRunner)

        // Second request gets the replacement runner and succeeds
        let capture2 = NativeImageCapture()
        let done2 = expectation(description: "Second request completed")
        let sub2 = loader.loadData(
            with: URLRequest(url: URL(string: "ito://fixture.plugin/cover2")!),
            didReceiveData: { data, _ in capture2.append(data) },
            completion: { error in
                capture2.complete(error)
                done2.fulfill()
            }
        )
        await fulfillment(of: [done2], timeout: 5)
        withExtendedLifetime(sub2) {}

        XCTAssertEqual(capture2.data, Data([9, 8]))
        XCTAssertEqual(capture2.completions, 1)
        XCTAssertNil(capture2.error)
        let legacyCalls = await healthyRunner.legacyCalls
        XCTAssertEqual(legacyCalls, 1)
    }


    func testReportedRefusalRemainsFailClosedAndDoesNotEvictRunner() async {
        let refusal = PluginCallError(kind: .reported, message: "Explicit refusal")
        let runner = NativeImageRunner(refusal: refusal)
        let cache = TestImageRunnerCache(initialRunner: runner)
        let loader = PluginDataLoader(
            configuration: .ephemeral,
            runnerProvider: { pluginId in
                await cache.runner(for: pluginId)
            },
            runnerEvictor: { pluginId, r in
                await cache.evict(pluginId: pluginId, matching: r)
            }
        )

        let capture = NativeImageCapture()
        let done = expectation(description: "Refusal request completed")
        let sub = loader.loadData(
            with: URLRequest(url: URL(string: "ito://fixture.plugin/cover")!),
            didReceiveData: { data, _ in capture.append(data) },
            completion: { error in
                capture.complete(error)
                done.fulfill()
            }
        )
        await fulfillment(of: [done], timeout: 5)
        withExtendedLifetime(sub) {}

        XCTAssertEqual(capture.error as? PluginCallError, refusal)
        XCTAssertTrue(capture.data.isEmpty)
        XCTAssertEqual(capture.completions, 1)
        let evictions = await cache.evictionCount
        XCTAssertEqual(evictions, 0, "Refusal must not evict the runner")
        let currentRunner = await cache.currentRunner
        XCTAssertNotNil(currentRunner, "Runner must remain in cache")
    }

    func testCancellationRemainsFailClosedAndDoesNotEvictRunner() async {
        let started = expectation(description: "Legacy handler entered")
        let done = expectation(description: "Cancelled request completed")
        let runner = DelayedLegacyImageRunner(didStart: { started.fulfill() })
        let cache = TestImageRunnerCache(initialRunner: runner)
        let loader = PluginDataLoader(
            configuration: .ephemeral,
            runnerProvider: { pluginId in
                await cache.runner(for: pluginId)
            },
            runnerEvictor: { pluginId, r in
                await cache.evict(pluginId: pluginId, matching: r)
            }
        )

        let capture = NativeImageCapture()
        let request = URLRequest(url: URL(string: "ito://fixture.plugin/https://images.example/cover")!)
        let sub = loader.loadData(
            with: request,
            didReceiveData: { data, _ in capture.append(data) },
            completion: { error in
                capture.complete(error)
                done.fulfill()
            }
        )

        await fulfillment(of: [started], timeout: 5)
        sub.cancel()
        await runner.resume(returning: Data([9, 8]))
        await fulfillment(of: [done], timeout: 5)

        XCTAssertTrue(capture.data.isEmpty)
        XCTAssertEqual(capture.completions, 1)
        XCTAssertEqual((capture.error as? URLError)?.code, .cancelled)
        let evictions = await cache.evictionCount
        XCTAssertEqual(evictions, 0, "Cancellation must not evict the runner")
        let currentRunner = await cache.currentRunner
        XCTAssertNotNil(currentRunner, "Runner must remain in cache")
    }

    private func load(_ runner: NativeImageRunner) async -> NativeImageCapture {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PluginImageTransportTestURLProtocol.self]
        let loader = PluginDataLoader(configuration: config, runnerProvider: { _ in runner })
        let capture = NativeImageCapture()
        let done = expectation(description: "Image load completed")
        let request = URLRequest(url: URL(string: "ito://fixture.plugin/api/v1/cover")!)
        let subscription = loader.loadData(with: request, didReceiveData: { data, _ in
            capture.append(data)
        }, completion: { error in
            capture.complete(error)
            done.fulfill()
        })
        await fulfillment(of: [done], timeout: 5)
        withExtendedLifetime(subscription) {}
        return capture
    }
}

private actor TestImageRunnerCache {
    private var current: (any PluginImageRunner)?
    private var replacement: (any PluginImageRunner)?
    private(set) var evictionCount = 0

    init(initialRunner: any PluginImageRunner) {
        self.current = initialRunner
    }

    func runner(for pluginId: String) -> any PluginImageRunner {
        if let current { return current }
        if let replacement {
            current = replacement
            return replacement
        }
        fatalError("No runner available")
    }

    func evict(pluginId: String, matching runner: any PluginImageRunner) {
        if let current, current as AnyObject === runner as AnyObject {
            self.current = nil
            evictionCount += 1
        }
    }

    func setReplacement(_ runner: any PluginImageRunner) {
        self.replacement = runner
        if current == nil {
            self.current = runner
        }
    }

    var currentRunner: (any PluginImageRunner)? { current }
}

private actor CrashingImageRunner: PluginImageRunner {
    private let crashOnDescriptor: Bool
    private let crashOnLegacy: Bool

    init(crashOnDescriptor: Bool = false, crashOnLegacy: Bool = false) {
        self.crashOnDescriptor = crashOnDescriptor
        self.crashOnLegacy = crashOnLegacy
    }

    func getImageRequest(_ locator: String) async throws -> PluginImageRequest? {
        if crashOnDescriptor {
            throw ItoError.wasmTrap("Synthetic image trap")
        }
        return nil
    }

    func getImageOrigins() async throws -> [String]? { nil }

    func handleImage(_ locator: String) async throws -> Data? {
        if crashOnLegacy {
            throw ItoError.wasmTrap("Synthetic image trap")
        }
        return Data([1, 2, 3])
    }
}

private actor NativeImageRunner: PluginImageRunner {
    private let request: PluginImageRequest?
    private let origins: [String]
    private let refusal: PluginCallError?
    private(set) var legacyCalls = 0

    init(request: PluginImageRequest? = nil, origins: [String] = [], refusal: PluginCallError? = nil) {
        self.request = request
        self.origins = origins
        self.refusal = refusal
    }

    func getImageRequest(_ locator: String) async throws -> PluginImageRequest? {
        if let refusal { throw refusal }
        return request
    }
    func getImageOrigins() async throws -> [String]? { origins }
    func handleImage(_ locator: String) async throws -> Data? {
        legacyCalls += 1
        return Data([9, 8])
    }
}

private actor DelayedLegacyImageRunner: PluginImageRunner {
    private let didStart: @Sendable () -> Void
    private var continuation: CheckedContinuation<Data?, Never>?

    init(didStart: @escaping @Sendable () -> Void) { self.didStart = didStart }
    func getImageRequest(_ locator: String) async throws -> PluginImageRequest? { nil }
    func getImageOrigins() async throws -> [String]? { nil }
    func handleImage(_ locator: String) async throws -> Data? {
        await withCheckedContinuation {
            continuation = $0
            didStart()
        }
    }
    func resume(returning data: Data?) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

nonisolated private final class NativeImageCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var failure: (any Error)?
    private var count = 0
    var data: Data { lock.withLock { bytes } }
    var error: (any Error)? { lock.withLock { failure } }
    var completions: Int { lock.withLock { count } }
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    func complete(_ error: (any Error)?) { lock.withLock { failure = error; count += 1 } }
}
