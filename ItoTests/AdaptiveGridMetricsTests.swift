import XCTest
@testable import Ito

final class AdaptiveGridMetricsTests: XCTestCase {
    private let spacing: CGFloat = 12

    func testFoldedDuoGetsThreeOrFourColumns() {
        let count = AdaptiveGridMetrics.columnCount(forWidth: 466, spacing: spacing)
        XCTAssertTrue((3...4).contains(count), "folded Duo gave \(count) columns")
    }

    func testUnfoldedPortraitGetsFiveColumns() {
        XCTAssertEqual(AdaptiveGridMetrics.columnCount(forWidth: 669, spacing: spacing), 5)
    }

    func testUnfoldedLandscapeGetsSixOrSevenColumns() {
        let count = AdaptiveGridMetrics.columnCount(forWidth: 951, spacing: spacing)
        XCTAssertTrue((6...7).contains(count), "unfolded landscape gave \(count) columns")
    }

    func testWiderThanUnfoldedLandscapeGetsMoreColumns() {
        let landscape = AdaptiveGridMetrics.columnCount(forWidth: 951, spacing: spacing)
        let wide = AdaptiveGridMetrics.columnCount(forWidth: 1180, spacing: spacing)
        XCTAssertGreaterThan(wide, landscape)
    }

    func testPhoneWidthGetsThreeColumns() {
        XCTAssertEqual(AdaptiveGridMetrics.columnCount(forWidth: 393, spacing: spacing), 3)
    }

    func testCellsStayWithinRangeWhenACountFits() {
        for width in stride(from: CGFloat(100), through: 1400, by: 7) where !(160..<224).contains(width) {
            let count = AdaptiveGridMetrics.columnCount(forWidth: width, spacing: spacing)
            let cell = AdaptiveGridMetrics.cellWidth(forWidth: width, columns: count, spacing: spacing)
            XCTAssertTrue(
                (AdaptiveGridMetrics.minimumCellWidth...AdaptiveGridMetrics.maximumCellWidth).contains(cell),
                "width \(width) gave cell \(cell) with \(count) columns"
            )
        }
    }

    func testGapBetweenCountsKeepsCellsAtOrAboveMinimum() {
        for width in stride(from: CGFloat(161), through: 211, by: 5) {
            let count = AdaptiveGridMetrics.columnCount(forWidth: width, spacing: spacing)
            let cell = AdaptiveGridMetrics.cellWidth(forWidth: width, columns: count, spacing: spacing)
            XCTAssertEqual(count, 1, "width \(width)")
            XCTAssertGreaterThanOrEqual(cell, AdaptiveGridMetrics.minimumCellWidth, "width \(width)")
        }
    }

    func testColumnsFillTheWidth() {
        let columns = AdaptiveGridMetrics.columns(forWidth: 637, spacing: spacing)
        XCTAssertEqual(columns.count, 5)
    }

    func testNarrowWidthGetsOneColumn() {
        XCTAssertEqual(AdaptiveGridMetrics.columnCount(forWidth: 170, spacing: spacing), 1)
    }

    func testNonPositiveWidthGetsOneColumn() {
        XCTAssertEqual(AdaptiveGridMetrics.columnCount(forWidth: 0, spacing: spacing), 1)
        XCTAssertEqual(AdaptiveGridMetrics.columnCount(forWidth: -40, spacing: spacing), 1)
    }
}
