import CoreGraphics
import XCTest
@testable import Ito

final class ReaderZoomGeometryTests: XCTestCase {
    func testZoomRectanglePreservesTheTappedPointAtDifferentDocumentDepths() {
        let viewport = CGSize(width: 390, height: 844)
        let finger = CGPoint(x: 120, y: 280)
        let scale: CGFloat = 2.5
        for contentPoint in [CGPoint(x: 120, y: 280), CGPoint(x: 180, y: 3_200), CGPoint(x: 240, y: 8_600)] {
            let rect = ReaderZoomGeometry.targetRect(
                contentPoint: contentPoint, viewportPoint: finger, viewportSize: viewport, scale: scale
            )
            XCTAssertEqual((contentPoint.x - rect.minX) * scale, finger.x, accuracy: 0.001)
            XCTAssertEqual((contentPoint.y - rect.minY) * scale, finger.y, accuracy: 0.001)
            XCTAssertEqual(rect.width * scale, viewport.width, accuracy: 0.001)
            XCTAssertEqual(rect.height * scale, viewport.height, accuracy: 0.001)
        }
    }

    func testZoomedViewportMapsBothHorizontalPanAndVerticalScrollIntoDocumentCoordinates() {
        let rect = ReaderZoomGeometry.documentViewport(
            contentOffset: CGPoint(x: 260, y: 4_500),
            viewportSize: CGSize(width: 390, height: 844),
            scale: 2
        )
        XCTAssertEqual(rect, CGRect(x: 130, y: 2_250, width: 195, height: 422))
        let pageAbove = CGRect(x: 0, y: 1_200, width: 390, height: 1_000)
        let visiblePage = CGRect(x: 0, y: 2_200, width: 390, height: 1_000)
        XCTAssertFalse(rect.intersects(pageAbove))
        XCTAssertTrue(rect.intersects(visiblePage))
    }
}
