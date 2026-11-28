import XCTest
import ito_runner
@testable import Ito

@MainActor
final class ReaderChapterJumpTests: XCTestCase {
    private static func chapter(
        _ key: String,
        _ number: Double,
        text: Bool = false,
        locked: Bool = false,
        other: Bool = false
    ) -> Chapter {
        var chapter = readerChapter(key, number, text: text, locked: locked)
        chapter.scanlator = other ? "Other" : "Group"
        chapter.scanlatorID = other ? "o" : "g"
        return chapter
    }

    private static let p1 = chapter("p1", 1)
    private static let p2 = chapter("p2", 2)
    private static let t3 = chapter("t3", 3, text: true)
    private static let p4 = chapter("p4", 4, locked: true)
    private static let p5 = chapter("p5", 5, other: true)
    private static let t6 = chapter("t6", 6, text: true, other: true)
    private static let mangaEntry = MediaEntry.manga(
        Manga(key: "series", title: "Series", chapters: [t6, p5, p4, t3, p2, p1])
    )

    private static let x1 = readerChapter("x1", 1, text: true)
    private static let x2 = readerChapter("x2", 2, text: true)
    private static let i3 = readerChapter("i3", 3)
    private static let x4 = readerChapter("x4", 4, text: true)
    private static let x5 = readerChapter("x5", 5, text: true, locked: true)
    private static let novelEntry = MediaEntry.novel(
        Novel(key: "series", title: "Series", chapters: [x5, x4, i3, x2, x1])
    )

    private static func pageList(_ key: String, count: Int = 1) -> [Page] {
        (0..<count).map { Page(index: Int32($0), content: .url("https://img.test/\(key)-\($0).jpg")) }
    }

    private func urls(_ model: MangaReaderViewModel) -> [String] {
        model.pagedPages.compactMap { page -> String? in
            guard case .url(let url) = page.content else { return nil }
            return url
        }
    }

    private func row(_ model: MangaReaderViewModel, _ key: String) -> ReaderChapterListRow? {
        model.chapterListRows.first { $0.chapter.key == key }
    }

    private func row(_ model: NovelReaderViewModel, _ key: String) -> ReaderChapterListRow? {
        model.chapterListRows.first { $0.chapter.key == key }
    }

    private func mangaRoute(
        _ chapter: Chapter,
        entry: MediaEntry? = nil,
        preparer: ScriptedChapterPreparer = ScriptedChapterPreparer()
    ) async -> RouteFixture {
        await makeRouteFixture(
            entry: entry ?? Self.mangaEntry,
            chapter: chapter,
            format: .pages,
            preparer: preparer
        )
    }

    private func novelRoute(_ chapter: Chapter, preparer: ScriptedChapterPreparer) async -> RouteFixture {
        await makeRouteFixture(entry: Self.novelEntry, chapter: chapter, format: .text, preparer: preparer)
    }

    private func makeMangaSubject(
        _ chapter: Chapter,
        entry: MediaEntry? = nil,
        offline: (any ReaderOfflineAvailability)? = nil
    ) -> MangaReaderTestSubject {
        makeMangaReaderSubject(
            entry: entry ?? Self.mangaEntry,
            initialChapter: chapter,
            offlineAvailability: offline ?? UnavailableReaderOfflineAvailability()
        )
    }

    private func start(_ subject: MangaReaderTestSubject) async {
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
    }

    private func makeNovelSubject(
        _ chapter: Chapter,
        offline: (any ReaderOfflineAvailability)? = nil
    ) -> NovelReaderTestSubject {
        makeNovelReaderSubject(
            entry: Self.novelEntry,
            initialChapter: chapter,
            offlineAvailability: offline ?? UnavailableReaderOfflineAvailability()
        )
    }

    private func start(_ subject: NovelReaderTestSubject) async {
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
    }

    private func preparingRequest(_ fixture: RouteFixture) -> ReaderHandoffRequest? {
        guard case .preparing(let request) = fixture.route.phase else { return nil }
        return request
    }

