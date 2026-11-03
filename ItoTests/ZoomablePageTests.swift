import UIKit
import XCTest
@testable import Ito

@MainActor
final class ZoomablePageTests: XCTestCase {
    private typealias Page = ReaderPageZoom

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

    func testDoubleTapKeepsTheVisiblePointFixedAcrossATallPanel() {
        let size = CGSize(width: 390, height: 6_000)
        let scale = Page.doubleTapScale
        // These points are visible after scrolling to the top, middle, and end of the panel.
        for point in [CGPoint(x: 80, y: 180), CGPoint(x: 300, y: 3_200), CGPoint(x: 120, y: 5_800)] {
            let offset = Page.zoomOffset(around: point, scale: scale, in: size)
            let projected = CGPoint(
                x: size.width / 2 + (point.x - size.width / 2) * scale + offset.width,
                y: size.height / 2 + (point.y - size.height / 2) * scale + offset.height
            )
            XCTAssertEqual(projected.x, point.x, accuracy: 0.001)
            XCTAssertEqual(projected.y, point.y, accuracy: 0.001)
        }
    }

    func testTapAtPageEdgesUsesTheFullOverhangWithoutExposingEmptySpace() {
        let size = CGSize(width: 300, height: 400)
        XCTAssertEqual(
            Page.zoomOffset(around: .zero, scale: 2.5, in: size),
            CGSize(width: 225, height: 300)
        )
        XCTAssertEqual(
            Page.zoomOffset(around: CGPoint(x: 300, y: 400), scale: 2.5, in: size),
            CGSize(width: -225, height: -300)
        )
    }

    func testPinchAfterPanKeepsTheSourcePointUnderTheMovingCentroid() {
        let size = CGSize(width: 390, height: 6_000)
        var initial = Page().doubleTapped(at: CGPoint(x: 120, y: 180), in: size)
        initial.offset.width -= 40
        initial.offset.height -= 300
        let start = CGPoint(x: 210, y: 280)
        let end = CGPoint(x: 230, y: 320)
        let sourcePoint = CGPoint(
            x: size.width / 2 + (start.x - size.width / 2 - initial.offset.width) / initial.scale,
            y: size.height / 2 + (start.y - size.height / 2 - initial.offset.height) / initial.scale
        )
        let result = initial.pinched(from: start, to: end, magnification: 1.4, in: size)
        XCTAssertEqual(
            size.width / 2 + (sourcePoint.x - size.width / 2) * result.scale + result.offset.width,
            end.x, accuracy: 0.001
        )
        XCTAssertEqual(
            size.height / 2 + (sourcePoint.y - size.height / 2) * result.scale + result.offset.height,
            end.y, accuracy: 0.001
        )
    }

    func testPinchUsesTheClampedScaleForItsFocusAndResetsAtMinimumScale() {
        let size = CGSize(width: 390, height: 6_000)
        let initial = Page(scale: 2.5, offset: CGSize(width: 0, height: 2_000))
        let point = CGPoint(x: 195, y: 3_200)
        let sourceY = size.height / 2 + (point.y - size.height / 2 - initial.offset.height) / initial.scale
        let maximum = initial.pinched(from: point, to: point, magnification: 10, in: size)
        XCTAssertEqual(maximum.scale, 4)
        XCTAssertEqual(
            size.height / 2 + (sourceY - size.height / 2) * maximum.scale + maximum.offset.height,
            point.y, accuracy: 0.001
        )
        XCTAssertEqual(initial.pinched(from: point, to: point, magnification: 0.01, in: size), Page())
    }

    func testDoubleTapOutClearsThePannedTransform() {
        let size = CGSize(width: 390, height: 6_000)
        let initial = Page(scale: 3, offset: CGSize(width: 90, height: -2_000))
        XCTAssertEqual(initial.doubleTapped(at: CGPoint(x: 100, y: 5_800), in: size), Page())
    }

    func testParentPanRemainsSuspendedUntilEveryPageReleasesIt() {
        let parent = UIPanGestureRecognizer()
        parent.isEnabled = true
        let first = ReaderParentPanSuspension([parent])
        let second = ReaderParentPanSuspension([parent])
        first.release()
        XCTAssertFalse(parent.isEnabled)
        second.release()
        XCTAssertTrue(parent.isEnabled)
        second.release()
        XCTAssertTrue(parent.isEnabled)
    }

    func testParentPanThatWasAlreadyDisabledIsNotEnabledOnRelease() {
        let parent = UIPanGestureRecognizer()
        parent.isEnabled = false
        let suspension = ReaderParentPanSuspension([parent])
        suspension.release()
        XCTAssertFalse(parent.isEnabled)
    }
}
