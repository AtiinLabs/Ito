import XCTest
import ito_runner
@testable import Ito

extension MangaReaderViewModelTests {
    func testContinuousCurrentPageIsTheTopmostVisiblePage() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1), page(2)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        let pages = subject.viewModel.flatPages

        // The first visible image remains current while another page enters below it.
        subject.viewModel.continuousViewportChanged([pages[0].id])
        subject.viewModel.continuousViewportChanged([pages[0].id, pages[1].id])
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 0)

        subject.viewModel.continuousViewportChanged([pages[1].id])
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
        XCTAssertEqual(subject.viewModel.continuousChapterPage.index, 1)
        XCTAssertEqual(subject.viewModel.continuousChapterPage.count, 3)
        await waitForReader { subject.progress.savedPages["a"] == 1 }

        // The last page shows without reaching the top: the chapter still counts as finished.
        subject.viewModel.continuousViewportChanged([pages[1].id, pages[2].id])
        await waitForReader { subject.progress.requests.map(\.chapterID) == ["a"] }
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
    }

    func testContinuousLayoutDriftPreservesVisiblePageViewportPosition() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        let coordinator = MangaContinuousScrollPositionCoordinator()
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        let previous = MangaContinuousGeometry(
            viewport: viewport,
            pages: [
                "a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 1_000, width: 390, height: 1_400),
                    viewportFrame: CGRect(x: 0, y: -350, width: 390, height: 1_400)
                )
            ]
        )
        XCTAssertNil(coordinator.update(previous, viewModel: subject.viewModel))

        let shifted = MangaContinuousGeometry(
            viewport: viewport,
            pages: [
                "a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 1_100, width: 390, height: 1_400),
                    viewportFrame: CGRect(x: 0, y: -250, width: 390, height: 1_400)
                )
            ]
        )
        let target = coordinator.update(shifted, viewModel: subject.viewModel)

        assertScrollRequest(
            target,
            pageID: "a#1",
            alignmentY: MangaContinuousScrollPositionCoordinator.alignmentY(
                viewportTop: -350,
                pageHeight: 1_400,
                viewportHeight: 844
            )
        )
    }

    func testNativeAnchoringDoesNotTriggerASecondScrollCorrection() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        let coordinator = MangaContinuousScrollPositionCoordinator()
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        let frame = CGRect(x: 0, y: -700, width: 390, height: 1_400)
        _ = coordinator.update(
            MangaContinuousGeometry(
                viewport: viewport,
                pages: ["a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 1_000, width: 390, height: 1_400),
                    viewportFrame: frame
                )]
            ),
            viewModel: subject.viewModel
        )

        let correction = coordinator.update(
            MangaContinuousGeometry(
                viewport: viewport,
                pages: ["a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 1_100, width: 390, height: 1_400),
                    viewportFrame: frame
                )]
            ),
            viewModel: subject.viewModel
        )

        XCTAssertNil(correction, "Native anchoring already preserved the viewport")
    }

    func testContinuousViewportScrollWithoutContentDriftDoesNotRequestCorrection() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        let coordinator = MangaContinuousScrollPositionCoordinator()
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        XCTAssertNil(
            coordinator.update(
                MangaContinuousGeometry(
                    viewport: viewport,
                    pages: [
                        "a#1": MangaContinuousPageGeometry(
                            contentFrame: CGRect(x: 0, y: 1_000, width: 390, height: 1_400),
                            viewportFrame: CGRect(x: 0, y: -350, width: 390, height: 1_400)
                        )
                    ]
                ),
                viewModel: subject.viewModel
            )
        )

        XCTAssertNil(
            coordinator.update(
                MangaContinuousGeometry(
                    viewport: viewport,
                    pages: [
                        "a#1": MangaContinuousPageGeometry(
                            contentFrame: CGRect(x: 0, y: 1_000, width: 390, height: 1_400),
                            viewportFrame: CGRect(x: 0, y: -450, width: 390, height: 1_400)
                        )
                    ]
                ),
                viewModel: subject.viewModel
            )
        )
    }
    func testLayoutDriftDoesNotPersistTheUncorrectedVisiblePage() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        let coordinator = MangaContinuousScrollPositionCoordinator()
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        _ = coordinator.update(
            MangaContinuousGeometry(
                viewport: viewport,
                pages: [
                    "a#0": MangaContinuousPageGeometry(
                        contentFrame: CGRect(x: 0, y: 0, width: 390, height: 1_200),
                        viewportFrame: CGRect(x: 0, y: -300, width: 390, height: 1_200)
                    ),
                    "a#1": MangaContinuousPageGeometry(
                        contentFrame: CGRect(x: 0, y: 1_200, width: 390, height: 600),
                        viewportFrame: CGRect(x: 0, y: 900, width: 390, height: 600)
                    )
                ]
            ),
            viewModel: subject.viewModel
        )

        let correction = coordinator.update(
            MangaContinuousGeometry(
                viewport: viewport,
                pages: [
                    "a#0": MangaContinuousPageGeometry(
                        contentFrame: CGRect(x: 0, y: -1_400, width: 390, height: 1_200),
                        viewportFrame: CGRect(x: 0, y: -1_700, width: 390, height: 1_200)
                    ),
                    "a#1": MangaContinuousPageGeometry(
                        contentFrame: CGRect(x: 0, y: -200, width: 390, height: 600),
                        viewportFrame: CGRect(x: 0, y: -500, width: 390, height: 600)
                    )
                ]
            ),
            viewModel: subject.viewModel
        )

        XCTAssertEqual(correction?.pageID, "a#0")
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 0)
    }

    func testPendingRestoreDoesNotSelectInitialViewportBeforeTargetAlignment() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.progress.savedPages["a"] = 1
        subject.loader.enqueue(.pages([page(0), page(1), page(2)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        guard let target = subject.viewModel.scrollTarget else {
            XCTFail("Expected the saved continuous page to produce a scroll target")
            return
        }
        XCTAssertEqual(target.pageID, "a#1")
        let coordinator = MangaContinuousScrollPositionCoordinator()
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        _ = coordinator.update(
            MangaContinuousGeometry(
                viewport: viewport,
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
            ),
            viewModel: subject.viewModel
        )
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
        XCTAssertEqual(subject.viewModel.scrollTarget, target)

        _ = coordinator.update(
            MangaContinuousGeometry(
                viewport: viewport,
                pages: [
                    "a#1": MangaContinuousPageGeometry(
                        contentFrame: CGRect(x: 0, y: 500, width: 390, height: 500),
                        viewportFrame: CGRect(x: 0, y: 0, width: 390, height: 500)
                    )
                ]
            ),
            viewModel: subject.viewModel
        )
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
        XCTAssertTrue(
            coordinator.isSettled(target)
        )
        subject.viewModel.consumeScrollTarget(target)
        XCTAssertNil(subject.viewModel.scrollTarget)
    }

    func testContinuousChapterButtonScrollsToAnAlreadyLoadedChapter() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a, viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0)]), for: "a")
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "b")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        subject.viewModel.appendNextChapter()
        await waitForReader { subject.viewModel.segments.count == 2 }

        subject.viewModel.goToNextChapter()

        XCTAssertEqual(subject.viewModel.segments.map { $0.chapter.key }, ["a", "b"])
        assertScrollRequest(subject.viewModel.scrollTarget, pageID: "b#0")
        XCTAssertEqual(subject.loader.callCount(for: "b"), 1)
    }

    func testPagedChapterChangePreloadsAheadInTheNewChapter() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a, preload: 3)
        subject.loader.enqueue(.pages([page(0, text: "only")]), for: "a")
        subject.loader.enqueue(
            .pages((0..<3).map { page(Int32($0), url: "https://example.com/b\($0)") }),
            for: "b"
        )
        subject.viewModel.start()
        await waitForReader { subject.viewModel.prefetchedChapters["b"] != nil }

        subject.viewModel.goToNextChapter()

        XCTAssertEqual(subject.imagePrefetcher.batches.last?.map(\.index), [1, 2])
    }

    func testReadingModeChoiceIsRestoredAndSaved() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)])
        subject.progress.savedViewer = .Webtoon
        let reopened = MangaReaderViewModel(
            pageLoader: subject.loader,
            pluginID: subject.viewModel.pluginID,
            entry: subject.viewModel.entry,
            initialChapter: makeChapter("a", number: 1),
            dependencies: subject.dependencies
        )
        XCTAssertEqual(reopened.overrideViewer, .Webtoon)
        XCTAssertFalse(reopened.isPaged)

        reopened.setViewerOverride(.Ltr)
        await waitForReader { subject.progress.savedViewerWrites == [.Ltr] }
    }

    func testCrossingBackAndForthRecordsEachChapterInHistoryOnce() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.pages([page(0)]), for: "a")
        subject.loader.enqueue(.pages([page(0)]), for: "b")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.prefetchedChapters["b"] != nil }

        subject.viewModel.goToNextChapter()
        await waitForReader { subject.viewModel.prefetchedChapters["a"] != nil }
        subject.viewModel.goToPreviousChapter()
        await waitForReader { subject.viewModel.prefetchedChapters["b"] != nil }
        subject.viewModel.goToNextChapter()

        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["a", "b"])
    }

    func testClosingRightAfterTheLastPageStillMarksTheChapterRead() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)])
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        subject.viewModel.setPagedIndex(1)
        subject.viewModel.disappear()

        await waitForReader { subject.progress.requests.map(\.chapterID) == ["a"] }
        await yieldReaderTasks()
        // The tracker belongs to the closed reader and is left alone.
        XCTAssertTrue(subject.tracker.requests.isEmpty)
    }
}
