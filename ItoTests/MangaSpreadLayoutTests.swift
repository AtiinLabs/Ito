import CoreGraphics
import XCTest
@testable import Ito

final class MangaSpreadLayoutTests: XCTestCase {
    func testWithoutPairingEveryPageStandsAlone() {
        let spreads = MangaSpreadLayout.spreads(count: 3, paired: false) { _ in nil }

        XCTAssertEqual(spreads, [0..<1, 1..<2, 2..<3])
    }

    func testNarrowPagesPairAfterTheChapterOpeningPage() {
        let spreads = MangaSpreadLayout.spreads(count: 5, paired: true) { _ in nil }

        XCTAssertEqual(spreads, [0..<1, 1..<3, 3..<5])
    }

    func testAWideFirstPageStandsAloneAndPairingResumesAfterIt() {
        let spreads = MangaSpreadLayout.spreads(count: 5, paired: true) { index in
            index == 2 ? 1.5 : nil
        }

        XCTAssertEqual(spreads, [0..<1, 1..<2, 2..<3, 3..<5])
    }

    func testAPageNextToAWidePageStandsAlone() {
        let spreads = MangaSpreadLayout.spreads(count: 5, paired: true) { index in
            index == 3 ? 2.0 : nil
        }

        XCTAssertEqual(spreads, [0..<1, 1..<3, 3..<4, 4..<5])
    }

    func testAnEmptyOrSinglePageChapter() {
        XCTAssertEqual(MangaSpreadLayout.spreads(count: 0, paired: true) { _ in nil }, [])
        XCTAssertEqual(MangaSpreadLayout.spreads(count: 1, paired: true) { _ in nil }, [0..<1])
    }

    func testAnUnknownAspectUsesTheFallback() {
        XCTAssertEqual(MangaSpreadLayout.aspect(nil), MangaSpreadLayout.fallbackAspect)
        XCTAssertEqual(MangaSpreadLayout.aspect(1.2), 1.2)
    }

    func testOnlyAspectsWiderThanTallAreWide() {
        XCTAssertFalse(MangaSpreadLayout.isWide(nil))
        XCTAssertFalse(MangaSpreadLayout.isWide(1))
        XCTAssertTrue(MangaSpreadLayout.isWide(1.01))
        XCTAssertFalse(MangaSpreadLayout.isWide(0.7))
    }

    func testAPairFitsTheWidthWhenTheWidthIsTheLimit() {
        let fitted = MangaSpreadLayout.fit(aspects: [0.5, 0.5], in: CGSize(width: 1000, height: 800))

        XCTAssertEqual(fitted.height, 800, accuracy: 0.001)
        XCTAssertEqual(fitted.widths.count, 2)
        XCTAssertEqual(fitted.widths[0], 400, accuracy: 0.001)
        XCTAssertEqual(fitted.widths[1], 400, accuracy: 0.001)
    }

    func testAPairFitsTheHeightWhenTheHeightIsTheLimit() {
        let fitted = MangaSpreadLayout.fit(aspects: [0.5, 0.5], in: CGSize(width: 400, height: 1000))

        XCTAssertEqual(fitted.height, 400, accuracy: 0.001)
        XCTAssertEqual(fitted.widths[0], 200, accuracy: 0.001)
        XCTAssertEqual(fitted.widths[1], 200, accuracy: 0.001)
    }

    func testAnEmptySpaceOrNoPagesFitsNothing() {
        let zeroWidth = MangaSpreadLayout.fit(aspects: [0.7], in: CGSize(width: 0, height: 100))
        XCTAssertEqual(zeroWidth.height, 0)
        XCTAssertEqual(zeroWidth.widths, [0])

        let noPages = MangaSpreadLayout.fit(aspects: [], in: CGSize(width: 100, height: 100))
        XCTAssertEqual(noPages.height, 0)
        XCTAssertEqual(noPages.widths, [])
    }

    func testARightToLeftSpreadPutsTheLaterPageOnTheLeft() {
        XCTAssertEqual(MangaSpreadLayout.order(12..<14, isRightToLeft: true), [13, 12])
    }

    func testALeftToRightSpreadPutsTheEarlierPageOnTheLeft() {
        XCTAssertEqual(MangaSpreadLayout.order(12..<14, isRightToLeft: false), [12, 13])
    }

    func testASinglePageIsOrderedTheSameInEitherDirection() {
        XCTAssertEqual(MangaSpreadLayout.order(4..<5, isRightToLeft: true), [4])
        XCTAssertEqual(MangaSpreadLayout.order(4..<5, isRightToLeft: false), [4])
    }

    func testAPairLimitedByHeightIsCenteredInTheSpace() {
        let frames = MangaSpreadLayout.frames(aspects: [0.5, 0.5], in: CGSize(width: 1000, height: 800))

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].minX, 100, accuracy: 0.001)
        XCTAssertEqual(frames[0].width, 400, accuracy: 0.001)
        XCTAssertEqual(frames[1].minX, 500, accuracy: 0.001)
        XCTAssertEqual(frames[1].maxX, 900, accuracy: 0.001)
        XCTAssertEqual(frames[0].minY, 0, accuracy: 0.001)
        XCTAssertEqual(frames[0].height, 800, accuracy: 0.001)
    }

    func testAPairLimitedByWidthIsCenteredVertically() {
        let frames = MangaSpreadLayout.frames(aspects: [0.5, 0.5], in: CGSize(width: 400, height: 1000))

        XCTAssertEqual(frames[0].minX, 0, accuracy: 0.001)
        XCTAssertEqual(frames[1].minX, 200, accuracy: 0.001)
        XCTAssertEqual(frames[0].minY, 300, accuracy: 0.001)
        XCTAssertEqual(frames[0].height, 400, accuracy: 0.001)
    }

    func testASpreadInTheSpaceLeftByATrailingInsetIsCenteredInIt() {
        let size = CGSize(width: 951 - 85, height: 669)
        let frames = MangaSpreadLayout.frames(aspects: [0.584, 0.584], in: size)
        XCTAssertEqual(frames[0].height, 669, accuracy: 0.001)
        XCTAssertEqual(frames[0].minX, 42.304, accuracy: 0.001)
        XCTAssertEqual(frames[1].minX, 433.0, accuracy: 0.001)
        XCTAssertEqual(frames[1].maxX, 823.696, accuracy: 0.001)
    }
}
