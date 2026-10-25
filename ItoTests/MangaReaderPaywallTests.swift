import XCTest
import ito_runner
@testable import Ito

extension MangaReaderViewModelTests {

    // MARK: - Initial Load

    func testInitialLockedChapterNeverCallsPluginLoaderAndRetainsNoFailure() async {
        let locked = makeChapter("locked", number: 1, paywalled: true)
        let subject = makeSubject(chapters: [locked], initial: locked)

        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()

        XCTAssertTrue(subject.loader.requestedChapterKeys.isEmpty)
        if case .failure = subject.viewModel.loadPhase {
            XCTFail("Initial locked chapter must not set generic failure")
        }
        XCTAssertEqual(subject.viewModel.currentChapter.key, "locked")
        XCTAssertTrue(subject.viewModel.pagedPages.isEmpty)
        XCTAssertTrue(subject.viewModel.segments.isEmpty)
    }

    func testAnOldUnlockedInitialChapterCannotOverrideLockedCatalogMetadata() async {
        let locked = makeChapter("locked", number: 1, paywalled: true)
        let stale = makeChapter("locked", number: 1, paywalled: false)
        let subject = makeSubject(chapters: [locked], initial: stale)
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        XCTAssertEqual(subject.loader.callCount(for: "locked"), 0)
    }

    func testInitialAvailableChapterNormalLoadFlow() async {
        for paywalledValue: Bool? in [false, nil] {
            let ch = makeChapter("avail", number: 1, paywalled: paywalledValue)
            let subject = makeSubject(chapters: [ch], initial: ch)
            subject.loader.enqueue(.pages([page(0), page(1)]), for: "avail")

            subject.viewModel.start()
            await waitForReader { subject.viewModel.loadPhase == .content }
            await subject.viewModel.waitForTestingOperations()

            XCTAssertEqual(subject.loader.requestedChapterKeys, ["avail"])
            XCTAssertEqual(subject.viewModel.currentChapter.key, "avail")
            XCTAssertEqual(subject.viewModel.pagedPages.count, 2)
            XCTAssertEqual(subject.viewModel.loadPhase, .content)
        }
    }

    // MARK: - Paged Navigation (Next / Previous / Sentinels)

    func testPagedNextChapterKnownLockedDoesNotCallLoaderAndRetainsCurrentChapter() async {
        let first = makeChapter("c1", number: 1)
        let lockedNext = makeChapter("c2", number: 2, paywalled: true)
        let farReadable = makeChapter("c3", number: 3)
        let subject = makeSubject(chapters: [farReadable, lockedNext, first], initial: first)
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "c1")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        XCTAssertEqual(subject.loader.callCount(for: "c1"), 1)

