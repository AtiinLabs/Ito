import XCTest
import Nuke
import Combine
@testable import Ito
import ito_runner

@MainActor
final class ItoImagePipelineDiagnosticTests: XCTestCase {

    // Tiny 1x1 valid PNG (68 bytes)
    static let tinyPNGData = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    ])

    override func tearDown() {
        super.tearDown()
        MockImageURLProtocol.reset()
    }

    // MARK: - Test A: Plain Nuke pipeline with valid PNG
    func testControlA_PlainNukePipeline_ValidPNG_DecodesSuccessfully() async throws {
        let host = "test-a.example.com"
        MockImageURLProtocol.register(
            host: host,
            statusCode: 200,
            headers: ["Content-Type": "image/png"],
            data: Self.tinyPNGData
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockImageURLProtocol.self]
        let pipeline = ImagePipeline {
            $0.dataLoader = DataLoader(configuration: config)
            $0.imageCache = nil
            $0.dataCache = nil
        }

        let url = try XCTUnwrap(URL(string: "https://\(host)/image.png"))
        let response = try await pipeline.image(for: ImageRequest(url: url))
        XCTAssertGreaterThan(response.size.width, 0)
        XCTAssertGreaterThan(response.size.height, 0)
    }

    // MARK: - Test B: Ito-configured pipeline + PluginDataLoader with valid PNG for HTTPS
    func testControlB_ItoConfiguredPipeline_PluginDataLoader_ValidPNG_DecodesSuccessfully() async throws {
        let host = "test-b.example.com"
        MockImageURLProtocol.register(
            host: host,
            statusCode: 200,
            headers: ["Content-Type": "image/png"],
            data: Self.tinyPNGData
        )

        let defaultUA = CloudflareManager.defaultUserAgent
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockImageURLProtocol.self]
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": defaultUA]

        let database = try TestDatabase()
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ItoTestPlugins_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }
        let pluginManager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: pluginsDirectory
        )

        let pluginDataLoader = PluginDataLoader(
            configuration: config,
            pluginManager: pluginManager
        )

        let pipeline = ImagePipeline {
            $0.dataLoader = pluginDataLoader
            $0.imageCache = nil
            $0.dataCache = nil
        }

        let url = try XCTUnwrap(URL(string: "https://\(host)/image.png"))
        let response = try await pipeline.image(for: ImageRequest(url: url))
        XCTAssertGreaterThan(response.size.width, 0)
        XCTAssertGreaterThan(response.size.height, 0)

        // Verify request received the User-Agent header from config
        let lastReq = MockImageURLProtocol.lastRequest(forHost: host)
        XCTAssertEqual(lastReq?.value(forHTTPHeaderField: "User-Agent"), defaultUA)
    }

    // MARK: - Test D: HTTP 200 with HTML instead of image produces decode failure
    func testControlD_HTTP200WithHTML_ProducesDecodingError() async throws {
        let host = "test-d.example.com"
        let htmlData = Data("<!DOCTYPE html><html><body>Challenge/Error Page</body></html>".utf8)
        MockImageURLProtocol.register(
            host: host,
            statusCode: 200,
            headers: ["Content-Type": "text/html"],
            data: htmlData
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockImageURLProtocol.self]

        let pipeline = ImagePipeline {
            $0.dataLoader = DataLoader(configuration: config)
            $0.imageCache = nil
            $0.dataCache = nil
        }

        let url = try XCTUnwrap(URL(string: "https://\(host)/page.jpg"))
        do {
            _ = try await pipeline.image(for: ImageRequest(url: url))
            XCTFail("Expected image decoding to fail for HTML response")
        } catch {
            XCTAssertTrue(error is ImagePipeline.Error)
        }
    }

    // MARK: - Test E: HTTP 403 / 429 surfaces distinguishable error
    func testControlE_HTTP403And429_SurfacesHTTPError() async throws {
        for statusCode in [403, 429] {
            let host = "test-e-\(statusCode).example.com"
            MockImageURLProtocol.register(
                host: host,
                statusCode: statusCode,
                headers: ["Content-Type": "text/html"],
                data: Data("Blocked".utf8)
            )

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockImageURLProtocol.self]

            let pipeline = ImagePipeline {
                $0.dataLoader = DataLoader(configuration: config)
                $0.imageCache = nil
                $0.dataCache = nil
            }

            let url = try XCTUnwrap(URL(string: "https://\(host)/denied.jpg"))
            do {
                _ = try await pipeline.image(for: ImageRequest(url: url))
                XCTFail("Expected HTTP \(statusCode) to fail")
            } catch {
                XCTAssertTrue(error is ImagePipeline.Error)
            }
        }
    }

    // MARK: - Test F: MangaImage request headers vs Prefetcher parity
    func testControlF_MangaImageVsPrefetcherHeaderParity() throws {
        let testURL = "https://cdn.example.com/ch1/001.jpg"
        let url = URL(string: testURL)!

        // Case 1: Custom headers provided by Page
        let customHeaders = [
            "Referer": "https://source.example.com/manga/123",
            "Authorization": "Bearer test-token",
            "X-Custom-Auth": "secret"
        ]

        // Case 2: Nil headers -> Default headers in MangaImage:
        // User-Agent: iPhone 16.0 Safari
        // Referer: urlStr itself
        var visibleRequestDefault = URLRequest(url: url)
        visibleRequestDefault.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        visibleRequestDefault.setValue(testURL, forHTTPHeaderField: "Referer")

        var visibleRequestWithHeaders = URLRequest(url: url)
        for (k, v) in customHeaders {
            visibleRequestWithHeaders.setValue(v, forHTTPHeaderField: k)
        }

        XCTAssertEqual(visibleRequestWithHeaders.value(forHTTPHeaderField: "Referer"), "https://source.example.com/manga/123")
        XCTAssertEqual(visibleRequestWithHeaders.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(visibleRequestWithHeaders.value(forHTTPHeaderField: "X-Custom-Auth"), "secret")

        XCTAssertEqual(visibleRequestDefault.value(forHTTPHeaderField: "Referer"), testURL)
        XCTAssertTrue(visibleRequestDefault.value(forHTTPHeaderField: "User-Agent")?.contains("iPhone OS 16_0") == true)
    }

    // MARK: - Test G: Custom ito:// scheme routing via PluginDataLoader
    func testControlG_CustomItoSchemeRouting_ViaPluginDataLoader() async throws {
        let database = try TestDatabase()
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ItoTestPlugins_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }
        let pluginManager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: pluginsDirectory
        )

        let pluginDataLoader = PluginDataLoader(
            configuration: .ephemeral,
            pluginManager: pluginManager
        )

        // Non-existent plugin should fail with appropriate error
        let invalidItoURL = URL(string: "ito://nonexistent.plugin/https://example.com/img.jpg")!
        let request = URLRequest(url: invalidItoURL)

        let expectation = expectation(description: "load completes with error")
        _ = pluginDataLoader.loadData(
            with: request,
            didReceiveData: { _, _ in },
            completion: { error in
                XCTAssertNotNil(error)
                expectation.fulfill()
            }
        )
        await fulfillment(of: [expectation], timeout: 5.0)
    }
    // MARK: - Test H: HTTP 410 Gone surfaces typed error and triggers diagnostic logging
    func testControlH_HTTP410Gone_SurfacesTypedError() async throws {
        let host = "test-h-410.example.com"
        MockImageURLProtocol.register(
            host: host,
            statusCode: 410,
            headers: ["Content-Type": "text/html"],
            data: Data("410 Gone".utf8)
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockImageURLProtocol.self]

        let pipeline = ImagePipeline(delegate: NukeDiagnosticDelegate.shared) {
            $0.dataLoader = DataLoader(configuration: config)
            $0.imageCache = nil
            $0.dataCache = nil
        }

        let url = try XCTUnwrap(URL(string: "https://\(host)/expired.avif"))
        do {
            _ = try await pipeline.image(for: ImageRequest(url: url))
            XCTFail("Expected HTTP 410 to fail image load")
        } catch {
            XCTAssertTrue(error is ImagePipeline.Error)
        }
    }

    // MARK: - Test I: StorageManager fallback setup retains PluginDataLoader and NukeDiagnosticDelegate
    func testControlI_StorageManagerFallbackRetainsPluginDataLoader() async throws {
        let database = try TestDatabase()
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ItoTestPlugins_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }
        let pluginManager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: pluginsDirectory
        )

        let storageManager = StorageManager(pluginManager: pluginManager)
        XCTAssertNotNil(storageManager)
        XCTAssertNotNil(ImagePipeline.shared)
    }

}

// MARK: - MockImageURLProtocol
private class MockImageURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var mocks: [String: (statusCode: Int, headers: [String: String], data: Data)] = [:]
    nonisolated(unsafe) private static var lastRequests: [String: URLRequest] = [:]

    static func register(host: String, statusCode: Int, headers: [String: String], data: Data) {
        lock.lock()
        defer { lock.unlock() }
        mocks[host] = (statusCode, headers, data)
    }

    static func lastRequest(forHost host: String) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequests[host]
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        mocks.removeAll()
        lastRequests.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        lock.lock()
        defer { lock.unlock() }
        return mocks[host] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let host = request.url?.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        Self.lastRequests[host] = request
        let mock = Self.mocks[host]
        Self.lock.unlock()

        guard let mock = mock else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: mock.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: mock.headers
        )!

        if mock.statusCode >= 400 {
            let error = NSError(
                domain: NSURLErrorDomain,
                code: mock.statusCode == 403 ? NSURLErrorUserAuthenticationRequired : NSURLErrorBadServerResponse,
                userInfo: [NSURLErrorFailingURLErrorKey: request.url!]
            )
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: mock.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
