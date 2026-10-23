import XCTest
import ito_runner
@testable import Ito

extension MangaReaderViewModelTests {
    func testRestorationAcknowledgesCrossingInEitherDirection() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        let coordinator = MangaContinuousScrollPositionCoordinator()
        func frame(contentY: CGFloat, screenY: CGFloat) -> MangaContinuousGeometry {
            MangaContinuousGeometry(
                viewport: CGRect(x: 0, y: 0, width: 390, height: 844),
                pages: ["a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: contentY, width: 390, height: 1_400),
                    viewportFrame: CGRect(x: 0, y: screenY, width: 390, height: 1_400)
                )]
            )
        }
        _ = coordinator.update(frame(contentY: 1_000, screenY: -250), viewModel: subject.viewModel)
        XCTAssertNotNil(coordinator.update(
            frame(contentY: 900, screenY: -350), viewModel: subject.viewModel
        ))
        XCTAssertNil(coordinator.update(
            frame(contentY: 900, screenY: -200), viewModel: subject.viewModel
        ))
        XCTAssertNil(coordinator.update(
            frame(contentY: 900, screenY: -300), viewModel: subject.viewModel
        ))
    }

    func testExplicitNavigationCanAbandonAnUnresolvedRestoration() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        let coordinator = MangaContinuousScrollPositionCoordinator()
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        _ = coordinator.update(MangaContinuousGeometry(
            viewport: viewport,
            pages: ["a#0": MangaContinuousPageGeometry(
                contentFrame: CGRect(x: 0, y: 1_000, width: 390, height: 1_400),
                viewportFrame: CGRect(x: 0, y: -350, width: 390, height: 1_400)
            )]
        ), viewModel: subject.viewModel)
        XCTAssertNotNil(coordinator.update(MangaContinuousGeometry(
            viewport: viewport,
            pages: ["a#0": MangaContinuousPageGeometry(
                contentFrame: CGRect(x: 0, y: 1_100, width: 390, height: 1_400),
                viewportFrame: CGRect(x: 0, y: -250, width: 390, height: 1_400)
            )]
        ), viewModel: subject.viewModel))

        coordinator.cancelRestoration()
        XCTAssertNil(coordinator.update(MangaContinuousGeometry(
            viewport: viewport,
            pages: ["a#1": MangaContinuousPageGeometry(
                contentFrame: CGRect(x: 0, y: 2_500, width: 390, height: 1_400),
                viewportFrame: CGRect(x: 0, y: 0, width: 390, height: 1_400)
            )]
        ), viewModel: subject.viewModel))
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
    }

    func testMutationRestoreWaitsForChangedLayoutAndSurvivesMissingAnchor() async {
        let chapters = (1...5).map { makeChapter("c\($0)", number: Float($0)) }
        let subject = makeSubject(chapters: chapters, viewer: .Vertical)
        for chapter in chapters {
            subject.loader.enqueue(.pages([page(0), page(1)]), for: chapter.key)
        }
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        for count in 2...4 {
            subject.viewModel.appendNextChapter()
            await waitForReader { subject.viewModel.segments.count == count }
        }
        let coordinator = MangaContinuousScrollPositionCoordinator()
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        let pageHeight: CGFloat = 5_201.1375
        func frame(contentY: CGFloat, screenY: CGFloat) -> MangaContinuousGeometry {
            MangaContinuousGeometry(
                viewport: viewport,
                pages: ["c4#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: contentY, width: 390, height: pageHeight),
                    viewportFrame: CGRect(x: 0, y: screenY, width: 390, height: pageHeight)
                )]
            )
        }
        let before = frame(contentY: 362_072.5, screenY: -4_558.5)
        _ = coordinator.update(before, viewModel: subject.viewModel)
        subject.viewModel.appendNextChapter()
        await waitForReader { subject.viewModel.segments.last?.chapter.key == "c5" }
        guard let mutation = subject.viewModel.scrollTarget else {
            XCTFail("Front eviction must retain a restoration target")
            return
        }

        XCTAssertNil(coordinator.update(before, viewModel: subject.viewModel))
        XCTAssertFalse(coordinator.isSettled(mutation), "The stale frame is not an acknowledgement")
        let missing = coordinator.update(
            MangaContinuousGeometry(
                viewport: viewport,
                pages: ["c5#0": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 276_252, width: 390, height: 480),
                    viewportFrame: CGRect(x: 0, y: 749, width: 390, height: 480)
                )]
            ),
            viewModel: subject.viewModel
        )
        XCTAssertEqual(missing?.pageID, "c4#1")
        XCTAssertEqual(subject.viewModel.currentChapter.key, "c4")
        XCTAssertEqual(subject.viewModel.continuousChapterPage.index, 1)

        let shifted = coordinator.update(
            frame(contentY: 365_723.43125, screenY: -907.56875), viewModel: subject.viewModel
        )
        XCTAssertEqual(shifted?.alignmentY ?? 0, mutation.alignmentY, accuracy: 0.0001)
        XCTAssertNil(coordinator.update(
            frame(contentY: 270_901.524635, screenY: -4_601.808699), viewModel: subject.viewModel
        ))
        XCTAssertTrue(coordinator.isSettled(mutation))
    }

    func testEvictionReplayDoesNotRestoreAnIntermediateEstimatedPosition() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        let coordinator = MangaContinuousScrollPositionCoordinator()
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        let pageHeight: CGFloat = 5_201.1375
        let originalTop: CGFloat = -4_558.5
        let originalAlignment = MangaContinuousScrollPositionCoordinator.alignmentY(
            viewportTop: originalTop, pageHeight: pageHeight, viewportHeight: viewport.height
        )
        func frame(contentY: CGFloat, screenY: CGFloat) -> MangaContinuousGeometry {
            MangaContinuousGeometry(
                viewport: viewport,
                pages: ["a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: contentY, width: 390, height: pageHeight),
                    viewportFrame: CGRect(x: 0, y: screenY, width: 390, height: pageHeight)
                )]
            )
        }

        // Recorded live at the second front eviction, in preference-delivery order.
        XCTAssertNil(coordinator.update(
            frame(contentY: 362_072.5, screenY: originalTop), viewModel: subject.viewModel
        ))
        let firstCorrection = coordinator.update(
            frame(contentY: 365_723.43125, screenY: -907.56875), viewModel: subject.viewModel
        )
        XCTAssertEqual(firstCorrection?.alignmentY ?? 0, originalAlignment, accuracy: 0.0001)
        let missingAnchor = coordinator.update(
            MangaContinuousGeometry(
                viewport: viewport,
                pages: ["a#0": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 276_252.328801, width: 390, height: 480),
                    viewportFrame: CGRect(x: 0, y: 748.995468, width: 390, height: 480)
                )]
            ),
            viewModel: subject.viewModel
        )
        XCTAssertEqual(missingAnchor?.pageID, "a#1")
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
        _ = coordinator.update(
            frame(contentY: 274_595.764583, screenY: -907.56875), viewModel: subject.viewModel
        )
        let finalCorrection = coordinator.update(
            frame(contentY: 270_901.524635, screenY: -4_601.808699), viewModel: subject.viewModel
        )

        // Crossing the requested point acknowledges the reader's remaining forward momentum.
        // Do not issue even a small reverse correction after that acknowledgement.
        XCTAssertNil(finalCorrection)
        XCTAssertNil(coordinator.update(
            frame(contentY: 270_901.524635, screenY: originalTop), viewModel: subject.viewModel
        ))
        XCTAssertNil(coordinator.update(
            frame(contentY: 270_901.524635, screenY: originalTop - 100), viewModel: subject.viewModel
        ))
    }
}
