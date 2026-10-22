import Foundation
import XCTest
@testable import Ito

final class PluginImageTransportTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        PluginImageTransportTestURLProtocol.reset()
    }

    // MARK: - Origin Normalization & Parsing Tests

    func testOriginNormalizationDefaultAndExplicitPorts() throws {
        let url1 = try XCTUnwrap(URL(string: "https://example.com/images/1.jpg"))
        let origin1 = try PluginImageTransport.parseAndNormalizeOrigin(from: url1)
        XCTAssertEqual(origin1.scheme, "https")
        XCTAssertEqual(origin1.host, "example.com")
        XCTAssertEqual(origin1.port, 443)
        XCTAssertEqual(origin1.description, "https://example.com")

        let url2 = try XCTUnwrap(URL(string: "http://EXAMPLE.COM/images/2.png"))
        let origin2 = try PluginImageTransport.parseAndNormalizeOrigin(from: url2)
        XCTAssertEqual(origin2.scheme, "http")
        XCTAssertEqual(origin2.host, "example.com")
        XCTAssertEqual(origin2.port, 80)
        XCTAssertEqual(origin2.description, "http://example.com")

        let url3 = try XCTUnwrap(URL(string: "https://api.cdn.net:8443/photo"))
        let origin3 = try PluginImageTransport.parseAndNormalizeOrigin(from: url3)
        XCTAssertEqual(origin3.scheme, "https")
        XCTAssertEqual(origin3.host, "api.cdn.net")
        XCTAssertEqual(origin3.port, 8443)
        XCTAssertEqual(origin3.description, "https://api.cdn.net:8443")

        let url4 = try XCTUnwrap(URL(string: "http://example.com:80/cover"))
        let origin4 = try PluginImageTransport.parseAndNormalizeOrigin(from: url4)
        XCTAssertEqual(origin4.port, 80)
        XCTAssertEqual(origin4.description, "http://example.com")
    }

    func testRejectUserInfoInURL() {
        let url1 = URL(string: "https://user:pass@example.com/pic.jpg")!
        XCTAssertThrowsError(try PluginImageTransport.parseAndNormalizeOrigin(from: url1)) { error in
            XCTAssertEqual(error as? PluginImageTransportError, .userInfoNotAllowed)
        }

        let url2 = URL(string: "https://@example.com/pic.jpg")!
        XCTAssertThrowsError(try PluginImageTransport.parseAndNormalizeOrigin(from: url2)) { error in
            XCTAssertEqual(error as? PluginImageTransportError, .userInfoNotAllowed)
        }

        let url3 = URL(string: "https://user@example.com/pic.jpg")!
        XCTAssertThrowsError(try PluginImageTransport.parseAndNormalizeOrigin(from: url3)) { error in
            XCTAssertEqual(error as? PluginImageTransportError, .userInfoNotAllowed)
        }
    }

    func testRejectNonHttpOrHttpsSchemes() {
        let fileURL = URL(string: "file:///path/to/image.png")!
        XCTAssertThrowsError(try PluginImageTransport.parseAndNormalizeOrigin(from: fileURL)) { error in
            XCTAssertEqual(error as? PluginImageTransportError, .unpermittedScheme)
        }

        let itoURL = URL(string: "ito://plugin-image/123")!
        XCTAssertThrowsError(try PluginImageTransport.parseAndNormalizeOrigin(from: itoURL)) { error in
            XCTAssertEqual(error as? PluginImageTransportError, .unpermittedScheme)
        }

        let ftpURL = URL(string: "ftp://example.com/pic.jpg")!
        XCTAssertThrowsError(try PluginImageTransport.parseAndNormalizeOrigin(from: ftpURL)) { error in
            XCTAssertEqual(error as? PluginImageTransportError, .unpermittedScheme)
        }
    }

    func testRejectInvalidHostOrPort() {
        let noHost = URL(string: "https:///path/to/image.png")!
        XCTAssertThrowsError(try PluginImageTransport.parseAndNormalizeOrigin(from: noHost)) { error in
            XCTAssertEqual(error as? PluginImageTransportError, .invalidURL)
        }

        let invalidPort = "https://example.com:999999"
        XCTAssertThrowsError(try PluginImageTransport.parseAndNormalizeOrigin(from: invalidPort)) { error in
            XCTAssertEqual(error as? PluginImageTransportError, .invalidURL)
        }
    }

    // MARK: - Header Validation Tests

    func testRejectProhibitedHeaders() async {
        let transport = PluginImageTransport()
        let targetURL = URL(string: "https://cdn.example.com/pic.png")!
        let allowed = ["https://cdn.example.com"]

        let forbiddenNames = [
            "Host",
            "host",
            "Connection",
            "Keep-Alive",
            "Proxy-Authenticate",
            "Proxy-Authorization",
            "TE",
            "Trailer",
            "Transfer-Encoding",
            "Upgrade",
            "Content-Length"
        ]

        for headerName in forbiddenNames {
            do {
                _ = try await transport.fetch(
                    url: targetURL,
                    headers: [headerName: "custom-val"],
                    allowedOrigins: allowed
                )
                XCTFail("Expected failure for prohibited header: \(headerName)")
            } catch let error as PluginImageTransportError {
                XCTAssertEqual(error, .prohibitedHeader)
            } catch {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    func testRejectInvalidHeaderNames() async {
        let transport = PluginImageTransport()
        let targetURL = URL(string: "https://cdn.example.com/pic.png")!
        let allowed = ["https://cdn.example.com"]

        let invalidNames = [
            "",
            "Header Name With Spaces",
            "Header\tTab",
            "Bad@Header",
            "Bad(Header)",
            "Bad[Header]",
            "Bad/Header",
            "Bad:Header",
            "Bad;Header",
            "Bad<Header>",
            "Bad?Header",
            "Bad=Header",
            "Bad{Header}",
            "Bad\"Quote\"",
            "Bad\\Slash",
            "Bad\r\nHeader",
            "X-É",
            "X-汉字"
        ]

        for badName in invalidNames {
            do {
                _ = try await transport.fetch(
                    url: targetURL,
                    headers: [badName: "validValue"],
                    allowedOrigins: allowed
                )
                XCTFail("Expected failure for invalid header name: '\(badName)'")
            } catch let error as PluginImageTransportError {
                XCTAssertEqual(error, .invalidHeaderName)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectCRLFInHeaderValues() async {
        let transport = PluginImageTransport()
        let targetURL = URL(string: "https://cdn.example.com/pic.png")!
        let allowed = ["https://cdn.example.com"]

        for value in ["value\ninjection", "value\rinjection", "value\r\ninjection"] {
            do {
                _ = try await transport.fetch(
                    url: targetURL,
                    headers: ["X-Safe-Name": value],
                    allowedOrigins: allowed
                )
                XCTFail("Header line delimiters must be rejected before networking")
            } catch let error as PluginImageTransportError {
                XCTAssertEqual(error, .invalidHeaderValue)
            } catch {
                XCTFail("Unexpected error category")
            }
        }
    }

    // MARK: - Secret Leakage / Error Description Boundary Tests

    func testRejectedPrivateRequestsDoNotExposeTheirInputsThroughErrors() async throws {
        let secret = "PRIVATE_TOKEN_SENTINEL"
        let host = "private-host-sentinel.example"
        let url = try XCTUnwrap(URL(string: "https://\(host)/private-path?token=\(secret)"))
        let transport = PluginImageTransport()

        for allowed in [["https://different.example"], ["https://\(host)"]] {
            do {
                _ = try await transport.fetch(
                    url: url,
                    headers: ["X-Private": "\(secret)\r\nInjected: value"],
                    allowedOrigins: allowed
                )
                XCTFail("Unsafe image request must be refused")
            } catch {
                let descriptions = [error.localizedDescription, String(describing: error)]
                for description in descriptions {
                    XCTAssertFalse(description.contains(secret))
                    XCTAssertFalse(description.contains(host))
                    XCTAssertFalse(description.contains("private-path"))
                }
            }
        }
    }

    func testSessionErrorsCannotRetainPrivateRequestMetadata() async throws {
        let secret = "PRIVATE_SESSION_ERROR_SENTINEL"
        let target = try XCTUnwrap(URL(string: "https://private.example/image?token=\(secret)"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PluginImageTransportTestURLProtocol.self]
        let transport = PluginImageTransport(configuration: config)
        PluginImageTransportTestURLProtocol.registerHandler(for: target) { _ in
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotFindHost,
                userInfo: [NSURLErrorFailingURLStringErrorKey: target.absoluteString]
            )
        }

        do {
            _ = try await transport.fetch(url: target, headers: nil, allowedOrigins: ["https://private.example"])
            XCTFail("Scripted connection failure must fail the image")
        } catch {
            XCTAssertEqual(error as? PluginImageTransportError, .downloadFailed)
            XCTAssertFalse(String(reflecting: error).contains(secret))
            XCTAssertFalse(String(describing: (error as NSError).userInfo).contains(secret))
        }
    }

    // MARK: - Pre-fetch Origin Mismatch Tests

    func testInitialOriginMismatchThrowsBeforeFetch() async {
        let transport = PluginImageTransport()
        let targetURL = URL(string: "https://attacker.com/pic.png")!
        let allowed = ["https://trusted.com"]

        do {
            _ = try await transport.fetch(url: targetURL, headers: nil, allowedOrigins: allowed)
            XCTFail("Expected unpermittedOrigin error")
        } catch let error as PluginImageTransportError {
            XCTAssertEqual(error, .unpermittedOrigin)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Request Execution & Non-2xx Rejection

    func testSuccessfulFetchPreservesHeaders() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PluginImageTransportTestURLProtocol.self]
        let transport = PluginImageTransport(configuration: config)

        let targetURL = try XCTUnwrap(URL(string: "https://cdn.example.com/image.jpg"))
        let allowed = ["https://cdn.example.com"]

        let responseBody = Data("JPEG_IMAGE_BYTES".utf8)
        PluginImageTransportTestURLProtocol.registerHandler(for: targetURL) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://read.example.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Token"), "secret123")
            return (
                HTTPURLResponse(
                    url: targetURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/jpeg"]
                )!,
                responseBody
            )
        }

        let (data, response) = try await transport.fetch(
            url: targetURL,
            headers: [
                "Referer": "https://read.example.com",
                "X-Auth-Token": "secret123"
            ],
            allowedOrigins: allowed
        )

        XCTAssertEqual(data, responseBody)
        XCTAssertEqual(response.statusCode, 200)
    }

    func testRejectNon2xxResponses() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PluginImageTransportTestURLProtocol.self]
        let transport = PluginImageTransport(configuration: config)

        let targetURL = try XCTUnwrap(URL(string: "https://cdn.example.com/not-found.jpg"))
        let allowed = ["https://cdn.example.com"]

        for statusCode in [400, 403, 404, 500, 502] {
            PluginImageTransportTestURLProtocol.registerHandler(for: targetURL) { _ in
                (
                    HTTPURLResponse(
                        url: targetURL,
                        statusCode: statusCode,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/plain"]
                    )!,
                    Data("Error body".utf8)
                )
            }

            do {
                _ = try await transport.fetch(url: targetURL, headers: nil, allowedOrigins: allowed)
                XCTFail("Expected fetch to fail for HTTP \(statusCode)")
            } catch let error as PluginImageTransportError {
                XCTAssertEqual(error, .badServerResponse)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Same-Origin vs Cross-Origin Redirect Tests

    func testSameOriginRedirectReappliesHeadersAndSucceeds() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PluginImageTransportTestURLProtocol.self]
        let transport = PluginImageTransport(configuration: config)

        let initialURL = try XCTUnwrap(URL(string: "https://cdn.example.com/redirect-me"))
        let redirectTargetURL = try XCTUnwrap(URL(string: "https://cdn.example.com/final-image.jpg"))
        let allowed = ["https://cdn.example.com"]

        let responseBody = Data("FINAL_IMAGE_BYTES".utf8)

        PluginImageTransportTestURLProtocol.registerHandler(for: initialURL) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Custom-Header"), "preserved-value")
            return (
                HTTPURLResponse(
                    url: initialURL,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": redirectTargetURL.absoluteString]
                )!,
                Data()
            )
        }

        PluginImageTransportTestURLProtocol.registerHandler(for: redirectTargetURL) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Custom-Header"), "preserved-value")
            return (
                HTTPURLResponse(
                    url: redirectTargetURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/jpeg"]
                )!,
                responseBody
            )
        }

        let (data, response) = try await transport.fetch(
            url: initialURL,
            headers: ["X-Custom-Header": "preserved-value"],
            allowedOrigins: allowed
        )

        XCTAssertEqual(data, responseBody)
        XCTAssertEqual(response.statusCode, 200)
    }

    func testCrossOriginRedirectBlockedEvenIfDestinationIsAnAllowedOrigin() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PluginImageTransportTestURLProtocol.self]
        let transport = PluginImageTransport(configuration: config)

        let initialURL = try XCTUnwrap(URL(string: "https://origin-a.com/image.jpg"))
        let redirectTargetURL = try XCTUnwrap(URL(string: "https://origin-b.com/image.jpg"))
        let allowed = ["https://origin-a.com", "https://origin-b.com"]

        PluginImageTransportTestURLProtocol.registerHandler(for: initialURL) { _ in
            (
                HTTPURLResponse(
                    url: initialURL,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": redirectTargetURL.absoluteString]
                )!,
                Data()
            )
        }

        do {
            _ = try await transport.fetch(
                url: initialURL,
                headers: ["Authorization": "Bearer secret"],
                allowedOrigins: allowed
            )
            XCTFail("Expected cross-origin redirect to be blocked")
        } catch let error as PluginImageTransportError {
            XCTAssertEqual(error, .crossOriginRedirectBlocked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHTTPSDowngradeRedirectBlocked() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PluginImageTransportTestURLProtocol.self]
        let transport = PluginImageTransport(configuration: config)

        let initialURL = try XCTUnwrap(URL(string: "https://cdn.example.com/secure.jpg"))
        let redirectTargetURL = try XCTUnwrap(URL(string: "http://cdn.example.com/insecure.jpg"))
        let allowed = ["https://cdn.example.com", "http://cdn.example.com"]

        PluginImageTransportTestURLProtocol.registerHandler(for: initialURL) { _ in
            (
                HTTPURLResponse(
                    url: initialURL,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": redirectTargetURL.absoluteString]
                )!,
                Data()
            )
        }

        do {
            _ = try await transport.fetch(
                url: initialURL,
                headers: nil,
                allowedOrigins: allowed
            )
            XCTFail("Expected HTTPS downgrade to be blocked")
        } catch let error as PluginImageTransportError {
            XCTAssertEqual(error, .httpsDowngradeBlocked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Cookie and URLCache Isolation Tests

    func testNoAmbientCookiesTransmittedOrStored() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PluginImageTransportTestURLProtocol.self]
        let customCookieStorage = HTTPCookieStorage.shared
        config.httpCookieStorage = customCookieStorage
        config.httpShouldSetCookies = true

        let targetURL = try XCTUnwrap(URL(string: "https://cdn.example.com/cookie-test.jpg"))
        let allowed = ["https://cdn.example.com"]

        let cookieProperties: [HTTPCookiePropertyKey: Any] = [
            .domain: "cdn.example.com",
            .path: "/",
            .name: "ambient_session",
            .value: "LEAKED_COOKIE",
            .secure: "TRUE"
        ]
        if let cookie = HTTPCookie(properties: cookieProperties) {
            customCookieStorage.setCookie(cookie)
        }

        let transport = PluginImageTransport(configuration: config)

        PluginImageTransportTestURLProtocol.registerHandler(for: targetURL) { request in
            let cookieHeader = request.value(forHTTPHeaderField: "Cookie")
            XCTAssertNil(cookieHeader, "Transport must not transmit ambient cookies")
            return (
                HTTPURLResponse(
                    url: targetURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "image/jpeg",
                        "Set-Cookie": "server_cookie=val; Path=/"
                    ]
                )!,
                Data("TEST".utf8)
            )
        }

        let (data, response) = try await transport.fetch(
            url: targetURL,
            headers: nil,
            allowedOrigins: allowed
        )

        XCTAssertEqual(data, Data("TEST".utf8))
        XCTAssertEqual(response.statusCode, 200)

        let storedCookies = customCookieStorage.cookies(for: targetURL) ?? []
        let serverCookie = storedCookies.first { $0.name == "server_cookie" }
        XCTAssertNil(serverCookie, "Set-Cookie from response must not be stored")
    }

    // MARK: - Cancellation Test

    func testCancellationCancelsInFlightFetch() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PluginImageTransportTestURLProtocol.self]
        let transport = PluginImageTransport(configuration: config)

        let targetURL = try XCTUnwrap(URL(string: "https://cdn.example.com/hang.jpg"))
        let allowed = ["https://cdn.example.com"]

        let startedExpectation = expectation(description: "Request started and entered URLProtocol")
        let stoppedExpectation = expectation(description: "Request stopped loading due to cancellation")

        PluginImageTransportTestURLProtocol.registerPendingRoute(
            for: targetURL,
            onStart: {
                startedExpectation.fulfill()
            },
            onStop: {
                stoppedExpectation.fulfill()
            }
        )

        let task = Task {
            try await transport.fetch(url: targetURL, headers: nil, allowedOrigins: allowed)
        }

        await fulfillment(of: [startedExpectation], timeout: 5.0)

        task.cancel()

        await fulfillment(of: [stoppedExpectation], timeout: 5.0)

        do {
            _ = try await task.value
            XCTFail("Fetch should throw when task is cancelled")
        } catch is CancellationError {
            // Expected CancellationError
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Expected URLError.cancelled
        } catch {
            let nsError = error as NSError
            XCTAssertTrue(
                nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled,
                "Expected cancellation error, got \(error)"
            )
        }
    }
}

