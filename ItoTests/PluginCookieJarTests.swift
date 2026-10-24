import Foundation
import Security
import Testing
@testable import Ito

struct PluginCookieJarTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cookie(
        _ name: String,
        _ value: String = "v",
        domain: String = ".example.com",
        path: String = "/",
        expires: Date? = nil,
        secure: Bool = false
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires { properties[.expires] = expires }
        if secure { properties[.secure] = "TRUE" }
        return try #require(HTTPCookie(properties: properties))
    }

    private func jar(_ keychain: InMemoryPluginSecretKeychain = InMemoryPluginSecretKeychain()) -> PluginCookieJar {
        PluginCookieJar(keychain: keychain, now: { Self.now })
    }

    private func names(_ cookies: [HTTPCookie]) -> Set<String> { Set(cookies.map(\.name)) }

    @Test func aCookieGoesToItsSiteAndSubdomainsOnly() throws {
        let jar = jar()
        try jar.store([try cookie("session")], pluginID: "a")

        #expect(names(jar.cookies(pluginID: "a", for: try #require(URL(string: "https://example.com/x")))) == ["session"])
        #expect(names(jar.cookies(pluginID: "a", for: try #require(URL(string: "https://a.example.com/x")))) == ["session"])
        #expect(jar.cookies(pluginID: "a", for: try #require(URL(string: "https://notexample.com/"))).isEmpty)
        #expect(jar.cookies(pluginID: "a", for: try #require(URL(string: "https://example.com.evil.test/"))).isEmpty)
    }

    @Test func aHostOnlyCookieGoesToItsExactHostOnly() throws {
        let jar = jar()
        try jar.store([try cookie("hostOnly", domain: "example.com")], pluginID: "a")

        #expect(names(jar.cookies(pluginID: "a", for: try #require(URL(string: "https://example.com/")))) == ["hostOnly"])
        #expect(jar.cookies(pluginID: "a", for: try #require(URL(string: "https://cdn.example.com/"))).isEmpty)
    }

    @Test func pathAndSecureRulesApply() throws {
        let jar = jar()
        try jar.store([
            try cookie("scoped", path: "/account"),
            try cookie("secure", secure: true)
        ], pluginID: "a")

        #expect(names(jar.cookies(pluginID: "a", for: try #require(URL(string: "https://example.com/account/me")))) == ["scoped", "secure"])
        #expect(names(jar.cookies(pluginID: "a", for: try #require(URL(string: "https://example.com/accounts")))) == ["secure"])
        #expect(jar.cookies(pluginID: "a", for: try #require(URL(string: "http://example.com/"))).isEmpty)
    }

    @Test func aNewValueReplacesTheOldAndAnExpiredCookieRemovesIt() throws {
        let jar = jar()
        let url = try #require(URL(string: "https://example.com/"))
        try jar.store([try cookie("session", "old")], pluginID: "a")
        try jar.store([try cookie("session", "new")], pluginID: "a")
        #expect(jar.cookies(pluginID: "a", for: url).map(\.value) == ["new"])

        try jar.store([try cookie("session", "gone", expires: Self.now.addingTimeInterval(-60))], pluginID: "a")
        #expect(jar.cookies(pluginID: "a", for: url).isEmpty)
    }

    @Test func pluginsNeverSeeEachOthersCookies() throws {
        let jar = jar()
        let url = try #require(URL(string: "https://example.com/"))
        try jar.store([try cookie("a-session")], pluginID: "a")

        #expect(jar.cookies(pluginID: "b", for: url).isEmpty)
    }

    @Test func cookiesSurviveANewJarAndRemovalEmptiesIt() throws {
        let keychain = InMemoryPluginSecretKeychain()
        let url = try #require(URL(string: "https://example.com/"))
        try jar(keychain).store([try cookie("session")], pluginID: "a")
        try jar(keychain).store([try cookie("session")], pluginID: "b")

        let reopened = jar(keychain)
        #expect(names(reopened.cookies(pluginID: "a", for: url)) == ["session"])

        try reopened.removeAll(pluginID: "a")
        #expect(reopened.cookies(pluginID: "a", for: url).isEmpty)
        #expect(names(reopened.cookies(pluginID: "b", for: url)) == ["session"])

        try reopened.removeEveryPlugin()
        #expect(reopened.cookies(pluginID: "b", for: url).isEmpty)
        #expect(keychain.storedAccounts.isEmpty)
    }

    @Test func aKeychainFailureIsReportedAndALockedKeychainReadsAsEmpty() throws {
        let keychain = InMemoryPluginSecretKeychain()
        let url = try #require(URL(string: "https://example.com/"))
        keychain.failingStatus = errSecInteractionNotAllowed

        #expect(throws: PluginSecretStoreError(status: errSecInteractionNotAllowed)) {
            try jar(keychain).store([try cookie("session")], pluginID: "a")
        }
        #expect(jar(keychain).cookies(pluginID: "a", for: url).isEmpty)
    }
}

struct PluginSignInTargetTests {
    @Test func onlyWebSitesCanBeSignedIn() {
        #expect(PluginSignInTarget(pluginID: "p", pluginName: "P", siteURL: "https://example.com") != nil)
        for site in [nil, "", "example.com", "ftp://example.com", "https://"] as [String?] {
            #expect(PluginSignInTarget(pluginID: "p", pluginName: "P", siteURL: site) == nil)
        }
    }

    @Test func theSignInKeepsOnlyTheSitesCookies() throws {
        let target = try #require(PluginSignInTarget(pluginID: "p", pluginName: "P", siteURL: "https://www.example.com/"))
        for domain in ["example.com", ".example.com", "www.example.com", "login.example.com"] {
            #expect(target.owns(cookieDomain: domain), "\(domain)")
        }
        for domain in ["tracker.test", "notexample.com", ".com", "example.com.evil.test"] {
            #expect(!target.owns(cookieDomain: domain), "\(domain)")
        }
    }
}
