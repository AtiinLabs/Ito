import Foundation
import XCTest
import ito_runner
@testable import Ito

final class AppNetModulePrivacyTests: XCTestCase {
    private let sentinelAuthorization = "Bearer SENTINEL_AUTHORIZATION_VALUE"
    private let sentinelClearance = "SENTINEL_CLEARANCE_VALUE"
    private let sentinelCookie = "SENTINEL_COOKIE_VALUE"
    private let sentinelCredentials = "SENTINEL_USER:SENTINEL_PASSWORD"
    private let sentinelQueryToken = "SENTINEL_QUERY_TOKEN"
    private let sentinelSearch = "SENTINEL_PRIVATE_SEARCH_TERM"
    private let sentinelUserAgent = "SENTINEL_CLOUDFLARE_USER_AGENT"

    func testSecretBearingRetryLogsOnlySafeEventsAndTransmitsRequiredMaterial() async throws {
        let fixture = try makeFixture(
            steps: [
                .success(
                    StubHTTPResponse(
                        statusCode: 403,
                        headers: ["Server": "cloudflare"],
                        body: Data("challenge".utf8)
                    )
                ),
                .success(
                    StubHTTPResponse(
                        statusCode: 201,
                        headers: ["X-Retry-Outcome": "success"],
                        body: Data("retry-response".utf8)
                    )
                )
            ]
        )

        let response = try await fixture.module.fetch(request: fixture.request)
        let requests = fixture.boundary.requests

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url, fixture.url)
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Authorization"),
            sentinelAuthorization
        )
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Cookie"),
            "initial_session=\(sentinelCookie)"
        )

        let retriedRequest = requests[1]
        XCTAssertEqual(retriedRequest.url, fixture.url)
        XCTAssertEqual(retriedRequest.httpMethod, "POST")
        XCTAssertEqual(
            fixture.boundary.requestBodies[1],
            Data("payload=\(sentinelCredentials)".utf8)
        )
        XCTAssertEqual(
            retriedRequest.value(forHTTPHeaderField: "Authorization"),
            sentinelAuthorization
        )
        XCTAssertEqual(
            retriedRequest.value(forHTTPHeaderField: "Cookie"),
            "cf_clearance=\(sentinelClearance); session=\(sentinelCookie)"
        )
        XCTAssertEqual(
            retriedRequest.value(forHTTPHeaderField: "User-Agent"),
            sentinelUserAgent
        )
        XCTAssertEqual(
            retriedRequest.url?.query,
            "q=\(sentinelSearch)&token=\(sentinelQueryToken)"
        )

        XCTAssertEqual(
            fixture.logger.events,
            [.challengeDetected, .retryStarted, .retryCompleted(status: 201)]
        )
        let loggedOutput = fixture.logger.messages.joined(separator: "\n")
        for sensitiveValue in sensitiveValues {
            XCTAssertFalse(loggedOutput.contains(sensitiveValue))
        }
        XCTAssertFalse(loggedOutput.contains(String(describing: fixture.request.headers)))
        XCTAssertFalse(loggedOutput.contains(String(describing: fixture.request)))

        XCTAssertEqual(response.status, 201)
        XCTAssertEqual(response.body, [UInt8]("retry-response".utf8))
        XCTAssertEqual(response.headers["X-Retry-Outcome"], "success")
        XCTAssertEqual(response.headers["X-Used-User-Agent"], sentinelUserAgent)
        XCTAssertEqual(fixture.cloudflare.resolvedURLs, [fixture.url])
    }

    func testSafeRetryDiagnosticsRetainOnlyHighLevelOutcomeAndStatus() {
        XCTAssertEqual(
            AppNetRetryDiagnostic.format(.challengeDetected),
            "[AppNetModule] Cloudflare challenge detected."
        )
        XCTAssertEqual(
            AppNetRetryDiagnostic.format(.retryStarted),
            "[AppNetModule] Cloudflare retry started."
        )
        XCTAssertEqual(
            AppNetRetryDiagnostic.format(.retryCompleted(status: 204)),
            "[AppNetModule] Cloudflare retry completed with status code: 204"
        )
    }

    func testAppLoggerBoundaryAcceptsOnlyClosedRetryEvents() throws {
        let source = try appNetModuleSource()
        let actorSource = try XCTUnwrap(source.range(of: "actor AppNetModule")).lowerBound...
        let actorBody = String(source[actorSource])

        XCTAssertEqual(
            source.components(separatedBy: "AppLogger.").count - 1,
            1
        )
        XCTAssertTrue(
            source.contains(
                "AppLogger.network.debug(\"\\(AppNetRetryDiagnostic.format(event))\")"
            )
        )
        XCTAssertFalse(actorBody.contains("AppLogger."))
        XCTAssertFalse(actorBody.contains("Logger(subsystem:"))
        XCTAssertFalse(actorBody.contains("os_log("))
        XCTAssertEqual(
            actorBody.components(separatedBy: "retryLogger.log").count - 1,
            3
        )
        XCTAssertTrue(actorBody.contains("retryLogger.log(.challengeDetected)"))
        XCTAssertTrue(actorBody.contains("retryLogger.log(.retryStarted)"))
        XCTAssertTrue(
            actorBody.contains(
                "retryLogger.log(.retryCompleted(status: retriedResponse.status))"
            )
        )
    }

    func testNonCloudflareForbiddenResponseDoesNotResolveOrRetry() async throws {
        let fixture = try makeFixture(
            steps: [
                .success(
                    StubHTTPResponse(
                        statusCode: 403,
                        headers: ["Server": "origin"],
                        body: Data("origin-forbidden".utf8)
                    )
                )
            ]
        )

        let response = try await fixture.module.fetch(request: fixture.request)

        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(response.body, [UInt8]("origin-forbidden".utf8))
        XCTAssertEqual(fixture.boundary.requests.count, 1)
        XCTAssertTrue(fixture.cloudflare.resolvedURLs.isEmpty)
        XCTAssertTrue(fixture.logger.events.isEmpty)
    }

    func testRepeatedCloudflareResponseRetriesOnlyOnceAndReturnsRetryResponse() async throws {
        let fixture = try makeFixture(
            steps: [
                .success(
                    StubHTTPResponse(
                        statusCode: 503,
                        headers: ["CF-Ray": "sentinel-ray"],
                        body: Data("challenge".utf8)
                    )
                ),
                .success(
                    StubHTTPResponse(
                        statusCode: 503,
                        headers: ["Server": "cloudflare"],
                        body: Data("retry-challenge".utf8)
                    )
                )
            ]
        )

        let response = try await fixture.module.fetch(request: fixture.request)

        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(response.body, [UInt8]("retry-challenge".utf8))
        XCTAssertEqual(fixture.boundary.requests.count, 2)
        XCTAssertEqual(fixture.cloudflare.resolvedURLs, [fixture.url])
        XCTAssertEqual(
            fixture.logger.events,
            [.challengeDetected, .retryStarted, .retryCompleted(status: 503)]
        )
    }

    func testChallengeResolutionErrorPropagatesWithoutRetry() async throws {
        let fixture = try makeFixture(
            steps: [
                .success(
                    StubHTTPResponse(
                        statusCode: 503,
                        headers: ["Server": "cloudflare"],
                        body: Data()
                    )
                )
            ],
            resolutionPlan: .failure(TestFailure.challengeResolution)
        )

        do {
            _ = try await fixture.module.fetch(request: fixture.request)
            XCTFail("Expected challenge resolution failure")
        } catch let error as TestFailure {
            XCTAssertEqual(error, .challengeResolution)
        }

        XCTAssertEqual(fixture.boundary.requests.count, 1)
        XCTAssertEqual(fixture.cloudflare.resolvedURLs, [fixture.url])
        XCTAssertEqual(fixture.logger.events, [.challengeDetected])
    }

    func testChallengeResolutionCancellationPropagatesWithoutRetry() async throws {
        let fixture = try makeFixture(
            steps: [
                .success(
                    StubHTTPResponse(
                        statusCode: 403,
                        headers: ["CF-Ray": "sentinel-ray"],
                        body: Data()
                    )
                )
            ],
            resolutionPlan: .failure(URLError(.cancelled))
        )

        do {
            _ = try await fixture.module.fetch(request: fixture.request)
            XCTFail("Expected cancellation")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }

        XCTAssertEqual(fixture.boundary.requests.count, 1)
        XCTAssertEqual(fixture.cloudflare.resolvedURLs, [fixture.url])
        XCTAssertEqual(fixture.logger.events, [.challengeDetected])
    }

    func testRetryTransportErrorPropagatesWithoutCompletionLog() async throws {
        let fixture = try makeFixture(
            steps: [
                .success(
                    StubHTTPResponse(
                        statusCode: 403,
                        headers: ["Server": "cloudflare"],
                        body: Data()
                    )
                ),
                .failure(URLError(.notConnectedToInternet))
            ]
        )

        do {
            _ = try await fixture.module.fetch(request: fixture.request)
            XCTFail("Expected retry transport failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }

        XCTAssertEqual(fixture.boundary.requests.count, 2)
        XCTAssertEqual(fixture.cloudflare.resolvedURLs, [fixture.url])
        XCTAssertEqual(fixture.logger.events, [.challengeDetected, .retryStarted])
    }

    func testCookiesTheSiteSetsAreSentOnLaterRequestsOfThatPluginOnly() async throws {
        let host = "cookies-\(UUID().uuidString.lowercased()).example.invalid"
        let url = try XCTUnwrap(URL(string: "https://\(host)/library"))
        let boundary = ScriptedRequestBoundary(steps: [
            .success(StubHTTPResponse(statusCode: 200, headers: ["Set-Cookie": "session=abc; Path=/"], body: Data())),
            .success(StubHTTPResponse(statusCode: 200, headers: [:], body: Data())),
            .success(StubHTTPResponse(statusCode: 200, headers: [:], body: Data()))
        ])
        ScriptedURLProtocol.register(boundary, forHost: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let jar = PluginCookieJar(keychain: InMemoryPluginSecretKeychain())
        func module(_ pluginID: String) -> AppNetModule {
            AppNetModule(
                configuration: config,
                cloudflare: StubCloudflareHandler(cachedUserAgent: "", resolution: .failure(TestFailure.challengeResolution)),
                retryLogger: RecordingRetryLogger(),
                pluginID: pluginID,
                cookieJar: jar
            )
        }
        let request = NetRequest(url: url.absoluteString, method: "GET", headers: [:], body: nil)
        let signedIn = module("plugin.a")

        _ = try await signedIn.fetch(request: request)
        _ = try await signedIn.fetch(request: request)
        _ = try await module("plugin.b").fetch(request: request)

        let cookies = boundary.requests.map { $0.value(forHTTPHeaderField: "Cookie") }
        XCTAssertEqual(cookies, [nil, "session=abc", nil])
    }

    func testThePluginsOwnCookieHeaderWinsOverItsStoredCookie() async throws {
        let host = "cookies-\(UUID().uuidString.lowercased()).example.invalid"
        let url = try XCTUnwrap(URL(string: "https://\(host)/"))
        let boundary = ScriptedRequestBoundary(steps: [
            .success(StubHTTPResponse(statusCode: 200, headers: [:], body: Data()))
        ])
        ScriptedURLProtocol.register(boundary, forHost: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        let jar = PluginCookieJar(keychain: InMemoryPluginSecretKeychain())
        try jar.store([try cookie(name: "session", value: "stored", url: url)], pluginID: "plugin.a")
        let module = AppNetModule(
            configuration: config,
            cloudflare: StubCloudflareHandler(cachedUserAgent: "", resolution: .failure(TestFailure.challengeResolution)),
            retryLogger: RecordingRetryLogger(),
            pluginID: "plugin.a",
            cookieJar: jar
        )

        _ = try await module.fetch(request: NetRequest(
            url: url.absoluteString, method: "GET", headers: ["Cookie": "session=explicit"], body: nil
        ))

        XCTAssertEqual(boundary.requests.first?.value(forHTTPHeaderField: "Cookie"), "session=explicit")
    }

    func testASessionNeverFollowsARedirectToAnotherHostAndRedirectCookiesAreKept() async throws {
        let site = "site-\(UUID().uuidString.lowercased()).example.invalid"
        let elsewhere = "cdn-\(UUID().uuidString.lowercased()).example.invalid"
        let siteURL = try XCTUnwrap(URL(string: "https://\(site)/login"))
        let boundary = ScriptedRequestBoundary(steps: [
            .success(StubHTTPResponse(
                statusCode: 302,
                headers: ["Location": "https://\(elsewhere)/asset", "Set-Cookie": "fresh=1; Path=/"],
                body: Data()
            )),
            .success(StubHTTPResponse(statusCode: 200, headers: ["Set-Cookie": "cdn=2; Path=/"], body: Data()))
        ])
        ScriptedURLProtocol.register(boundary, forHost: site)
        ScriptedURLProtocol.register(boundary, forHost: elsewhere)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let jar = PluginCookieJar(keychain: InMemoryPluginSecretKeychain())
        try jar.store([try XCTUnwrap(HTTPCookie(properties: [
            .name: "session", .value: "abc", .domain: site, .path: "/"
        ]))], pluginID: "plugin.a")
        let module = AppNetModule(
            configuration: config,
            cloudflare: StubCloudflareHandler(cachedUserAgent: "", resolution: .failure(TestFailure.challengeResolution)),
            retryLogger: RecordingRetryLogger(),
            pluginID: "plugin.a",
            cookieJar: jar
        )

        let response = try await module.fetch(request: NetRequest(
            url: siteURL.absoluteString, method: "GET", headers: ["Cookie": "explicit=1"], body: nil
        ))

        XCTAssertEqual(response.status, 200)
        let sent = boundary.requests.map { $0.value(forHTTPHeaderField: "Cookie") }
        XCTAssertEqual(sent, ["session=abc; explicit=1", nil])
        let siteCookies = jar.cookies(pluginID: "plugin.a", for: siteURL).map(\.name).sorted()
        XCTAssertEqual(siteCookies, ["fresh", "session"])
        let elsewhereCookies = jar.cookies(pluginID: "plugin.a", for: try XCTUnwrap(URL(string: "https://\(elsewhere)/"))).map(\.name)
        XCTAssertEqual(elsewhereCookies, ["cdn"])
    }

    private var sensitiveValues: [String] {
        [
            sentinelAuthorization,
            sentinelClearance,
            sentinelCookie,
            sentinelCredentials,
            sentinelQueryToken,
            sentinelSearch,
            String(describing: [
                "Authorization": sentinelAuthorization,
                "Cookie": sentinelCookie
            ])
        ]
    }

    private func makeFixture(
        steps: [Result<StubHTTPResponse, Error>],
        resolutionPlan: ResolutionPlan = .success
    ) throws -> Fixture {
        let host = "appnet-\(UUID().uuidString.lowercased()).example.invalid"
        let url = try XCTUnwrap(
            URL(
                string: "https://\(host)/search?q=\(sentinelSearch)&token=\(sentinelQueryToken)"
            )
        )
        let boundary = ScriptedRequestBoundary(steps: steps)
        ScriptedURLProtocol.register(boundary, forHost: host)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false

        let resolution: Result<AppNetCloudflareResolution, Error>
        switch resolutionPlan {
        case .success:
            resolution = .success(
                AppNetCloudflareResolution(
                    userAgent: sentinelUserAgent,
                    cookies: [
                        try cookie(
                            name: "cf_clearance",
                            value: sentinelClearance,
                            url: url
                        ),
                        try cookie(
                            name: "session",
                            value: sentinelCookie,
                            url: url
                        )
                    ]
                )
            )
        case .failure(let error):
            resolution = .failure(error)
        }

        let cloudflare = StubCloudflareHandler(
            cachedUserAgent: sentinelUserAgent,
            resolution: resolution
        )
        let logger = RecordingRetryLogger()
        let module = AppNetModule(
            configuration: config,
            cloudflare: cloudflare,
            retryLogger: logger,
            pluginID: "test.plugin",
            cookieJar: PluginCookieJar(keychain: InMemoryPluginSecretKeychain())
        )
        let request = NetRequest(
            url: url.absoluteString,
            method: "POST",
            headers: [
                "Authorization": sentinelAuthorization,
                "Cookie": "initial_session=\(sentinelCookie)",
                "X-Credentials": sentinelCredentials
            ],
            body: [UInt8]("payload=\(sentinelCredentials)".utf8)
        )

        return Fixture(
            module: module,
            boundary: boundary,
            cloudflare: cloudflare,
            logger: logger,
            request: request,
            url: url
        )
    }

    private func cookie(name: String, value: String, url: URL) throws -> HTTPCookie {
        try XCTUnwrap(
            HTTPCookie(
                properties: [
                    .domain: try XCTUnwrap(url.host),
                    .path: "/",
                    .name: name,
                    .value: value,
                    .secure: "TRUE",
                    .originURL: url
                ]
            )
        )
    }

    private func appNetModuleSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent("Ito/AppNetModule.swift"),
            encoding: .utf8
        )
    }
}

private struct Fixture {
    let module: AppNetModule
    let boundary: ScriptedRequestBoundary
    let cloudflare: StubCloudflareHandler
    let logger: RecordingRetryLogger
    let request: NetRequest
    let url: URL
}

private struct StubHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

private enum ResolutionPlan {
    case success
    case failure(Error)
}

private enum TestFailure: Error, Equatable {
    case challengeResolution
}

private final class RecordingRetryLogger: AppNetRetryLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [AppNetRetryEvent] = []

    nonisolated func log(_ event: AppNetRetryEvent) {
        lock.withLock {
            storedEvents.append(event)
        }
    }

    nonisolated var events: [AppNetRetryEvent] {
        lock.withLock { storedEvents }
    }

    nonisolated var messages: [String] {
        events.map(AppNetRetryDiagnostic.format)
    }
}

