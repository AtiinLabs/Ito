import Combine
import Foundation
import Testing
import ito_runner
@testable import Ito

/// A reader's view of stored copies and the network that the test moves by hand.
@MainActor
final class ReaderAvailabilityFake: ReaderOfflineAvailability {
    private let subject = PassthroughSubject<Void, Never>()
    let isAvailable: Bool

    var isOffline: Bool {
        didSet { subject.send() }
    }

    var verified: Set<String> {
        didSet { subject.send() }
    }

    init(isAvailable: Bool = true, isOffline: Bool = false, verified: Set<String> = []) {
        self.isAvailable = isAvailable
        self.isOffline = isOffline
        self.verified = verified
    }

    func isVerified(chapterKey: String) -> Bool {
        verified.contains(chapterKey)
    }

    var changes: AnyPublisher<Void, Never> {
        subject.eraseToAnyPublisher()
    }
}

/// What lies past a chapter, in the words of the typed boundary.
func boundaryLabel(_ boundary: ReaderChapterBoundary<Chapter>) -> String {
    switch boundary {
    case .chapter(let chapter): "chapter:\(chapter.key)"
    case .end: "end"
    case .locked(let chapter): "locked:\(chapter.key)"
    case .otherReader(let chapter): "otherReader:\(chapter.key)"
    case .notAvailableOffline(let chapter): "notAvailableOffline:\(chapter.key)"
    }
}

func readerChapter(_ key: String, _ number: Double, text: Bool = false, locked: Bool = false) -> Chapter {
    var chapter = text
        ? Chapter(key: key, chapter: number, kind: .text)
        : Chapter(key: key, chapter: number, kind: .images)
    if locked { chapter.paywalled = true }
    return chapter
}

private func label(_ boundary: ReaderChapterBoundary<Chapter>) -> String { boundaryLabel(boundary) }
private func chapter(_ key: String, _ number: Double, text: Bool = false, locked: Bool = false) -> Chapter {
    readerChapter(key, number, text: text, locked: locked)
}

@MainActor
struct ReaderChapterBoundaryTests {
    // Reading order: p1 (pages), t2 (text), p3 (locked pages), p4, p5.
    private static let p1 = chapter("p1", 1)
    private static let t2 = chapter("t2", 2, text: true)
    private static let p3 = chapter("p3", 3, locked: true)
    private static let p4 = chapter("p4", 4)
    private static let p5 = chapter("p5", 5)
    private static let all = [p5, p4, p3, t2, p1]

    // Reading order for a novel: x1 (text), i2 (pages), x3 (locked text), x4, x5.
    private static let x1 = chapter("x1", 1, text: true)
    private static let i2 = chapter("i2", 2)
    private static let x3 = chapter("x3", 3, text: true, locked: true)
    private static let x4 = chapter("x4", 4, text: true)
    private static let x5 = chapter("x5", 5, text: true)
    private static let allText = [x5, x4, x3, i2, x1]

    // MARK: - Ordering

    @Test func orderingReportsALockedNeighborBeforeTheLockFilterAndTheWrappersStayUnchanged() {
        let after = ReaderChapterOrdering.boundary(after: Self.t2, in: Self.all, preferredScanlator: nil)
        let before = ReaderChapterOrdering.boundary(before: Self.p4, in: Self.all, preferredScanlator: nil)
        let end = ReaderChapterOrdering.boundary(after: Self.p5, in: Self.all, preferredScanlator: nil)

        #expect(label(after) == "locked:p3")
        #expect(label(before) == "locked:p3")
        #expect(label(end) == "end")
        // The wrappers still stop at a lock instead of reaching past it.
        #expect(ReaderChapterOrdering.mangaChapter(after: Self.t2, in: Self.all, preferredScanlator: nil) == nil)
        #expect(ReaderChapterOrdering.mangaChapter(after: Self.p4, in: Self.all, preferredScanlator: nil)?.key == "p5")

        #expect(label(ReaderChapterOrdering.boundary(after: Self.i2, in: Self.allText)) == "locked:x3")
        #expect(label(ReaderChapterOrdering.boundary(before: Self.x4, in: Self.allText)) == "locked:x3")
        #expect(label(ReaderChapterOrdering.boundary(after: Self.x5, in: Self.allText)) == "end")
        #expect(ReaderChapterOrdering.novelChapter(after: Self.i2, in: Self.allText) == nil)
    }

