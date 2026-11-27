import CoreGraphics
import XCTest
@testable import Ito

@MainActor
final class MediaDetailLayoutTests: XCTestCase {
    func testWideLandscapeRegularHeightWindowGetsTwoColumnsWithAClampedLeadingColumn() {
        // The unfolded Duo held sideways is the target case; the leading column grows with the window within its bounds.
        guard case .twoColumns(let duoWidth) = MediaDetailLayout.make(
            size: CGSize(width: 951, height: 520),
            verticallyRegular: true
        ) else {
            return XCTFail("A wide landscape space should use two columns")
        }
        XCTAssertEqual(duoWidth, 361.38, accuracy: 0.001)

        XCTAssertEqual(
            MediaDetailLayout.make(size: CGSize(width: 700, height: 500), verticallyRegular: true),
            .twoColumns(leadingWidth: 340)
        )
        XCTAssertEqual(
            MediaDetailLayout.make(size: CGSize(width: 1100, height: 834), verticallyRegular: true),
            .twoColumns(leadingWidth: 380)
        )
    }

    func testNarrowOrPortraitOrCompactHeightSpacesKeepTheSingleColumn() {
        // Unfolded portrait, folded, a phone held sideways, and a wide but compact-height window keep the page as it was.
        XCTAssertEqual(
            MediaDetailLayout.make(size: CGSize(width: 669, height: 800), verticallyRegular: true),
            .singleColumn
        )
        XCTAssertEqual(
            MediaDetailLayout.make(size: CGSize(width: 466, height: 600), verticallyRegular: true),
            .singleColumn
        )
        XCTAssertEqual(
            MediaDetailLayout.make(size: CGSize(width: 932, height: 330), verticallyRegular: false),
            .singleColumn
        )
        XCTAssertEqual(
            MediaDetailLayout.make(size: CGSize(width: 699, height: 500), verticallyRegular: true),
            .singleColumn
        )
        // A space at the threshold width that is not landscape stays one column.
        XCTAssertEqual(
            MediaDetailLayout.make(size: CGSize(width: 800, height: 800), verticallyRegular: true),
            .singleColumn
        )
    }
}
