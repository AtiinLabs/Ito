import XCTest
import ito_runner
@testable import Ito

@MainActor
final class MangaReaderViewModelTests: XCTestCase {
    func testInitialPagedLoadSortsPublishesAndMarksReadOnlyAtTheLastPage() async {
        let chapter = makeChapter("a", number: 12.75)
        let subject = makeSubject(chapters: [chapter])
        subject.loader.enqueue(
            .pages([page(8), page(2), page(5)]),
            for: chapter.key
        )

        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        XCTAssertEqual(subject.loader.requestedChapterKeys, ["a"])
        XCTAssertEqual(subject.viewModel.pagedPages.map(\.index), [2, 5, 8])
        XCTAssertEqual(subject.viewModel.pagedIndex, 0)
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["a"])
        XCTAssertEqual(subject.history.requests[0].chapterTitle, "a")
        XCTAssertEqual(subject.history.requests[0].pluginID, "plugin.test")
        XCTAssertEqual(subject.history.requests[0].manga.key, "manga")
        XCTAssertTrue(subject.progress.requests.isEmpty)
        XCTAssertFalse(subject.viewModel.markedChapterKeys.contains("a"))

        subject.viewModel.setPagedIndex(1)
        subject.viewModel.setPagedIndex(2)
        await waitForReader { subject.tracker.requests.count == 1 }

