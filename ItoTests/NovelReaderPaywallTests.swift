import XCTest
import ito_runner
@testable import Ito

@MainActor
final class NovelReaderPaywallTests: XCTestCase {

    // MARK: - Initial / Retry Load

    func testInitialLockedChapterNeverCallsPluginLoaderAndRetainsNoFailure() async {
        let locked = makeChapter("locked", number: 1, paywalled: true)
        let subject = makeSubject(chapters: [locked], initial: locked)

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.loader.callCount(for: "locked"), 0)
        XCTAssertTrue(subject.loader.requests.isEmpty)
        if case .failure = subject.viewModel.loadPhase {
            XCTFail("Initial locked chapter must not set generic failure")
        }
        XCTAssertEqual(subject.viewModel.currentChapter.key, "locked")
        XCTAssertTrue(subject.viewModel.loadedChapters.isEmpty)
    }

    func testInitialAvailableChapterNormalLoadFlow() async {
        for paywalledValue: Bool? in [false, nil] {
            let ch = makeChapter("avail", number: 1, paywalled: paywalledValue)
            let subject = makeSubject(chapters: [ch], initial: ch)
            subject.loader.enqueue(.pages([page(0), page(1)]), for: "avail")

            subject.viewModel.start()
            await subject.viewModel.waitForAllOperationsForTesting()

            XCTAssertEqual(subject.loader.callCount(for: "avail"), 1)
            XCTAssertEqual(subject.viewModel.currentChapter.key, "avail")
            XCTAssertEqual(subject.viewModel.loadedChapters.count, 1)
            XCTAssertEqual(subject.viewModel.loadedChapters[0].pages.count, 2)
            XCTAssertEqual(subject.viewModel.loadPhase, .content)
        }
    }

    func testAnOldUnlockedSelectionCannotOverrideLockedCatalogMetadata() async {
        let first = makeChapter("first", number: 1)
        let locked = makeChapter("locked", number: 2, paywalled: true)
        let subject = makeSubject(chapters: [locked, first], initial: first)
        subject.loader.enqueue(.pages([page(0)]), for: "first")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()

        subject.viewModel.goToChapter(makeChapter("locked", number: 2, paywalled: false))
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.loader.callCount(for: "locked"), 0)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "first")
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
    }

    // MARK: - Navigation: Next / Previous Chapter

    func testNextChapterKnownLockedDoesNotCallLoaderInPagedAndContinuousModes() async {
        for isPaging in [true, false] {
            let first = makeChapter("c1", number: 1)
            let lockedNext = makeChapter("c2", number: 2, paywalled: true)
            let farReadable = makeChapter("c3", number: 3)
            let subject = makeSubject(
                chapters: [farReadable, lockedNext, first], initial: first,
                settings: defaultSettings(isPaging: isPaging)
            )
            subject.loader.enqueue(.pages([page(0), page(1)]), for: "c1")
            subject.viewModel.start()
            await subject.viewModel.waitForAllOperationsForTesting()

            subject.viewModel.goToNextChapter()
            await subject.viewModel.waitForAllOperationsForTesting()

            XCTAssertEqual(subject.loader.callCount(for: "c2"), 0)
            XCTAssertEqual(subject.loader.callCount(for: "c3"), 0)
            XCTAssertEqual(subject.viewModel.currentChapter.key, "c1")
            XCTAssertEqual(subject.viewModel.loadedChapters.count, 1)
            XCTAssertEqual(subject.viewModel.loadPhase, .content)
        }
    }

    func testPreviousChapterKnownLockedDoesNotCallLoaderInPagedAndContinuousModes() async {
        for isPaging in [true, false] {
            let farReadable = makeChapter("c1", number: 1)
            let lockedPrev = makeChapter("c2", number: 2, paywalled: true)
            let last = makeChapter("c3", number: 3)
            let subject = makeSubject(
                chapters: [last, lockedPrev, farReadable], initial: last,
                settings: defaultSettings(isPaging: isPaging)
            )
            subject.loader.enqueue(.pages([page(0), page(1)]), for: "c3")
            subject.viewModel.start()
            await subject.viewModel.waitForAllOperationsForTesting()

            subject.viewModel.goToPreviousChapter()
            await subject.viewModel.waitForAllOperationsForTesting()

            XCTAssertEqual(subject.loader.callCount(for: "c2"), 0)
            XCTAssertEqual(subject.loader.callCount(for: "c1"), 0)
            XCTAssertEqual(subject.viewModel.currentChapter.key, "c3")
            XCTAssertEqual(subject.viewModel.loadedChapters.count, 1)
            XCTAssertEqual(subject.viewModel.loadPhase, .content)
        }
    }

    // MARK: - Direct Selection (goToChapter)

    func testDirectSelectionOfLockedChapterNeverCallsPluginLoaderAndRetainsCurrentState() async {
        let c1 = makeChapter("c1", number: 1)
        let locked = makeChapter("c2", number: 2, paywalled: true)
        let subject = makeSubject(chapters: [locked, c1], initial: c1)
        subject.loader.enqueue(.pages([page(0), page(1)]), for: "c1")

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.loader.callCount(for: "c1"), 1)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "c1")
        XCTAssertEqual(subject.viewModel.loadedChapters.count, 1)

        // Directly call goToChapter with locked chapter
        subject.viewModel.goToChapter(locked)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.loader.callCount(for: "c2"), 0)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "c1")
        XCTAssertEqual(subject.viewModel.loadedChapters.count, 1)
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
    }

    // MARK: - Continuous Mode: Append & Prefetch

    func testContinuousAppendLockedNeighborDoesNotCallLoaderAndSetsNoFailureFlags() async {
        let first = makeChapter("c1", number: 1)
        let lockedNext = makeChapter("c2", number: 2, paywalled: true)
        let farReadable = makeChapter("c3", number: 3)
        let subject = makeSubject(chapters: [farReadable, lockedNext, first], initial: first)
        subject.loader.enqueue(.pages([page(0)]), for: "c1")

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.loader.callCount(for: "c1"), 1)

        // Attempt append
        subject.viewModel.loadNextChapter()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.loader.callCount(for: "c2"), 0)
        XCTAssertEqual(subject.loader.callCount(for: "c3"), 0)
        XCTAssertFalse(subject.viewModel.isLoadingNext)
        XCTAssertFalse(subject.viewModel.appendFailed)
        XCTAssertEqual(subject.viewModel.loadedChapters.map { $0.chapter.key }, ["c1"])
        XCTAssertNil(subject.viewModel.nextChapter)

        // Retry append should be no-op because appendFailed is false
        subject.viewModel.retryNextChapter()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.loader.callCount(for: "c2"), 0)
        XCTAssertFalse(subject.viewModel.appendFailed)
    }

    func testContinuousPrefetchNeverLoadsLockedNextChapter() async {
        let first = makeChapter("c1", number: 1)
        let lockedNext = makeChapter("c2", number: 2, paywalled: true)
        let subject = makeSubject(chapters: [lockedNext, first], initial: first)
        subject.loader.enqueue(.pages((0...5).map { page(Int32($0)) }), for: "c1")

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.loader.callCount(for: "c1"), 1)

        // Trigger continuous page appearance past the prefetch threshold (last 5 pages)
        let chapterID = subject.viewModel.loadedChapters[0].id
        subject.viewModel.continuousPageAppeared(chapterID: chapterID, pageIndex: 5)
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.loader.callCount(for: "c2"), 0)
        XCTAssertFalse(subject.viewModel.isLoadingNext)
        XCTAssertFalse(subject.viewModel.appendFailed)
        XCTAssertEqual(subject.viewModel.loadedChapters.count, 1)
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
        await subject.viewModel.waitForAllOperationsForTesting()

        subject.viewModel.goToNextChapter()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.loader.callCount(for: "u2"), 0)
        XCTAssertEqual(subject.loader.callCount(for: "u3"), 0)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "u1")
    }

    // MARK: - Refreshed Unlocked Metadata Normal Flow Control

    func testRefreshedUnlockedMetadataRestoresNormalFlow() async {
        let first = makeChapter("c1", number: 1)
        let unlockedNext = makeChapter("c2", number: 2, paywalled: false)
        let subject = makeSubject(chapters: [unlockedNext, first], initial: first)
        subject.loader.enqueue(.pages([page(0)]), for: "c1")
        subject.loader.enqueue(.pages([page(0)]), for: "c2")

        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.loader.callCount(for: "c1"), 1)

        subject.viewModel.goToNextChapter()
        await subject.viewModel.waitForAllOperationsForTesting()

        XCTAssertEqual(subject.loader.callCount(for: "c2"), 1)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "c2")
        XCTAssertEqual(subject.viewModel.loadPhase, .content)
    }

    // MARK: - Helpers

    private func makeSubject(
        chapters: [Novel.Chapter],
        initial: Novel.Chapter,
        settings: NovelReaderSettingsSnapshot? = nil
    ) -> NovelReaderTestSubject {
        makeNovelReaderSubject(
            novel: Novel(
                key: "novel",
                title: "Novel",
                chapters: chapters
            ),
            initialChapter: initial,
            settingsSnapshot: settings ?? defaultSettings()
        )
    }

    private func makeChapter(
        _ key: String,
        number: Float32?,
        title: String? = nil,
        scanlator: String? = nil,
        paywalled: Bool? = nil
    ) -> Novel.Chapter {
        Novel.Chapter(
            key: key,
            title: title,
            chapter: number,
            scanlator: scanlator,
            paywalled: paywalled
        )
    }

    private func page(
        _ index: Int32,
        text: String? = nil,
        url: String? = nil
    ) -> Page {
        if let url {
            return Page(index: index, content: .url(url))
        }
        return Page(index: index, content: .text(text ?? "page-\(index)"))
    }

    private func defaultSettings(isPaging: Bool = false) -> NovelReaderSettingsSnapshot {
        NovelReaderSettingsSnapshot(
            fontSize: 18,
            lineSpacing: 8,
            fontFamily: .system,
            theme: .system,
            isPaging: isPaging,
            prefetchChapters: true
        )
    }
}
