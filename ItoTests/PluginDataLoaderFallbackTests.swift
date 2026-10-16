import XCTest
import Nuke
@testable import Ito
import ito_runner

@MainActor
final class PluginDataLoaderFallbackTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        MockFallbackURLProtocol.reset()
    }

    func testPassthroughLoaderCancellation() async throws {
        let host = "passthrough-test.example.com"
        MockFallbackURLProtocol.register(host: host)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockFallbackURLProtocol.self]

        let database = try TestDatabase()
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginDataLoaderTest_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }

        let pluginManager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: pluginsDirectory
        )

        let loader = PluginDataLoader(
            configuration: config,
            pluginManager: pluginManager
        )

        let request = URLRequest(url: URL(string: "https://\(host)/plain-image.jpg")!)

        let expectation = expectation(description: "cancelled or completed")
        let cancellable = loader.loadData(
            with: request,
            didReceiveData: { _, _ in },
            completion: { _ in
                expectation.fulfill()
            }
        )

        cancellable.cancel()
        await fulfillment(of: [expectation], timeout: 5.0)
    }

    func testCustomItoSchemeFallbackCancellationLatch() async throws {
        // Direct test of the CancellationLatch state machine
        let cancelledLatch = CancellationLatch()
        XCTAssertFalse(cancelledLatch.isCancelled)

        var cancelCalled = false
        let dummyCancellable = AnyCancellable {
            cancelCalled = true
        }

        // When latch is cancelled before underlying cancellable is set:
        cancelledLatch.cancel()
        XCTAssertTrue(cancelledLatch.isCancelled)

        // Setting underlying on an already-cancelled latch must immediately cancel it:
        cancelledLatch.setUnderlying(dummyCancellable)
        XCTAssertTrue(cancelCalled, "Underlying cancellable must be immediately cancelled when latch is cancelled")
    }

    func testCancellationLatchActiveCancellation() async throws {
        let latch = CancellationLatch()
        var cancelCalled = false
        let dummyCancellable = AnyCancellable {
            cancelCalled = true
        }

        latch.setUnderlying(dummyCancellable)
        XCTAssertFalse(cancelCalled)

        latch.cancel()
        XCTAssertTrue(cancelCalled)
        XCTAssertTrue(latch.isCancelled)
    }
}

private class MockFallbackURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registeredHosts = Set<String>()

    static func register(host: String) {
        lock.lock()
        defer { lock.unlock() }
        registeredHosts.insert(host)
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        registeredHosts.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        lock.lock()
        defer { lock.unlock() }
        return registeredHosts.contains(host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            let response = HTTPURLResponse(
                url: self.request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/jpeg"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data([0xFF, 0xD8, 0xFF]))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
}

private final class AnyCancellable: Cancellable, @unchecked Sendable {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }
    func cancel() {
        closure()
    }
}
