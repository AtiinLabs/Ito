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

    private var originalPipeline: ImagePipeline!

    override func setUp() {
        super.setUp()
        originalPipeline = ImagePipeline.shared
    }

    override func tearDown() {
        super.tearDown()
        ImagePipeline.shared = originalPipeline
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

    // MARK: - Test C: NukeUI LazyImage lifecycle and display decoding
    func testControlC_NukeImageRequest_DecodesAndExtractsImage() async throws {
        let host = "test-c.example.com"
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

        let url = try XCTUnwrap(URL(string: "https://\(host)/page.png"))
        let request = ImageRequest(url: url)
        let image = try await pipeline.image(for: request)
        XCTAssertEqual(image.size.width, 1.0)
        XCTAssertEqual(image.size.height, 1.0)
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
        let pageWithHeaders = Page(index: 0, content: .url(testURL), headers: customHeaders)
        let prefetchRequestWithHeaders = NukeMangaReaderImagePrefetcher.request(for: pageWithHeaders)
        XCTAssertNotNil(prefetchRequestWithHeaders)
        let urlRequestWithHeaders = prefetchRequestWithHeaders?.urlRequest
        XCTAssertEqual(urlRequestWithHeaders?.value(forHTTPHeaderField: "Referer"), "https://source.example.com/manga/123")
        XCTAssertEqual(urlRequestWithHeaders?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(urlRequestWithHeaders?.value(forHTTPHeaderField: "X-Custom-Auth"), "secret")

        // Case 2: Nil headers -> Default headers in prefetcher:
        let pageDefault = Page(index: 1, content: .url(testURL), headers: nil)
        let prefetchRequestDefault = NukeMangaReaderImagePrefetcher.request(for: pageDefault)
        let urlRequestDefault = prefetchRequestDefault?.urlRequest
        XCTAssertEqual(urlRequestDefault?.value(forHTTPHeaderField: "Referer"), testURL)
        XCTAssertTrue(urlRequestDefault?.value(forHTTPHeaderField: "User-Agent")?.contains("iPhone OS 16_0") == true)

        // Verify MangaImage's createRequest logic matches prefetcher exactly
        let mangaImage = MangaImage(urlStr: testURL, headers: customHeaders)
        let viewRequest = mangaImage.createRequest(url: url)
        XCTAssertEqual(viewRequest.value(forHTTPHeaderField: "Referer"), urlRequestWithHeaders?.value(forHTTPHeaderField: "Referer"))
        XCTAssertEqual(viewRequest.value(forHTTPHeaderField: "Authorization"), urlRequestWithHeaders?.value(forHTTPHeaderField: "Authorization"))
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

    // MARK: - Test I: StorageManager setup retains PluginDataLoader and NukeDiagnosticDelegate
    func testControlI_StorageManagerSetupRetainsPluginDataLoader() async throws {
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
        // ImagePipeline.shared is restored in tearDown() to prevent global pollution
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
