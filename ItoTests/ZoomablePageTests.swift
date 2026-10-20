import SwiftUI
import XCTest
@testable import Ito

final class ZoomablePageTests: XCTestCase {
    private typealias Page = ZoomablePage<EmptyView>

    func testZoomedPageMovesOnlyAsFarAsItOverhangs() {
        let size = CGSize(width: 300, height: 400)

        // At 2x the page overhangs by half its size on each axis.
        XCTAssertEqual(
            Page.clamped(CGSize(width: 1000, height: -1000), scale: 2, in: size),
            CGSize(width: 150, height: -200)
        )
        XCTAssertEqual(
            Page.clamped(CGSize(width: -40, height: 90), scale: 2, in: size),
            CGSize(width: -40, height: 90)
        )
    }

    func testUnzoomedPageCannotMove() {
        XCTAssertEqual(
            Page.clamped(
                CGSize(width: 25, height: -25),
                scale: 1,
                in: CGSize(width: 300, height: 400)
            ),
            .zero
        )
    }
}