    // MARK: - Page reader

    @Test func pageReaderBoundaryTable() {
        let availability = ReaderAvailabilityFake()
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "m", title: "M", chapters: Self.all),
            initialChapter: Self.p4,
            offlineAvailability: availability
        )
        let viewModel = subject.viewModel

        #expect(label(viewModel.boundaryAfter(Self.p4)) == "chapter:p5")
        #expect(label(viewModel.boundaryAfter(Self.p5)) == "end")
        #expect(label(viewModel.boundaryBefore(Self.p1)) == "end")
        #expect(label(viewModel.boundaryAfter(Self.t2)) == "locked:p3")
        #expect(label(viewModel.boundaryBefore(Self.p4)) == "locked:p3")
        #expect(label(viewModel.boundaryAfter(Self.p1)) == "otherReader:t2")
        #expect(label(viewModel.boundaryBefore(Self.p3)) == "otherReader:t2")
        // The ordinary navigation answers keep their behavior.
        #expect(viewModel.chapterAfter(Self.p1) == nil)
        #expect(viewModel.chapterAfter(Self.p4)?.key == "p5")
    }

    @Test func pageReaderStopsAtAnUnstoredNeighborOnASavedOnlyRoute() {
        let availability = ReaderAvailabilityFake(verified: ["p5"])
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "m", title: "M", chapters: Self.all),
            initialChapter: Self.p4,
            offlineAvailability: availability,
            isSavedOnly: true
        )
        let viewModel = subject.viewModel

        #expect(label(viewModel.boundaryAfter(Self.p3)) == "notAvailableOffline:p4")
        #expect(label(viewModel.boundaryAfter(Self.p4)) == "chapter:p5")
        // A lock and the other reader are reported as themselves, not as a missing download.
        #expect(label(viewModel.boundaryAfter(Self.t2)) == "locked:p3")
        #expect(label(viewModel.boundaryAfter(Self.p1)) == "otherReader:t2")
    }

    @Test func pageReaderStopsAtAnUnstoredNeighborWhileOfflineAndResumesOnline() {
        let availability = ReaderAvailabilityFake(isOffline: true, verified: ["p5"])
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "m", title: "M", chapters: Self.all),
            initialChapter: Self.p4,
            offlineAvailability: availability
        )
        let viewModel = subject.viewModel

        #expect(label(viewModel.boundaryAfter(Self.p3)) == "notAvailableOffline:p4")
        #expect(label(viewModel.boundaryAfter(Self.p4)) == "chapter:p5")
        #expect(label(viewModel.boundaryAfter(Self.t2)) == "locked:p3")
        #expect(label(viewModel.boundaryAfter(Self.p1)) == "otherReader:t2")

        availability.isOffline = false
        #expect(label(viewModel.boundaryAfter(Self.p3)) == "chapter:p4")
    }

    @Test func pageReaderStopsBeforeAnUnstoredPreviousNeighborOnASavedOnlyRouteAndWhileOffline() {
        let savedOnly = makeMangaReaderSubject(
            manga: Manga(key: "m", title: "M", chapters: Self.all),
            initialChapter: Self.p5,
            offlineAvailability: ReaderAvailabilityFake(verified: ["p1"]),
            isSavedOnly: true
        ).viewModel
        let availability = ReaderAvailabilityFake(isOffline: true, verified: ["p1"])
        let offline = makeMangaReaderSubject(
            manga: Manga(key: "m", title: "M", chapters: Self.all),
            initialChapter: Self.p5,
            offlineAvailability: availability
        ).viewModel

        for viewModel in [savedOnly, offline] {
            #expect(label(viewModel.boundaryBefore(Self.p5)) == "notAvailableOffline:p4")
            #expect(label(viewModel.boundaryBefore(Self.p4)) == "locked:p3")
            #expect(label(viewModel.boundaryBefore(Self.p3)) == "otherReader:t2")
            #expect(label(viewModel.boundaryBefore(Self.p1)) == "end")
        }
        availability.isOffline = false
        #expect(label(offline.boundaryBefore(Self.p5)) == "chapter:p4")
    }

    @Test func anUnstoredNeighborOfARouteWithASourceIsOpenedWhenTheSystemSaysNothingIsWrong() {
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "m", title: "M", chapters: Self.all),
            initialChapter: Self.p4,
            offlineAvailability: ReaderAvailabilityFake()
        )

        #expect(label(subject.viewModel.boundaryAfter(Self.p3)) == "chapter:p4")
    }

    @Test func aNeighborThatReadsFromTheSourceCountsAsNotStoredWhateverIsStored() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let availability = ReaderAvailabilityFake(isOffline: true, verified: ["p5"])
        let base = makeMangaReaderSubject(manga: Manga(key: "m", title: "M", chapters: Self.all), initialChapter: Self.p4)
        let entry = MediaEntry.manga(Manga(key: "m", title: "M", chapters: Self.all))
        let loader = ResolvingMangaPageLoader(
            pluginID: "plugin.test",
            local: store,
            remote: SourceOnlyPages(),
            preference: .remoteThisTime(chapterKey: "p5")
        )
        let viewModel = MangaReaderViewModel(
            pageLoader: loader,
            pluginID: "plugin.test",
            entry: entry,
            initialChapter: Self.p4,
            dependencies: base.dependencies,
            offline: ReaderOfflineContext(availability: availability, downloadedCopy: loader)
        )

        // Chosen to read online this time: offline that cannot work, so the reader stops instead.
        #expect(label(viewModel.boundaryAfter(Self.p4)) == "notAvailableOffline:p5")

        // Loaded from the source before its copy finished: it stays pinned there.
        let pinned = ResolvingMangaPageLoader(pluginID: "plugin.test", local: store, remote: SourceOnlyPages())
        _ = try await pinned.pages(for: entry, chapter: Self.p5, operation: makeTestNetworkOperation())
        let pinnedModel = MangaReaderViewModel(
            pageLoader: pinned,
            pluginID: "plugin.test",
            entry: entry,
            initialChapter: Self.p4,
            dependencies: base.dependencies,
            offline: ReaderOfflineContext(availability: availability, downloadedCopy: pinned)
        )
        #expect(label(pinnedModel.boundaryAfter(Self.p4)) == "notAvailableOffline:p5")
        availability.isOffline = false
        #expect(label(pinnedModel.boundaryAfter(Self.p4)) == "chapter:p5")
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func continuousPageReaderShowsTheBoundaryInsteadOfAnAppendThatWouldFail() async {
        let chapters = [chapter("c3", 3), chapter("c2", 2), chapter("c1", 1)]
        let availability = ReaderAvailabilityFake()
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "m", title: "M", viewer: .Webtoon, chapters: chapters),
            initialChapter: chapters[1],
            offlineAvailability: availability
        )
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("two"))]), for: "c2")
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        #expect(label(subject.viewModel.continuousSnapshot.nextBoundary) == "chapter:c3")

        availability.isOffline = true
        #expect(label(subject.viewModel.continuousSnapshot.nextBoundary) == "notAvailableOffline:c3")
        subject.viewModel.appendNextChapter()
        await subject.viewModel.waitForTestingOperations()

        #expect(subject.loader.callCount(for: "c3") == 0)
        #expect(!subject.viewModel.appendFailed)
        #expect(!subject.viewModel.loadingNextChapter)

        // The chapter finishes downloading: the same boundary becomes a chapter that appends.
        availability.verified = ["c3"]
        #expect(label(subject.viewModel.continuousSnapshot.nextBoundary) == "chapter:c3")
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("three"))]), for: "c3")
        subject.viewModel.appendNextChapter()
        await subject.viewModel.waitForTestingOperations()

        #expect(subject.viewModel.segments.map(\.chapter.key) == ["c2", "c3"])
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aPagedReaderRestingOnTheNoticePageLoadsTheChapterWhenItBecomesAvailable() async {
        let chapters = [chapter("c3", 3), chapter("c2", 2), chapter("c1", 1)]
        let availability = ReaderAvailabilityFake(isOffline: true)
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "m", title: "M", chapters: chapters),
            initialChapter: chapters[1],
            offlineAvailability: availability
        )
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("a")), Page(index: 1, content: .text("b"))]), for: "c2")
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        subject.viewModel.setPagedIndex(2)

        // The pager rests on the notice page; the footer keeps to the chapter's own pages.
        #expect(subject.loader.callCount(for: "c3") == 0)
        #expect(subject.viewModel.pagedIndex == 2)
        #expect(subject.viewModel.pagedDisplayIndex == 1)
        subject.viewModel.setPagedIndex(-1)
        #expect(subject.viewModel.pagedDisplayIndex == 0)
        subject.viewModel.setPagedIndex(2)

        subject.loader.enqueue(.pages([Page(index: 0, content: .text("c"))]), for: "c3")
        availability.verified = ["c3"]
        await subject.viewModel.waitForTestingOperations()

        #expect(subject.loader.callCount(for: "c3") == 1)
        #expect(subject.viewModel.currentChapter.key == "c3")
        #expect(subject.viewModel.pagedPages.count == 1)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aPagedReaderNotOnANoticePagePrefetchesTheNeighborThatBecameAvailable() async {
        let chapters = [chapter("c3", 3), chapter("c2", 2), chapter("c1", 1)]
        let availability = ReaderAvailabilityFake(isOffline: true)
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "m", title: "M", chapters: chapters),
            initialChapter: chapters[1],
            offlineAvailability: availability
        )
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("a")), Page(index: 1, content: .text("b"))]), for: "c2")
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        #expect(subject.loader.callCount(for: "c3") == 0)

        subject.loader.enqueue(.pages([Page(index: 0, content: .text("c"))]), for: "c3")
        availability.verified = ["c3"]
        await subject.viewModel.waitForTestingOperations()

        #expect(subject.loader.callCount(for: "c3") == 1)
        #expect(subject.viewModel.currentChapter.key == "c2")
        #expect(subject.viewModel.prefetchedChapters["c3"]?.count == 1)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func switchingViewerFromTheNoticePageLandsOnTheLastPage() async {
        let chapters = [chapter("c3", 3), chapter("c2", 2), chapter("c1", 1)]
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "m", title: "M", chapters: chapters),
            initialChapter: chapters[1],
            offlineAvailability: ReaderAvailabilityFake(isOffline: true)
        )
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("a")), Page(index: 1, content: .text("b"))]), for: "c2")
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        subject.viewModel.setPagedIndex(2)

        subject.viewModel.setViewerOverride(.Webtoon)

        #expect(subject.viewModel.continuousPageIndex == 1)
    }

    // MARK: - Text reader

    @Test func textReaderBoundaryTable() {
        let subject = makeNovelReaderSubject(
            novel: Novel(key: "n", title: "N", chapters: Self.allText),
            initialChapter: Self.x4,
            offlineAvailability: ReaderAvailabilityFake()
        )
        let viewModel = subject.viewModel

        #expect(label(viewModel.boundaryAfter(Self.x4)) == "chapter:x5")
        #expect(label(viewModel.boundaryAfter(Self.x5)) == "end")
        #expect(label(viewModel.boundaryBefore(Self.x1)) == "end")
        #expect(label(viewModel.boundaryAfter(Self.i2)) == "locked:x3")
        #expect(label(viewModel.boundaryBefore(Self.x4)) == "locked:x3")
        #expect(label(viewModel.boundaryAfter(Self.x1)) == "otherReader:i2")
        #expect(label(viewModel.boundaryBefore(Self.x3)) == "otherReader:i2")
        #expect(viewModel.chapterAfter(Self.x1) == nil)
        #expect(viewModel.chapterAfter(Self.x4)?.key == "x5")
    }

    @Test func textReaderStopsAtAnUnstoredNeighborOnASavedOnlyRoute() {
        let availability = ReaderAvailabilityFake(verified: ["x5"])
        let subject = makeNovelReaderSubject(
            novel: Novel(key: "n", title: "N", chapters: Self.allText),
            initialChapter: Self.x4,
            offlineAvailability: availability,
            isSavedOnly: true
        )
        let viewModel = subject.viewModel

        #expect(label(viewModel.boundaryAfter(Self.x3)) == "notAvailableOffline:x4")
        #expect(label(viewModel.boundaryAfter(Self.x4)) == "chapter:x5")
        #expect(label(viewModel.boundaryAfter(Self.i2)) == "locked:x3")
        #expect(label(viewModel.boundaryAfter(Self.x1)) == "otherReader:i2")
    }

    @Test func textReaderStopsAtAnUnstoredNeighborWhileOffline() {
        let availability = ReaderAvailabilityFake(isOffline: true, verified: ["x5"])
        let subject = makeNovelReaderSubject(
            novel: Novel(key: "n", title: "N", chapters: Self.allText),
            initialChapter: Self.x4,
            offlineAvailability: availability
        )
        let viewModel = subject.viewModel

        #expect(label(viewModel.boundaryAfter(Self.x3)) == "notAvailableOffline:x4")
        #expect(label(viewModel.boundaryAfter(Self.x4)) == "chapter:x5")
        #expect(viewModel.nextChapter?.key == "x5")
        // The previous side follows the same rules, though the text reader shows no prompt there.
        #expect(label(viewModel.boundaryBefore(Self.x5)) == "notAvailableOffline:x4")
        availability.isOffline = false
        #expect(label(viewModel.boundaryAfter(Self.x3)) == "chapter:x4")
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func textReaderShowsTheBoundaryThenAppendsByItselfWhenTheChapterBecomesAvailable() async {
        let chapters = [chapter("x3", 3, text: true), chapter("x2", 2, text: true), chapter("x1", 1, text: true)]
        let availability = ReaderAvailabilityFake(isOffline: true)
        let subject = makeNovelReaderSubject(
            novel: Novel(key: "n", title: "N", chapters: chapters),
            initialChapter: chapters[1],
            offlineAvailability: availability
        )
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("two"))]), for: "x2")
        subject.viewModel.start()
        await subject.viewModel.waitForCurrentMainLoadForTesting()

        #expect(label(subject.viewModel.boundaryAfter(chapters[1])) == "notAvailableOffline:x3")
        subject.viewModel.loadNextChapter(trigger: .reader)
        await subject.viewModel.waitForAllOperationsForTesting()

        #expect(subject.loader.callCount(for: "x3") == 0)
        #expect(!subject.viewModel.appendFailed)
        #expect(!subject.viewModel.isLoadingNext)

        // The chapter finishes downloading: the held-back append goes ahead without another request.
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("three"))]), for: "x3")
        availability.verified = ["x3"]
        await subject.viewModel.waitForAllOperationsForTesting()

        #expect(subject.viewModel.loadedChapters.map(\.chapter.key) == ["x2", "x3"])
    }

    // MARK: - Availability changes in flight, inactive and with Seamless Reading off

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func availabilityChangesDuringAPrefetchDoNotRestartIt() async {
        let chapters = [chapter("c3", 3), chapter("c2", 2), chapter("c1", 1)]
        let availability = ReaderAvailabilityFake()
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "m", title: "M", chapters: chapters),
            initialChapter: chapters[1],
            offlineAvailability: availability
        )
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("two"))]), for: "c2")
        subject.loader.enqueue(.suspended, for: "c3")
        subject.loader.enqueue(.suspended, for: "c1")
        subject.viewModel.start()
        await subject.loader.waitForPendingCount(1, for: "c3")

        // A batch download finishes copies one after another while the neighbors are being fetched.
        availability.verified = ["c3"]
        availability.verified = ["c3", "c1"]
        #expect(subject.loader.callCount(for: "c3") == 1)
        #expect(subject.loader.callCount(for: "c1") == 0)

        subject.loader.resolveFirst(for: "c3", with: .success([Page(index: 0, content: .text("three"))]))
        await subject.loader.waitForPendingCount(1, for: "c1")
        subject.loader.resolveFirst(for: "c1", with: .success([Page(index: 0, content: .text("one"))]))
        await subject.viewModel.waitForTestingOperations()

        #expect(subject.loader.callCount(for: "c3") == 1)
        #expect(subject.loader.callCount(for: "c1") == 1)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aChangeThatArrivesWhileThePagedReaderIsInactiveIsAppliedWhenItReturns() async {
        let chapters = [chapter("c3", 3), chapter("c2", 2), chapter("c1", 1)]
        let availability = ReaderAvailabilityFake(isOffline: true)
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "m", title: "M", chapters: chapters),
            initialChapter: chapters[1],
            offlineAvailability: availability
        )
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("a")), Page(index: 1, content: .text("b"))]), for: "c2")
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        subject.viewModel.setPagedIndex(2)
        subject.viewModel.disappear()

        subject.loader.enqueue(.pages([Page(index: 0, content: .text("c"))]), for: "c3")
        availability.verified = ["c3"]
        #expect(subject.loader.callCount(for: "c3") == 0)

        subject.viewModel.appear()
        await subject.viewModel.waitForTestingOperations()

        #expect(subject.loader.callCount(for: "c3") == 1)
        #expect(subject.viewModel.currentChapter.key == "c3")
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aHeldBackAppendThatBecomesPossibleWhileTheTextReaderIsInactiveRunsWhenItReturns() async {
        let chapters = [chapter("x3", 3, text: true), chapter("x2", 2, text: true), chapter("x1", 1, text: true)]
        let availability = ReaderAvailabilityFake(isOffline: true)
        let subject = makeNovelReaderSubject(
            novel: Novel(key: "n", title: "N", chapters: chapters),
            initialChapter: chapters[1],
            offlineAvailability: availability
        )
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("two"))]), for: "x2")
        subject.viewModel.start()
        await subject.viewModel.waitForCurrentMainLoadForTesting()
        subject.viewModel.loadNextChapter(trigger: .reader)
        subject.viewModel.disappear()

        subject.loader.enqueue(.pages([Page(index: 0, content: .text("three"))]), for: "x3")
        availability.verified = ["x3"]
        #expect(subject.loader.callCount(for: "x3") == 0)

        subject.viewModel.appear()
        await subject.viewModel.waitForAllOperationsForTesting()

        #expect(subject.loader.callCount(for: "x3") == 1)
        #expect(subject.viewModel.loadedChapters.map(\.chapter.key) == ["x2", "x3"])
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aHeldBackAppendIsDroppedWhenSeamlessReadingIsTurnedOff() async {
        let chapters = [chapter("x3", 3, text: true), chapter("x2", 2, text: true), chapter("x1", 1, text: true)]
        let availability = ReaderAvailabilityFake(isOffline: true)
        let subject = makeNovelReaderSubject(
            novel: Novel(key: "n", title: "N", chapters: chapters),
            initialChapter: chapters[1],
            offlineAvailability: availability
        )
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("two"))]), for: "x2")
        subject.viewModel.start()
        await subject.viewModel.waitForCurrentMainLoadForTesting()
        subject.viewModel.loadNextChapter(trigger: .reader)

        subject.viewModel.setPrefetchChapters(false)
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("three"))]), for: "x3")
        availability.verified = ["x3"]
        await subject.viewModel.waitForAllOperationsForTesting()

        #expect(subject.loader.callCount(for: "x3") == 0)
        #expect(subject.viewModel.loadedChapters.map(\.chapter.key) == ["x2"])
    }

    // MARK: - Prompts

    @Test func promptsUseTheExactWordsOfEachBoundary() {
        let locked = ReaderChapterBoundary.locked(Self.p3)
        let other = ReaderChapterBoundary.otherReader(Self.t2)
        let missing = ReaderChapterBoundary.notAvailableOffline(Self.p4)

        #expect(ReaderBoundaryNotice.pages(for: locked, isNext: true)?.text == "Next chapter is locked")
        #expect(ReaderBoundaryNotice.pages(for: other, isNext: true)?.text == "Next chapter opens in the text reader")
        #expect(ReaderBoundaryNotice.pages(for: missing, isNext: true)?.text == "Next chapter isn't downloaded")
        #expect(ReaderBoundaryNotice.pages(for: locked, isNext: false)?.text == "Previous chapter is locked")
        #expect(ReaderBoundaryNotice.pages(for: other, isNext: false)?.text == "Previous chapter opens in the text reader")
        #expect(ReaderBoundaryNotice.pages(for: missing, isNext: false)?.text == "Previous chapter isn't downloaded")

        #expect(ReaderBoundaryNotice.textAfterLast(for: locked)?.text == "Next chapter is locked")
        #expect(ReaderBoundaryNotice.textAfterLast(for: ReaderChapterBoundary.otherReader(Self.p1))?.text
            == "Next chapter opens in the page reader")
        #expect(ReaderBoundaryNotice.textAfterLast(for: missing)?.text == "Next chapter isn't downloaded")

        #expect(ReaderBoundaryNotice.pages(for: ReaderChapterBoundary<Chapter>.end, isNext: true) == nil)
        #expect(ReaderBoundaryNotice.pages(for: ReaderChapterBoundary.chapter(Self.p4), isNext: true) == nil)
        #expect(ReaderBoundaryNotice.textAfterLast(for: ReaderChapterBoundary.chapter(Self.x4)) == nil)
    }

    // MARK: - Availability seam

    @Test func observedAvailabilityFiresOnAVerifiedKeyOrNetworkChangeButNotOnProgress() {
        let downloads = MediaDetailDownloadsFake()
        let connectivity = ConnectivityFake()
        let availability = ObservedReaderOfflineAvailability(
            media: MediaDetailDownloadsFake.series,
            downloads: downloads,
            connectivity: connectivity
        )
        let counter = ChangeCounter()
        let subscription = availability.changes.sink { counter.count += 1 }
        defer { subscription.cancel() }

        downloads.set(.queued, chapterKey: "a")
        downloads.set(.downloading(completed: 1, total: 3), chapterKey: "a")
        downloads.set(.downloading(completed: 2, total: 3), chapterKey: "a")
        #expect(counter.count == 0)
        #expect(!availability.isVerified(chapterKey: "a"))

        downloads.set(.downloaded, chapterKey: "a")
        #expect(counter.count == 1)
        #expect(availability.isVerified(chapterKey: "a"))

        // Another series' copy and a repeated state are not this reader's business.
        let other = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "other", mediaKind: .manga)
        downloads.set(.downloaded, chapterKey: "b", media: other)
        downloads.set(.downloaded, chapterKey: "a")
        #expect(counter.count == 1)

        connectivity.set(isOffline: false)
        #expect(counter.count == 1)
        connectivity.set(isOffline: true)
        connectivity.set(isOffline: true)
        #expect(counter.count == 2)
        #expect(availability.isOffline)

        downloads.set(.damaged, chapterKey: "a")
        #expect(counter.count == 3)
        #expect(!availability.isVerified(chapterKey: "a"))
    }

    // MARK: - Where downloads are unavailable

    @Test func whereDownloadsAreUnavailableReadersKeepTheirEarlierBehaviorEvenWhileOffline() {
        let base = makeMangaReaderSubject(manga: Manga(key: "m", title: "M", chapters: Self.all), initialChapter: Self.p4)
        let novelBase = makeNovelReaderSubject(novel: Novel(key: "n", title: "N", chapters: Self.allText), initialChapter: Self.x4)
        let factory = MediaDetailReaderViewFactory(
            mangaReaderDependencies: base.dependencies,
            novelReaderDependencies: novelBase.dependencies,
            downloads: UnavailableMediaDetailDownloads(),
            connectivity: ConnectivityFake(isOffline: true),
            networkContexts: PluginNetworkContexts(policy: NetworkPolicyCenter())
        )
        let pages = factory.makeMangaViewModel(
            content: ReaderContentSource(remote: ItoRunner()),
            pluginID: "plugin.test",
            entry: .manga(Manga(key: "m", title: "M", chapters: Self.all)),
            chapter: Self.p4
        )
        let savedOnlyPages = factory.makeMangaViewModel(
            content: ReaderContentSource(remote: nil),
            pluginID: "plugin.test",
            entry: .manga(Manga(key: "m", title: "M", chapters: Self.all)),
            chapter: Self.p4
        )
        let text = factory.makeNovelViewModel(
            content: ReaderContentSource(remote: ItoRunner()),
            pluginID: "plugin.test",
            entry: .novel(Novel(key: "n", title: "N", chapters: Self.allText)),
            chapter: Self.x4
        )

        for viewModel in [pages, savedOnlyPages] {
            // A neighbor that was not downloaded is still opened: the source is asked, as ever.
            #expect(label(viewModel.boundaryAfter(Self.p3)) == "chapter:p4")
            #expect(label(viewModel.boundaryBefore(Self.p5)) == "chapter:p4")
            // A lock and the other reader end the reader without a notice, as they always did.
            #expect(label(viewModel.boundaryAfter(Self.t2)) == "end")
            #expect(label(viewModel.boundaryBefore(Self.p4)) == "end")
            #expect(label(viewModel.boundaryAfter(Self.p1)) == "end")
            #expect(label(viewModel.boundaryBefore(Self.p3)) == "end")
            #expect(viewModel.chapterAfter(Self.p4)?.key == "p5")
        }
        #expect(label(text.boundaryAfter(Self.x3)) == "chapter:x4")
        #expect(label(text.boundaryAfter(Self.i2)) == "end")
        #expect(label(text.boundaryBefore(Self.x4)) == "end")
        #expect(label(text.boundaryAfter(Self.x1)) == "end")
        #expect(text.nextChapter?.key == "x5")
        #expect(ReaderBoundaryNotice.pages(for: pages.boundaryAfter(Self.t2), isNext: true) == nil)
        #expect(ReaderBoundaryNotice.pages(for: pages.boundaryAfter(Self.p1), isNext: true) == nil)
        #expect(ReaderBoundaryNotice.textAfterLast(for: text.boundaryAfter(Self.x1)) == nil)
    }

    @Test func whereDownloadsExistTheFactoryBuildsReadersThatShowBoundaries() {
        let base = makeMangaReaderSubject(manga: Manga(key: "m", title: "M", chapters: Self.all), initialChapter: Self.p4)
        let connectivity = ConnectivityFake(isOffline: true)
        let factory = MediaDetailReaderViewFactory(
            mangaReaderDependencies: base.dependencies,
            downloads: MediaDetailDownloadsFake(isAvailable: true),
            connectivity: connectivity,
            networkContexts: PluginNetworkContexts(policy: NetworkPolicyCenter())
        )
        let viewModel = factory.makeMangaViewModel(
            content: ReaderContentSource(remote: ItoRunner()),
            pluginID: "plugin.test",
            entry: .manga(Manga(key: "m", title: "M", chapters: Self.all)),
            chapter: Self.p4
        )

        #expect(label(viewModel.boundaryAfter(Self.p3)) == "notAvailableOffline:p4")
        #expect(label(viewModel.boundaryAfter(Self.t2)) == "locked:p3")
        #expect(label(viewModel.boundaryAfter(Self.p1)) == "otherReader:t2")
        connectivity.set(isOffline: false)
        #expect(label(viewModel.boundaryAfter(Self.p3)) == "chapter:p4")
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func anUnavailableSeamIgnoresTheNetworkWhenAppending() async {
        let chapters = [chapter("c3", 3), chapter("c2", 2), chapter("c1", 1)]
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "m", title: "M", viewer: .Webtoon, chapters: chapters),
            initialChapter: chapters[1],
            offlineAvailability: ReaderAvailabilityFake(isAvailable: false, isOffline: true)
        )
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("two"))]), for: "c2")
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        subject.loader.enqueue(.pages([Page(index: 0, content: .text("three"))]), for: "c3")

        subject.viewModel.appendNextChapter()
        await subject.viewModel.waitForTestingOperations()

        #expect(subject.loader.callCount(for: "c3") == 1)
        #expect(subject.viewModel.segments.map(\.chapter.key) == ["c2", "c3"])
    }
}

@MainActor
private final class ChangeCounter {
    var count = 0
}

/// A source that serves one remote page for any chapter.
@MainActor
private final class SourceOnlyPages: MangaPageLoading {
    func pages(for entry: MediaEntry, chapter: Chapter, operation: PluginNetworkOperation) async throws -> [Page] {
        _ = entry
        return [Page(index: 0, content: .url("https://remote.example.test/\(chapter.key)/p0000.jpg"))]
    }
}
