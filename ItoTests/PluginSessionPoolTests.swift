import Foundation
import Testing
@testable import Ito

@Suite("Plugin session pool")
struct PluginSessionPoolTests {
    private let url = URL(string: "https://example.invalid/")!

    @Test func sourcesNeverShareAConnectionPool() async {
        let pool = PluginSessionPool(configuration: .ephemeral, trust: PluginTrustStore(keychain: InMemoryPluginSecretKeychain()))
        let first = await pool.withSession(for: "a") { $0 }
        let again = await pool.withSession(for: "a") { $0 }
        let other = await pool.withSession(for: "b") { $0 }

        #expect(first === again)
        #expect(first !== other)
    }

    @Test func everyTrustChangeStartsANewPool() async throws {
        let trust = PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        let pool = PluginSessionPool(configuration: .ephemeral, trust: trust)
        var seen: [URLSession] = [await pool.withSession(for: "a") { $0 }]

        try trust.trust(fingerprint: "AA", host: "example.com", pluginID: "a")
        seen.append(await pool.withSession(for: "a") { $0 })
        try trust.removeAll(pluginID: "a")
        seen.append(await pool.withSession(for: "a") { $0 })
        try trust.removeEveryPlugin()
        seen.append(await pool.withSession(for: "a") { $0 })

        #expect(Set(seen.map(ObjectIdentifier.init)).count == seen.count)
    }

    /// A caller holding a session when trust changes still completes its request on it: a
    /// session is invalidated only after its last holder is done.
    @Test func aRetiredSessionStaysUsableWhileHeld() async throws {
        let trust = PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PoolOKProtocol.self]
        let pool = PluginSessionPool(configuration: configuration, trust: trust)

        let status = try await pool.withSession(for: "a") { held in
            try trust.trust(fingerprint: "AA", host: "example.com", pluginID: "a")
            let replacement = await pool.withSession(for: "a") { $0 }
            #expect(replacement !== held)

            let (_, response) = try await held.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode
        }
        #expect(status == 200)
    }
}

private final class PoolOKProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
