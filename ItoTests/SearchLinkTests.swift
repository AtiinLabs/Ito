import Testing
@testable import Ito

struct SearchLinkTests {
    @Test func onlyWebAddressesAreLinks() {
        #expect(SearchLink(query: "  https://mangafire.to/title/abc  ")?.url == "https://mangafire.to/title/abc")
        #expect(SearchLink(query: "HTTP://Example.org/x") != nil)
        for query in [
            "One Piece", "mangafire.to/title/abc", "ftp://mangafire.to/a", "ito://repo/add",
            "https://", "https://mangafire.to/a b", "https://mangafire.to/a https://b.to"
        ] {
            #expect(SearchLink(query: query) == nil, "\(query)")
        }
    }

    @Test func aLinkBelongsToItsSiteAndSubdomainsOnly() throws {
        let site = "https://mangafire.to"
        for query in [
            "https://mangafire.to/title/abc", "https://www.mangafire.to/title/abc",
            "https://MangaFire.TO./title/abc", "http://m.mangafire.to/title/abc",
            "https://mangafire.to:8443/title/abc"
        ] {
            #expect(try #require(SearchLink(query: query)).belongs(toSite: site), "\(query)")
        }
        for query in [
            "https://notmangafire.to/title/abc", "https://mangafire.to.evil.example/title/abc",
            "https://evil.example/https://mangafire.to/title/abc", "https://user@evil.example/mangafire.to"
        ] {
            #expect(try !#require(SearchLink(query: query)).belongs(toSite: site), "\(query)")
        }
    }

    @Test func aSourceWithoutAUsableWebsiteOwnsNoLinks() throws {
        let link = try #require(SearchLink(query: "https://mangafire.to/title/abc"))
        #expect(!link.belongs(toSite: nil))
        #expect(!link.belongs(toSite: ""))
        #expect(!link.belongs(toSite: "mangafire.to"))
        #expect(link.belongs(toSite: "https://www.mangafire.to/"))
    }
}
