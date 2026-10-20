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

        // Scrolling down: the page entering at the bottom does not become current.
        subject.viewModel.continuousPageAppeared(pages[0])
        subject.viewModel.continuousPageAppeared(pages[1])
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 0)

        subject.viewModel.continuousPageDisappeared(pages[0])
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
        XCTAssertEqual(subject.viewModel.continuousChapterPage.index, 1)
        XCTAssertEqual(subject.viewModel.continuousChapterPage.count, 3)
        await waitForReader { subject.progress.savedPages["a"] == 1 }

        // The last page shows without reaching the top: the chapter still counts as finished.
        subject.viewModel.continuousPageAppeared(pages[2])
        await waitForReader { subject.progress.requests.map(\.chapterID) == ["a"] }
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
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
        XCTAssertEqual(
            subject.viewModel.scrollTarget,
            MangaScrollRequest(pageID: "b#0", animated: false)
        )
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
            manga: subject.viewModel.manga,
            initialChapter: makeChapter("a", number: 1),
            dependencies: subject.dependencies
        )
        XCTAssertEqual(reopened.overrideViewer, .Webtoon)
        XCTAssertFalse(reopened.isPaged)

        reopened.setViewerOverride(.Ltr)
        await waitForReader { subject.progress.savedViewerWrites == [.Ltr] }
    }
}
