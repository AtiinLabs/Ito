import CoreGraphics
import XCTest
@testable import Ito

final class NovelReaderLayoutTests: XCTestCase {
    func testReadableWidthScalesWithFontAndStaysWithinBounds() {
        XCTAssertEqual(NovelReaderLayout.readableTextWidth(fontSize: 10), 600)
        XCTAssertEqual(NovelReaderLayout.readableTextWidth(fontSize: 18), 612)
        XCTAssertEqual(NovelReaderLayout.readableTextWidth(fontSize: 20), 680)
        XCTAssertEqual(NovelReaderLayout.readableTextWidth(fontSize: 40), 680)
    }

    func testPhoneWidthsKeepFullWidthText() {
        // Portrait phones: the text fills the window minus the page inset, as it did before the cap.
        for width: CGFloat in [320, 375, 390, 430] {
            XCTAssertEqual(
                NovelReaderLayout.pageTextWidth(availableWidth: width, fontSize: 18, spread: false),
                width - 32
            )
        }
    }

    func testSingleColumnCapsAtReadableWidth() {
        XCTAssertEqual(
            NovelReaderLayout.pageTextWidth(availableWidth: 820, fontSize: 18, spread: false),
            612
        )
        XCTAssertEqual(
            NovelReaderLayout.pageTextWidth(availableWidth: 1194, fontSize: 40, spread: false),
            680
        )
    }

    func testSpreadSplitsContentWidthInsideMargins() {
        // Unfolded Duo landscape with a trailing inset of 80: 951 - 80 = 871 available.
        // (871 - 2 * 44 - 32) / 2 = 375.5 per page, below the 612 point cap at 18 pt.
        let width = NovelReaderLayout.pageTextWidth(availableWidth: 871, fontSize: 18, spread: true)
        XCTAssertEqual(width, 375.5)
        // The two pages and the gutter fill the available width less the spread margins on each side.
        XCTAssertEqual(2 * width + NovelReaderLayout.spreadGutter, 871 - 2 * NovelReaderLayout.spreadMargin)
        // Unfolded Duo landscape with no insets: (951 - 88 - 32) / 2 = 415.5 per page.
        XCTAssertEqual(
            NovelReaderLayout.pageTextWidth(availableWidth: 951, fontSize: 18, spread: true),
            415.5
        )
    }

    func testSpreadColumnWidthIsCappedAtReadableWidth() {
        // iPad landscape at 18 pt: (1180 - 88 - 32) / 2 = 530, below the cap.
        XCTAssertEqual(
            NovelReaderLayout.pageTextWidth(availableWidth: 1180, fontSize: 18, spread: true),
            530
        )
        // A very wide window is capped at the readable width: (2600 - 120) / 2 = 1240, capped at 612.
        XCTAssertEqual(
            NovelReaderLayout.pageTextWidth(availableWidth: 2600, fontSize: 18, spread: true),
            612
        )
    }

    func testTextWidthNeverNegative() {
        XCTAssertEqual(NovelReaderLayout.pageTextWidth(availableWidth: 0, fontSize: 18, spread: true), 0)
        XCTAssertEqual(NovelReaderLayout.pageTextWidth(availableWidth: 20, fontSize: 18, spread: false), 0)
    }

    func testSpreadOnlyInTheWideWidthClass() {
        XCTAssertTrue(NovelReaderLayout.showsSpread(widthClass: .wide))
        XCTAssertFalse(NovelReaderLayout.showsSpread(widthClass: .regular))
        XCTAssertFalse(NovelReaderLayout.showsSpread(widthClass: .compact))
    }

    func testSpreadsPairPagesInOrder() {
        let ranges = NovelReaderLayout.spreads(count: 5, spread: true) { _ in true }
        XCTAssertEqual(ranges, [0..<2, 2..<4, 4..<5])
    }

    func testSpreadsWithoutSpreadLayoutAreSinglePages() {
        let ranges = NovelReaderLayout.spreads(count: 3, spread: false) { _ in true }
        XCTAssertEqual(ranges, [0..<1, 1..<2, 2..<3])
    }

    func testSpreadsBreakWhereCanShareIsFalse() {
        // Page 0 cannot share with page 1, so it stands alone; the pairing restarts at page 1.
        let ranges = NovelReaderLayout.spreads(count: 4, spread: true) { $0 != 0 }
        XCTAssertEqual(ranges, [0..<1, 1..<3, 3..<4])
    }

    func testSpreadsOfEmptyPagesIsEmpty() {
        XCTAssertEqual(NovelReaderLayout.spreads(count: 0, spread: true) { _ in true }, [])
    }

    func testSpreadIndexFindsContainingRange() {
        let ranges = [0..<2, 2..<3, 3..<5]
        XCTAssertEqual(NovelReaderLayout.spreadIndex(containing: 1, in: ranges), 0)
        XCTAssertEqual(NovelReaderLayout.spreadIndex(containing: 2, in: ranges), 1)
        XCTAssertEqual(NovelReaderLayout.spreadIndex(containing: 4, in: ranges), 2)
        XCTAssertNil(NovelReaderLayout.spreadIndex(containing: 5, in: ranges))
    }
}
