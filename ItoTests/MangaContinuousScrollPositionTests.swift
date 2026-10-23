import XCTest
@testable import Ito

@MainActor
final class MangaContinuousScrollPositionTests: XCTestCase {
    func testAlignmentPreservesTopPositionForTallPage() {
        XCTAssertEqual(
            MangaContinuousScrollPositionCoordinator.alignmentY(
                viewportTop: -350,
                pageHeight: 1_500,
                viewportHeight: 800
            ),
            0.5,
            accuracy: 0.001
        )
    }

    func testAlignmentPreservesTopPositionForShortPage() {
        XCTAssertEqual(
            MangaContinuousScrollPositionCoordinator.alignmentY(
                viewportTop: 100,
                pageHeight: 600,
                viewportHeight: 800
            ),
            0.5,
            accuracy: 0.001
        )
    }

    func testAlignmentFallsBackToTopWhenPageAndViewportHaveEqualHeight() {
        XCTAssertEqual(
            MangaContinuousScrollPositionCoordinator.alignmentY(
                viewportTop: 0,
                pageHeight: 800,
                viewportHeight: 800
            ),
            0
        )
    }

    func testRestoreTargetIsNotSettledWhileAnEarlierPageStillLeadsTheViewport() {
        let target = MangaScrollRequest(pageID: "a#1", animated: false)
        let geometry = MangaContinuousGeometry(
            viewport: CGRect(x: 0, y: 0, width: 390, height: 844),
            pages: [
                "a#0": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 0, width: 390, height: 500),
                    viewportFrame: CGRect(x: 0, y: 0, width: 390, height: 500)
                ),
                "a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 500, width: 390, height: 500),
                    viewportFrame: CGRect(x: 0, y: 500, width: 390, height: 500)
                )
            ]
        )

        XCTAssertFalse(
            MangaContinuousScrollPositionCoordinator.isSettled(target, in: geometry)
        )
    }

    func testRestoreTargetSettlesWhenItsTopIsAligned() {
        let target = MangaScrollRequest(pageID: "a#1", animated: false)
        let geometry = MangaContinuousGeometry(
            viewport: CGRect(x: 0, y: 0, width: 390, height: 844),
            pages: [
                "a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 500, width: 390, height: 1_400),
                    viewportFrame: CGRect(x: 0, y: 0, width: 390, height: 1_400)
                )
            ]
        )

        XCTAssertTrue(
            MangaContinuousScrollPositionCoordinator.isSettled(target, in: geometry)
        )
    }

    func testLastShortPageSettlesAtBottomWithPreviousPageStillVisible() {
        let target = MangaScrollRequest(pageID: "a#2", animated: false)
        let geometry = MangaContinuousGeometry(
            viewport: CGRect(x: 0, y: 0, width: 390, height: 844),
            contentBounds: CGRect(x: 0, y: -1_000, width: 390, height: 1_844),
            pages: [
                "a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 500, width: 390, height: 500),
                    viewportFrame: CGRect(x: 0, y: -256, width: 390, height: 500)
                ),
                "a#2": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 1_000, width: 390, height: 600),
                    viewportFrame: CGRect(x: 0, y: 244, width: 390, height: 600)
                )
            ]
        )

        XCTAssertTrue(
            MangaContinuousScrollPositionCoordinator.isSettled(target, in: geometry)
        )
    }
    func testShortContentSettlesAnyVisiblePageWithoutScrollTravel() {
        let target = MangaScrollRequest(pageID: "a#1", animated: false)
        let geometry = MangaContinuousGeometry(
            viewport: CGRect(x: 0, y: 0, width: 390, height: 844),
            contentBounds: CGRect(x: 0, y: 0, width: 390, height: 600),
            pages: [
                "a#0": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 0, width: 390, height: 300),
                    viewportFrame: CGRect(x: 0, y: 0, width: 390, height: 300)
                ),
                "a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 300, width: 390, height: 300),
                    viewportFrame: CGRect(x: 0, y: 300, width: 390, height: 300)
                )
            ]
        )

        XCTAssertTrue(MangaContinuousScrollPositionCoordinator.isSettled(target, in: geometry))
    }

    func testPenultimateShortPageSettlesAtTheBottomBoundary() {
        let target = MangaScrollRequest(pageID: "a#1", animated: false)
        let geometry = MangaContinuousGeometry(
            viewport: CGRect(x: 0, y: 0, width: 390, height: 844),
            contentBounds: CGRect(x: 0, y: -1_356, width: 390, height: 2_200),
            pages: [
                "a#0": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 0, width: 390, height: 2_000),
                    viewportFrame: CGRect(x: 0, y: -1_356, width: 390, height: 2_000)
                ),
                "a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 2_000, width: 390, height: 100),
                    viewportFrame: CGRect(x: 0, y: 644, width: 390, height: 100)
                ),
                "a#2": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 2_100, width: 390, height: 100),
                    viewportFrame: CGRect(x: 0, y: 744, width: 390, height: 100)
                )
            ]
        )

        XCTAssertTrue(MangaContinuousScrollPositionCoordinator.isSettled(target, in: geometry))
    }

    func testBottomBoundaryDoesNotSettleTargetThatCanStillMoveDown() {
        let target = MangaScrollRequest(pageID: "a#1", animated: false)
        let geometry = MangaContinuousGeometry(
            viewport: CGRect(x: 0, y: 0, width: 390, height: 844),
            contentBounds: CGRect(x: 0, y: -1_000, width: 390, height: 1_844),
            pages: [
                "a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 900, width: 390, height: 600),
                    viewportFrame: CGRect(x: 0, y: -100, width: 390, height: 600)
                )
            ]
        )

        XCTAssertFalse(MangaContinuousScrollPositionCoordinator.isSettled(target, in: geometry))
    }
}
