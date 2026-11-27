import CoreGraphics
import XCTest
@testable import Ito

@MainActor
final class MediaDetailLayoutTests: XCTestCase {
    func testWideWidthClassGetsTwoColumnsWithAClampedLeadingColumn() {
        // The unfolded Duo held sideways is the target case; the leading column grows with the window within its bounds.
        guard case .twoColumns(let duoWidth) = MediaDetailLayout.make(widthClass: .wide, width: 951) else {
            return XCTFail("The wide width class should use two columns")
        }
        XCTAssertEqual(duoWidth, 361.38, accuracy: 0.001)

        XCTAssertEqual(
            MediaDetailLayout.make(widthClass: .wide, width: 700),
            .twoColumns(leadingWidth: 340)
        )
        XCTAssertEqual(
            MediaDetailLayout.make(widthClass: .wide, width: 1100),
            .twoColumns(leadingWidth: 380)
        )
    }

    func testNonWideWidthClassesKeepTheSingleColumn() {
        XCTAssertEqual(MediaDetailLayout.make(widthClass: .regular, width: 669), .singleColumn)
        XCTAssertEqual(MediaDetailLayout.make(widthClass: .compact, width: 466), .singleColumn)
        XCTAssertEqual(MediaDetailLayout.make(widthClass: .compact, width: 932), .singleColumn)
    }
}
