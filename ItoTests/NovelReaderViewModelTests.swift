import XCTest
import ito_runner
@testable import Ito

@MainActor
final class NovelReaderViewModelTests: XCTestCase {
    func testInitialLoadRecordsHistoryAndMarksReadOnlyAtTheEnd() async {
        let chapter = makeChapter("a", number: 12.75)
        let subject = makeSubject(chapters: [chapter], initial: chapter)
        subject.loader.enqueue(
            .pages([page(8), page(2), page(5)]),
            for: "a"
        )
        var phaseAtHistory: NovelReaderLoadPhase?
        var chapterCountAtHistory = 0
        subject.history.onRecord = {
            phaseAtHistory = subject.viewModel.loadPhase
            chapterCountAtHistory = subject.viewModel.loadedChapters.count
        }

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.loadPhase, .content)
        XCTAssertEqual(subject.viewModel.loadedChapters.map { $0.chapter.key }, ["a"])
        XCTAssertEqual(subject.viewModel.loadedChapters[0].pages.map(\.index), [2, 5, 8])
        XCTAssertEqual(phaseAtHistory, .content)
        XCTAssertEqual(chapterCountAtHistory, 1)
        XCTAssertEqual(subject.events.events, ["history:a"])
        XCTAssertEqual(subject.history.requests[0].chapterTitle, "a")
        XCTAssertEqual(subject.history.requests[0].pluginID, "plugin.test")

