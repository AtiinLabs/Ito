import Testing
@testable import Ito

@MainActor
struct DiscoverHomeLayoutTests {
    @Test func heroKeepsOnlyItemsWithBannersInOrder() {
        let trending = [
            layoutMedia(1, banner: nil),
            layoutMedia(2, banner: "https://img.example/2.jpg"),
            layoutMedia(3, banner: ""),
            layoutMedia(4, banner: "https://img.example/4.jpg")
        ]

        #expect(DiscoverHeroSelection.items(from: trending).map(\.id) == [2, 4])
    }

    @Test func heroStopsAtItsLimit() {
        let trending = (1...8).map { layoutMedia($0, banner: "https://img.example/\($0).jpg") }

        #expect(DiscoverHeroSelection.items(from: trending).map(\.id) == [1, 2, 3, 4, 5])
    }

    @Test func heroIsEmptyWithoutBanners() {
        let trending = [layoutMedia(1, banner: nil), layoutMedia(2, banner: "")]

        #expect(DiscoverHeroSelection.items(from: trending).isEmpty)
    }

    @Test func shelvesSkipEmptyOnesAndShowSeasonalOnlyForAnime() {
        let content = DiscoverHomeContent(
            trending: [layoutMedia(1, banner: nil)],
            seasonal: [layoutMedia(2, banner: nil)],
            popular: [],
            topRated: [layoutMedia(3, banner: nil)]
        )

        #expect(
            DiscoverShelfLayout.shelves(for: content, mediaType: .anime).map(\.kind)
                == [.trending, .seasonal, .topRated]
        )
        #expect(
            DiscoverShelfLayout.shelves(for: content, mediaType: .manga).map(\.kind)
                == [.trending, .topRated]
        )
    }

    @Test func onlyWideShareRows() {
        #expect(DiscoverShelfLayout.columns(for: .compact) == 1)
        #expect(DiscoverShelfLayout.columns(for: .regular) == 1)
        #expect(DiscoverShelfLayout.columns(for: .wide) == 2)
    }

    @Test func pairsShelvesTwoPerRowWithAShorterLastRow() {
        #expect(DiscoverShelfLayout.rows([1, 2, 3, 4, 5], columns: 2) == [[1, 2], [3, 4], [5]])
        #expect(DiscoverShelfLayout.rows([1, 2, 3, 4], columns: 2) == [[1, 2], [3, 4]])
    }

    @Test func oneShelfPerRowKeepsOrder() {
        #expect(DiscoverShelfLayout.rows([1, 2, 3], columns: 1) == [[1], [2], [3]])
    }

    @Test func noShelvesMeansNoRows() {
        #expect(DiscoverShelfLayout.rows([Int](), columns: 2).isEmpty)
    }

    private func layoutMedia(_ id: Int, banner: String?) -> DiscoverMedia {
        DiscoverMedia(
            id: id,
            title: "Media \(id)",
            titleEnglish: nil,
            titleRomaji: nil,
            titleNative: nil,
            synonyms: [],
            coverImage: nil,
            bannerImage: banner,
            format: nil,
            status: nil,
            description: nil,
            cleanDescription: nil,
            genres: nil,
            averageScore: nil,
            episodes: nil,
            chapters: nil,
            season: nil,
            seasonYear: nil,
            type: "ANIME",
            recommendations: nil
        )
    }
}
