import Foundation
import Testing
import WebKit
import ito_runner
@testable import Ito

/// Records the User-Agent of every request it answers, per host, and answers 200.
private final class UserAgentRecordingProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var agents: [String: [String?]] = [:]

    static func agents(for host: String) -> [String?] {
        lock.withLock { agents[host] ?? [] }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let agent = request.value(forHTTPHeaderField: "User-Agent")
        Self.lock.withLock { Self.agents[host, default: []].append(agent) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite("Site verification user agent")
struct SiteVerificationUserAgentTests {
    private let challengeURL = URL(string: "https://fixture.invalid/")!

    private func fixture() -> (ManualNetworkPathObserver, PluginNetworkContexts, NetworkRequestAuthority) {
        let path = ManualNetworkPathObserver(initial: .init(status: .satisfied))
        let policy = NetworkPolicyCenter(path: path)
        policy.enterForeground()
        let contexts = PluginNetworkContexts(epochs: ["fixture": String(repeating: "a", count: 32)], policy: policy)
        let context = contexts.context(pluginID: "fixture", PluginNetworkOperation(purpose: .foregroundReading, operationID: UUID()))
        return (path, contexts, NetworkRequestAuthority(contexts: contexts, context: context))
    }

    private func clearance() throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [.domain: "fixture.invalid", .path: "/", .name: "cf_clearance", .value: "token"]))
    }

    private func makeChallenge(
        userAgent: WebKitUserAgent,
        authority: NetworkRequestAuthority,
        results: AsyncStream<Result<AppNetCloudflareResolution, Error>>.Continuation
    ) -> CloudflareChallenge {
        CloudflareChallenge(
            url: challengeURL, authority: authority, websites: SourceWebsiteContexts(), userAgent: userAgent,
            presentsPage: false, loadPage: { _, _ in }, completion: { results.yield($0) }
        )
    }

    // MARK: Cloudflare clearance

    @Test func aClearanceCarriesTheProbedWebKitUserAgent() async throws {
        let (path, contexts, authority) = fixture()
        let results = AsyncStream<Result<AppNetCloudflareResolution, Error>>.makeStream()
        let challenge = makeChallenge(userAgent: .testing("Agent/7"), authority: authority, results: results.continuation)
        challenge.start()
        let page = try #require(challenge.webView)

        challenge.resolve(cookies: [try clearance()], in: page)
        var iterator = results.stream.makeAsyncIterator()
        let resolution = try #require(await iterator.next()).get()

        #expect(resolution.userAgent == "Agent/7")
        #expect(resolution.cookies.map(\.name) == ["cf_clearance"])
        withExtendedLifetime((path, contexts)) {}
    }

    @Test func aClearanceWithoutAUserAgentFailsAsUnavailable() async throws {
        let (path, contexts, authority) = fixture()
        let results = AsyncStream<Result<AppNetCloudflareResolution, Error>>.makeStream()
        let challenge = makeChallenge(userAgent: .testing(nil), authority: authority, results: results.continuation)
        challenge.start()
        let page = try #require(challenge.webView)

        challenge.resolve(cookies: [try clearance()], in: page)
        var iterator = results.stream.makeAsyncIterator()
        let result = try #require(await iterator.next())

        #expect(throws: WebKitUserAgentError.unavailable) { try result.get() }
        withExtendedLifetime((path, contexts)) {}
    }

    @Test func aUserAgentThatArrivesAfterTheChallengeEndedPublishesNothing() async throws {
        let (path, contexts, authority) = fixture()
        let probe = HeldUserAgentProbe()
        let userAgent = WebKitUserAgent(probe: { await probe.run() })
        var outcomes: [Result<AppNetCloudflareResolution, Error>] = []
        let challenge = CloudflareChallenge(
            url: challengeURL, authority: authority, websites: SourceWebsiteContexts(), userAgent: userAgent,
            presentsPage: false, loadPage: { _, _ in }, completion: { outcomes.append($0) }
        )
        challenge.start()
        let page = try #require(challenge.webView)

        challenge.resolve(cookies: [try clearance()], in: page)
        await probe.waitUntilStarted()
        // The user closes the challenge while its user agent is still being read.
        challenge.finish(.failure(CancellationError()))
        probe.release("Agent/late")
        #expect(try await userAgent.value() == "Agent/late")

        #expect(outcomes.count == 1)
        #expect(throws: CancellationError.self) { try outcomes.first?.get() }
        #expect(challenge.webView == nil)
        withExtendedLifetime((path, contexts)) {}
    }

    // MARK: Plugin HTTP

    private func fetchAgent(host: String, pluginHeaders: [String: String], webKit: String?) async throws -> (sent: [String?], reported: String?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserAgentRecordingProtocol.self]
        let manager = CloudflareManager(websites: SourceWebsiteContexts(), userAgent: .testing(webKit))
        let module = AppNetModule(
            configuration: configuration,
            cloudflare: LiveAppNetCloudflareHandler(manager: manager),
            retryLogger: OSLogAppNetRetryLogger(),
            pluginID: "plugin.ua",
            cookieJar: PluginCookieJar(keychain: InMemoryPluginSecretKeychain())
        )
        let response = try await module.fetch(
            request: NetRequest(url: "https://\(host)/page", method: "GET", headers: pluginHeaders, body: nil),
            context: makeTestNetworkContext()
        )
        return (UserAgentRecordingProtocol.agents(for: host), response.headers["X-Used-User-Agent"])
    }

    @Test func theWebKitUserAgentReplacesThePluginsWhateverItsCase() async throws {
        for (index, name) in ["User-Agent", "user-agent", "USER-AGENT"].enumerated() {
            let host = "ua-replace-\(index).test"
            let result = try await fetchAgent(host: host, pluginHeaders: [name: "Plugin/9"], webKit: "WebKit/1")
            #expect(result.sent == ["WebKit/1"], "\(name)")
            #expect(result.reported == "WebKit/1", "\(name)")
        }
    }

    @Test func thePluginsUserAgentIsKeptWhenWebKitReportsNone() async throws {
        let result = try await fetchAgent(host: "ua-keep.test", pluginHeaders: ["User-Agent": "Plugin/9"], webKit: nil)

        #expect(result.sent == ["Plugin/9"])
        #expect(result.reported == "Plugin/9")
    }
}