        let loaded = subject.viewModel.loadedChapters[0]
        subject.viewModel.continuousPageAppeared(chapterID: loaded.id, pageIndex: 2)
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.events.events, ["history:a"])

        subject.viewModel.continuousChapterEndAppeared(chapterID: loaded.id)
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.events.events, ["history:a", "progress:a", "tracker:12"])
        XCTAssertEqual(subject.progress.requests[0].media, mediaIdentity)
        XCTAssertEqual(subject.progress.requests[0].chapterNumber, 12.75)
    }

    func testChapterOpensAtTheSavedOffsetAndSavesNewOffsets() async {
        let chapter = makeChapter("a", number: 1)
        let subject = makeSubject(chapters: [chapter], initial: chapter)
        // Blocks of 10, 20 and 5 characters plus separators start at 0, 12 and 34.
        subject.loader.enqueue(
            .pages([
                page(0, text: String(repeating: "a", count: 10)),
                page(1, text: String(repeating: "b", count: 20)),
                page(2, text: String(repeating: "c", count: 5))
            ]),
            for: "a"
        )
        subject.progress.savedOffsets["a"] = 20

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        let loaded = subject.viewModel.loadedChapters[0]
        XCTAssertEqual(subject.viewModel.restoreAnchor, NovelReadingAnchor(chapterID: loaded.id, offset: 20))
        XCTAssertEqual(NovelTextOffsets.blockIndex(containing: 20, in: loaded.pages), 1)
        subject.viewModel.consumeRestoreAnchor(NovelReadingAnchor(chapterID: loaded.id, offset: 20))
        XCTAssertNil(subject.viewModel.restoreAnchor)

        subject.viewModel.continuousPageAppeared(chapterID: loaded.id, pageIndex: 2)
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.progress.savedOffsetWrites.map(\.offset), [34])
        XCTAssertTrue(subject.progress.requests.isEmpty)
    }

    func testFinishedChapterStartsOverInsteadOfRestoringItsEnd() async {
        let chapter = makeChapter("a", number: 1)
        let subject = makeSubject(chapters: [chapter], initial: chapter)
        subject.loader.enqueue(.pages([page(0, text: "abc")]), for: "a")
        subject.progress.savedOffsets["a"] = 5

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertNil(subject.viewModel.restoreAnchor)
    }

    func testInitialFailureAndRetryReplaceFailureWithOneChapter() async {
        let chapter = makeChapter("a", number: 1)
        let subject = makeSubject(chapters: [chapter], initial: chapter)
        subject.loader.enqueue(.failure(NovelReaderTestError.expected), for: "a")
        subject.loader.enqueue(.pages([page(4)]), for: "a")

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(
            subject.viewModel.loadPhase,
            .failure("expected novel reader failure")
        )
        XCTAssertTrue(subject.viewModel.loadedChapters.isEmpty)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
        XCTAssertTrue(subject.history.requests.isEmpty)

        subject.viewModel.retry()
        subject.viewModel.retry()
        XCTAssertEqual(subject.viewModel.loadPhase, .loading)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.loader.callCount(for: "a"), 2)
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
        XCTAssertEqual(subject.viewModel.loadedChapters.count, 1)
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["a"])
    }

    func testDuplicateStartDoesNotOverlapSuspendedInitialLoad() async {
        let chapter = makeChapter("a", number: 1)
        let subject = makeSubject(chapters: [chapter], initial: chapter)
        subject.loader.enqueue(.suspended, for: "a")

        subject.viewModel.start()
        subject.viewModel.start()
        await subject.loader.waitForPendingCount(1, for: "a")
        subject.viewModel.start()

        XCTAssertEqual(subject.loader.callCount(for: "a"), 1)
        subject.loader.resolveFirst(for: "a", with: .success([page(1)]))
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
    }

    func testPageOrderingRetainsDuplicateContentHeadersAndDoesNotMutateInput() async {
        let chapter = makeChapter("a", number: 1)
        let subject = makeSubject(chapters: [chapter], initial: chapter)
        let original = [
            page(9, url: "page-secret", headers: ["Auth": "header-secret"]),
            page(2, text: "first"),
            page(2, text: "second")
        ]
        subject.loader.enqueue(.pages(original), for: "a")

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        let result = subject.viewModel.loadedChapters[0].pages
        XCTAssertEqual(original.map(\.index), [9, 2, 2])
        XCTAssertEqual(result.map(\.index), [2, 2, 9])
        XCTAssertEqual(result.last?.headers, ["Auth": "header-secret"])
        if case .url(let value) = result.last?.content {
            XCTAssertEqual(value, "page-secret")
        } else {
            XCTFail("Expected URL page")
        }
    }

    func testDirectNavigationMutatesPresenceAndClearsChainBeforeLoadThenTracksAfterSuccess() async {
        let a = makeChapter("a", number: 1, title: "A")
        let b = makeChapter("b", number: 2, title: "B")
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.pages([page(1)]), for: "a")
        subject.viewModel.start()
        subject.viewModel.appear()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.loader.enqueue(.suspended, for: "b")

        subject.viewModel.goToNextChapter()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        XCTAssertTrue(subject.viewModel.loadedChapters.isEmpty)
        XCTAssertEqual(subject.viewModel.loadPhase, .loading)
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["a"])
        XCTAssertEqual(subject.presence.presented.last?.state, "Reading B")
        XCTAssertEqual(subject.presence.presented.last?.resetTimer, false)

        await subject.loader.waitForPendingCount(1, for: "b")
        subject.loader.resolveFirst(for: "b", with: .success([page(7)]))
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["a", "b"])
    }

    func testDirectNavigationReloadsAlreadyAppendedChapterInsteadOfReusingIt() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.pages([page(1)]), for: "a")
        subject.loader.enqueue(.pages([page(2)]), for: "b")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.loadNextChapter()
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.viewModel.loadedChapters.count, 2)
        subject.loader.enqueue(.pages([page(9)]), for: "b")

        subject.viewModel.goToChapter(b)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.loader.callCount(for: "b"), 2)
        XCTAssertEqual(subject.viewModel.loadedChapters.count, 1)
        XCTAssertEqual(subject.viewModel.loadedChapters[0].pages.map(\.index), [9])
    }

    func testLateInitialSuccessCannotReplaceDirectNavigation() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.suspended, for: "a")
        subject.loader.enqueue(.pages([page(7)]), for: "b")
        subject.viewModel.start()
        await subject.loader.waitForPendingCount(1, for: "a")

        subject.viewModel.goToChapter(b)
        await subject.viewModel.waitForCurrentMainLoadForTesting()
        subject.loader.resolveFirst(for: "a", with: .success([page(1)]))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        XCTAssertEqual(subject.viewModel.loadedChapters[0].chapter.key, "b")
        XCTAssertEqual(subject.viewModel.loadedChapters[0].pages.map(\.index), [7])
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["b"])
        XCTAssertTrue(hasFinishedOutcome(.ignoredStale, in: subject.logger.events))
    }

    func testLateInitialErrorCannotReplaceNewerContent() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.suspended, for: "a")
        subject.loader.enqueue(.pages([page(7)]), for: "b")
        subject.viewModel.start()
        await subject.loader.waitForPendingCount(1, for: "a")
        subject.viewModel.goToChapter(b)
        await subject.viewModel.waitForCurrentMainLoadForTesting()

        subject.loader.resolveFirst(for: "a", with: .failure(NovelReaderTestError.expected))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.loadPhase, .content)
        XCTAssertEqual(subject.viewModel.loadedChapters[0].chapter.key, "b")
    }

    func testSupersededRetryCannotPublishOverDirectNavigation() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.failure(NovelReaderTestError.expected), for: "a")
        subject.loader.enqueue(.suspended, for: "a")
        subject.loader.enqueue(.pages([page(8)]), for: "b")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.retry()
        await subject.loader.waitForPendingCount(1, for: "a")

        subject.viewModel.goToChapter(b)
        await subject.viewModel.waitForCurrentMainLoadForTesting()
        subject.loader.resolveFirst(for: "a", with: .success([page(2)]))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        XCTAssertEqual(subject.viewModel.loadedChapters[0].pages.map(\.index), [8])
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["b"])
    }

    func testRapidDirectNavigationRejectsLateIntermediateSuccess() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let c = makeChapter("c", number: 3)
        let subject = makeSubject(chapters: [a, b, c], initial: a)
        subject.loader.enqueue(.pages([page(1)]), for: "a")
        subject.loader.enqueue(.suspended, for: "b")
        subject.loader.enqueue(.pages([page(30)]), for: "c")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        subject.viewModel.goToChapter(b)
        await subject.loader.waitForPendingCount(1, for: "b")
        subject.viewModel.goToChapter(c)
        await subject.viewModel.waitForCurrentMainLoadForTesting()
        subject.loader.resolveFirst(for: "b", with: .success([page(20)]))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "c")
        XCTAssertEqual(subject.viewModel.loadedChapters.map { $0.chapter.key }, ["c"])
        XCTAssertEqual(subject.viewModel.loadedChapters[0].pages.map(\.index), [30])
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["a", "c"])
    }

    func testRapidDirectNavigationRejectsLateIntermediateFailure() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let c = makeChapter("c", number: 3)
        let subject = makeSubject(chapters: [a, b, c], initial: a)
        subject.loader.enqueue(.pages([page(1)]), for: "a")
        subject.loader.enqueue(.suspended, for: "b")
        subject.loader.enqueue(.pages([page(30)]), for: "c")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        subject.viewModel.goToChapter(b)
        await subject.loader.waitForPendingCount(1, for: "b")
        subject.viewModel.goToChapter(c)
        await subject.viewModel.waitForCurrentMainLoadForTesting()
        subject.loader.resolveFirst(for: "b", with: .failure(NovelReaderTestError.expected))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.loadPhase, .content)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "c")
        XCTAssertEqual(subject.viewModel.loadedChapters.map { $0.chapter.key }, ["c"])
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["a", "c"])
    }

    func testAppendSortsSuppressesDuplicatesAndDoesNotTrackOrChangeCurrentChapter() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.pages([page(1)]), for: "a")
        subject.loader.enqueue(.suspended, for: "b")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        let baselineEffects = subject.history.requests.count

        subject.viewModel.loadNextChapter()
        subject.viewModel.loadNextChapter()
        await subject.loader.waitForPendingCount(1, for: "b")
        XCTAssertTrue(subject.viewModel.isLoadingNext)
        XCTAssertEqual(subject.loader.callCount(for: "b"), 1)
        subject.loader.resolveFirst(for: "b", with: .success([page(7), page(3)]))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.loadedChapters.map { $0.chapter.key }, ["a", "b"])
        XCTAssertEqual(subject.viewModel.loadedChapters[1].pages.map(\.index), [3, 7])
        XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
        XCTAssertEqual(subject.history.requests.count, baselineEffects)
        XCTAssertFalse(subject.viewModel.isLoadingNext)

        let appendEvents = subject.logger.events.filter { $0.kind == .chapterAppend }
        XCTAssertEqual(appendEvents.count, 2)
        XCTAssertEqual(appendEvents[0].phase, .started)
        XCTAssertEqual(appendEvents[1].phase, .finished)
        XCTAssertEqual(appendEvents[1].outcome, .succeeded)
        XCTAssertEqual(appendEvents[0].operationID, appendEvents[1].operationID)
    }

    func testAppendAtEndIsNoOp() async {
        let a = makeChapter("a", number: 1)
        let subject = makeSubject(chapters: [a], initial: a)
        subject.loader.enqueue(.pages([page(1)]), for: "a")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        subject.viewModel.loadNextChapter()

        XCTAssertEqual(subject.loader.requests.map { $0.chapter.key }, ["a"])
        XCTAssertFalse(subject.viewModel.isLoadingNext)
        XCTAssertEqual(subject.viewModel.loadedChapters.count, 1)
    }

    func testAppendOnTheNewestChapterDoesNotLoadTheOneBeforeIt() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        // Plugins list chapters newest first.
        let subject = makeSubject(chapters: [b, a], initial: b)
        subject.loader.enqueue(.pages([page(1)]), for: "b")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertNil(subject.viewModel.chapterAfter(b))
        subject.viewModel.loadNextChapter()

        XCTAssertEqual(subject.loader.requests.map { $0.chapter.key }, ["b"])
        XCTAssertEqual(subject.viewModel.loadedChapters.map { $0.chapter.key }, ["b"])
    }

    func testAppendFailureKeepsContentAndWaitsForAnExplicitRetry() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.pages([page(1)]), for: "a")
        subject.loader.enqueue(.failure(NovelReaderTestError.expected), for: "b")
        subject.loader.enqueue(.pages([page(2)]), for: "b")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        subject.viewModel.loadNextChapter()
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
        XCTAssertEqual(subject.viewModel.loadedChapters.map { $0.chapter.key }, ["a"])
        XCTAssertFalse(subject.viewModel.isLoadingNext)
        XCTAssertTrue(subject.viewModel.appendFailed)

        // Scrolling to the end or turning pages again does not retry by itself.
        subject.viewModel.loadNextChapter()
        XCTAssertEqual(subject.loader.callCount(for: "b"), 1)

        subject.viewModel.retryNextChapter()
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.loader.callCount(for: "b"), 2)
        XCTAssertFalse(subject.viewModel.appendFailed)
        XCTAssertEqual(subject.viewModel.loadedChapters.map { $0.chapter.key }, ["a", "b"])
    }

    func testScrollingBackUpIntoAnEarlierChapterMakesItCurrent() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.loader.enqueue(.pages([page(1), page(2)]), for: "a")
        subject.loader.enqueue(.pages([page(1), page(2)]), for: "b")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.loadNextChapter()
        await subject.viewModel.waitForAllOperationsForTesting()
        let chapterA = subject.viewModel.loadedChapters[0]
        let chapterB = subject.viewModel.loadedChapters[1]

        // Read down into b: a's text leaves the screen, b's heading and text are on it.
        subject.viewModel.continuousPageAppeared(chapterID: chapterA.id, pageIndex: 1)
        subject.viewModel.continuousChapterTitleAppeared(chapterB)
        subject.viewModel.continuousPageDisappeared(chapterID: chapterA.id, pageIndex: 1)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")

        // Scroll back up until only a's last paragraph and b's heading are on screen.
        subject.viewModel.continuousPageAppeared(chapterID: chapterA.id, pageIndex: 1)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
    }

    func testAppendStartedForOldChainCannotAppendAfterDirectNavigation() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let c = makeChapter("c", number: 3)
        let subject = makeSubject(chapters: [a, b, c], initial: a)
        subject.loader.enqueue(.pages([page(1)]), for: "a")
        subject.loader.enqueue(.suspended, for: "b")
        subject.loader.enqueue(.pages([page(30)]), for: "c")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.loadNextChapter()
        await subject.loader.waitForPendingCount(1, for: "b")

        subject.viewModel.goToChapter(c)
        await subject.viewModel.waitForCurrentMainLoadForTesting()
        subject.loader.resolveFirst(for: "b", with: .success([page(20)]))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.loadedChapters.map { $0.chapter.key }, ["c"])
        XCTAssertEqual(subject.viewModel.currentChapter.key, "c")
    }

    func testAppendRemainsValidAcrossSameChainCurrentChapterTransition() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let c = makeChapter("c", number: 3)
        let subject = makeSubject(chapters: [a, b, c], initial: a)
        subject.loader.enqueue(.pages([page(1)]), for: "a")
        subject.loader.enqueue(.pages([page(2)]), for: "b")
        subject.loader.enqueue(.suspended, for: "c")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.loadNextChapter()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.loadNextChapter()
        await subject.loader.waitForPendingCount(1, for: "c")

        subject.viewModel.pagedChapterChanged(subject.viewModel.loadedChapters[1].chapter)
        subject.loader.resolveFirst(for: "c", with: .success([page(3)]))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        XCTAssertEqual(subject.viewModel.loadedChapters.map { $0.chapter.key }, ["a", "b", "c"])
    }

    func testContinuousPrefetchThresholdAndDuplicateSuppression() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let c = makeChapter("c", number: 3)
        let subject = makeSubject(chapters: [a, b, c], initial: a)
        subject.loader.enqueue(.pages((0...5).map { page(Int32($0)) }), for: "a")
        subject.loader.enqueue(.pages((0...5).map { page(Int32($0)) }), for: "b")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.loadNextChapter()
        await subject.viewModel.waitForAllOperationsForTesting()
        let firstID = subject.viewModel.loadedChapters[0].id
        let lastID = subject.viewModel.loadedChapters[1].id
        subject.loader.enqueue(.suspended, for: "c")

        subject.viewModel.continuousPageAppeared(chapterID: firstID, pageIndex: 5)
        subject.viewModel.continuousPageAppeared(chapterID: lastID, pageIndex: 0)
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.loader.callCount(for: "c"), 0)

        subject.viewModel.continuousPageAppeared(chapterID: lastID, pageIndex: 1)
        subject.viewModel.continuousPageAppeared(chapterID: lastID, pageIndex: 5)
        await subject.loader.waitForPendingCount(1, for: "c")
        XCTAssertEqual(subject.loader.callCount(for: "c"), 1)
        subject.loader.resolveFirst(for: "c", with: .success([page(1)]))
        await subject.viewModel.waitForAllOperationsForTesting()
    }

    func testContinuousPrefetchDisabledAndShortChapterThreshold() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let disabled = makeSubject(
            chapters: [a, b],
            initial: a,
            settings: settings(prefetch: false)
        )
        disabled.loader.enqueue(.pages([page(0)]), for: "a")
        disabled.viewModel.start()
        await disabled.viewModel.waitForAllOperationsForTesting()
        disabled.viewModel.continuousPageAppeared(
            chapterID: disabled.viewModel.loadedChapters[0].id,
            pageIndex: 0
        )
        await disabled.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(disabled.loader.callCount(for: "b"), 0)

        let short = makeSubject(chapters: [a, b], initial: a)
        short.loader.enqueue(.pages([page(0), page(1)]), for: "a")
        short.loader.enqueue(.suspended, for: "b")
        short.viewModel.start()
        await short.viewModel.waitForAllOperationsForTesting()
        short.viewModel.continuousPageAppeared(
            chapterID: short.viewModel.loadedChapters[0].id,
            pageIndex: 0
        )
        await short.loader.waitForPendingCount(1, for: "b")
        XCTAssertEqual(short.loader.callCount(for: "b"), 1)
        short.loader.resolveFirst(for: "b", with: .success([]))
        await short.viewModel.waitForAllOperationsForTesting()
    }

    func testContinuousTitleTransitionRecordsHistoryOnce() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = await loadedTwoChapterSubject(a: a, b: b)
        subject.viewModel.appear()
        let baseline = subject.history.requests.count
        let loadedB = subject.viewModel.loadedChapters[1]

        subject.viewModel.continuousChapterTitleAppeared(loadedB)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        XCTAssertEqual(subject.history.requests.count, baseline + 1)
        XCTAssertFalse(subject.progress.requests.contains { $0.chapterID == "b" })
        XCTAssertEqual(subject.presence.presented.last?.resetTimer, false)

        subject.viewModel.continuousChapterTitleAppeared(loadedB)
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.history.requests.count, baseline + 1)
    }

    func testPagerTransitionRecordsHistoryWithoutProgressOrTracker() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = await loadedTwoChapterSubject(a: a, b: b)
        subject.viewModel.appear()
        let historyCount = subject.history.requests.count
        let progressCount = subject.progress.requests.count
        let trackerCount = subject.tracker.requests.count

        subject.viewModel.pagedChapterChanged(subject.viewModel.loadedChapters[1].chapter)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        XCTAssertEqual(subject.presence.presented.last?.resetTimer, false)
        XCTAssertEqual(subject.history.requests.count, historyCount + 1)
        XCTAssertEqual(subject.progress.requests.count, progressCount)
        XCTAssertEqual(subject.tracker.requests.count, trackerCount)
    }

    func testLocalProgressFailureKeepsContentAndBlocksTracker() async {
        let chapter = makeChapter("a", number: 4)
        let subject = makeSubject(chapters: [chapter], initial: chapter)
        subject.progress.enqueue(.failure(NovelReaderTestError.expected))
        subject.loader.enqueue(.pages([page(1)]), for: "a")

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.readingPositionChanged(
            chapterID: subject.viewModel.loadedChapters[0].id,
            offset: 0,
            reachedEnd: true
        )
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.loadPhase, .content)
        XCTAssertEqual(subject.history.requests.count, 1)
        XCTAssertEqual(subject.progress.requests.count, 1)
        XCTAssertTrue(subject.tracker.requests.isEmpty)
        XCTAssertEqual(subject.events.events, ["history:a", "progress:a"])
    }

    func testRepeatedFinishInOneSessionMarksOnce() async {
        let chapter = makeChapter("a", number: 4)
        let subject = makeSubject(chapters: [chapter], initial: chapter)

        subject.viewModel.markChapterFinished(chapter)
        subject.viewModel.markChapterFinished(chapter)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.progress.requests.count, 1)
        XCTAssertEqual(subject.tracker.requests.map(\.progress), [4])
    }

    func testNilChapterNumberUsesLeadingTitleNumberWithoutJoiningDecimals() async {
        let chapter = makeChapter("ignored", number: nil, title: "Chapter 12.5 Extra")
        let subject = makeSubject(chapters: [chapter], initial: chapter)

        subject.viewModel.markChapterFinished(chapter)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertNil(subject.progress.requests[0].chapterNumber)
        XCTAssertEqual(subject.tracker.requests.map(\.progress), [12])
    }

    func testSettingsInitializeAndAllWritesPublishCanonicalValuesWithoutReaderWork() async {
        let chapter = makeChapter("a", number: 1)
        let subject = makeSubject(
            chapters: [chapter],
            initial: chapter,
            settings: NovelReaderSettingsSnapshot(
                fontSize: 22,
                lineSpacing: 11,
                fontFamily: .serif,
                theme: .sepia,
                isPaging: true,
                prefetchChapters: false
            )
        )
        XCTAssertEqual(subject.viewModel.fontSize, 22)
        XCTAssertEqual(subject.viewModel.lineSpacing, 11)
        XCTAssertEqual(subject.viewModel.fontFamily, .serif)
        XCTAssertEqual(subject.viewModel.theme, .sepia)
        XCTAssertTrue(subject.viewModel.isPaging)
        XCTAssertFalse(subject.viewModel.prefetchChapters)

        subject.viewModel.setFontSize(24)
        subject.viewModel.setLineSpacing(12)
        subject.viewModel.setFontFamily(.rounded)
        subject.viewModel.setTheme(.mint)
        subject.viewModel.setIsPaging(false)
        subject.viewModel.setPrefetchChapters(true)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.fontSize, 24)
        XCTAssertEqual(subject.viewModel.lineSpacing, 12)
        XCTAssertEqual(subject.viewModel.fontFamily, .rounded)
        XCTAssertEqual(subject.viewModel.theme, .mint)
        XCTAssertFalse(subject.viewModel.isPaging)
        XCTAssertTrue(subject.viewModel.prefetchChapters)
        XCTAssertTrue(subject.loader.requests.isEmpty)
        XCTAssertTrue(subject.history.requests.isEmpty)
    }

    func testFailedSettingWriteShowsTheChoiceThenPutsBackTheSavedValue() async {
        let chapter = makeChapter("a", number: 1)
        let subject = makeSubject(chapters: [chapter], initial: chapter)
        subject.settings.enqueue(.failure(NovelReaderTestError.expected), for: .fontSize)

        subject.viewModel.setFontSize(30)
        XCTAssertEqual(subject.viewModel.fontSize, 30)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.fontSize, 18)
        XCTAssertEqual(subject.settings.writes, [.fontSize(30)])
        XCTAssertTrue(hasFinishedOutcome(.failed(.persistence), in: subject.logger.events))
    }

    func testQuickSettingChangesBuildOnEachOtherAndSaveInOrder() async {
        let chapter = makeChapter("a", number: 1)
        let subject = makeSubject(chapters: [chapter], initial: chapter)
        subject.settings.enqueue(.suspended, for: .fontSize)
        subject.settings.enqueue(.success, for: .fontSize)

        // Two A+ taps before the first save finishes: the second starts from the first.
        subject.viewModel.setFontSize(subject.viewModel.fontSize + 2)
        subject.viewModel.setFontSize(subject.viewModel.fontSize + 2)
        XCTAssertEqual(subject.viewModel.fontSize, 22)
        await subject.settings.waitForPendingCount(1, for: .fontSize)
        XCTAssertEqual(subject.settings.writes, [.fontSize(20)])

        subject.settings.resolveFirst(for: .fontSize)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.settings.writes, [.fontSize(20), .fontSize(22)])
        XCTAssertEqual(subject.viewModel.fontSize, 22)
    }

    func testFontSizeStaysWithinTheOfferedRange() async {
        let chapter = makeChapter("a", number: 1)
        let subject = makeSubject(chapters: [chapter], initial: chapter)

        subject.viewModel.setFontSize(100)
        XCTAssertEqual(subject.viewModel.fontSize, 40)
        subject.viewModel.setFontSize(2)
        XCTAssertEqual(subject.viewModel.fontSize, 10)
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.settings.writes, [.fontSize(40), .fontSize(10)])
    }

    func testDisappearCancelsRetainedSettingWriteAndRejectsDismissedPresentationUpdate() async {
        let chapter = makeChapter("a", number: 1)
        let subject = makeSubject(chapters: [chapter], initial: chapter)
        subject.settings.enqueue(.suspended, for: .fontSize)

        subject.viewModel.setFontSize(30)
        await subject.settings.waitForPendingCount(1, for: .fontSize)
        subject.viewModel.disappear()
        subject.settings.resolveFirst(for: .fontSize)
        await subject.viewModel.waitForAllOperationsForTesting()

        let events = subject.logger.events.filter { $0.kind == .preferenceWrite }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].phase, .started)
        XCTAssertEqual(events[1].phase, .finished)
        XCTAssertEqual(events[1].outcome, .cancelled)
        XCTAssertEqual(events[0].operationID, events[1].operationID)
    }

    func testPagingAndRenderingSettingsDoNotReloadOrTrack() async {
        let chapter = makeChapter("a", number: 1)
        let subject = makeSubject(chapters: [chapter], initial: chapter)
        subject.loader.enqueue(.pages([page(1)]), for: "a")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        let loadedID = subject.viewModel.loadedChapters[0].id
        let loadCount = subject.loader.requests.count
        let effectCount = subject.history.requests.count

        subject.viewModel.setIsPaging(true)
        subject.viewModel.setFontSize(20)
        subject.viewModel.setLineSpacing(10)
        subject.viewModel.setFontFamily(.monospaced)
        subject.viewModel.setTheme(.dark)
        subject.viewModel.setPrefetchChapters(false)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.loadedChapters[0].id, loadedID)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
        XCTAssertEqual(subject.loader.requests.count, loadCount)
        XCTAssertEqual(subject.history.requests.count, effectCount)
        XCTAssertTrue(subject.viewModel.isPaging)
        XCTAssertFalse(subject.viewModel.prefetchChapters)
    }

    func testDiscordInitialMappedPresenceTransitionSameKeyAndDisappear() async {
        let a = makeChapter("a", number: 1, title: "Opening", scanlator: "Group")
        let b = makeChapter("b", number: 2, title: "Second")
        let subject = await loadedTwoChapterSubject(a: a, b: b, cover: "https://cover")
        subject.metadata.names["plugin.test"] = "Plugin Name"
        subject.tracker.anilistIDs[mediaIdentity] = "tracker-secret"

        subject.viewModel.appear()
        let initial = subject.presence.presented.last
        XCTAssertEqual(initial?.details, "Novel")
        XCTAssertEqual(initial?.state, "Reading Opening")
        XCTAssertEqual(initial?.activityType, 3)
        XCTAssertEqual(initial?.detailsURL, "https://anilist.co/manga/tracker-secret")
        XCTAssertEqual(initial?.largeImageText, "Reading from Group at Plugin Name")
        XCTAssertEqual(initial?.imageURL, "https://cover")
        XCTAssertEqual(initial?.resetTimer, true)

        subject.viewModel.pagedChapterChanged(subject.viewModel.loadedChapters[1].chapter)
        XCTAssertEqual(subject.presence.presented.last?.resetTimer, false)
        let count = subject.presence.presented.count
        subject.viewModel.pagedChapterChanged(subject.viewModel.loadedChapters[1].chapter)
        XCTAssertEqual(subject.presence.presented.count, count)

        subject.viewModel.disappear()
        XCTAssertEqual(subject.presence.events.last, .clear)
    }

    func testDiscordFallbacksOmitURLAndUseOfficialUnknownPlugin() {
        let chapter = makeChapter("a", number: 3, title: nil, scanlator: nil)
        let subject = makeSubject(chapters: [chapter], initial: chapter)

        subject.viewModel.appear()

        let presence = subject.presence.presented.last
        XCTAssertEqual(presence?.state, "Reading Chapter 3")
        XCTAssertNil(presence?.detailsURL)
        XCTAssertEqual(
            presence?.largeImageText,
            "Reading from Official at Unknown Plugin"
        )
    }

    func testDisappearRejectsNonCooperativeLoadAndReappearRestartsOnce() async {
        let a = makeChapter("a", number: 1)
        let subject = makeSubject(chapters: [a], initial: a)
        subject.loader.enqueue(.suspended, for: "a")
        subject.viewModel.start()
        subject.viewModel.appear()
        await subject.loader.waitForPendingCount(1, for: "a")

        subject.viewModel.disappear()
        subject.loader.enqueue(.pages([page(9)]), for: "a")
        subject.viewModel.appear()
        await subject.viewModel.waitForCurrentMainLoadForTesting()
        subject.loader.resolveFirst(for: "a", with: .success([page(1)]))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.loader.callCount(for: "a"), 2)
        XCTAssertEqual(subject.viewModel.loadedChapters[0].pages.map(\.index), [9])
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["a"])
    }

    func testDisappearRejectsStaleAppendAndCancelsEffectsBeforeTracker() async {
        let a = makeChapter("a", number: 1)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a)
        subject.progress.enqueue(.suspended)
        subject.loader.enqueue(.pages([page(1)]), for: "a")
        subject.loader.enqueue(.suspended, for: "b")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.continuousChapterEndAppeared(
            chapterID: subject.viewModel.loadedChapters[0].id
        )
        await subject.progress.waitForPendingCount(1)
        subject.viewModel.loadNextChapter()
        await subject.loader.waitForPendingCount(1, for: "b")

        subject.viewModel.disappear()
        subject.progress.resolveFirst()
        subject.loader.resolveFirst(for: "b", with: .success([page(2)]))
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.viewModel.loadedChapters.map { $0.chapter.key }, ["a"])
        XCTAssertTrue(subject.tracker.requests.isEmpty)
        XCTAssertFalse(subject.viewModel.isLoadingNext)
        XCTAssertEqual(subject.presence.events.last, .clear)
    }

    func testTypedLoggingCorrelatesSuccessFailureCancellationStaleAndRedactsValues() async {
        let secret = "sentinel-media-chapter-page-header-tracker-scanlator-error"
        let a = makeChapter(secret, number: 1, title: secret, scanlator: secret)
        let b = makeChapter("b", number: 2)
        let subject = makeSubject(chapters: [a, b], initial: a, title: secret, cover: secret)
        subject.loader.enqueue(.suspended, for: secret)
        subject.loader.enqueue(.pages([page(2, url: secret, headers: [secret: secret])]), for: "b")
        subject.viewModel.start()
        await subject.loader.waitForPendingCount(1, for: secret)
        subject.viewModel.goToChapter(b)
        await subject.viewModel.waitForCurrentMainLoadForTesting()
        subject.loader.resolveFirst(for: secret, with: .failure(NovelReaderTestError.secret(secret)))
        await subject.viewModel.waitForAllOperationsForTesting()

        let cancelled = makeSubject(chapters: [b], initial: b)
        cancelled.loader.enqueue(.failure(CancellationError()), for: "b")
        cancelled.viewModel.start()
        await cancelled.viewModel.waitForAllOperationsForTesting()

        XCTAssertTrue(hasFinishedOutcome(.succeeded, in: subject.logger.events))
        XCTAssertTrue(hasFinishedOutcome(.ignoredStale, in: subject.logger.events))
        XCTAssertTrue(hasFinishedOutcome(.cancelled, in: cancelled.logger.events))
        XCTAssertTrue(subject.logger.events.allSatisfy { $0.feature == .novelReader })
        XCTAssertFalse(subject.logger.formattedMessages.joined().contains(secret))
    }

    private var mediaIdentity: MediaIdentity {
        MediaIdentity(pluginId: "plugin.test", itemId: "novel")
    }

    private func makeSubject(
        chapters: [Novel.Chapter],
        initial: Novel.Chapter,
        settings: NovelReaderSettingsSnapshot? = nil,
        title: String = "Novel",
        cover: String? = nil
    ) -> NovelReaderTestSubject {
        makeNovelReaderSubject(
            novel: Novel(
                key: "novel",
                title: title,
                cover: cover,
                chapters: chapters
            ),
            initialChapter: initial,
            settingsSnapshot: settings ?? self.settings()
        )
    }

    private func loadedTwoChapterSubject(
        a: Novel.Chapter,
        b: Novel.Chapter,
        cover: String? = nil
    ) async -> NovelReaderTestSubject {
        let subject = makeSubject(chapters: [a, b], initial: a, cover: cover)
        subject.loader.enqueue(.pages([page(1)]), for: a.key)
        subject.loader.enqueue(.pages([page(2)]), for: b.key)
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        subject.viewModel.loadNextChapter()
        await subject.viewModel.waitForAllOperationsForTesting()
        return subject
    }

    private func makeChapter(
        _ key: String,
        number: Float32?,
        title: String? = nil,
        scanlator: String? = nil
    ) -> Novel.Chapter {
        Novel.Chapter(
            key: key,
            title: title,
            chapter: number,
            scanlator: scanlator
        )
    }

    private func page(
        _ index: Int32,
        text: String? = nil,
        url: String? = nil,
        headers: [String: String]? = nil
    ) -> Page {
        if let url {
            return Page(index: index, content: .url(url), headers: headers)
        }
        return Page(index: index, content: .text(text ?? "page-\(index)"), headers: headers)
    }

    private func settings(prefetch: Bool = true) -> NovelReaderSettingsSnapshot {
        NovelReaderSettingsSnapshot(
            fontSize: 18,
            lineSpacing: 8,
            fontFamily: .system,
            theme: .system,
            isPaging: false,
            prefetchChapters: prefetch
        )
    }

    private func hasFinishedOutcome(
        _ outcome: PresentationEventOutcome,
        in events: [PresentationLogEvent]
    ) -> Bool {
        events.contains { $0.phase == .finished && $0.outcome == outcome }
    }
}
