import CoreGraphics
import XCTest
@testable import Ito

@MainActor
final class WidthClassTests: XCTestCase {
    func testUnfoldedDuoAndFoldedDuoSpaces() {
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 466, height: 678), verticallyRegular: true), .compact)
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 669, height: 951), verticallyRegular: true), .regular)
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 951, height: 669), verticallyRegular: true), .wide)
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 880, height: 625), verticallyRegular: true), .wide)
    }

    func testPhoneSpacesAreCompact() {
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 393, height: 852), verticallyRegular: false), .compact)
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 852, height: 393), verticallyRegular: false), .compact)
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 932, height: 430), verticallyRegular: false), .compact)
    }

    func testIPadSpaces() {
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 820, height: 1180), verticallyRegular: true), .regular)
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 1180, height: 820), verticallyRegular: true), .wide)
    }

    func testWidthThresholdsAreExact() {
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 599, height: 800), verticallyRegular: true), .compact)
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 600, height: 800), verticallyRegular: true), .regular)
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 699, height: 500), verticallyRegular: true), .regular)
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 700, height: 500), verticallyRegular: true), .wide)
        // A square space at the wide width is not landscape, so it is regular.
        XCTAssertEqual(WidthClass.make(size: CGSize(width: 800, height: 800), verticallyRegular: true), .regular)
    }

    func testSpacingPerWidthClass() {
        XCTAssertEqual(
            WidthClass.compact.spacing,
            LayoutSpacing(margin: 16, gridSpacing: 12, gridRowSpacing: 14)
        )
        XCTAssertEqual(
            WidthClass.regular.spacing,
            LayoutSpacing(margin: 20, gridSpacing: 14, gridRowSpacing: 16)
        )
        XCTAssertEqual(
            WidthClass.wide.spacing,
            LayoutSpacing(margin: 24, gridSpacing: 16, gridRowSpacing: 18)
        )
    }
}
