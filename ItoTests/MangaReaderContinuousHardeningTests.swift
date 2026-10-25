import XCTest
import ito_runner
@testable import Ito

extension MangaReaderViewModelTests {
    private static let readerViewport = CGRect(x: 0, y: 0, width: 390, height: 844)
    private static let tallPageHeight: CGFloat = 5_201.1375

    /// Four loaded chapters with the reader deep in c4#1, the page the next append keeps.
    private func readerDeepInFourthChapter() async -> MangaReaderTestSubject {
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
        return subject
    }

    private func tallPage(_ id: String, contentY: CGFloat, top: CGFloat) -> MangaContinuousGeometry {
        MangaContinuousGeometry(
            viewport: Self.readerViewport,
            pages: [id: MangaContinuousPageGeometry(
                contentFrame: CGRect(x: 0, y: contentY, width: 390, height: Self.tallPageHeight),
                viewportFrame: CGRect(x: 0, y: top, width: 390, height: Self.tallPageHeight)
            )]
        )
    }

    private func evictFirstChapter(_ subject: MangaReaderTestSubject) async -> MangaScrollRequest? {
        subject.viewModel.appendNextChapter()
        await waitForReader { subject.viewModel.segments.last?.chapter.key == "c5" }
        return subject.viewModel.scrollTarget
    }

    // MARK: - Restoration baseline

    func testRestorationWithoutAPreMutationSampleAcceptsAPageAlreadyAtItsSavedPosition() async {
        let subject = await readerDeepInFourthChapter()
        subject.viewModel.continuousViewportChanged(["c4#1"])
        subject.viewModel.updateContinuousScrollAlignment(
            MangaContinuousScrollPositionCoordinator.alignmentY(
                viewportTop: -4_558.5, pageHeight: Self.tallPageHeight, viewportHeight: 844
            )
        )
        guard let mutation = await evictFirstChapter(subject) else {
            return XCTFail("Front eviction must retain a restoration target")
        }
        // The view appeared after the mutation, so no pre-mutation sample exists. Native
        // anchoring already kept the page where it was.
        let coordinator = MangaContinuousScrollPositionCoordinator()

        XCTAssertNil(coordinator.update(
            tallPage("c4#1", contentY: 270_901.5, top: -4_558.5), viewModel: subject.viewModel
        ))
        XCTAssertTrue(coordinator.isSettled(mutation), "A post-mutation frame is not a stale baseline")

        // Reading resumes: a later scroll is the reader's, not a blocked restoration.
        subject.viewModel.consumeScrollTarget(mutation)
        XCTAssertNil(coordinator.update(
            tallPage("c4#1", contentY: 270_901.5, top: -4_700), viewModel: subject.viewModel
        ))
        XCTAssertEqual(subject.viewModel.flatPages[subject.viewModel.continuousPageIndex].id, "c4#1")
    }

