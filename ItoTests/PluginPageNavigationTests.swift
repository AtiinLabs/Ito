import Foundation
import Testing
@testable import Ito

struct PluginPageNavigationTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    @Test func aNavigationWithinThePluginsSiteIsAllowed() throws {
        let page = try url("https://comix.to/title/1")
        #expect(!PluginPageNavigation.refuses(target: try url("https://comix.to/title/2"), isMainFrame: true, pageURL: page))
        #expect(!PluginPageNavigation.refuses(target: try url("https://www.comix.to/title/2"), isMainFrame: true, pageURL: page))
        // A challenge redirect that stays on the site keeps the verification going.
        #expect(!PluginPageNavigation.refuses(
            target: try url("https://comix.to/title/1?__cf_chl_tk=token"), isMainFrame: true, pageURL: page))
    }

    @Test func aMainFrameNavigationToAnotherSiteIsRefused() throws {
        let page = try url("https://templetoons.com/series/1")
        #expect(PluginPageNavigation.refuses(target: try url("https://top-webtoons.org/"), isMainFrame: true, pageURL: page))
        #expect(PluginPageNavigation.refuses(target: try url("https://comix.to/"), isMainFrame: true, pageURL: try url("https://comix.com/")))
    }

    @Test func subframesAreNeverRefused() throws {
        let page = try url("https://comix.to/title/1")
        #expect(!PluginPageNavigation.refuses(
            target: try url("https://challenges.cloudflare.com/cdn-cgi/challenge-platform"), isMainFrame: false, pageURL: page))
    }

    @Test func localAndNonWebTargetsAreNotRefused() throws {
        let page = try url("https://comix.to/title/1")
        for target in ["about:blank", "data:text/html,hi", "blob:https://ads.example/1"] {
            #expect(!PluginPageNavigation.refuses(target: try url(target), isMainFrame: true, pageURL: page), "\(target)")
        }
    }

    @Test func withoutAPageNothingIsRefused() throws {
        #expect(!PluginPageNavigation.refuses(target: try url("https://top-webtoons.org/"), isMainFrame: true, pageURL: nil))
    }

    @Test func siteKeysAreRegistrableDomains() {
        #expect(PluginPageNavigation.siteKey(for: "www.example.com") == "example.com")
        #expect(PluginPageNavigation.siteKey(for: "WWW.Example.COM") == "example.com")
        #expect(PluginPageNavigation.siteKey(for: "example.com") == "example.com")
        #expect(PluginPageNavigation.siteKey(for: "a.example.co.uk") == "example.co.uk")
        #expect(PluginPageNavigation.siteKey(for: "example.co.uk") == "example.co.uk")
        #expect(PluginPageNavigation.siteKey(for: "localhost") == "localhost")
        #expect(PluginPageNavigation.siteKey(for: "192.168.0.1") == "192.168.0.1")
    }
}
