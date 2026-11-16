import ito_runner
import XCTest
@testable import Ito

/// What a reader keeps while a neighbor it started to load turns out to be made for the other reader, and what
/// the route does with a reader that has nothing on screen. Every wait is on a suspended preparation or an
/// operation the test awaits; no write is ever issued for the chapter the user left.
@MainActor
final class ReaderHandoffRollbackTests: XCTestCase {
    private static let c1 = readerChapter("c1", 1)
    private static let c2 = readerChapter("c2", 2)
    private static let c3 = readerChapter("c3", 3)
    private static let c4 = readerChapter("c4", 4)

    private func mangaEntry(_ viewer: Manga.Viewer) -> MediaEntry {
        .manga(Manga(key: "series", title: "Series", viewer: viewer, chapters: [Self.c4, Self.c3, Self.c2, Self.c1]))
    }

    private func threePages() -> [Page] {
        (0..<3).map { Page(index: Int32($0), content: .text("page \($0)")) }
    }

    private func pagesRoute(
        _ viewer: Manga.Viewer,
        suspending: Set<String> = []
    ) async -> (RouteFixture, ScriptedChapterPreparer) {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["c3"] = .text
        preparer.pages["c2"] = threePages()
        preparer.suspended = suspending
        // No adjacent prefetch: the neighbor's form is found out by the transition itself.
        let fixture = await makeRouteFixture(
            entry: mangaEntry(viewer), chapter: Self.c2, format: .pages, preparer: preparer, preloadImageCount: 0
        )
        return (fixture, preparer)
    }

    // MARK: - The source keeps its real position

    func testAPagedReaderStaysOnItsRealPageWhenTheNeighborTurnsOutToBeText() async throws {
        let (fixture, preparer) = await pagesRoute(.Ltr)
        let source = try XCTUnwrap(fixture.pagesModel)
        source.setPagedIndex(1)
        await fixture.session.waitForPositionWritesForTesting()
        let writes = fixture.manga.progress.savedPageWrites.count

        source.goToNextChapter()
        XCTAssertEqual(source.loadPhase, .loading, "The transition is under way")
        await source.waitForTestingOperations()
        await fixture.route.waitForPreparationForTesting()

        XCTAssertEqual(preparer.callCount("c3"), 1)
        XCTAssertEqual(source.loadPhase, .content)
        XCTAssertEqual(source.currentChapter.key, "c2")
        XCTAssertEqual(source.pagedIndex, 1, "The page the reader was on, not the first one")
        await fixture.session.waitForPositionWritesForTesting()
        XCTAssertEqual(fixture.manga.progress.savedPageWrites.count, writes, "The transient state wrote nothing")
        XCTAssertEqual(fixture.manga.progress.savedPages["c2"], 1)
        XCTAssertNil(fixture.manga.progress.savedPages["c3"])
        XCTAssertTrue(fixture.novel.progress.savedOffsetWrites.isEmpty, "Staging saved nothing")
        guard case .staging = fixture.route.phase else { return XCTFail("Handed off with what was loaded") }
        fixture.route.cancelHandoff()
    }

    func testAPagerThatRestedPastTheLastPageIsRestoredOnThatPage() async throws {
        let (fixture, _) = await pagesRoute(.Ltr)
        let source = try XCTUnwrap(fixture.pagesModel)
        source.setPagedIndex(2)
        await fixture.session.waitForPositionWritesForTesting()
        let writes = fixture.manga.progress.savedPageWrites.count

        source.setPagedIndex(source.pagedPages.count)
        await source.waitForTestingOperations()
        await fixture.route.waitForPreparationForTesting()

        XCTAssertEqual(source.pagedIndex, 2, "Not the notice index past the end")
        XCTAssertEqual(source.loadPhase, .content)
        await fixture.session.waitForPositionWritesForTesting()
        XCTAssertEqual(fixture.manga.progress.savedPageWrites.count, writes)
        fixture.route.cancelHandoff()
    }