private final class StubCloudflareHandler: AppNetCloudflareHandling, @unchecked Sendable {
    private let lock = NSLock()
    private let cachedUserAgent: String
    private let resolution: Result<AppNetCloudflareResolution, Error>
    private var storedResolvedURLs: [URL] = []

    init(
        cachedUserAgent: String,
        resolution: Result<AppNetCloudflareResolution, Error>
    ) {
        self.cachedUserAgent = cachedUserAgent
        self.resolution = resolution
    }

    nonisolated func cachedUserAgent(for host: String) async -> String {
        cachedUserAgent
    }

    nonisolated func resolveChallenge(
        for url: URL
    ) async throws -> AppNetCloudflareResolution {
        lock.withLock {
            storedResolvedURLs.append(url)
        }
        return try resolution.get()
    }

    nonisolated var resolvedURLs: [URL] {
        lock.withLock { storedResolvedURLs }
    }
}

private final class ScriptedRequestBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [Result<StubHTTPResponse, Error>]
    private var storedRequests: [URLRequest] = []
    private var storedRequestBodies: [Data?] = []

    init(steps: [Result<StubHTTPResponse, Error>]) {
        self.steps = steps
    }

    nonisolated func response(for request: URLRequest) throws -> StubHTTPResponse {
        try lock.withLock {
            storedRequests.append(request)
            storedRequestBodies.append(try Self.bodyData(from: request))
            guard !steps.isEmpty else {
                throw URLError(.badServerResponse)
            }
            return try steps.removeFirst().get()
        }
    }

    nonisolated var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    nonisolated var requestBodies: [Data?] {
        lock.withLock { storedRequestBodies }
    }

    nonisolated private static func bodyData(from request: URLRequest) throws -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeContentData)
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