// MARK: - Test URLProtocol for Mocking Network

final class PluginImageTransportTestURLProtocol: URLProtocol, @unchecked Sendable {
    private struct PendingRoute: Sendable {
        let onStart: @Sendable () -> Void
        let onStop: @Sendable () -> Void
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [URL: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]
    nonisolated(unsafe) private static var pendingRoutes: [URL: PendingRoute] = [:]

    private let routeLock = NSLock()
    private var activePendingRoute: PendingRoute?

    static func reset() {
        lock.lock()
        handlers.removeAll()
        pendingRoutes.removeAll()
        lock.unlock()
    }

    static func registerHandler(
        for url: URL,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.lock()
        handlers[url] = handler
        lock.unlock()
    }

    static func registerPendingRoute(
        for url: URL,
        onStart: @escaping @Sendable () -> Void,
        onStop: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        pendingRoutes[url] = PendingRoute(onStart: onStart, onStop: onStop)
        lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        lock.lock()
        defer { lock.unlock() }
        return handlers[url] != nil || pendingRoutes[url] != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        let handler = Self.handlers[url]
        let pending = Self.pendingRoutes[url]
        Self.lock.unlock()

        if let pending = pending {
            routeLock.lock()
            activePendingRoute = pending
            routeLock.unlock()

            pending.onStart()
            // Intentionally leave request pending with no client callbacks
            return
        }

        if let handler = handler {
            do {
                let (response, data) = try handler(request)

                if (300...399).contains(response.statusCode),
                   let location = response.allHeaderFields["Location"] as? String,
                   let redirectURL = URL(string: location, relativeTo: url) {
                    var redirectRequest = URLRequest(url: redirectURL)
                    redirectRequest.httpMethod = "GET"
                    client?.urlProtocol(self, wasRedirectedTo: redirectRequest, redirectResponse: response)
                    return
                }

                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {
        routeLock.lock()
        let pending = activePendingRoute
        activePendingRoute = nil
        routeLock.unlock()

        pending?.onStop()
    }
}