        XCTAssertEqual(subject.progress.requests.map(\.chapterID), ["a"])
        XCTAssertEqual(subject.tracker.requests.map(\.progress), [12])
        XCTAssertEqual(
            subject.events.events,
            ["history:a", "progress:a", "tracker:12"]
        )
        XCTAssertTrue(subject.viewModel.markedChapterKeys.contains("a"))
    }

    func testPagedChapterOpensAtTheSavedPageAndSavesNewPages() async {
        let chapter = makeChapter("a", number: 3)
        let subject = makeSubject(chapters: [chapter])
        subject.progress.savedPages["a"] = 2
        subject.loader.enqueue(.pages([page(0), page(1), page(2), page(3)]), for: "a")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        XCTAssertEqual(subject.viewModel.pagedIndex, 2)

        subject.viewModel.setPagedIndex(1)
        await waitForReader { subject.progress.savedPageWrites.count == 2 }
        XCTAssertEqual(subject.progress.savedPageWrites.map(\.page), [2, 1])
        XCTAssertTrue(subject.progress.requests.isEmpty)
    }

    func testFinishedChapterStartsOverInsteadOfReopeningAtTheLastPage() async {
        let chapter = makeChapter("a", number: 3)
        let subject = makeSubject(chapters: [chapter], viewer: .Vertical)
        subject.progress.savedPages["a"] = 2
        subject.loader.enqueue(.pages([page(0), page(1), page(2)]), for: "a")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        XCTAssertEqual(subject.viewModel.continuousPageIndex, 0)
        XCTAssertNil(subject.viewModel.scrollTarget)
    }

    func testContinuousChapterOpensAtTheSavedPage() async {
        let chapter = makeChapter("a", number: 3)
        let subject = makeSubject(chapters: [chapter], viewer: .Vertical)
        subject.progress.savedPages["a"] = 1
        subject.loader.enqueue(.pages([page(0), page(1), page(2)]), for: "a")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        XCTAssertEqual(subject.viewModel.continuousPageIndex, 1)
        XCTAssertEqual(
            subject.viewModel.scrollTarget,
            MangaScrollRequest(pageID: "a#1", animated: false)
        )
    }

    func testInitialContinuousLoadPublishesSingleSortedSegment() async {
        let chapter = makeChapter("a", number: 1)
        let subject = makeSubject(chapters: [chapter], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(4), page(1)]), for: "a")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        XCTAssertFalse(subject.viewModel.isPaged)
        XCTAssertEqual(subject.viewModel.segments.map { $0.chapter.key }, ["a"])
        XCTAssertEqual(subject.viewModel.segments[0].pages.map(\.index), [1, 4])
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 0)
    }

    func testDuplicateStartDoesNotOverlapInitialLoad() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)])
        subject.loader.enqueue(.suspended, for: "a")

        subject.viewModel.start()
        subject.viewModel.start()
        subject.viewModel.start()
        await waitForReader { subject.loader.pendingCount(for: "a") == 1 }

        XCTAssertEqual(subject.loader.callCount(for: "a"), 1)
        subject.loader.resolveFirst(for: "a", with: .success([page(0)]))
        await waitForReader { subject.viewModel.loadPhase == .content }
    }

    func testInitialFailurePublishesInlineFailureAndRetryLoadsAgain() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)])
        subject.loader.enqueue(.failure(MangaReaderTestError.expected), for: "a")
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "a")

        subject.viewModel.start()
        await waitForReader {
            subject.viewModel.loadPhase == .failure("expected reader failure")
        }

        XCTAssertTrue(subject.viewModel.pagedPages.isEmpty)
        XCTAssertTrue(subject.history.requests.isEmpty)

        subject.viewModel.retry()
        await waitForReader { subject.viewModel.loadPhase == .content }
        XCTAssertEqual(subject.viewModel.pagedPages.count, 2)
        XCTAssertEqual(subject.loader.callCount(for: "a"), 2)
    }

    func testStaleInitialCompletionCannotReplaceDirectNavigation() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.suspended, for: "a")
        subject.loader.enqueue(.pages([page(7, text: "b")]), for: "b")

        subject.viewModel.start()
        await waitForReader { subject.loader.pendingCount(for: "a") == 1 }
        subject.viewModel.goToNextChapter()
        await waitForReader {
            subject.viewModel.currentChapter.key == "b"
                && subject.viewModel.loadPhase == .content
        }
        subject.loader.resolveFirst(
            for: "a",
            with: .success([page(1, text: "stale-a")])
        )
        await yieldReaderTasks()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        XCTAssertEqual(subject.viewModel.pagedPages.map(\.index), [7])
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["b"])
    }

    func testStaleInitialFailureCannotReplaceDirectNavigationSuccess() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.suspended, for: "a")
        subject.loader.enqueue(.pages([page(7, text: "b")]), for: "b")

        subject.viewModel.start()
        await waitForReader { subject.loader.pendingCount(for: "a") == 1 }
        subject.viewModel.goToNextChapter()
        await waitForReader {
            subject.viewModel.currentChapter.key == "b"
                && subject.viewModel.loadPhase == .content
        }
        subject.loader.resolveFirst(
            for: "a",
            with: .failure(MangaReaderTestError.expected)
        )
        await yieldReaderTasks()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        XCTAssertEqual(subject.viewModel.pagedPages.map(\.index), [7])
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["b"])
    }

    func testStaleDirectNavigationCompletionCannotReplaceNewerChapter() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let c = makeChapter("c", number: 3)
        let subject = makeSubject(chapters: [a, b, c], initial: a)
        subject.loader.enqueue(.pages([page(0)]), for: "a")
        subject.loader.enqueue(.suspended, for: "b")
        subject.loader.enqueue(.suspended, for: "b")
        subject.loader.enqueue(.pages([page(30, text: "c")]), for: "c")

        subject.viewModel.start()
        await waitForReader { subject.loader.pendingCount(for: "b") == 1 }
        subject.viewModel.goToNextChapter()
        await waitForReader { subject.loader.pendingCount(for: "b") == 2 }
        subject.viewModel.goToNextChapter()
        await waitForReader {
            subject.viewModel.currentChapter.key == "c"
                && subject.viewModel.loadPhase == .content
        }
        subject.loader.resolveFirst(for: "b", with: .success([page(20)]))
        subject.loader.resolveFirst(for: "b", with: .failure(MangaReaderTestError.expected))
        await yieldReaderTasks()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "c")
        XCTAssertEqual(subject.viewModel.pagedPages.map(\.index), [30])
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["a", "c"])
    }

    func testStaleAdjacentPrefetchCannotPopulateCacheAfterDisappear() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.pages([page(0)]), for: "a")
        subject.loader.enqueue(.suspended, for: "b")
        subject.viewModel.start()
        await waitForReader { subject.loader.pendingCount(for: "b") == 1 }

        subject.viewModel.disappear()
        subject.loader.resolveFirst(for: "b", with: .success([page(2)]))
        await yieldReaderTasks()

        XCTAssertNil(subject.viewModel.prefetchedChapters["b"])
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
    }

    func testAdjacentPrefetchChecksNextThenPreviousAndKeepsFailuresBestEffort() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let c = makeChapter("c", number: 3)
        let subject = makeSubject(chapters: [a, b, c], initial: b)
        subject.loader.enqueue(.pages([page(0)]), for: "b")
        subject.loader.enqueue(.failure(MangaReaderTestError.expected), for: "c")
        subject.loader.enqueue(.pages([page(8), page(2)]), for: "a")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.prefetchedChapters["a"] != nil }

        XCTAssertEqual(subject.loader.requestedChapterKeys, ["b", "c", "a"])
        XCTAssertNil(subject.viewModel.prefetchedChapters["c"])
        XCTAssertEqual(subject.viewModel.prefetchedChapters["a"]?.map(\.index), [2, 8])
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
    }

    func testDisappearInvalidatesNonCooperativeLoadAndStopsPresentationEffects() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)])
        subject.loader.enqueue(.suspended, for: "a")
        subject.viewModel.appear()
        subject.viewModel.start()
        await waitForReader { subject.loader.pendingCount(for: "a") == 1 }

        subject.viewModel.disappear()
        subject.loader.resolveFirst(for: "a", with: .success([page(0)]))
        await yieldReaderTasks()

        XCTAssertEqual(subject.viewModel.loadPhase, .loading)
        XCTAssertTrue(subject.viewModel.pagedPages.isEmpty)
        XCTAssertTrue(subject.history.requests.isEmpty)
        XCTAssertEqual(subject.imagePrefetcher.stopCount, 1)
        XCTAssertEqual(subject.presence.events.last, .clear)
    }

    func testReappearDeterministicallyRestartsCancelledLoadOnce() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)])
        subject.loader.enqueue(.suspended, for: "a")
        subject.loader.enqueue(.pages([page(4)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.loader.pendingCount(for: "a") == 1 }

        subject.viewModel.disappear()
        subject.viewModel.appear()
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        XCTAssertEqual(subject.loader.callCount(for: "a"), 2)
        XCTAssertEqual(subject.viewModel.pagedPages.map(\.index), [4])
        subject.loader.resolveFirst(for: "a", with: .success([page(99)]))
        await yieldReaderTasks()
        XCTAssertEqual(subject.viewModel.pagedPages.map(\.index), [4])
    }

    func testCachedPagedNextUsesOrderedCacheWithoutMainReload() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.pages([page(0)]), for: "a")
        subject.loader.enqueue(.pages([page(5), page(2)]), for: "b")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.prefetchedChapters["b"] != nil }
        let priorBCalls = subject.loader.callCount(for: "b")
        subject.viewModel.goToNextChapter()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        XCTAssertEqual(subject.viewModel.pagedPages.map(\.index), [2, 5])
        XCTAssertEqual(subject.viewModel.pagedIndex, 0)
        XCTAssertEqual(subject.loader.callCount(for: "b"), priorBCalls)
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["a", "b"])
    }

    func testCachedPagedPreviousUsesCacheWithoutMainReload() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let c = makeChapter("c", number: 3)
        let subject = makeSubject(chapters: [a, b, c], initial: b)
        subject.loader.enqueue(.pages([page(0)]), for: "b")
        subject.loader.enqueue(.pages([page(0)]), for: "c")
        subject.loader.enqueue(.pages([page(9), page(1)]), for: "a")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.prefetchedChapters["a"] != nil }
        let priorACalls = subject.loader.callCount(for: "a")
        subject.viewModel.goToPreviousChapter()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
        XCTAssertEqual(subject.viewModel.pagedPages.map(\.index), [1, 9])
        XCTAssertEqual(subject.loader.callCount(for: "a"), priorACalls)
    }

    func testUncachedPagedNextAndPreviousResetAndLoadExactSortedChapter() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.pages([page(0)]), for: "a")
        subject.loader.enqueue(.suspended, for: "a")
        subject.loader.enqueue(.suspended, for: "b")
        subject.loader.enqueue(.pages([page(8), page(3)]), for: "b")

        subject.viewModel.start()
        await waitForReader { subject.loader.pendingCount(for: "b") == 1 }
        subject.viewModel.goToNextChapter()
        await waitForReader { subject.viewModel.currentChapter.key == "b" }
        XCTAssertEqual(subject.viewModel.loadPhase, .loading)
        XCTAssertTrue(subject.viewModel.pagedPages.isEmpty)
        await waitForReader { subject.viewModel.loadPhase == .content }
        XCTAssertEqual(subject.viewModel.pagedPages.map(\.index), [3, 8])

        await waitForReader { subject.loader.pendingCount(for: "a") == 1 }
        subject.loader.enqueue(.pages([page(6), page(2)]), for: "a")
        subject.viewModel.goToPreviousChapter()
        await waitForReader {
            subject.viewModel.currentChapter.key == "a"
                && subject.viewModel.loadPhase == .content
        }
        XCTAssertEqual(subject.viewModel.pagedPages.map(\.index), [2, 6])

        subject.loader.resolveFirst(for: "a", with: .success([page(98)]))
        subject.loader.resolveFirst(for: "b", with: .success([page(99)]))
        await yieldReaderTasks()
        XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
        XCTAssertEqual(subject.viewModel.pagedPages.map(\.index), [2, 6])
    }

    func testPagedSentinelsAndFooterPageNavigationPreserveBoundaries() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.pages([page(0), page(1), page(2)]), for: "a")
        subject.loader.enqueue(.pages([page(0)]), for: "b")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        subject.viewModel.nextPage()
        XCTAssertEqual(subject.viewModel.pagedIndex, 1)
        subject.viewModel.previousPage()
        subject.viewModel.previousPage()
        XCTAssertEqual(subject.viewModel.pagedIndex, 0)
        subject.viewModel.setPagedIndex(subject.viewModel.pagedPages.count)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
    }

    func testSwipingBackOpensThePreviousChapterAtItsLastPage() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let c = makeChapter("c", number: 3)
        let subject = makeSubject(chapters: [a, b, c], initial: c)
        subject.loader.enqueue(.pages([page(0)]), for: "c")
        subject.loader.enqueue(.suspended, for: "b")
        subject.loader.enqueue(.pages([page(0), page(1), page(2)]), for: "b")
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.loader.pendingCount(for: "b") == 1 }

        // Not cached yet: opens at the end once loaded.
        subject.viewModel.setPagedIndex(-1)
        await waitForReader {
            subject.viewModel.currentChapter.key == "b"
                && subject.viewModel.loadPhase == .content
        }
        XCTAssertEqual(subject.viewModel.pagedIndex, 2)

        // Cached: opens at the end straight away.
        await waitForReader { subject.viewModel.prefetchedChapters["a"] != nil }
        subject.viewModel.setPagedIndex(-1)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
        XCTAssertEqual(subject.viewModel.pagedIndex, 1)
        subject.loader.resolveFirst(for: "b", with: .success([]))
    }

    func testContinuousAppendSortsSuppressesDuplicatesAndDoesNotChangeCurrentChapter() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a, viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0)]), for: "a")
        subject.loader.enqueue(.suspended, for: "b")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        subject.viewModel.appendNextChapter()
        subject.viewModel.appendNextChapter()
        await waitForReader { subject.loader.pendingCount(for: "b") == 1 }
        XCTAssertTrue(subject.viewModel.loadingNextChapter)
        XCTAssertEqual(subject.loader.callCount(for: "b"), 1)
        subject.loader.resolveFirst(for: "b", with: .success([page(7), page(3)]))
        await waitForReader { !subject.viewModel.loadingNextChapter }

        XCTAssertEqual(subject.viewModel.segments.map { $0.chapter.key }, ["a", "b"])
        XCTAssertEqual(subject.viewModel.segments[1].pages.map(\.index), [3, 7])
        XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["a"])
    }

    func testContinuousAppendFailureWaitsForAnExplicitRetry() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a, viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0)]), for: "a")
        subject.loader.enqueue(.failure(MangaReaderTestError.expected), for: "b")
        subject.loader.enqueue(.pages([page(2)]), for: "b")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        subject.viewModel.appendNextChapter()
        await waitForReader { !subject.viewModel.loadingNextChapter }
        XCTAssertEqual(subject.viewModel.segments.count, 1)
        XCTAssertTrue(subject.viewModel.appendFailed)

        // The end of the list coming back into view does not retry by itself.
        subject.viewModel.appendNextChapter()
        XCTAssertFalse(subject.viewModel.loadingNextChapter)
        XCTAssertEqual(subject.loader.callCount(for: "b"), 1)

        subject.viewModel.retryAppendNextChapter()
        await waitForReader { subject.viewModel.segments.count == 2 }
        XCTAssertFalse(subject.viewModel.appendFailed)
        XCTAssertEqual(subject.loader.callCount(for: "b"), 2)
    }

    func testStaleAppendCannotMutateAfterModeChange() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a, viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0)]), for: "a")
        subject.loader.enqueue(.suspended, for: "b")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        subject.viewModel.appendNextChapter()
        await waitForReader { subject.loader.pendingCount(for: "b") == 1 }

        subject.viewModel.setViewerOverride(.Rtl)
        subject.loader.resolveFirst(for: "b", with: .success([page(2)]))
        await yieldReaderTasks()

        XCTAssertTrue(subject.viewModel.isPaged)
        XCTAssertEqual(subject.viewModel.segments.map { $0.chapter.key }, ["a"])
        XCTAssertFalse(subject.viewModel.loadingNextChapter)
    }

    func testContinuousPrependSortsSuppressesDuplicatesAndCompensatesScrollIndex() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: b, viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "b")
        subject.loader.enqueue(.suspended, for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        subject.viewModel.continuousPageAppeared(subject.viewModel.flatPages[1])

        subject.viewModel.prependPreviousChapter()
        subject.viewModel.prependPreviousChapter()
        await waitForReader { subject.loader.pendingCount(for: "a") == 1 }
        subject.loader.resolveFirst(for: "a", with: .success([page(5), page(2)]))
        await waitForReader { !subject.viewModel.loadingPrevChapter }

        XCTAssertEqual(subject.loader.callCount(for: "a"), 1)
        XCTAssertEqual(subject.viewModel.segments.map { $0.chapter.key }, ["a", "b"])
        XCTAssertEqual(subject.viewModel.segments[0].pages.map(\.index), [2, 5])
        XCTAssertEqual(subject.viewModel.continuousPageIndex, 3)
        XCTAssertEqual(
            subject.viewModel.scrollTarget,
            MangaScrollRequest(pageID: "b#1", animated: false)
        )
    }

    func testContinuousDropsChaptersFarBehindTheReader() async {
        let chapters = (1...5).map { makeChapter("c\($0)", number: Float($0)) }
        let subject = makeSubject(chapters: chapters, initial: chapters[0], viewer: .Vertical)
        for chapter in chapters {
            subject.loader.enqueue(.pages([page(0), page(1)]), for: chapter.key)
        }
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        for loaded in 1..<5 {
            // Scroll to the end of the newest chapter, then load the next one.
            let last = subject.viewModel.flatPages.last!
            subject.viewModel.continuousPageAppeared(last)
            for passed in subject.viewModel.flatPages where passed.id != last.id {
                subject.viewModel.continuousPageDisappeared(passed)
            }
            subject.viewModel.appendNextChapter()
            await waitForReader { subject.viewModel.flatPages.last?.chapter.key == "c\(loaded + 1)" }
        }

        XCTAssertEqual(
            subject.viewModel.segments.map { $0.chapter.key },
            ["c2", "c3", "c4", "c5"]
        )
        // The reader stays on the same page after the chapter above it is dropped.
        XCTAssertEqual(subject.viewModel.flatPages[subject.viewModel.continuousPageIndex].id, "c4#1")
        XCTAssertEqual(
            subject.viewModel.scrollTarget,
            MangaScrollRequest(pageID: "c4#1", animated: false)
        )
    }

    func testContinuousPrependFailureCleansOperationAndAllowsRetry() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: b, viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0)]), for: "b")
        subject.loader.enqueue(.failure(MangaReaderTestError.expected), for: "a")
        subject.loader.enqueue(.pages([page(1)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        subject.viewModel.prependPreviousChapter()
        await waitForReader { !subject.viewModel.loadingPrevChapter }
        XCTAssertEqual(subject.viewModel.segments.count, 1)
        subject.viewModel.prependPreviousChapter()
        await waitForReader { subject.viewModel.segments.count == 2 }

        XCTAssertEqual(subject.loader.callCount(for: "a"), 2)
        XCTAssertEqual(subject.viewModel.segments.map { $0.chapter.key }, ["a", "b"])
    }

    func testStalePrependCannotMutateAfterModeChange() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: b, viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0)]), for: "b")
        subject.loader.enqueue(.suspended, for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        subject.viewModel.prependPreviousChapter()
        await waitForReader { subject.loader.pendingCount(for: "a") == 1 }

        subject.viewModel.setViewerOverride(.Rtl)
        subject.loader.resolveFirst(for: "a", with: .success([page(2)]))
        await yieldReaderTasks()

        XCTAssertTrue(subject.viewModel.isPaged)
        XCTAssertEqual(subject.viewModel.segments.map { $0.chapter.key }, ["b"])
        XCTAssertFalse(subject.viewModel.loadingPrevChapter)
    }

    func testVisibleContinuousChapterTransitionOpensThenPrefetches() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(
            chapters: [a, b],
            initial: a,
            viewer: .Vertical,
            preload: 2
        )
        subject.loader.enqueue(.pages([page(0)]), for: "a")
        subject.loader.enqueue(
            .pages([
                page(0, url: "https://example.com/b0"),
                page(1, url: "https://example.com/b1"),
                page(2, url: "https://example.com/b2")
            ]),
            for: "b"
        )
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        // A one-page chapter is finished as soon as it is shown.
        await waitForReader { subject.progress.requests.count == 1 }
        subject.viewModel.appendNextChapter()
        await waitForReader { subject.viewModel.segments.count == 2 }

        let firstB = subject.viewModel.flatPages.first { $0.chapter.key == "b" }!
        subject.viewModel.continuousPageAppeared(firstB)
        await yieldReaderTasks()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["a", "b"])
        XCTAssertEqual(subject.progress.requests.map(\.chapterID), ["a"])
        XCTAssertEqual(subject.imagePrefetcher.batches.last?.map(\.index), [1, 2])

        let lastB = subject.viewModel.flatPages.last { $0.chapter.key == "b" }!
        subject.viewModel.continuousPageAppeared(lastB)
        await waitForReader { subject.progress.requests.count == 2 }
        XCTAssertEqual(subject.progress.requests.map(\.chapterID), ["a", "b"])
    }

    func testViewerPrecedenceAndModeClassification() {
        let mangaDefault = makeSubject(chapters: [makeChapter("a", number: 1)])
        XCTAssertEqual(mangaDefault.viewModel.activeViewer, .Rtl)
        XCTAssertTrue(MangaReaderViewModel.isPagedViewer(.Default))
        XCTAssertTrue(MangaReaderViewModel.isPagedViewer(.Ltr))
        XCTAssertTrue(MangaReaderViewModel.isPagedViewer(.Rtl))
        XCTAssertFalse(MangaReaderViewModel.isPagedViewer(.Vertical))
        XCTAssertFalse(MangaReaderViewModel.isPagedViewer(.Webtoon))

        let mangaLTR = makeSubject(
            chapters: [makeChapter("a", number: 1)],
            viewer: .Ltr
        )
        XCTAssertEqual(mangaLTR.viewModel.activeViewer, .Ltr)
        mangaLTR.viewModel.setViewerOverride(.Webtoon)
        XCTAssertEqual(mangaLTR.viewModel.activeViewer, .Webtoon)
    }

    func testContinuousToPagedUsesCurrentFlatPageIndex() async {
        let subject = makeSubject(
            chapters: [makeChapter("a", number: 1)],
            viewer: .Vertical
        )
        subject.loader.enqueue(.pages([page(4), page(9)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        subject.viewModel.continuousPageAppeared(subject.viewModel.flatPages[1])

        subject.viewModel.setViewerOverride(.Rtl)

        XCTAssertTrue(subject.viewModel.isPaged)
        XCTAssertEqual(subject.viewModel.pagedPages.map(\.index), [4, 9])
        XCTAssertEqual(subject.viewModel.pagedIndex, 1)
    }

    func testContinuousToPagedProjectionDoesNotStartAdjacentRunnerWork() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a, viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        subject.viewModel.setViewerOverride(.Rtl)
        await yieldReaderTasks()

        XCTAssertTrue(subject.viewModel.isPaged)
        XCTAssertEqual(subject.loader.requestedChapterKeys, ["a"])
        XCTAssertTrue(subject.viewModel.prefetchedChapters.isEmpty)
    }

    func testContinuousToPagedMismatchedFlatPageFallsBackToFirstPage() {
        let current = makeChapter("a", number: 1)
        let other = makeChapter("b", number: 2)
        let currentPages = [page(4), page(9)]
        let projection = MangaReaderViewModel.pagedProjection(
            currentChapter: current,
            segments: [ChapterSegment(chapter: current, pages: currentPages)],
            flatPages: [
                FlatPage(
                    id: "b_7",
                    segmentIndex: 1,
                    chapter: other,
                    page: page(7),
                    globalIndex: 0
                )
            ],
            continuousPageIndex: 0
        )

        XCTAssertEqual(projection?.pages.map(\.index), [4, 9])
        XCTAssertEqual(projection?.index, 0)
    }

    func testContinuousToPagedOutOfRangeFallsBackToFirstPage() {
        let current = makeChapter("a", number: 1)
        let currentPages = [page(4), page(9)]
        let projection = MangaReaderViewModel.pagedProjection(
            currentChapter: current,
            segments: [ChapterSegment(chapter: current, pages: currentPages)],
            flatPages: [],
            continuousPageIndex: 12
        )

        XCTAssertEqual(projection?.pages.map(\.index), [4, 9])
        XCTAssertEqual(projection?.index, 0)
    }

    func testContinuousToPagedMissingSegmentStartsPagedReload() async {
        let subject = makeSubject(
            chapters: [makeChapter("a", number: 1)],
            viewer: .Vertical
        )
        subject.loader.enqueue(.pages([page(8), page(3)]), for: "a")

        subject.viewModel.setViewerOverride(.Rtl)
        await waitForReader { subject.viewModel.loadPhase == .content }

        XCTAssertTrue(subject.viewModel.isPaged)
        XCTAssertEqual(subject.loader.callCount(for: "a"), 1)
        XCTAssertEqual(subject.viewModel.pagedPages.map(\.index), [3, 8])
        XCTAssertEqual(subject.viewModel.pagedIndex, 0)
    }

    func testPagedToContinuousMapsIndexAndFallsBackToZeroWhenAbsent() async {
        let mapped = makeSubject(chapters: [makeChapter("a", number: 1)])
        mapped.loader.enqueue(.pages([page(0), page(1)]), for: "a")
        mapped.viewModel.start()
        await waitForReader { mapped.viewModel.loadPhase == .content }
        mapped.viewModel.setPagedIndex(1)
        mapped.viewModel.setViewerOverride(.Vertical)
        XCTAssertEqual(mapped.viewModel.continuousPageIndex, 1)
        XCTAssertEqual(
            mapped.viewModel.scrollTarget,
            MangaScrollRequest(pageID: "a#1", animated: false)
        )

        let fallback = makeSubject(chapters: [makeChapter("a", number: 1)])
        fallback.loader.enqueue(.pages([page(2), page(4)]), for: "a")
        fallback.viewModel.start()
        await waitForReader { fallback.viewModel.loadPhase == .content }
        fallback.viewModel.setViewerOverride(.Vertical)
        XCTAssertEqual(fallback.viewModel.continuousPageIndex, 0)
        XCTAssertEqual(
            fallback.viewModel.scrollTarget,
            MangaScrollRequest(pageID: "a#0", animated: false)
        )
    }

    func testModeChangeWithoutAvailablePagesReloadsAndRejectsOldModeResult() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)])
        subject.loader.enqueue(.suspended, for: "a")
        subject.loader.enqueue(.pages([page(6)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.loader.pendingCount(for: "a") == 1 }

        subject.viewModel.setViewerOverride(.Vertical)
        await waitForReader {
            !subject.viewModel.isPaged && subject.viewModel.loadPhase == .content
        }
        subject.loader.resolveFirst(for: "a", with: .success([page(99)]))
        await yieldReaderTasks()

        XCTAssertEqual(subject.loader.callCount(for: "a"), 2)
        XCTAssertEqual(subject.viewModel.segments[0].pages.map(\.index), [6])
    }

    func testLocalProgressFailureKeepsMarkedTimingAndBlocksTracker() async {
        let chapter = makeChapter("a", number: 4)
        let subject = makeSubject(chapters: [chapter])
        subject.progress.error = MangaReaderTestError.expected

        subject.viewModel.markChapterFinished(chapter)
        XCTAssertTrue(subject.viewModel.markedChapterKeys.contains("a"))
        await waitForReader { subject.progress.requests.count == 1 }

        XCTAssertTrue(subject.tracker.requests.isEmpty)
        XCTAssertEqual(subject.viewModel.loadPhase, .idle)
    }

    func testRepeatedFinishSuppressesLocalAndTracker() async {
        let chapter = makeChapter("a", number: 4)
        let subject = makeSubject(chapters: [chapter])

        subject.viewModel.markChapterFinished(chapter)
        await waitForReader { subject.tracker.requests.count == 1 }
        subject.viewModel.markChapterFinished(chapter)
        await yieldReaderTasks()

        XCTAssertEqual(subject.progress.requests.count, 1)
        XCTAssertEqual(subject.tracker.requests.count, 1)
    }

    func testNilChapterNumberUsesLeadingTitleNumberWithoutJoiningDecimals() async {
        let chapter = makeChapter("a", number: nil, title: "Chapter 12.5 Extra")
        let subject = makeSubject(chapters: [chapter])

        subject.viewModel.markChapterFinished(chapter)
        await waitForReader { subject.tracker.requests.count == 1 }

        XCTAssertNil(subject.progress.requests[0].chapterNumber)
        XCTAssertEqual(subject.tracker.requests[0].progress, 12)
    }

    func testDiscordLifecycleUsesCanonicalMetadataAndTimerSemantics() {
        let a = makeChapter("a", number: 1, title: nil, scanlator: "Group")
        let b = makeChapter("b", number: 2, title: "Second")
        let subject = makeSubject(chapters: [a, b], initial: a, cover: "cover")
        let identity = MediaIdentity(pluginId: "plugin.test", itemId: "manga")
        subject.tracker.anilistIDs[identity] = "123"
        subject.metadata.names["plugin.test"] = "Plugin Name"

        subject.viewModel.appear()
        let initial = subject.presence.presented[0]
        XCTAssertEqual(initial.details, "Manga")
        XCTAssertEqual(initial.state, "Reading Chapter 1.0")
        XCTAssertEqual(initial.activityType, 3)
        XCTAssertEqual(initial.detailsURL, "https://anilist.co/manga/123")
        XCTAssertEqual(initial.largeImageText, "Reading from Group at Plugin Name")
        XCTAssertEqual(initial.imageURL, "cover")
        XCTAssertTrue(initial.resetTimer)

        subject.viewModel.goToNextChapter()
        XCTAssertEqual(subject.presence.presented.last?.state, "Reading Second")
        XCTAssertEqual(subject.presence.presented.last?.resetTimer, false)
        let countAfterChange = subject.presence.presented.count
        subject.viewModel.markChapterFinished(b)
        XCTAssertEqual(subject.presence.presented.count, countAfterChange)
        subject.viewModel.disappear()
        XCTAssertEqual(subject.presence.events.last, .clear)
    }

    func testDiscordFallbacksOmitTrackingURL() {
        let chapter = makeChapter("a", number: nil, title: nil, scanlator: nil)
        let subject = makeSubject(chapters: [chapter])

        subject.viewModel.appear()
        let activity = subject.presence.presented[0]

        XCTAssertNil(activity.detailsURL)
        XCTAssertEqual(activity.largeImageText, "Reading from Official at Unknown Plugin")
    }

    func testPagedImagePrefetchUsesExactAheadWindowAndURLFiltering() async {
        let subject = makeSubject(
            chapters: [makeChapter("a", number: 1)],
            preload: 3
        )
        subject.loader.enqueue(
            .pages([
                page(0, url: "https://example.com/0"),
                page(1, text: "text"),
                page(
                    2,
                    url: "https://example.com/2",
                    headers: ["Authorization": "fixture"]
                ),
                page(3, url: ""),
                page(4, url: "https://example.com/4")
            ]),
            for: "a"
        )
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        subject.viewModel.setPagedIndex(0)

        XCTAssertEqual(subject.imagePrefetcher.batches.count, 1)
        XCTAssertEqual(subject.imagePrefetcher.batches[0].map(\.index), [2])
        XCTAssertEqual(
            subject.imagePrefetcher.batches[0][0].headers,
            ["Authorization": "fixture"]
        )
    }

    func testContinuousImagePrefetchKeepsOrderAndDuplicates() async {
        let duplicateURL = "https://example.com/same"
        let subject = makeSubject(
            chapters: [makeChapter("a", number: 1)],
            viewer: .Vertical,
            preload: 3
        )
        subject.loader.enqueue(
            .pages([
                page(0, url: "https://example.com/0"),
                page(1, url: duplicateURL),
                page(2, text: "skip"),
                page(3, url: duplicateURL)
            ]),
            for: "a"
        )
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        subject.viewModel.continuousPageAppeared(subject.viewModel.flatPages[0])

        XCTAssertEqual(subject.imagePrefetcher.batches[0].map(\.index), [1, 3])
    }

    func testZeroImagePreloadDisablesPrefetchAndDisappearStopsAdapter() async {
        let subject = makeSubject(
            chapters: [makeChapter("a", number: 1)],
            preload: 0
        )
        subject.loader.enqueue(
            .pages([page(0, url: "https://example.com/0"), page(1, url: "https://example.com/1")]),
            for: "a"
        )
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        subject.viewModel.setPagedIndex(0)
        subject.viewModel.disappear()

        XCTAssertTrue(subject.imagePrefetcher.batches.isEmpty)
        XCTAssertEqual(subject.imagePrefetcher.stopCount, 1)
    }

    func testPreloadPreferenceUsesInjectedSettingsBoundary() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], preload: 5)

        subject.viewModel.setPreloadImageCount(10)
        await waitForReader { subject.viewModel.preloadImageCount == 10 }

        XCTAssertEqual(subject.settings.writtenValues, [10])
    }

    // MARK: - Fixtures

    func makeSubject(
        chapters: [Manga.Chapter],
        initial: Manga.Chapter? = nil,
        viewer: Manga.Viewer = .Default,
        preload: Int = 5,
        cover: String? = nil
    ) -> MangaReaderTestSubject {
        let manga = Manga(
            key: "manga",
            title: "Manga",
            cover: cover,
            viewer: viewer,
            chapters: chapters
        )
        return makeMangaReaderSubject(
            manga: manga,
            initialChapter: initial ?? chapters[0],
            preloadImageCount: preload
        )
    }

    func makeChapter(
        _ key: String,
        number: Float32?,
        title: String? = nil,
        scanlator: String? = nil
    ) -> Manga.Chapter {
        Manga.Chapter(
            key: key,
            title: title,
            chapter: number,
            scanlator: scanlator
        )
    }

    func page(
        _ index: Int32,
        text: String? = nil,
        url: String? = nil,
        headers: [String: String]? = nil
    ) -> Page {
        if let url {
            return Page(index: index, content: .url(url), headers: headers)
        }
        return Page(
            index: index,
            content: .text(text ?? "page-\(index)"),
            headers: headers
        )
    }

    func waitForReader(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for deterministic Reader condition")
    }

    func yieldReaderTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
