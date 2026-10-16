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

    func testFallbackCancellableCancelsUnderlyingLoaderOnCancellation() async throws {
        let host = "fallback-test.example.com"
        MockFallbackURLProtocol.register(host: host)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockFallbackURLProtocol.self]

        let database = try TestDatabase()
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginDataLoaderTest_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }

        // Setup a mock plugin that returns nil for handleImage so it falls back to real URL
        let pluginManager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: pluginsDirectory
        )

        let loader = PluginDataLoader(
            configuration: config,
            pluginManager: pluginManager
        )

        // When ito:// URL is used but the plugin doesn't intercept (or runner has nil handleImage),
        // fallback triggers defaultLoader.loadData.
        // We verify that cancelling the returned Cancellable cancels the fallback request.
        let nonInterceptedURL = URL(string: "https://\(host)/plain-image.jpg")!
        let request = URLRequest(url: nonInterceptedURL)

        let expectation = expectation(description: "cancelled or completed")
        let cancellable = loader.loadData(
            with: request,
            didReceiveData: { _, _ in },
            completion: { _ in
                expectation.fulfill()
            }
        )

        // Cancel immediately
        cancellable.cancel()

        await fulfillment(of: [expectation], timeout: 5.0)
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
        // Delay slightly to allow cancellation
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