    func testAContinuousReaderIsRestoredAtItsCurrentPageAsANonAnimatedTarget() async throws {
        let (fixture, _) = await pagesRoute(.Webtoon)
        let source = try XCTUnwrap(fixture.pagesModel)
        let ids = source.flatPages.map(\.id)
        source.continuousViewportChanged([ids[1]])
        await fixture.session.waitForPositionWritesForTesting()
        let writes = fixture.manga.progress.savedPageWrites.count

        source.goToNextChapter()
        XCTAssertEqual(source.loadPhase, .loading)
        await source.waitForTestingOperations()
        await fixture.route.waitForPreparationForTesting()

        XCTAssertEqual(source.loadPhase, .content)
        XCTAssertEqual(source.continuousPageIndex, 1)
        XCTAssertEqual(source.scrollTarget?.pageID, ids[1])
        XCTAssertEqual(source.scrollTarget?.animated, false)
        await fixture.session.waitForPositionWritesForTesting()
        XCTAssertEqual(fixture.manga.progress.savedPageWrites.count, writes)
        XCTAssertEqual(fixture.manga.progress.savedPages["c2"], 1)
        fixture.route.cancelHandoff()
    }

    func testATextReaderIsRestoredAtTheLastPlaceItReported() async throws {
        let chapters = [readerChapter("x3", 3, text: true), readerChapter("x2", 2, text: true), readerChapter("x1", 1, text: true)]
        let entry = MediaEntry.novel(Novel(key: "series", title: "Series", chapters: chapters))
        let preparer = ScriptedChapterPreparer()
        preparer.formats["x2"] = .text
        preparer.pages["x2"] = [Page(index: 0, content: .text("one two")), Page(index: 1, content: .text("three four"))]
        let fixture = await makeRouteFixture(entry: entry, chapter: chapters[1], format: .text, preparer: preparer)
        let source = try XCTUnwrap(fixture.textModel)
        let id = try XCTUnwrap(source.loadedChapters.first?.id)
        source.readingPositionChanged(chapterID: id, offset: 4, reachedEnd: false)
        await source.waitForAllOperationsForTesting()
        let reported = try XCTUnwrap(source.lastPosition)
        let writes = fixture.novel.progress.savedOffsetWrites.count

        source.goToNextChapter()
        XCTAssertEqual(source.loadPhase, .loading)
        await source.waitForAllOperationsForTesting()
        await fixture.route.waitForPreparationForTesting()

        XCTAssertEqual(source.loadPhase, .content)
        XCTAssertEqual(source.currentChapter.key, "x2")
        XCTAssertEqual(source.restoreAnchor, reported, "The view lands where the reader was, not at the top")
        XCTAssertFalse(source.userScrolledSinceInstall)
        await source.waitForAllOperationsForTesting()
        XCTAssertEqual(fixture.novel.progress.savedOffsetWrites.count, writes, "The transient state wrote nothing")
        XCTAssertEqual(fixture.novel.progress.savedOffsets["x2"], reported.offset)
        fixture.route.cancelHandoff()
    }

    // MARK: - A reader with nothing on screen

    func testPressingNextTwiceDoesNotLeaveALoadingReaderWhenTheSecondChapterIsText() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["c4"] = .text
        preparer.suspended = ["c3", "c4"]
        let fixture = await makeRouteFixture(
            entry: mangaEntry(.Ltr), chapter: Self.c2, format: .pages, preparer: preparer, preloadImageCount: 0
        )
        let source = try XCTUnwrap(fixture.pagesModel)

        source.goToNextChapter()
        await preparer.waitForPending(1)
        source.goToNextChapter()
        await preparer.waitForPending(2)
        XCTAssertNil(source.transition, "Nothing is on screen to put back")

        preparer.resolveFirst()
        preparer.resolveFirst()
        await source.waitForTestingOperations()

