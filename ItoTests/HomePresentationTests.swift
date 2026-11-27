import CoreGraphics
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class HomePresentationTests: XCTestCase {
    func testBigScrollerIsAShelfAndNeverBecomesTheCarousel() {
        let layout = HomeLayout(components: [
            HomeComponent(title: "Featured", value: .bigScroller([manga("b1"), manga("b2")], 8))
        ])

        let presentation = HomePresentation.make(layout)

        XCTAssertNil(presentation.featured)
        XCTAssertEqual(presentation.shelves.map(\.id), [0])
        guard case .bigScroller(let entries, _)? = presentation.shelves.first?.component.value else {
            return XCTFail("Expected the BigScroller to stay a shelf")
        }
        XCTAssertEqual(entries.map(\.key), ["b1", "b2"])
    }

    func testScrollersAndListsNeverBecomeTheCarousel() {
        let layout = HomeLayout(components: [
            HomeComponent(title: "Latest", value: .scroller([manga("a"), manga("b"), manga("c")], nil)),
            HomeComponent(title: "Anime", value: .animeList(false, nil, (1...7).map { anime("n\($0)") }, nil))
        ])

        let presentation = HomePresentation.make(layout)

        XCTAssertNil(presentation.featured)
        XCTAssertEqual(presentation.shelves.map(\.id), [0, 1])
    }

    func testIntervalIsHonoredOnlyWhenFiniteAndBetweenTwoAndSixtySeconds() {
        XCTAssertEqual(FeaturedSection.autoAdvance(from: 8), 8)
        XCTAssertEqual(FeaturedSection.autoAdvance(from: 2), 2)
        XCTAssertEqual(FeaturedSection.autoAdvance(from: 60), 60)
        XCTAssertEqual(FeaturedSection.autoAdvance(from: nil), FeaturedSection.defaultAutoAdvance)
        XCTAssertEqual(FeaturedSection.autoAdvance(from: 1), FeaturedSection.defaultAutoAdvance)
        XCTAssertEqual(FeaturedSection.autoAdvance(from: 61), FeaturedSection.defaultAutoAdvance)
        XCTAssertEqual(FeaturedSection.autoAdvance(from: .nan), FeaturedSection.defaultAutoAdvance)
        XCTAssertEqual(FeaturedSection.autoAdvance(from: .infinity), FeaturedSection.defaultAutoAdvance)
    }

    func testEmptyHomeHasNoHeroAndNoShelves() {
        let presentation = HomePresentation.make(HomeLayout(components: []))

        XCTAssertNil(presentation.featured)
        XCTAssertTrue(presentation.shelves.isEmpty)
    }

    func testFiltersOnlyHomeHasNoHeroButKeepsItsShelf() {
        let layout = HomeLayout(components: [
            HomeComponent(title: "Filters", value: .filters([]))
        ])

        let presentation = HomePresentation.make(layout)

        XCTAssertNil(presentation.featured)
        XCTAssertEqual(presentation.shelves.map(\.id), [0])
    }

    func testCardMetadataComesFromTheEntry() {
        let card = FeaturedCard(item: FeaturedItem(entry: .manga(Manga(key: "m", title: "Title", description: "Summary", tags: ["Action"]))))

        XCTAssertEqual(card.title, "Title")
        XCTAssertEqual(card.summary, "Summary")
        XCTAssertEqual(card.genres, ["Action"])
        XCTAssertNil(card.unitCount)
        XCTAssertEqual(card.id, MediaEntryIdentity(kind: .manga, key: "m"))
    }

    func testLayoutModeIsWideOnlyForLandscapeSpaceInARegularHeightWindowAndTheSideBySidePreference() {
        // The unfolded Duo held sideways: the home itself is shorter than the window (bars above it), still wide.
        XCTAssertEqual(
            HomeLayoutMode.make(size: CGSize(width: 951, height: 520), verticallyRegular: true, preference: .sideBySide),
            .sideBySide
        )
        XCTAssertEqual(
            HomeLayoutMode.make(size: CGSize(width: 951, height: 520), verticallyRegular: true, preference: .stacked),
            .narrow
        )
        // Unfolded portrait, folded, and a phone held sideways (compact height) stay narrow.
        XCTAssertEqual(
            HomeLayoutMode.make(size: CGSize(width: 669, height: 800), verticallyRegular: true, preference: .sideBySide),
            .narrow
        )
        XCTAssertEqual(
            HomeLayoutMode.make(size: CGSize(width: 466, height: 600), verticallyRegular: true, preference: .sideBySide),
            .narrow
        )
        XCTAssertEqual(
            HomeLayoutMode.make(size: CGSize(width: 932, height: 330), verticallyRegular: false, preference: .sideBySide),
            .narrow
        )
        XCTAssertEqual(
            HomeLayoutMode.make(size: CGSize(width: 699, height: 500), verticallyRegular: true, preference: .sideBySide),
            .narrow
        )
    }

    func testPosterWidthScalesWithTheSpaceAndStaysWithinBounds() {
        XCTAssertEqual(HomeLayoutMetrics.posterWidth(forWidth: 390), 110)
        XCTAssertEqual(HomeLayoutMetrics.posterWidth(forWidth: 669), 669 * 0.22, accuracy: 0.001)
        XCTAssertEqual(HomeLayoutMetrics.posterWidth(forWidth: 2000), 160)
    }

    func testHeroColumnAndNarrowHeroAreClamped() {
        XCTAssertEqual(HomeLayoutMetrics.heroColumnWidth(forWidth: 600), 300)
        XCTAssertEqual(HomeLayoutMetrics.heroColumnWidth(forWidth: 951), 951 * 0.42, accuracy: 0.001)
        XCTAssertEqual(HomeLayoutMetrics.heroColumnWidth(forWidth: 2000), 400)
        XCTAssertEqual(HomeLayoutMetrics.narrowHeroHeight(forViewportHeight: 844), 520)
        XCTAssertEqual(HomeLayoutMetrics.narrowHeroHeight(forViewportHeight: 400), 248, accuracy: 0.001)
    }

    func testNativeFeaturedLeadsAndTheBigScrollerBesideItStaysAShelf() {
        let listing = Listing(id: "latest", name: "Latest", kind: 0)
        let layout = HomeLayout(components: [
            HomeComponent(title: "Featured", value: .bigScroller([manga("b1"), manga("b2")], nil)),
            HomeComponent(title: "Home", value: .featured(FeaturedComponent(
                items: [FeaturedItem(entry: .manga(Manga(key: "n1", title: "n1")))],
                autoAdvance: 10,
                listing: listing
            )))
        ])

        let presentation = HomePresentation.make(layout)

        XCTAssertEqual(presentation.featured?.items.map(\.title), ["n1"])
        XCTAssertEqual(presentation.featured?.autoAdvance, 10)
        XCTAssertEqual(presentation.featured?.listing?.id, "latest")
        XCTAssertEqual(presentation.featured?.listing?.name, "Latest")
        XCTAssertEqual(presentation.shelves.map(\.id), [0])
    }

    func testLaterNativeFeaturedStaysInlineAsBannersWithItsItems() {
        let layout = HomeLayout(components: [
            HomeComponent(title: "Home", value: .featured(FeaturedComponent(
                items: [FeaturedItem(entry: .manga(Manga(key: "a", title: "a")))]
            ))),
            HomeComponent(title: "Later", value: .featured(FeaturedComponent(
                items: [
                    FeaturedItem(entry: .manga(Manga(key: "b", title: "b"))),
                    FeaturedItem(entry: .anime(Anime(key: "c", title: "c")))
                ]
            )))
        ])

        let presentation = HomePresentation.make(layout)

        XCTAssertEqual(presentation.featured?.items.map(\.title), ["a"])
        XCTAssertEqual(presentation.shelves.map(\.id), [1])
        XCTAssertEqual(presentation.shelves.first?.banners.map(\.title), ["b", "c"])
    }

    func testNativeFeaturedWithoutItemsDoesNotLeadTheHome() {
        let layout = HomeLayout(components: [
            HomeComponent(title: "Empty", value: .featured(FeaturedComponent(items: []))),
            HomeComponent(title: "Shelf", value: .scroller([manga("a"), manga("b"), manga("c")], nil))
        ])

        let presentation = HomePresentation.make(layout)

        XCTAssertNil(presentation.featured)
        XCTAssertEqual(presentation.shelves.map(\.id), [0, 1])
    }

    func testBadgeKindsMapToTheirOwnDisplayAndUnknownKindsKeepOnlyPluginText() {
        XCTAssertEqual(FeaturedBadgeDisplay(FeaturedBadge(kind: 1)), .new)
        XCTAssertEqual(FeaturedBadgeDisplay(FeaturedBadge(kind: 2, rank: 5)), .trending(rank: 5))
        XCTAssertEqual(FeaturedBadgeDisplay(FeaturedBadge(kind: 2, rank: 1000)), .trending(rank: nil))
        XCTAssertEqual(FeaturedBadgeDisplay(FeaturedBadge(kind: 2)), .trending(rank: nil))
        XCTAssertEqual(FeaturedBadgeDisplay(FeaturedBadge(kind: 3)), .popular)
        XCTAssertEqual(FeaturedBadgeDisplay(FeaturedBadge(kind: 4)), .updated)
        XCTAssertEqual(FeaturedBadgeDisplay(FeaturedBadge(kind: 0, label: "Limited")), .custom("Limited"))
        XCTAssertNil(FeaturedBadgeDisplay(FeaturedBadge(kind: 0)))
        XCTAssertEqual(FeaturedBadgeDisplay(FeaturedBadge(kind: 9, label: "Later kind")), .custom("Later kind"))
        XCTAssertNil(FeaturedBadgeDisplay(FeaturedBadge(kind: 9)))
    }

    func testChipKindsMapToTypedDisplayAndDegradeToTheirTextWhenTheNumberIsUnusable() {
        XCTAssertEqual(FeaturedChipDisplay(FeaturedChip(kind: 1, number: 2024)), .year(2024))
        XCTAssertEqual(FeaturedChipDisplay(FeaturedChip(kind: 1, number: 2024.5, text: "2024")), .text("2024"))
        XCTAssertNil(FeaturedChipDisplay(FeaturedChip(kind: 1, number: 2024.5)))
        XCTAssertEqual(FeaturedChipDisplay(FeaturedChip(kind: 2, number: 8.5)), .rating(8.5))
        XCTAssertEqual(FeaturedChipDisplay(FeaturedChip(kind: 2, number: 11, text: "11/10")), .text("11/10"))
        XCTAssertEqual(FeaturedChipDisplay(FeaturedChip(kind: 3, number: 12)), .units(12))
        XCTAssertEqual(FeaturedChipDisplay(FeaturedChip(kind: 4, text: "Action")), .genre("Action"))
        XCTAssertEqual(FeaturedChipDisplay(FeaturedChip(kind: 5, text: "TV")), .format("TV"))
        XCTAssertEqual(FeaturedChipDisplay(FeaturedChip(kind: 0, text: "Plain")), .text("Plain"))
        XCTAssertEqual(FeaturedChipDisplay(FeaturedChip(kind: 99, text: "Future")), .text("Future"))
        XCTAssertNil(FeaturedChipDisplay(FeaturedChip(kind: 99)))
        XCTAssertNil(FeaturedChipDisplay(FeaturedChip(kind: 4, text: "  ")))
    }

    func testActionOneStartsAndEveryOtherValueIsDetails() {
        XCTAssertEqual(FeaturedAction(native: 1), .start)
        XCTAssertEqual(FeaturedAction(native: 0), .details)
        XCTAssertEqual(FeaturedAction(native: 7), .details)
    }

    func testAccentIsKeptOnlyWhenWhiteTextReadsOnIt() {
        func card(accent: UInt32) -> FeaturedCard {
            FeaturedCard(item: FeaturedItem(entry: .manga(Manga(key: "a", title: "a")), accent: accent))
        }

        XCTAssertEqual(card(accent: 0x1565C0).accent, 0x1565C0)
        XCTAssertNil(card(accent: 0x1E88E5).accent)
        XCTAssertNil(card(accent: 0xFFFFFF).accent)
        XCTAssertNil(card(accent: 0x1000000).accent)
    }

    func testBackdropPrefersTheBannerThenTheCover() {
        let withBanner = FeaturedCard(item: FeaturedItem(
            entry: .manga(Manga(key: "a", title: "a", cover: "https://example.com/cover.jpg")),
            banner: "https://example.com/banner.jpg"
        ))
        let coverOnly = FeaturedCard(item: FeaturedItem(
            entry: .manga(Manga(key: "b", title: "b", cover: "https://example.com/cover.jpg"))
        ))
        let neither = FeaturedCard(item: FeaturedItem(entry: .manga(Manga(key: "c", title: "c"))))

        XCTAssertEqual(withBanner.backdrop?.absoluteString, "https://example.com/banner.jpg")
        XCTAssertEqual(coverOnly.backdrop?.absoluteString, "https://example.com/cover.jpg")
        XCTAssertNil(neither.backdrop)
    }

    private func manga(_ key: String) -> Manga {
        Manga(key: key, title: key)
    }

    private func anime(_ key: String) -> Anime {
        Anime(key: key, title: key)
    }
}