    private func reportReady(_ fixture: RouteFixture) {
        guard case .staging(let request, let staged) = fixture.route.phase else {
            XCTFail("expected staging, got \(fixture.route.phase)")
            return
        }
        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)
    }

    private func assertIdle(_ fixture: RouteFixture) {
        guard case .idle = fixture.route.phase else {
            XCTFail("expected idle, got \(fixture.route.phase)")
            return
        }
    }

    /// Resolves the one suspended preparation a test left behind, so no continuation leaks.
    private func drain(_ fixture: RouteFixture) async {
        await fixture.preparer.waitForPending(1)
        fixture.preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()
    }

    private func event(
        _ model: MangaReaderViewModel,
        origin: ChapterToken,
        target: ReaderHandoffTarget
    ) -> ReaderHandoffEvent {
        ReaderHandoffEvent(
            sourceVisitID: model.routeVisitID,
            sourceSessionID: model.sessionID,
            sourceContentGeneration: model.contentGeneration,
            origin: origin,
            direction: .next,
            position: .resume,
            trigger: .chapterControl,
            boundaryEntryID: UUID(),
            target: target
        )
    }

    // MARK: Same-reader picks

    func testAPickOfThisReadersChapterOpensInPlaceAtItsResumePage() async {
        let preparer = ScriptedChapterPreparer()
        preparer.pages["p2"] = Self.pageList("p2", count: 3)
        let fixture = await mangaRoute(Self.p1, preparer: preparer)
        guard let source = fixture.pagesModel else { return XCTFail("expected the pages reader") }
        fixture.manga.progress.savedPages["p2"] = 1

        XCTAssertTrue(source.jump(to: Self.p2))
        await source.waitForTestingOperations()

        XCTAssertTrue(fixture.pagesModel === source)
        XCTAssertEqual(fixture.presentations.created.count, 1)
        assertIdle(fixture)
        XCTAssertEqual(source.currentChapter.key, "p2")
        XCTAssertEqual(source.pagedIndex, 1)
        XCTAssertEqual(fixture.preparer.callCount("p2"), 1)
    }

    func testAPickNeverAsksAboutItsGroupEvenWhenAskingIsOn() async {
        let fixture = await mangaRoute(Self.p1)
        fixture.manga.settings.askBeforeSwitchingGroups = true
        fixture.novel.settings.askBeforeSwitchingGroups = true
        guard let source = fixture.pagesModel else { return XCTFail("expected the pages reader") }
        fixture.manga.loader.enqueue(.pages(Self.pageList("p5")), for: "p5")

        XCTAssertTrue(source.jump(to: Self.p5))
        await source.waitForTestingOperations()
        XCTAssertNil(source.groupSwitchConsent)
        XCTAssertEqual(source.currentChapter.key, "p5")

        let crossing = ScriptedChapterPreparer()
        crossing.formats["t6"] = .text
        crossing.suspended = ["t6"]
        let other = await mangaRoute(Self.p1, preparer: crossing)
        other.manga.settings.askBeforeSwitchingGroups = true
        guard let otherSource = other.pagesModel else { return XCTFail("expected the pages reader") }

        XCTAssertTrue(otherSource.jump(to: Self.t6))
        guard let request = preparingRequest(other) else { return XCTFail("expected preparing") }
        XCTAssertEqual(request.event.target, .chosen(ChapterToken(Self.t6)))
        XCTAssertNil(otherSource.groupSwitchConsent)
        XCTAssertTrue(other.manga.settings.askBeforeSwitchingGroups)
        await drain(other)
    }

    func testALockedPickIsRefusedAndRequestsNothing() async {
        let subject = makeMangaSubject(Self.p1)
        await start(subject)

        XCTAssertFalse(subject.viewModel.jump(to: Self.p4))
        XCTAssertEqual(subject.loader.callCount(for: "p4"), 0)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "p1")
        XCTAssertEqual(row(subject.viewModel, "p4")?.availability, .locked)
        XCTAssertEqual(row(subject.viewModel, "p4")?.isSelectable, false)
    }

    func testAPickWithoutAStoredCopyIsRefusedOfflineAndOpensOnceDownloaded() async {
        let offline = ReaderAvailabilityFake(isOffline: true, verified: ["p1"])
        let subject = makeMangaSubject(Self.p1, offline: offline)
        await start(subject)

        XCTAssertFalse(subject.viewModel.jump(to: Self.p2))
        XCTAssertEqual(row(subject.viewModel, "p2")?.availability, .notDownloaded)

        offline.verified.insert("p2")
        XCTAssertEqual(row(subject.viewModel, "p2")?.availability, .opensHere)
        subject.loader.enqueue(.pages(Self.pageList("p2")), for: "p2")
        XCTAssertTrue(subject.viewModel.jump(to: Self.p2))
        await subject.viewModel.waitForTestingOperations()
        XCTAssertEqual(subject.viewModel.currentChapter.key, "p2")
    }

    func testRapidPicksInThisReaderLetTheLatestWin() async {
        let subject = makeMangaSubject(Self.p5)
        await start(subject)
        subject.loader.enqueue(.suspended, for: "p2")
        subject.loader.enqueue(.suspended, for: "p1")

        XCTAssertTrue(subject.viewModel.jump(to: Self.p2))
        await subject.loader.waitForPendingCount(1, for: "p2")
        XCTAssertTrue(subject.viewModel.jump(to: Self.p1))
        await subject.loader.waitForPendingCount(1, for: "p1")
        subject.loader.resolveFirst(for: "p2", with: .success(Self.pageList("p2")))
        subject.loader.resolveFirst(for: "p1", with: .success(Self.pageList("p1")))
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.viewModel.currentChapter.key, "p1")
        XCTAssertEqual(urls(subject.viewModel), ["https://img.test/p1-0.jpg"])
        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["p5", "p1"])
        XCTAssertFalse(subject.progress.savedPageWrites.contains { $0.chapterID == "p2" })
    }

    func testAPickRecordsItsChapterInHistoryAgain() async {
        let subject = makeMangaSubject(Self.p1)
        await start(subject)
        subject.loader.enqueue(.pages(Self.pageList("p2")), for: "p2")

        XCTAssertTrue(subject.viewModel.jump(to: Self.p2))
        await subject.viewModel.waitForTestingOperations()
        XCTAssertTrue(subject.viewModel.jump(to: Self.p1))
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.history.requests.map(\.chapterKey), ["p1", "p2", "p1"])
    }

    func testAPickToAnEarlierChapterWritesNoReadMarkAndNoTrackerProgress() async {
        let subject = makeMangaSubject(Self.p5)
        await start(subject)
        subject.loader.enqueue(.pages(Self.pageList("p2", count: 3)), for: "p2")
        let claimedBefore = subject.session.claimedCompletionKeys

        XCTAssertTrue(subject.viewModel.jump(to: Self.p2))
        await subject.viewModel.waitForTestingOperations()

        XCTAssertTrue(subject.progress.requests.isEmpty)
        XCTAssertTrue(subject.tracker.requests.isEmpty)
        XCTAssertEqual(subject.session.claimedCompletionKeys, claimedBefore)
        XCTAssertEqual(subject.progress.savedPageWrites.last?.chapterID, "p2")
        XCTAssertEqual(subject.progress.savedPageWrites.last?.page, 0)
    }

    func testThePickOfTheCurrentChapterIsANoOp() async {
        let subject = makeMangaSubject(Self.p1)
        await start(subject)

        XCTAssertTrue(subject.viewModel.jump(to: Self.p1))
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.loader.callCount(for: "p1"), 1)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "p1")
    }

    func testThePickOfTheCurrentChapterRetriesAFailedOpening() async {
        let subject = makeMangaSubject(Self.p1)
        subject.loader.enqueue(.failure(MangaReaderTestError.expected), for: "p1")
        await start(subject)

        XCTAssertTrue(subject.viewModel.jump(to: Self.p1))
        await subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(subject.loader.callCount(for: "p1"), 2)
    }

    func testAPickWithNothingOnScreenIsCorrectedInPlace() async {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t3"] = .text
        preparer.failures["p1"] = MangaReaderTestError.expected
        let fixture = await makeRouteFixture(
            entry: Self.mangaEntry,
            chapter: Self.p1,
            format: .pages,
            preparer: preparer
        )
        guard let source = fixture.pagesModel else { return XCTFail("expected the pages reader") }
        guard case .failure = source.loadPhase else {
            return XCTFail("expected a failed opening, got \(source.loadPhase)")
        }

        XCTAssertTrue(source.jump(to: Self.t3))
        await source.waitForTestingOperations()
        await fixture.route.waitForPreparationForTesting()
        assertIdle(fixture)

        XCTAssertEqual(fixture.textModel?.currentChapter.key, "t3")
    }

    // MARK: Other-reader picks

    func testAPickOfTheOtherReadersChapterIsPreparedBehindTheSourceAndCommits() async {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t3"] = .text
        preparer.suspended = ["t3"]
        let fixture = await mangaRoute(Self.p1, preparer: preparer)
        guard let source = fixture.pagesModel else { return XCTFail("expected the pages reader") }

        XCTAssertTrue(source.jump(to: Self.t3))
        guard let request = preparingRequest(fixture) else { return XCTFail("expected preparing") }
        XCTAssertEqual(request.event.target, .chosen(ChapterToken(Self.t3)))
        XCTAssertEqual(request.event.position, .resume)
        XCTAssertEqual(request.chapter.key, "t3")
        XCTAssertEqual(source.currentChapter.key, "p1")
        XCTAssertEqual(source.loadPhase, .content)
        XCTAssertTrue(fixture.novel.history.requests.isEmpty)

        await preparer.waitForPending(1)
        preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()
        reportReady(fixture)

        XCTAssertEqual(fixture.textModel?.currentChapter.key, "t3")
        XCTAssertEqual(fixture.novel.history.requests.map(\.chapterKey), ["t3"])
        assertIdle(fixture)
    }

    func testAPickOfAChapterSavedInTheOtherFormRestoresTheSourceAndHandsOffWithItsPayload() async {
        // Declared as text, so the pages reader does not open it here and hands it to the text reader.
        let text = Self.chapter("q2", 2, text: true)
        let entry = MediaEntry.manga(Manga(key: "series", title: "Series", chapters: [Self.t6, Self.p5, Self.p4, Self.t3, text, Self.p1]))
        let preparer = ScriptedChapterPreparer()
        preparer.formats["q2"] = .text
        let fixture = await mangaRoute(Self.p1, entry: entry, preparer: preparer)
        guard let source = fixture.pagesModel else { return XCTFail("expected the pages reader") }

        XCTAssertTrue(source.jump(to: text))
        await fixture.route.waitForPreparationForTesting()

        guard case .staging(let request, _) = fixture.route.phase else {
            return XCTFail("expected staging, got \(fixture.route.phase)")
        }
        XCTAssertEqual(request.event.target, .chosen(ChapterToken(text)))
        XCTAssertEqual(source.currentChapter.key, "p1")
        XCTAssertEqual(source.pagedIndex, 0)
        XCTAssertEqual(preparer.callCount("q2"), 1)

        reportReady(fixture)
        XCTAssertEqual(fixture.textModel?.currentChapter.key, "q2")
    }

    func testAFailedCrossReaderPickIsRetriedAsANewOperationAndEndsWhenTheReaderMoves() async {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t3"] = .text
        preparer.failures["t3"] = MangaReaderTestError.expected
        let fixture = await mangaRoute(Self.p1, preparer: preparer)
        guard let source = fixture.pagesModel else { return XCTFail("expected the pages reader") }

        XCTAssertTrue(source.jump(to: Self.t3))
        await fixture.route.waitForPreparationForTesting()
        guard case .failed(let first, _) = fixture.route.phase else {
            return XCTFail("expected failed, got \(fixture.route.phase)")
        }

        fixture.route.retryHandoff(requestID: first.id)
        await fixture.route.waitForPreparationForTesting()
        guard case .failed(let second, _) = fixture.route.phase else {
            return XCTFail("expected failed after retry, got \(fixture.route.phase)")
        }
        XCTAssertNotEqual(first.id, second.id)

        fixture.route.handoffBoundaryLeft(visitID: source.routeVisitID)
        assertIdle(fixture)
    }

    func testANeighborCrossingAfterAPickIsNotSwallowedByThePicksLatch() async {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t3"] = .text
        preparer.formats["t6"] = .text
        preparer.failures["t6"] = MangaReaderTestError.expected
        preparer.suspended = ["t3"]
        let fixture = await mangaRoute(Self.p2, preparer: preparer)
        guard let source = fixture.pagesModel else { return XCTFail("expected the pages reader") }

        XCTAssertTrue(source.jump(to: Self.t6))
        await fixture.route.waitForPreparationForTesting()
        guard case .failed = fixture.route.phase else {
            return XCTFail("expected failed, got \(fixture.route.phase)")
        }
        fixture.route.cancelHandoff()

        source.setPagedIndex(source.pagedPages.count)
        guard let request = preparingRequest(fixture) else { return XCTFail("expected preparing") }
        XCTAssertEqual(request.chapter.key, "t3")
        XCTAssertEqual(request.event.target, .adjacent)
        await drain(fixture)
    }

    func testAChosenRequestNoLongerStandsOnceTheSourceIsOnAnotherChapter() async {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t3"] = .text
        preparer.suspended = ["t3"]
        let fixture = await mangaRoute(Self.p1, preparer: preparer)
        guard let source = fixture.pagesModel else { return XCTFail("expected the pages reader") }

        XCTAssertTrue(source.jump(to: Self.t3))
        fixture.manga.loader.enqueue(.pages(Self.pageList("p2")), for: "p2")
        source.goToNextChapter()
        await source.waitForTestingOperations()

        await drain(fixture)
        assertIdle(fixture)
        XCTAssertEqual(fixture.presentations.created.count, 1)
        XCTAssertTrue(fixture.novel.history.requests.isEmpty)
    }

    func testACancelledCrossReaderPickPublishesNothingAndAnotherPickIsANewRequest() async {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t3"] = .text
        preparer.suspended = ["t3"]
        let fixture = await mangaRoute(Self.p1, preparer: preparer)
        guard let source = fixture.pagesModel else { return XCTFail("expected the pages reader") }

        XCTAssertTrue(source.jump(to: Self.t3))
        guard let first = preparingRequest(fixture) else { return XCTFail("expected preparing") }
        fixture.route.cancelHandoff()
        await drain(fixture)

        assertIdle(fixture)
        XCTAssertEqual(fixture.presentations.created.count, 1)
        XCTAssertTrue(fixture.novel.history.requests.isEmpty)

        XCTAssertTrue(source.jump(to: Self.t3))
        guard let second = preparingRequest(fixture) else { return XCTFail("expected preparing") }
        XCTAssertNotEqual(first.id, second.id)
        await drain(fixture)
    }

    func testAPickWhileAHandoffIsPendingIsRefused() async {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t3"] = .text
        preparer.suspended = ["t3"]
        let fixture = await mangaRoute(Self.p1, preparer: preparer)
        guard let source = fixture.pagesModel else { return XCTFail("expected the pages reader") }

        XCTAssertTrue(source.jump(to: Self.t3))
        XCTAssertNotNil(preparingRequest(fixture))
        XCTAssertFalse(source.jump(to: Self.p2))
        XCTAssertEqual(source.currentChapter.key, "p1")
        XCTAssertEqual(fixture.manga.loader.callCount(for: "p2"), 0)
        await drain(fixture)
    }

    func testAPickWhileAGroupConsentHandoffIsAwaitingIsRefused() async {
        let entry = MediaEntry.manga(Manga(key: "series", title: "Series", chapters: [Self.t6, Self.p2, Self.p1]))
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t6"] = .text
        let fixture = await mangaRoute(Self.p2, entry: entry, preparer: preparer)
        fixture.manga.settings.askBeforeSwitchingGroups = true
        guard let source = fixture.pagesModel else { return XCTFail("expected the pages reader") }

        source.goToNextChapter()
        guard case .awaitingConsent = fixture.route.phase else {
            return XCTFail("expected awaitingConsent, got \(fixture.route.phase)")
        }
        XCTAssertFalse(source.jump(to: Self.p1))
        XCTAssertEqual(source.currentChapter.key, "p2")
    }

    func testAChosenEventForAnUnlistedOrMovedOriginHasNoBoundary() async {
        let subject = makeMangaSubject(Self.p1)
        await start(subject)
        let model = subject.viewModel
        let ghost = Self.chapter("ghost", 9, text: true)

        let unlisted = event(model, origin: ChapterToken(Self.p1), target: .chosen(ChapterToken(ghost)))
        XCTAssertNil(model.handoffBoundary(for: unlisted))

        let moved = event(model, origin: ChapterToken(Self.p2), target: .chosen(ChapterToken(Self.t3)))
        XCTAssertFalse(model.isCurrentHandoffSource(moved))
    }

    // MARK: Text reader

    func testTheTextReaderAppliesTheSameRules() async {
        let subject = makeNovelSubject(Self.x1)
        await start(subject)
        subject.progress.savedOffsets["x4"] = 42

        XCTAssertTrue(subject.viewModel.jump(to: Self.x4))
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.viewModel.currentChapter.key, "x4")
        XCTAssertEqual(subject.progress.savedOffsets["x4"], 42)

        XCTAssertFalse(subject.viewModel.jump(to: Self.x5))
        XCTAssertEqual(row(subject.viewModel, "x5")?.availability, .locked)

        let preparer = ScriptedChapterPreparer()
        preparer.formats["x1"] = .text
        preparer.formats["x4"] = .text
        preparer.suspended = ["i3"]
        let fixture = await novelRoute(Self.x1, preparer: preparer)
        guard let reader = fixture.textModel else { return XCTFail("expected the text reader") }

        XCTAssertTrue(reader.jump(to: Self.i3))
        guard let request = preparingRequest(fixture) else { return XCTFail("expected preparing") }
        XCTAssertEqual(request.event.target, .chosen(ChapterToken(Self.i3)))
        await drain(fixture)
    }

    func testTheTextReaderRefusesAnOfflineChapterUntilItIsDownloaded() async {
        let offline = ReaderAvailabilityFake(isOffline: true, verified: ["x1"])
        let subject = makeNovelSubject(Self.x1, offline: offline)
        await start(subject)

        XCTAssertFalse(subject.viewModel.jump(to: Self.x2))
        XCTAssertEqual(row(subject.viewModel, "x2")?.availability, .notDownloaded)

        offline.verified.insert("x2")
        XCTAssertEqual(row(subject.viewModel, "x2")?.availability, .opensHere)
        XCTAssertTrue(subject.viewModel.jump(to: Self.x2))
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.viewModel.currentChapter.key, "x2")
    }
}