        XCTAssertNil(fixture.pagesModel, "The text reader replaced the one that had nothing to show")
        XCTAssertEqual(fixture.textModel?.currentChapter.key, "c4")
        XCTAssertEqual(fixture.textModel?.loadPhase, .content)
        guard case .idle = fixture.route.phase else { return XCTFail("The route is idle") }
    }

    func testTryAgainAfterAFailureOpensTheOtherReaderAtItsStartAndSavesThatPlace() async throws {
        let (fixture, preparer) = await pagesRoute(.Ltr)
        let source = try XCTUnwrap(fixture.pagesModel)
        fixture.novel.progress.savedOffsets["c3"] = 5
        preparer.failures["c3"] = MangaReaderTestError.expected
        source.goToNextChapter()
        await source.waitForTestingOperations()
        guard case .failure = source.loadPhase else { return XCTFail("The load failed") }

        preparer.failures["c3"] = nil
        preparer.pages["c3"] = [Page(index: 0, content: .text("a long enough chapter body"))]
        source.retry()
        await source.waitForTestingOperations()

        let destination = try XCTUnwrap(fixture.textModel, "The route opens the reader the chapter is made for")
        XCTAssertEqual(destination.currentChapter.key, "c3")
        XCTAssertEqual(destination.loadPhase, .content)
        XCTAssertNil(destination.restoreAnchor, "The saved number may belong to the other form: it opens at the start")
        XCTAssertNil(fixture.pagesModel)
        guard case .idle = fixture.route.phase else { return XCTFail("The route is idle") }
        // The new reader saves its first place, as the page reader does.
        await fixture.session.waitForPositionWritesForTesting()
        XCTAssertTrue(fixture.novel.progress.savedOffsetWrites.contains { $0.chapterID == "c3" && $0.offset == 0 })
        XCTAssertEqual(fixture.novel.history.requests.map(\.chapterKey), ["c3"])
    }

    func testARouteThatCannotTakeTheCorrectionLeavesTheReaderFailedNotLoading() async throws {
        let (fixture, preparer) = await pagesRoute(.Ltr)
        let source = try XCTUnwrap(fixture.pagesModel)
        let router = RecordingHandoffRouter()
        router.acceptsCorrections = false
        source.handoffRouter = router
        preparer.failures["c3"] = MangaReaderTestError.expected
        source.goToNextChapter()
        await source.waitForTestingOperations()

        preparer.failures["c3"] = nil
        source.retry()
        await source.waitForTestingOperations()

        XCTAssertEqual(router.corrections.map(\.key), ["c3"])
        XCTAssertEqual(router.corrections.map(\.position), [.start])
        guard case .failure = source.loadPhase else { return XCTFail("A refused correction is reported, not dropped") }
    }

    func testAClosedRouteRefusesTheCorrection() async throws {
        let (fixture, preparer) = await pagesRoute(.Ltr)
        let source = try XCTUnwrap(fixture.pagesModel)
        preparer.failures["c3"] = MangaReaderTestError.expected
        source.goToNextChapter()
        await source.waitForTestingOperations()

        fixture.route.close()
        preparer.failures["c3"] = nil
        source.retry()
        await source.waitForTestingOperations()

        XCTAssertTrue(fixture.pagesModel === source)
        guard case .failure = source.loadPhase else { return XCTFail("The reader says so itself") }
    }

    // MARK: - A failure that is shown, and a payload that cannot be drawn

    func testAFailureGivesWayWhenTheSourceLeavesItsBoundaryOrStartsANewCrossing() async throws {
        // t2 is declared as text, so the page reader hands it to the route and a failure is the route's.
        let chapters = [readerChapter("p3", 3), readerChapter("t2", 2, text: true), readerChapter("p1", 1)]
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t2"] = .text
        preparer.failures["t2"] = MangaReaderTestError.expected
        let fixture = await makeRouteFixture(
            entry: .manga(Manga(key: "series", title: "Series", viewer: .Ltr, chapters: chapters)),
            chapter: chapters[2], format: .pages, preparer: preparer
        )
        let source = try XCTUnwrap(fixture.pagesModel)
        source.goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .failed = fixture.route.phase else { return XCTFail("The failure is shown") }

        // The user pages away from the boundary: the failure no longer describes anything on screen.
        source.setPagedIndex(0)
        guard case .idle = fixture.route.phase else { return XCTFail("Navigating in the source clears it") }

        // A new crossing replaces a failure instead of being ignored behind it.
        source.goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .failed = fixture.route.phase else { return XCTFail("Failed again") }
        preparer.failures["t2"] = nil
        preparer.suspended = ["t2"]
        source.goToNextChapter()
        guard case .preparing = fixture.route.phase else { return XCTFail("The new crossing was taken") }
        fixture.route.cancelHandoff()
    }

    func testAChapterWithNoPagesFailsInsteadOfWaitingForever() async throws {
        let (fixture, preparer) = await pagesRoute(.Ltr)
        preparer.pages["c3"] = []
        let source = try XCTUnwrap(fixture.pagesModel)

        source.goToNextChapter()
        await source.waitForTestingOperations()
        await fixture.route.waitForPreparationForTesting()

        guard case .failed(_, let failure) = fixture.route.phase else { return XCTFail("Nothing to draw fails") }
        XCTAssertEqual(failure, .loadFailed)
        XCTAssertEqual(fixture.presentations.created.count, 1, "No destination was built for it")
        XCTAssertEqual(fixture.pagesModel?.currentChapter.key, "c2")
    }

    func testAPayloadForTheSourcesOwnReaderIsNotHandedOffAsAChapterBoundary() async throws {
        let (fixture, _) = await pagesRoute(.Ltr)
        let source = try XCTUnwrap(fixture.pagesModel)
        let resolver = OfflineChapterSourceResolver(
            pluginID: "plugin.test", local: UnavailableOfflineChapterReading(), hasRemote: true
        )
        func payload(_ format: HistoryReaderFormat) -> ReaderPreparedChapter {
            ReaderPreparedChapter(
                entry: mangaEntry(.Ltr), chapter: Self.c3, pages: threePages(), format: format,
                resolver: resolver, content: ReaderContentSource(remote: nil)
            )
        }
        func event() -> ReaderHandoffEvent {
            ReaderHandoffEvent(
                sourceVisitID: source.routeVisitID, sourceSessionID: source.sessionID,
                sourceContentGeneration: source.contentGeneration, origin: ChapterToken(Self.c2),
                direction: .next, position: .resume, trigger: .chapterControl, boundaryEntryID: UUID()
            )
        }

        // c3 is a plain chapter boundary for the page reader: a payload made for pages proves nothing.
        fixture.route.requestHandoff(event(), prepared: payload(.pages))
        guard case .idle = fixture.route.phase else { return XCTFail("The same reader is not swapped in") }
        XCTAssertEqual(fixture.presentations.created.count, 1)

        fixture.route.requestHandoff(event(), prepared: payload(.text))
        guard case .staging(_, .text) = fixture.route.phase else { return XCTFail("A payload for the other reader is") }
        fixture.route.cancelHandoff()
    }

    // MARK: - Consent and network

    func testAConsentSettingChangeDuringPreparationIsNotBypassedByAPolicyChange() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t2"] = .text
        preparer.suspended = ["t2"]
        let chapters = [readerChapter("p3", 3), Self.otherGroupText, readerChapter("p1", 1)]
        let fixture = await makeRouteFixture(
            entry: .manga(Manga(key: "series", title: "Series", chapters: chapters)), chapter: chapters[2],
            format: .pages, preparer: preparer
        )
        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await preparer.waitForPending(1)

        // Consent is switched on for another group, then the network policy moves.
        fixture.manga.settings.askBeforeSwitchingGroups = true
        fixture.network.policyRevision = 2
        fixture.route.networkDidChange()

        XCTAssertEqual(preparer.callCount("t2"), 1, "No second preparation started without asking")
        guard case .idle = fixture.route.phase else { return XCTFail("The stale request was dropped") }
        preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()
        XCTAssertEqual(fixture.presentations.created.count, 1)
    }

    func testAScopeChangeDuringPreparationIsNotRenewedUnderTheNewScope() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t2"] = .text
        preparer.suspended = ["t2"]
        let chapters = [readerChapter("p3", 3), Self.otherGroupText, readerChapter("p1", 1)]
        let fixture = await makeRouteFixture(
            entry: .manga(Manga(key: "series", title: "Series", chapters: chapters)), chapter: chapters[2],
            format: .pages, preparer: preparer
        )
        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await preparer.waitForPending(1)

        fixture.network.scope = UUID()
        fixture.network.policyRevision = 2
        fixture.route.networkDidChange()

        XCTAssertEqual(preparer.callCount("t2"), 1, "Nothing is requested under a scope nobody asked about")
        guard case .idle = fixture.route.phase else { return XCTFail("Dropped") }
        preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()
    }

    private static let otherGroupText: Chapter = {
        var chapter = readerChapter("t2", 2, text: true)
        chapter.scanlator = "Other"
        return chapter
    }()

    func testApprovingAPayloadTheSourceAlreadyLoadedFetchesNothingAgain() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["c3"] = .text
        var other = Self.c3
        other.scanlator = "Other"
        let entry = MediaEntry.manga(Manga(key: "series", title: "Series", viewer: .Ltr, chapters: [other, Self.c2]))
        // Opening the paged reader prefetches c3, which is found to be text and held as a payload.
        let fixture = await makeRouteFixture(entry: entry, chapter: Self.c2, format: .pages, preparer: preparer)
        XCTAssertEqual(preparer.callCount("c3"), 1)
        fixture.manga.settings.askBeforeSwitchingGroups = true
        let source = try XCTUnwrap(fixture.pagesModel)

        source.goToNextChapter()
        guard case .awaitingConsent(_, let consent) = fixture.route.phase else { return XCTFail("Asks first") }
        fixture.route.confirmHandoff(consentID: consent.id)

        XCTAssertEqual(preparer.callCount("c3"), 1, "The held payload is used, not fetched again")
        guard case .staging = fixture.route.phase else { return XCTFail("Staged from the held payload") }
        fixture.route.cancelHandoff()
    }

    // MARK: - A destination that is not live starts no speculative work

    func testAStagedPageReaderStartsNoAdjacentPrefetchUntilItIsLive() async throws {
        let chapters = [readerChapter("i3", 3), readerChapter("i2", 2), readerChapter("x1", 1, text: true)]
        let entry = MediaEntry.novel(Novel(key: "series", title: "Series", chapters: chapters))
        let preparer = ScriptedChapterPreparer()
        preparer.formats["x1"] = .text
        let fixture = await makeRouteFixture(entry: entry, chapter: chapters[2], format: .text, preparer: preparer)
        XCTAssertGreaterThan(fixture.manga.settings.mangaReaderAdjacentPrefetchCount, 0)

        try XCTUnwrap(fixture.textModel).goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(let request, let staged) = fixture.route.phase, case .pages(_, let destination) = staged else {
            return XCTFail("Staged as pages")
        }

        destination.beginAdjacentChapterPrefetch()
        destination.networkPolicyDidChange()
        destination.applyOfflineChange()
        await destination.waitForTestingOperations()
        XCTAssertEqual(preparer.callCount("i3"), 0, "Staged, it fetches nothing ahead")
        XCTAssertNil(destination.adjacentPrefetchOperationID)

        // Control: once it is live, the same reader does prefetch its next chapter.
        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)
        XCTAssertTrue(fixture.pagesModel === destination)
        await destination.waitForTestingOperations()
        XCTAssertEqual(preparer.callCount("i3"), 1)
    }
}