private class ScriptedURLProtocol: URLProtocol {
    nonisolated private static let registryLock = NSLock()
    nonisolated(unsafe) private static var boundaries: [String: ScriptedRequestBoundary] = [:]

    nonisolated static func register(
        _ boundary: ScriptedRequestBoundary,
        forHost host: String
    ) {
        registryLock.withLock {
            boundaries[host] = boundary
        }
    }

    nonisolated override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host.map(hasBoundary(forHost:)) ?? false
    }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    nonisolated override func startLoading() {
        guard
            let url = request.url,
            let host = url.host,
            let boundary = Self.boundary(forHost: host)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            let stub = try boundary.response(for: request)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            ) else {
                throw URLError(.badServerResponse)
            }
            if (300..<400).contains(stub.statusCode),
               let location = stub.headers["Location"],
               let target = URL(string: location, relativeTo: url)?.absoluteURL {
                // URLSession forwards the original headers, Cookie included, unless told otherwise.
                var next = URLRequest(url: target)
                next.allHTTPHeaderFields = request.allHTTPHeaderFields
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    nonisolated override func stopLoading() {}

    nonisolated private static func hasBoundary(forHost host: String) -> Bool {
        boundary(forHost: host) != nil
    }

    nonisolated private static func boundary(
        forHost host: String
    ) -> ScriptedRequestBoundary? {
        registryLock.withLock { boundaries[host] }
    }
}