    func testRestorationWithoutAnyReferenceTakesTheSavedTopFromTheRequestedAlignment() async {
        let subject = await readerDeepInFourthChapter()
        subject.viewModel.continuousViewportChanged(["c4#1"])
        subject.viewModel.updateContinuousScrollAlignment(
            MangaContinuousScrollPositionCoordinator.alignmentY(
                viewportTop: -4_558.5, pageHeight: Self.tallPageHeight, viewportHeight: 844
            )
        )
        guard let mutation = await evictFirstChapter(subject) else {
            return XCTFail("Front eviction must retain a restoration target")
        }
        let coordinator = MangaContinuousScrollPositionCoordinator()

        // The restored page is not laid out yet.
        let missing = coordinator.update(
            MangaContinuousGeometry(
                viewport: Self.readerViewport,
                pages: ["c5#0": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 276_252, width: 390, height: 480),
                    viewportFrame: CGRect(x: 0, y: 749, width: 390, height: 480)
                )]
            ),
            viewModel: subject.viewModel
        )
        XCTAssertEqual(missing?.pageID, "c4#1")

        // Once it is, a page already at the saved depth needs no correction.
        XCTAssertNil(coordinator.update(
            tallPage("c4#1", contentY: 270_901.5, top: -4_558.5), viewModel: subject.viewModel
        ))
        XCTAssertTrue(coordinator.isSettled(mutation))
    }

    // MARK: - Forward momentum

    func testFirstPostEvictionFrameAlreadyPastTheSavedTopDoesNotRecoil() async {
        let subject = await readerDeepInFourthChapter()
        let coordinator = MangaContinuousScrollPositionCoordinator()
        // The reader scrolls forward through c4#1.
        _ = coordinator.update(tallPage("c4#1", contentY: 362_072.5, top: -4_500), viewModel: subject.viewModel)
        _ = coordinator.update(tallPage("c4#1", contentY: 362_072.5, top: -4_558.5), viewModel: subject.viewModel)
        guard let mutation = await evictFirstChapter(subject) else {
            return XCTFail("Front eviction must retain a restoration target")
        }

        // The first changed frame has already moved on, with no intermediate estimate.
        XCTAssertNil(coordinator.update(
            tallPage("c4#1", contentY: 270_901.524635, top: -4_601.808699), viewModel: subject.viewModel
        ))
        XCTAssertTrue(coordinator.isSettled(mutation))
    }

    func testStationaryReaderDisplacedByEvictionIsStillRestored() async {
        let subject = await readerDeepInFourthChapter()
        let coordinator = MangaContinuousScrollPositionCoordinator()
        _ = coordinator.update(tallPage("c4#1", contentY: 362_072.5, top: -4_558.5), viewModel: subject.viewModel)
        guard let mutation = await evictFirstChapter(subject) else {
            return XCTFail("Front eviction must retain a restoration target")
        }

        // Nobody was scrolling, so a changed position is the layout's, and is corrected.
        let correction = coordinator.update(
            tallPage("c4#1", contentY: 270_901.524635, top: -4_601.808699), viewModel: subject.viewModel
        )
        XCTAssertEqual(correction?.pageID, "c4#1")
        XCTAssertEqual(correction?.alignmentY ?? 0, mutation.alignmentY, accuracy: 0.0001)
        XCTAssertFalse(coordinator.isSettled(mutation))
    }

    // MARK: - Current page and alignment

    func testSubPointRemnantOfThePreviousPageDoesNotRevertTheCurrentPage() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1), page(2)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        let coordinator = MangaContinuousScrollPositionCoordinator()
        func frame(_ id: String, top: CGFloat, height: CGFloat = 600) -> (String, MangaContinuousPageGeometry) {
            (id, MangaContinuousPageGeometry(
                contentFrame: CGRect(x: 0, y: 1_000 + top, width: 390, height: height),
                viewportFrame: CGRect(x: 0, y: top, width: 390, height: height)
            ))
        }
        subject.viewModel.continuousViewportChanged(["a#0", "a#1"])
        subject.viewModel.nextPage()
        guard let target = subject.viewModel.scrollTarget else { return XCTFail("Next page must target a#1") }

        // The navigation lands with 0.4pt of a#0 still above it.
        let landed = MangaContinuousGeometry(
            viewport: Self.readerViewport,
            pages: Dictionary(uniqueKeysWithValues: [frame("a#0", top: -599.6), frame("a#1", top: 0.4)])
        )
        _ = coordinator.update(landed, viewModel: subject.viewModel)
        XCTAssertTrue(coordinator.isSettled(target))
        subject.viewModel.consumeScrollTarget(target)

        // The next page entering below must not hand the current page back to the sliver.
        _ = coordinator.update(
            MangaContinuousGeometry(
                viewport: Self.readerViewport,
                pages: Dictionary(uniqueKeysWithValues: [
                    frame("a#0", top: -599.6), frame("a#1", top: 0.4), frame("a#2", top: 600.4)
                ])
            ),
            viewModel: subject.viewModel
        )
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
        XCTAssertEqual(
            subject.viewModel.continuousScrollAlignmentY,
            MangaContinuousScrollPositionCoordinator.alignmentY(viewportTop: 0.4, pageHeight: 600, viewportHeight: 844),
            accuracy: 0.0001
        )
    }

    // MARK: - Layout drift and user scrolling

    private func readerOnFirstChapterPage() async -> MangaReaderTestSubject {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        return subject
    }

    private func pages(_ entries: [(String, CGFloat, CGFloat, CGFloat)]) -> MangaContinuousGeometry {
        MangaContinuousGeometry(
            viewport: Self.readerViewport,
            pages: Dictionary(uniqueKeysWithValues: entries.map { id, contentY, top, height in
                (id, MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: contentY, width: 390, height: height),
                    viewportFrame: CGRect(x: 0, y: top, width: 390, height: height)
                ))
            })
        )
    }

    func testAReflowAboveTheViewportDuringAScrollIsNotPulledAgainstTheScroll() async {
        let subject = await readerOnFirstChapterPage()
        let coordinator = MangaContinuousScrollPositionCoordinator()
        _ = coordinator.update(pages([("a#1", 1_000, -350, 1_400)]), viewModel: subject.viewModel)

        // An image above grew 100pt while the reader scrolled 30pt the other way.
        XCTAssertNil(coordinator.update(pages([("a#1", 1_100, -280, 1_400)]), viewModel: subject.viewModel))
    }

    func testAPageTheReaderScrolledAwayFromIsNotAnAnchor() async {
        let subject = await readerOnFirstChapterPage()
        let coordinator = MangaContinuousScrollPositionCoordinator()
        _ = coordinator.update(
            pages([("a#0", 0, -300, 1_200), ("a#1", 1_200, 900, 1_200)]), viewModel: subject.viewModel
        )

        // The reader scrolled 1,400pt down; a#0 is still laid out above the viewport, and a 50pt
        // image above it loaded meanwhile.
        let correction = coordinator.update(
            pages([("a#0", 50, -1_650, 1_200), ("a#1", 1_250, -450, 1_200)]), viewModel: subject.viewModel
        )
        XCTAssertNil(correction, "Scrolling away from a page never pulls the reader back to it")
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
    }

    func testStationaryLayoutDriftIsStillCorrectedFromTheVisibleAnchor() async {
        let subject = await readerOnFirstChapterPage()
        let coordinator = MangaContinuousScrollPositionCoordinator()
        _ = coordinator.update(pages([("a#1", 1_000, -350, 1_400)]), viewModel: subject.viewModel)

        let correction = coordinator.update(pages([("a#1", 1_100, -250, 1_400)]), viewModel: subject.viewModel)
        assertScrollRequest(
            correction,
            pageID: "a#1",
            alignmentY: MangaContinuousScrollPositionCoordinator.alignmentY(
                viewportTop: -350, pageHeight: 1_400, viewportHeight: 844
            )
        )
    }

    func testDraggingAwayFromAnActiveLayoutCorrectionReleasesTheRestoration() async {
        let subject = await readerOnFirstChapterPage()
        let coordinator = MangaContinuousScrollPositionCoordinator()
        _ = coordinator.handle(pages([("a#1", 1_000, -350, 1_400)]), viewModel: subject.viewModel)
        XCTAssertNotNil(coordinator.handle(
            pages([("a#1", 1_100, -250, 1_400)]), viewModel: subject.viewModel
        ))

        // The correction would move the top toward -350, but the reader drags toward -200.
        XCTAssertNil(coordinator.handle(
            pages([("a#1", 1_100, -200, 1_400)]), viewModel: subject.viewModel
        ))
        XCTAssertNil(coordinator.handle(
            pages([("a#1", 1_100, -150, 1_400)]), viewModel: subject.viewModel
        ))
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
    }

    func testAnUnsettledMutationRestorationCannotRetryIndefinitely() async {
        let subject = await readerDeepInFourthChapter()
        let coordinator = MangaContinuousScrollPositionCoordinator()
        _ = coordinator.handle(
            tallPage("c4#1", contentY: 362_072.5, top: -4_558.5), viewModel: subject.viewModel
        )
        guard await evictFirstChapter(subject) != nil else {
            return XCTFail("Eviction must publish its restoration target")
        }
        let unsettled = tallPage("c4#1", contentY: 270_901.5, top: -4_400)
        var requests = 0
        for _ in 0...MangaContinuousScrollPositionCoordinator.maximumTargetRetries {
            if coordinator.handle(unsettled, viewModel: subject.viewModel) != nil { requests += 1 }
        }
        XCTAssertLessThanOrEqual(requests, MangaContinuousScrollPositionCoordinator.maximumTargetRetries)
        XCTAssertNil(subject.viewModel.scrollTarget)
        XCTAssertNil(coordinator.handle(unsettled, viewModel: subject.viewModel))
    }

    // MARK: - Prefetch

    func testContinuousPrefetchRunsAheadOfTheBottommostVisiblePage() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical, preload: 2)
        subject.loader.enqueue(
            .pages((0..<8).map { page($0, url: "https://example.com/\($0)") }),
            for: "a"
        )
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        let ids = subject.viewModel.flatPages.map(\.id)

        // Four short strips are on screen at once.
        subject.viewModel.continuousViewportChanged(Array(ids[0...3]))

        XCTAssertEqual(subject.imagePrefetcher.batches.last?.map(\.index), [4, 5])
    }

    // MARK: - Targets the view drives

    func testAnimatedNextPageStaysCurrentUntilItArrivesAtTheBottomBoundary() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1), page(2)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        let coordinator = MangaContinuousScrollPositionCoordinator()
        // a#0 and a#1 are 600pt tall; the last page, a#2, is a 300pt strip. The content is 1,500pt.
        func pass(offset: CGFloat) -> MangaContinuousGeometry {
            MangaContinuousGeometry(
                viewport: Self.readerViewport,
                contentBounds: CGRect(x: 0, y: -offset, width: 390, height: 1_500),
                pages: [
                    "a#0": MangaContinuousPageGeometry(
                        contentFrame: CGRect(x: 0, y: 0, width: 390, height: 600),
                        viewportFrame: CGRect(x: 0, y: -offset, width: 390, height: 600)
                    ),
                    "a#1": MangaContinuousPageGeometry(
                        contentFrame: CGRect(x: 0, y: 600, width: 390, height: 600),
                        viewportFrame: CGRect(x: 0, y: 600 - offset, width: 390, height: 600)
                    ),
                    "a#2": MangaContinuousPageGeometry(
                        contentFrame: CGRect(x: 0, y: 1_200, width: 390, height: 300),
                        viewportFrame: CGRect(x: 0, y: 1_200 - offset, width: 390, height: 300)
                    )
                ]
            )
        }
        XCTAssertNil(coordinator.handle(pass(offset: 600), viewModel: subject.viewModel))
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)

        subject.viewModel.nextPage()
        guard let target = subject.viewModel.scrollTarget else { return XCTFail("Next page must target a#2") }
        XCTAssertEqual(coordinator.issue(target, viewModel: subject.viewModel)?.pageID, "a#2")
        XCTAssertEqual(subject.viewModel.scrollTarget, target, "Issuing an animation does not finish it")

        // The animation's first frames still show a#1 leading the viewport.
        for offset: CGFloat in [610, 630] {
            XCTAssertNil(coordinator.handle(pass(offset: offset), viewModel: subject.viewModel))
            XCTAssertEqual(subject.viewModel.scrollTarget, target)
            XCTAssertEqual(subject.viewModel.continuousPageIndex, 2)
        }

        // It stops at the bottom boundary with part of a#1 still visible.
        XCTAssertNil(coordinator.handle(pass(offset: 656), viewModel: subject.viewModel))
        XCTAssertNil(subject.viewModel.scrollTarget)
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 2)
        XCTAssertNil(coordinator.handle(pass(offset: 655.5), viewModel: subject.viewModel))
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 2)

        // Previous must likewise remain authoritative while the short last page is still visible.
        subject.viewModel.previousPage()
        guard let previous = subject.viewModel.scrollTarget else { return XCTFail("Previous must target a#1") }
        XCTAssertEqual(coordinator.issue(previous, viewModel: subject.viewModel)?.pageID, "a#1")
        for offset: CGFloat in [650, 620] {
            XCTAssertNil(coordinator.handle(pass(offset: offset), viewModel: subject.viewModel))
            XCTAssertEqual(subject.viewModel.scrollTarget, previous)
            XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
        }
        XCTAssertNil(coordinator.handle(pass(offset: 600), viewModel: subject.viewModel))
        XCTAssertNil(subject.viewModel.scrollTarget)
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
    }

    func testAnimatedTargetTheReaderDragsAwayFromIsReleased() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1), page(2)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        let coordinator = MangaContinuousScrollPositionCoordinator()
        func pass(top a1Top: CGFloat) -> MangaContinuousGeometry {
            MangaContinuousGeometry(
                viewport: Self.readerViewport,
                pages: [
                    "a#0": MangaContinuousPageGeometry(
                        contentFrame: CGRect(x: 0, y: 0, width: 390, height: 1_000),
                        viewportFrame: CGRect(x: 0, y: a1Top - 1_000, width: 390, height: 1_000)
                    ),
                    "a#1": MangaContinuousPageGeometry(
                        contentFrame: CGRect(x: 0, y: 1_000, width: 390, height: 1_000),
                        viewportFrame: CGRect(x: 0, y: a1Top, width: 390, height: 1_000)
                    )
                ]
            )
        }
        _ = coordinator.handle(pass(top: 900), viewModel: subject.viewModel)
        subject.viewModel.nextPage()
        guard let target = subject.viewModel.scrollTarget else { return XCTFail("Next page must target a#1") }
        _ = coordinator.issue(target, viewModel: subject.viewModel)

        XCTAssertNil(coordinator.handle(pass(top: 500), viewModel: subject.viewModel))
        XCTAssertEqual(subject.viewModel.scrollTarget, target)
        // The reader drags back up, away from the target.
        XCTAssertNil(coordinator.handle(pass(top: 560), viewModel: subject.viewModel))
        XCTAssertNil(subject.viewModel.scrollTarget)

        // From then on the reader's own position decides the current page.
        _ = coordinator.handle(pass(top: 700), viewModel: subject.viewModel)
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 0)
    }

    func testAJumpThatStopsGettingCloserIsNotRetriedForever() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.progress.savedPages["a"] = 1
        subject.loader.enqueue(.pages([page(0), page(1), page(2)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        XCTAssertNotNil(subject.viewModel.scrollTarget, "Expected the saved page target")
        let coordinator = MangaContinuousScrollPositionCoordinator()
        // The layout keeps a#1 300pt below where the jump asks for it, without a boundary.
        let stuck = MangaContinuousGeometry(
            viewport: Self.readerViewport,
            pages: [
                "a#0": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 0, width: 390, height: 300),
                    viewportFrame: CGRect(x: 0, y: 0, width: 390, height: 300)
                ),
                "a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 300, width: 390, height: 2_000),
                    viewportFrame: CGRect(x: 0, y: 300, width: 390, height: 2_000)
                )
            ]
        )

        XCTAssertEqual(coordinator.handle(stuck, viewModel: subject.viewModel)?.pageID, "a#1")
        XCTAssertNil(coordinator.handle(stuck, viewModel: subject.viewModel), "No progress: stop retrying")
        XCTAssertNil(subject.viewModel.scrollTarget)
        XCTAssertNil(coordinator.handle(stuck, viewModel: subject.viewModel))
    }

    func testAJumpThatKeepsGettingCloserIsRetriedOnlyABoundedNumberOfTimes() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.progress.savedPages["a"] = 1
        subject.loader.enqueue(.pages([page(0), page(1), page(2)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        let coordinator = MangaContinuousScrollPositionCoordinator()
        var scrolls = 0
        var top: CGFloat = 900
        while subject.viewModel.scrollTarget != nil, scrolls < 100 {
            let pass = MangaContinuousGeometry(
                viewport: Self.readerViewport,
                pages: ["a#1": MangaContinuousPageGeometry(
                    contentFrame: CGRect(x: 0, y: 300, width: 390, height: 2_000),
                    viewportFrame: CGRect(x: 0, y: top, width: 390, height: 2_000)
                )]
            )
            if coordinator.handle(pass, viewModel: subject.viewModel) != nil { scrolls += 1 }
            top -= 10
        }
        XCTAssertEqual(scrolls, MangaContinuousScrollPositionCoordinator.maximumTargetRetries)
        XCTAssertNil(subject.viewModel.scrollTarget)
    }
}