        // Direct navigation to next chapter
        subject.viewModel.goToNextChapter()
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.loader.callCount(for: "c2"), 0)
        XCTAssertEqual(subject.loader.callCount(for: "c3"), 0)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "c1")
        XCTAssertEqual(subject.viewModel.pagedPages.count, 2)
        XCTAssertEqual(subject.viewModel.loadPhase, .content)

        // Swipe past the last page sentinel
        subject.viewModel.setPagedIndex(subject.viewModel.pagedPages.count)
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.loader.callCount(for: "c2"), 0)
        XCTAssertEqual(subject.loader.callCount(for: "c3"), 0)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "c1")
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
    }

    func testPagedPreviousChapterKnownLockedDoesNotCallLoaderAndRetainsCurrentChapter() async {
        let farReadable = makeChapter("c1", number: 1)
        let lockedPrev = makeChapter("c2", number: 2, paywalled: true)
        let last = makeChapter("c3", number: 3)
        let subject = makeSubject(chapters: [last, lockedPrev, farReadable], initial: last)
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "c3")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        XCTAssertEqual(subject.loader.callCount(for: "c3"), 1)

        // Direct navigation to previous chapter
        subject.viewModel.goToPreviousChapter()
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.loader.callCount(for: "c2"), 0)
        XCTAssertEqual(subject.loader.callCount(for: "c1"), 0)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "c3")
        XCTAssertEqual(subject.viewModel.pagedPages.count, 2)
        XCTAssertEqual(subject.viewModel.loadPhase, .content)

        // Swipe past the first page sentinel
        subject.viewModel.setPagedIndex(-1)
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.loader.callCount(for: "c2"), 0)
        XCTAssertEqual(subject.loader.callCount(for: "c1"), 0)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "c3")
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
    }

    // MARK: - Adjacent Prefetch

    func testAdjacentPrefetchNeverLoadsLockedNeighbors() async {
        let prevLocked = makeChapter("c1", number: 1, paywalled: true)
        let middle = makeChapter("c2", number: 2)
        let nextLocked = makeChapter("c3", number: 3, paywalled: true)
        let subject = makeSubject(chapters: [nextLocked, middle, prevLocked], initial: middle)
        subject.loader.enqueue(.pages([page(0)]), for: "c2")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.loader.requestedChapterKeys, ["c2"])
        XCTAssertEqual(subject.loader.callCount(for: "c1"), 0)
        XCTAssertEqual(subject.loader.callCount(for: "c3"), 0)
        XCTAssertTrue(subject.viewModel.prefetchedChapters.isEmpty)
    }

    func testAdjacentPrefetchLoadsRefreshedUnlockedNeighbor() async {
        let current = makeChapter("c1", number: 1)
        let unlockedNext = makeChapter("c2", number: 2, paywalled: false)
        let subject = makeSubject(chapters: [unlockedNext, current], initial: current)
        subject.loader.enqueue(.pages([page(0)]), for: "c1")
        subject.loader.enqueue(.pages([page(0)]), for: "c2")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.prefetchedChapters["c2"] != nil }
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.loader.callCount(for: "c2"), 1)
        XCTAssertNotNil(subject.viewModel.prefetchedChapters["c2"])
    }

    // MARK: - Continuous Mode (Append / Prepend)

    func testContinuousAppendLockedNeighborDoesNotCallLoaderAndSetsNoFailureFlags() async {
        let first = makeChapter("c1", number: 1)
        let lockedNext = makeChapter("c2", number: 2, paywalled: true)
        let farReadable = makeChapter("c3", number: 3)
        let subject = makeSubject(
            chapters: [farReadable, lockedNext, first],
            initial: first,
            viewer: .Vertical
        )
        subject.loader.enqueue(.pages([page(0)]), for: "c1")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        XCTAssertEqual(subject.loader.callCount(for: "c1"), 1)

        // Attempt append
        subject.viewModel.appendNextChapter()
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.loader.callCount(for: "c2"), 0)
        XCTAssertEqual(subject.loader.callCount(for: "c3"), 0)
        XCTAssertFalse(subject.viewModel.loadingNextChapter)
        XCTAssertFalse(subject.viewModel.appendFailed)
        XCTAssertEqual(subject.viewModel.segments.map { $0.chapter.key }, ["c1"])
        XCTAssertNil(subject.viewModel.nextChapterForLastSegment)

        // Retry append should be no-op because appendFailed is false
        subject.viewModel.retryAppendNextChapter()
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.loader.callCount(for: "c2"), 0)
        XCTAssertFalse(subject.viewModel.appendFailed)
    }

    func testContinuousPrependLockedNeighborDoesNotCallLoaderAndSetsNoFailureFlags() async {
        let farReadable = makeChapter("c1", number: 1)
        let lockedPrev = makeChapter("c2", number: 2, paywalled: true)
        let last = makeChapter("c3", number: 3)
        let subject = makeSubject(
            chapters: [last, lockedPrev, farReadable],
            initial: last,
            viewer: .Vertical
        )
        subject.loader.enqueue(.pages([page(0)]), for: "c3")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        XCTAssertEqual(subject.loader.callCount(for: "c3"), 1)

        // Attempt prepend
        subject.viewModel.prependPreviousChapter()
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.loader.callCount(for: "c2"), 0)
        XCTAssertEqual(subject.loader.callCount(for: "c1"), 0)
        XCTAssertFalse(subject.viewModel.loadingPrevChapter)
        XCTAssertFalse(subject.viewModel.prependFailed)
        XCTAssertEqual(subject.viewModel.segments.map { $0.chapter.key }, ["c3"])
        XCTAssertNil(subject.viewModel.previousChapterForFirstSegment)
    }

    func testContinuousGoToNextOrPreviousLockedNeighborDoesNotCallLoaderAndRetainsContent() async {
        let prevLocked = makeChapter("c1", number: 1, paywalled: true)
        let middle = makeChapter("c2", number: 2)
        let nextLocked = makeChapter("c3", number: 3, paywalled: true)
        let subject = makeSubject(
            chapters: [nextLocked, middle, prevLocked],
            initial: middle,
            viewer: .Vertical
        )
        subject.loader.enqueue(.pages([page(0)]), for: "c2")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        subject.viewModel.goToNextChapter()
        await subject.viewModel.waitForTestingOperations()
        XCTAssertEqual(subject.loader.callCount(for: "c3"), 0)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "c2")

        subject.viewModel.goToPreviousChapter()
        await subject.viewModel.waitForTestingOperations()
        XCTAssertEqual(subject.loader.callCount(for: "c1"), 0)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "c2")
        XCTAssertEqual(subject.viewModel.segments.map { $0.chapter.key }, ["c2"])
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
    }

    // MARK: - Unnumbered Chapter Navigation Boundary

    func testUnnumberedChaptersStopAtLockedNeighborWithoutCallingLoader() async {
        let first = makeChapter("u1", number: nil)
        let lockedNext = makeChapter("u2", number: nil, paywalled: true)
        let third = makeChapter("u3", number: nil)
        // Listed newest first: u3, u2, u1
        let subject = makeSubject(chapters: [third, lockedNext, first], initial: first)
        subject.loader.enqueue(.pages([page(0)]), for: "u1")

        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }

        subject.viewModel.goToNextChapter()
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.loader.callCount(for: "u2"), 0)
        XCTAssertEqual(subject.loader.callCount(for: "u3"), 0)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "u1")
    }
}
