import Combine
import ito_runner
import XCTest
@testable import Ito

/// A route moves between the page reader and the text reader when the next chapter is made for the other one.
/// Everything here is driven by explicit barriers: a suspended preparation, a readiness report, a scope change.
@MainActor
final class ReaderRouteCoordinatorTests: XCTestCase {
    private static let p1 = readerChapter("p1", 1)
    private static let t2: Chapter = {
        var chapter = readerChapter("t2", 2, text: true)
        chapter.scanlator = "Other"
        return chapter
    }()
    private static let p3 = readerChapter("p3", 3)
    private static let mangaEntry = MediaEntry.manga(Manga(key: "series", title: "Series", chapters: [p3, t2, p1]))

    private static let x1 = readerChapter("x1", 1, text: true)
    private static let i2 = readerChapter("i2", 2)
    private static let x3 = readerChapter("x3", 3, text: true)
    private static let novelEntry = MediaEntry.novel(Novel(key: "series", title: "Series", chapters: [x3, i2, x1]))

    /// A page reader opened on p1 whose next chapter t2 is text, with `t2` held until the test lets it go.
    private func pagesRoute(suspending: Bool = true) async -> RouteFixture {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t2"] = .text
        if suspending { preparer.suspended = ["t2"] }
        return await makeRouteFixture(entry: Self.mangaEntry, chapter: Self.p1, format: .pages, preparer: preparer)
    }

    private func textRoute() async -> RouteFixture {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["x1"] = .text
        preparer.formats["x3"] = .text
        preparer.suspended = ["i2"]
        return await makeRouteFixture(entry: Self.novelEntry, chapter: Self.x1, format: .text, preparer: preparer)
    }

    /// Reports that the staged destination's first layout is applied, as its view would.
    private func reportReady(_ fixture: RouteFixture) {
        guard case .staging(let request, let staged) = fixture.route.phase else { return XCTFail("Nothing is staged") }
        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)
    }

    private func prepareStaged(_ fixture: RouteFixture, key: String) async {
        await fixture.preparer.waitForPending(1)
        fixture.preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()
        _ = key
    }

    // MARK: - Pages to text and text to pages

    func testNextCrossingPreparesBehindTheSourceThenCommitsOnceWhenReady() async throws {
        let fixture = await pagesRoute()
        let source = try XCTUnwrap(fixture.pagesModel)
        XCTAssertEqual(fixture.manga.history.requests.map(\.chapterKey), ["p1"], "Opening p1 recorded it once")
        let historyBefore = fixture.manga.history.requests.count

        source.goToNextChapter()
        guard case .preparing(let request) = fixture.route.phase else { return XCTFail("The crossing is being prepared") }
        await fixture.preparer.waitForPending(1)

        // The visible reader is untouched while the destination loads.
        XCTAssertTrue(fixture.pagesModel === source)
        XCTAssertEqual(source.currentChapter.key, "p1")
        XCTAssertEqual(source.loadPhase, .content)
        XCTAssertEqual(fixture.novel.history.requests.count, 0)

        let operation = try XCTUnwrap(fixture.preparer.calls.first { $0.key == "t2" }?.operation)
        XCTAssertEqual(operation.purpose, .foregroundReading)
        XCTAssertEqual(operation.operationID, request.id)
        XCTAssertNil(operation.batchID)
        XCTAssertNil(operation.scopedGrant)
        XCTAssertEqual(operation.policyRevision, fixture.network.policyRevision)

        fixture.preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(_, let staged) = fixture.route.phase, case .text(_, let destination) = staged else {
            return XCTFail("The prepared chapter is staged in the text reader")
        }
        // Staged: laid out behind the source, with no effect of its own.
        XCTAssertTrue(fixture.pagesModel === source)
        XCTAssertEqual(destination.presentationMode, .staged(requestID: request.id, visitID: staged.visitID))
        XCTAssertEqual(fixture.novel.history.requests.count, 0)
        XCTAssertTrue(fixture.novel.progress.savedOffsetWrites.isEmpty)
        XCTAssertEqual(fixture.novel.presence.events.count, 0)

        reportReady(fixture)
        XCTAssertTrue(fixture.textModel === destination)
        XCTAssertEqual(destination.presentationMode, .live)
        XCTAssertEqual(fixture.novel.history.requests.map(\.chapterKey), ["t2"])
        XCTAssertEqual(fixture.novel.history.requests.first?.format, .text)
        XCTAssertEqual(fixture.novel.history.requests.first?.entry.kind, .manga)
        XCTAssertEqual(fixture.manga.history.requests.count, historyBefore)
        XCTAssertFalse(source.isActive)
        XCTAssertEqual(fixture.manga.presence.events.last, .clear)

        // A duplicate readiness report finds nothing to commit.
        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)
        XCTAssertEqual(fixture.novel.history.requests.count, 1)
        XCTAssertEqual(fixture.preparer.callCount("t2"), 1)
        guard case .idle = fixture.route.phase else { return XCTFail("The route is idle after the swap") }
    }

    func testTextToPagesCrossingKeepsTheNovelCatalogKind() async throws {
        let fixture = await textRoute()
        let source = try XCTUnwrap(fixture.textModel)

        source.goToNextChapter()
        await prepareStaged(fixture, key: "i2")
        reportReady(fixture)

        let destination = try XCTUnwrap(fixture.pagesModel)
        XCTAssertEqual(destination.currentChapter.key, "i2")
        XCTAssertEqual(fixture.manga.history.requests.map(\.chapterKey), ["i2"])
        XCTAssertEqual(fixture.manga.history.requests.first?.format, .pages)
        XCTAssertEqual(fixture.manga.history.requests.first?.entry.kind, .novel)
    }

    func testMixedPayloadStaysInTheChosenRendererUnchangedAndInOrder() async throws {
        let fixture = await pagesRoute()
        let mixed = [
            Page(index: 0, content: .text("first")),
            Page(index: 1, content: .url("https://example.test/illustration.png")),
            Page(index: 2, content: .text("last"))
        ]
        fixture.preparer.pages["t2"] = mixed

        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await prepareStaged(fixture, key: "t2")
        guard case .staging(_, .text(_, let destination)) = fixture.route.phase else { return XCTFail("Staged as text") }

        XCTAssertEqual(destination.loadedChapters.first?.pages.map(\.index), [0, 1, 2])
        XCTAssertEqual(fixture.preparer.callCount("t2"), 1)
        fixture.route.cancelHandoff()
    }

    // MARK: - Positions

    func testPagedEdgesUseStartAndEndAndTheControlsResume() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t2"] = .text
        preparer.formats["p3"] = .pages
        let fixture = await makeRouteFixture(entry: Self.mangaEntry, chapter: Self.p1, format: .pages, preparer: preparer)
        let source = try XCTUnwrap(fixture.pagesModel)
        let router = RecordingHandoffRouter()
        source.handoffRouter = router

        source.setPagedIndex(source.pagedPages.count)
        source.goToNextChapter()

        XCTAssertEqual(router.events.map(\.position), [.start, .resume])
        XCTAssertEqual(router.events.map(\.trigger), [.pagedEdge, .chapterControl])
        XCTAssertEqual(router.events.map(\.direction), [.next, .next])
        // The reader's own position did not move.
        XCTAssertEqual(source.pagedIndex, 0)
    }

    func testBackwardEdgeOpensTheDestinationAtTheEndOfItsText() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t2"] = .text
        preparer.pages["t2"] = [Page(index: 0, content: .text("one")), Page(index: 1, content: .text("two"))]
        let fixture = await makeRouteFixture(entry: Self.mangaEntry, chapter: Self.p3, format: .pages, preparer: preparer)
        let source = try XCTUnwrap(fixture.pagesModel)

        source.setPagedIndex(-1)
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(_, .text(_, let destination)) = fixture.route.phase else { return XCTFail("Staged as text") }

        XCTAssertEqual(destination.restoreAnchor?.offset, NovelTextOffsets.bodyLength(preparer.pages["t2"] ?? []))
    }

    func testResumeUsesTheDestinationsOwnSavedPositionAndStartIgnoresIt() async throws {
        let fixture = await pagesRoute(suspending: false)
        fixture.novel.progress.savedOffsets["t2"] = 3
        fixture.preparer.pages["t2"] = [Page(index: 0, content: .text("a long enough chapter body"))]

        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(_, .text(_, let resumed)) = fixture.route.phase else { return XCTFail("Staged as text") }
        XCTAssertEqual(resumed.restoreAnchor?.offset, 3)
        fixture.route.cancelHandoff()

        // Cancelling leaves the boundary latched; leaving it and arriving again is a new crossing.
        try XCTUnwrap(fixture.pagesModel).releaseHandoffLatch()
        try XCTUnwrap(fixture.pagesModel).setPagedIndex(1)
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(_, .text(_, let started)) = fixture.route.phase else { return XCTFail("Staged as text") }
        XCTAssertNil(started.restoreAnchor)
    }

    // MARK: - Consent

    func testDefaultOffCrossesDirectlyWithoutAsking() async throws {
        let fixture = await pagesRoute()
        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        guard case .preparing = fixture.route.phase else { return XCTFail("No consent is asked by default") }
        fixture.route.cancelHandoff()
    }

    func testAnotherGroupAsksBeforeAnyDestinationRequestAndCancelIsSilent() async throws {
        let fixture = await pagesRoute()
        fixture.manga.settings.askBeforeSwitchingGroups = true
        let source = try XCTUnwrap(fixture.pagesModel)

        source.goToNextChapter()
        guard case .awaitingConsent(let request, let consent) = fixture.route.phase else {
            return XCTFail("A different group asks first")
        }
        XCTAssertEqual(consent.chapter.key, "t2")
        XCTAssertEqual(fixture.preparer.calls.count, 1, "Only the opening chapter was ever requested")
        XCTAssertNil(request.event.groupSwitchApproved ? request : nil)

        fixture.route.cancelHandoff()
        guard case .idle = fixture.route.phase else { return XCTFail("Cancel leaves the route idle") }
        XCTAssertEqual(fixture.preparer.callCount("t2"), 0)
        XCTAssertTrue(fixture.pagesModel === source)
        XCTAssertEqual(source.currentChapter.key, "p1")
    }

    func testConfirmingOpensThatOneUploadAndTheNextBoundaryAsksAgain() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t2"] = .text
        preparer.formats["p3"] = .pages
        let fixture = await makeRouteFixture(entry: Self.mangaEntry, chapter: Self.p1, format: .pages, preparer: preparer)
        fixture.manga.settings.askBeforeSwitchingGroups = true

        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        guard case .awaitingConsent(_, let consent) = fixture.route.phase else { return XCTFail("Asks first") }
        fixture.route.confirmHandoff(consentID: consent.id)
        await fixture.route.waitForPreparationForTesting()
        reportReady(fixture)
        XCTAssertEqual(fixture.textModel?.currentChapter.key, "t2")
        XCTAssertEqual(fixture.manga.settings.askBeforeSwitchingGroups, true, "The setting is not written")

        // Nothing was remembered: the next transition across another group asks again.
        fixture.novel.settings.askBeforeSwitchingGroups = true
        fixture.textModel?.goToNextChapter()
        guard case .awaitingConsent = fixture.route.phase else { return XCTFail("A new boundary asks again") }
        XCTAssertEqual(preparer.callCount("p3"), 0)
    }

    func testTheSameGroupCrossesDirectlyEvenWhenAsking() async throws {
        let sameGroup = Manga(key: "series", title: "Series", chapters: [
            Self.sameGroup("p1", 1, text: false), Self.sameGroup("t2", 2, text: true)
        ])
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t2"] = .text
        preparer.suspended = ["t2"]
        let fixture = await makeRouteFixture(
            entry: .manga(sameGroup), chapter: Self.sameGroup("p1", 1, text: false), format: .pages, preparer: preparer
        )
        fixture.manga.settings.askBeforeSwitchingGroups = true

        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        guard case .preparing = fixture.route.phase else { return XCTFail("The same group needs no consent") }
        fixture.route.cancelHandoff()
    }

    func testAnUnverifiableSourceScopeCannotAuthorizeAGroupSwitch() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t2"] = .text
        let fixture = await makeRouteFixture(
            entry: Self.mangaEntry, chapter: Self.p1, format: .pages, preparer: preparer, epoch: nil
        )
        fixture.manga.settings.askBeforeSwitchingGroups = true

        try XCTUnwrap(fixture.pagesModel).goToNextChapter()

        guard case .idle = fixture.route.phase else { return XCTFail("No consent can be minted without a scope") }
        XCTAssertEqual(preparer.callCount("t2"), 0)
    }

    private static func sameGroup(_ key: String, _ number: Double, text: Bool) -> Chapter {
        var chapter = readerChapter(key, number, text: text)
        chapter.scanlator = "Group"
        chapter.scanlatorID = "g"
        return chapter
    }

    // MARK: - Failure, cancel and stale work

    func testAFailedPreparationKeepsTheSourceAndRetryIsANewOperation() async throws {
        let fixture = await pagesRoute(suspending: false)
        let source = try XCTUnwrap(fixture.pagesModel)
        fixture.preparer.failures["t2"] = OfflineReadError.localCopyUnavailable

        source.goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .failed(let first, let failure) = fixture.route.phase else { return XCTFail("The failure is shown") }
        XCTAssertEqual(failure, .localCopyUnavailable)
        XCTAssertTrue(fixture.pagesModel === source)
        XCTAssertEqual(source.loadPhase, .content)
        XCTAssertEqual(fixture.novel.history.requests.count, 0)

        fixture.preparer.failures["t2"] = nil
        fixture.route.retryHandoff(requestID: first.id)
        guard case .preparing(let second) = fixture.route.phase else { return XCTFail("Retry starts again") }
        XCTAssertNotEqual(first.id, second.id)
        await fixture.route.waitForPreparationForTesting()
        reportReady(fixture)
        XCTAssertEqual(fixture.textModel?.currentChapter.key, "t2")
        XCTAssertEqual(fixture.preparer.callCount("t2"), 2)
    }

    func testFailuresAreTypedWithoutLeakingTheSource() {
        XCTAssertEqual(ReaderRouteCoordinator.failure(for: OfflineReadError.notDownloaded), .unavailableOffline)
        XCTAssertEqual(ReaderRouteCoordinator.failure(for: OfflineReadError.protectedDataUnavailable), .protectedDataUnavailable)
        XCTAssertEqual(ReaderRouteCoordinator.failure(for: OfflineReadError.localCopyDamaged), .localCopyUnavailable)
        XCTAssertEqual(ReaderRouteCoordinator.failure(for: MangaReaderTestError.expected), .loadFailed)
    }

    func testCancelThenALateResultPublishesNothingAndLeavesNoSpinner() async throws {
        let fixture = await pagesRoute()
        let source = try XCTUnwrap(fixture.pagesModel)

        source.goToNextChapter()
        await fixture.preparer.waitForPending(1)
        fixture.route.cancelHandoff()
        fixture.preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()

        guard case .idle = fixture.route.phase else { return XCTFail("A late success finds nothing to publish") }
        XCTAssertTrue(fixture.pagesModel === source)
        XCTAssertEqual(fixture.presentations.created.count, 1, "No destination was ever built")
        XCTAssertEqual(fixture.novel.history.requests.count, 0)
    }

    func testALateFailureOfACancelledOperationShowsNoError() async throws {
        let fixture = await pagesRoute()

        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.preparer.waitForPending(1)
        fixture.route.cancelHandoff()
        fixture.preparer.resolveFirst(failing: MangaReaderTestError.expected)
        await fixture.route.waitForPreparationForTesting()

        guard case .idle = fixture.route.phase else { return XCTFail("A cancelled operation reports nothing") }
    }

    func testAnOlderOperationCannotClearANewerOne() async throws {
        let fixture = await pagesRoute()
        let source = try XCTUnwrap(fixture.pagesModel)

        source.goToNextChapter()
        await fixture.preparer.waitForPending(1)
        let firstID = try XCTUnwrap(fixture.requestID)
        fixture.route.cancelHandoff()
        source.goToNextChapter()
        await fixture.preparer.waitForPending(2)
        let secondID = try XCTUnwrap(fixture.requestID)
        XCTAssertNotEqual(firstID, secondID)

        // The first answer arrives: it belongs to a cancelled operation and changes nothing.
        fixture.preparer.resolveFirst()
        await Task.yield()
        guard case .preparing(let current) = fixture.route.phase else { return XCTFail("The newer operation stays") }
        XCTAssertEqual(current.id, secondID)

        fixture.preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(let staged, _) = fixture.route.phase else { return XCTFail("The newer result is staged") }
        XCTAssertEqual(staged.id, secondID)
        fixture.route.cancelHandoff()
    }

    func testAStagedDestinationThatCannotBeShownFailsAndTheSourceSurvives() async throws {
        let fixture = await pagesRoute(suspending: false)
        let source = try XCTUnwrap(fixture.pagesModel)

        source.goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(let request, let staged) = fixture.route.phase, case .text(_, let destination) = staged else {
            return XCTFail("Staged")
        }
        fixture.route.presentationFailed(requestID: request.id, visitID: staged.visitID)

        guard case .failed(_, let failure) = fixture.route.phase else { return XCTFail("The failure is shown") }
        XCTAssertEqual(failure, .presentationFailed)
        XCTAssertTrue(fixture.pagesModel === source)
        XCTAssertFalse(destination.isActive, "The destination was dropped")
        XCTAssertEqual(fixture.novel.history.requests.count, 0)
        // A ready report of the dropped destination cannot revive it.
        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)
        XCTAssertTrue(fixture.pagesModel === source)
    }

    // MARK: - Invalidation at each barrier

    func testClosingTheRouteDuringPreparationDropsTheLateResult() async throws {
        let fixture = await pagesRoute()
        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.preparer.waitForPending(1)

        fixture.route.close()
        fixture.preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()

        guard case .closed = fixture.route.phase else { return XCTFail("The route is closed") }
        XCTAssertFalse(fixture.session.isOpen)
        XCTAssertEqual(fixture.presentations.created.count, 1)
        XCTAssertEqual(fixture.novel.history.requests.count, 0)
    }

    func testLeavingTheForegroundCancelsAPendingHandoff() async throws {
        let fixture = await pagesRoute()
        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.preparer.waitForPending(1)

        fixture.route.sceneDidLeaveActive()
        fixture.preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()

        guard case .idle = fixture.route.phase else { return XCTFail("Nothing outlives the foreground") }
        XCTAssertEqual(fixture.presentations.created.count, 1)
    }

    func testASourceScopeChangeInvalidatesEvenWhenItComesBack() async throws {
        let fixture = await pagesRoute()
        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.preparer.waitForPending(1)

        fixture.network.scopeSubject.send()
        fixture.route.scopeDidChange()
        fixture.preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()

        guard case .idle = fixture.route.phase else { return XCTFail("A replaced scope drops the work") }
        XCTAssertEqual(fixture.presentations.created.count, 1)
    }

    func testAnEpochThatChangedBeforeTheResultArrivesStopsTheSwap() async throws {
        let fixture = await pagesRoute()
        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.preparer.waitForPending(1)

        fixture.manga.progress.originatingEpoch = "rotated"
        fixture.preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()

        guard case .idle = fixture.route.phase else { return XCTFail("A moved epoch is refused, with no spinner left") }
        XCTAssertEqual(fixture.presentations.created.count, 1, "Nothing is staged")
    }

    func testAChangedContinuationSettingStopsTheSwap() async throws {
        let fixture = await pagesRoute()
        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.preparer.waitForPending(1)

        fixture.manga.settings.askBeforeSwitchingGroups = true
        fixture.preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()

        XCTAssertEqual(fixture.presentations.created.count, 1, "The revision moved, so nothing is staged")
        XCTAssertTrue(fixture.pagesModel != nil)
    }

    func testANewCatalogOrANavigatedSourceInvalidatesThePendingRequest() async throws {
        let fixture = await pagesRoute()
        let source = try XCTUnwrap(fixture.pagesModel)
        source.goToNextChapter()
        await fixture.preparer.waitForPending(1)

        fixture.route.catalogDidChange()
        fixture.preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()
        XCTAssertEqual(fixture.presentations.created.count, 1)

        source.goToNextChapter()
        await fixture.preparer.waitForPending(1)
        // The reader moved on (its content generation changed): the old crossing no longer describes it.
        source.disappear()
        source.appear()
        fixture.preparer.resolveFirst()
        await fixture.route.waitForPreparationForTesting()
        XCTAssertEqual(fixture.presentations.created.count, 1)
    }

    // MARK: - Network

    func testAPolicyChangeRenewsAPendingPreparationUnderTheNewRevision() async throws {
        let fixture = await pagesRoute()
        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.preparer.waitForPending(1)

        fixture.network.policyRevision = 2
        fixture.route.networkDidChange()
        await fixture.preparer.waitForPending(2)

        let operations = fixture.preparer.calls.filter { $0.key == "t2" }.map(\.operation)
        XCTAssertEqual(operations.map(\.policyRevision), [1, 2])
        XCTAssertNotEqual(operations[0].operationID, operations[1].operationID)
        XCTAssertEqual(operations.map(\.purpose), [.foregroundReading, .foregroundReading])
        XCTAssertEqual(operations.map(\.batchID), [nil, nil])
        fixture.route.cancelHandoff()
    }

    func testALoadTheSourceRefusedFailsInsteadOfPresenting() async throws {
        let fixture = await pagesRoute(suspending: false)
        fixture.preparer.failures["t2"] = MangaReaderTestError.expected

        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.route.waitForPreparationForTesting()

        guard case .failed(_, let failure) = fixture.route.phase else { return XCTFail("A refusal is a failure") }
        XCTAssertEqual(failure, .loadFailed)
    }

    // MARK: - History and completion

    func testACrossingBackAndForthRecordsEachChapterInHistoryOnce() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t2"] = .text
        let fixture = await makeRouteFixture(entry: Self.mangaEntry, chapter: Self.p1, format: .pages, preparer: preparer)

        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        reportReady(fixture)
        try XCTUnwrap(fixture.textModel).goToPreviousChapter()
        await fixture.route.waitForPreparationForTesting()
        reportReady(fixture)
        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        reportReady(fixture)

        // p1 was recorded by the first page reader, t2 once by the text reader, and neither again.
        XCTAssertEqual(fixture.manga.history.requests.map(\.chapterKey), ["p1"])
        XCTAssertEqual(fixture.novel.history.requests.map(\.chapterKey), ["t2"])
        XCTAssertEqual(preparer.callCount("p1"), 2)
    }

    func testAPendingTrackerStepOfTheSourceSurvivesASwapButNotTheRouteClosing() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["x1"] = .text
        let fixture = await makeRouteFixture(entry: Self.novelEntry, chapter: Self.x1, format: .text, preparer: preparer)
        let source = try XCTUnwrap(fixture.textModel)
        fixture.novel.progress.enqueue(.suspended)
        let loadedID = try XCTUnwrap(source.loadedChapters.first?.id)

        source.readingPositionChanged(chapterID: loadedID, offset: 0, reachedEnd: true)
        await fixture.novel.progress.waitForPendingCount(1)
        source.goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        reportReady(fixture)
        XCTAssertNotNil(fixture.pagesModel, "The swap happened while the local mark was pending")

        fixture.novel.progress.resolveFirst()
        await source.waitForAllOperationsForTesting()
        // Local mark first, then the tracker: the retired reader's step did not need it to stay alive.
        XCTAssertEqual(fixture.novel.events.events, ["history:x1", "progress:x1", "tracker:1", "history:i2"].filter { fixture.novel.events.events.contains($0) })
        XCTAssertEqual(fixture.novel.tracker.requests.map(\.progress), [1])
        XCTAssertEqual(fixture.novel.events.events.firstIndex(of: "progress:x1").map { $0 < (fixture.novel.events.events.firstIndex(of: "tracker:1") ?? 0) }, true)
    }

    func testAClosedRouteDoesNotRunAPendingTrackerStep() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["x1"] = .text
        let fixture = await makeRouteFixture(entry: Self.novelEntry, chapter: Self.x1, format: .text, preparer: preparer)
        let source = try XCTUnwrap(fixture.textModel)
        fixture.novel.progress.enqueue(.suspended)
        let loadedID = try XCTUnwrap(source.loadedChapters.first?.id)

        source.readingPositionChanged(chapterID: loadedID, offset: 0, reachedEnd: true)
        await fixture.novel.progress.waitForPendingCount(1)
        fixture.route.close()
        fixture.novel.progress.resolveFirst()
        await source.waitForAllOperationsForTesting()

        XCTAssertEqual(fixture.novel.progress.requests.map(\.chapterID), ["x1"], "The admitted local mark finished")
        XCTAssertTrue(fixture.novel.tracker.requests.isEmpty)
    }

    func testAStagedDestinationNeverCompletesAChapterAndALiveOneCompletesOnce() async throws {
        let fixture = await pagesRoute(suspending: false)
        fixture.preparer.pages["t2"] = [Page(index: 0, content: .text("short"))]

        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(_, .text(_, let destination)) = fixture.route.phase else { return XCTFail("Staged") }
        // Laid out behind the source, with its end visible: nothing is marked.
        destination.continuousChapterEndAppeared(chapterID: destination.loadedChapters[0].id)
        destination.readingPositionChanged(chapterID: destination.loadedChapters[0].id, offset: 0, reachedEnd: true)
        XCTAssertTrue(fixture.novel.progress.requests.isEmpty)

        reportReady(fixture)
        destination.readingPositionChanged(chapterID: destination.loadedChapters[0].id, offset: 0, reachedEnd: true)
        destination.readingPositionChanged(chapterID: destination.loadedChapters[0].id, offset: 0, reachedEnd: true)
        await destination.waitForAllOperationsForTesting()
        XCTAssertEqual(fixture.novel.progress.requests.map(\.chapterID), ["t2"])
    }

    func testPositionWritesRunInOrderAcrossReadersAndNeverAfterANewerOne() async throws {
        let fixture = await pagesRoute()
        var order: [String] = []
        let gate = RouteWriteGate()

        fixture.session.enqueuePositionWrite {
            await gate.wait()
            order.append("source")
        }
        fixture.session.enqueuePositionWrite { order.append("destination") }
        gate.open()
        await fixture.session.waitForPositionWritesForTesting()

        XCTAssertEqual(order, ["source", "destination"])
    }

    // MARK: - A chapter that is not what it was declared to be

    func testANeighborSavedInTheOtherFormMidTransitionRestoresTheSourceAndHandsOff() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["p3"] = .text
        let fixture = await makeRouteFixture(entry: Self.mangaEntry, chapter: Self.t2Pages, format: .pages, preparer: preparer)
        let source = try XCTUnwrap(fixture.pagesModel)
        let pagesBefore = source.pagedPages.map(\.index)

        source.goToNextChapter()
        await source.waitForTestingOperations()
        await fixture.route.waitForPreparationForTesting()

        // The chapter loaded as text: the reader is back on the chapter it left, with the same pages.
        XCTAssertEqual(source.currentChapter.key, "t2")
        XCTAssertEqual(source.pagedPages.map(\.index), pagesBefore)
        XCTAssertEqual(source.loadPhase, .content)
        guard case .staging(_, .text(_, let destination)) = fixture.route.phase else { return XCTFail("Handed off") }
        XCTAssertEqual(destination.currentChapter.key, "p3")
        XCTAssertEqual(preparer.callCount("p3"), 1, "What was loaded is reused, not fetched again")
        fixture.route.cancelHandoff()
    }

    private static let t2Pages = readerChapter("t2", 2)

    func testAnAppendThatFindsTheOtherFormStopsAtThatBoundary() async throws {
        let chapters = [readerChapter("c3", 3), readerChapter("c2", 2), readerChapter("c1", 1)]
        let entry = MediaEntry.manga(Manga(key: "series", title: "Series", viewer: .Webtoon, chapters: chapters))
        let preparer = ScriptedChapterPreparer()
        preparer.formats["c3"] = .text
        let fixture = await makeRouteFixture(entry: entry, chapter: chapters[1], format: .pages, preparer: preparer)
        let source = try XCTUnwrap(fixture.pagesModel)

        source.appendNextChapter()
        await source.waitForTestingOperations()

        XCTAssertEqual(source.segments.map(\.chapter.key), ["c2"], "The other form is never appended")
        guard case .handoff(let candidate, _) = source.boundaryAfter(chapters[1]) else { return XCTFail("It is a handoff boundary now") }
        XCTAssertEqual(candidate.key, "c3")

        let router = RecordingHandoffRouter()
        source.handoffRouter = router
        source.requestHandoff(direction: .next, position: .start, trigger: .visibleBoundary, atLoadedEdge: true)
        XCTAssertEqual(router.preparedEvents.map(\.key), ["c3"], "At the boundary the loaded payload is reused")
        XCTAssertEqual(preparer.callCount("c3"), 1)
    }

    func testAnOpeningWhoseChapterIsSavedInTheOtherFormIsCorrectedInPlace() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["p1"] = .text
        let fixture = await makeRouteFixture(entry: Self.mangaEntry, chapter: Self.p1, format: .pages, preparer: preparer)

        XCTAssertNotNil(fixture.textModel, "The route opens in the reader the chapter is actually made for")
        XCTAssertEqual(fixture.novel.history.requests.map(\.chapterKey), ["p1"])
        XCTAssertEqual(fixture.novel.history.requests.first?.format, .text)
        XCTAssertTrue(fixture.manga.history.requests.isEmpty)
        XCTAssertEqual(preparer.callCount("p1"), 1)
        guard case .idle = fixture.route.phase else { return XCTFail("The route is idle") }
    }

    func testPrefetchAndAppendNeverConsumeAHandoffNeighbor() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t2"] = .text
        let fixture = await makeRouteFixture(entry: Self.mangaEntry, chapter: Self.p1, format: .pages, preparer: preparer)
        let source = try XCTUnwrap(fixture.pagesModel)

        source.beginAdjacentChapterPrefetch()
        await source.waitForTestingOperations()
        source.appendNextChapter()

        XCTAssertEqual(preparer.callCount("t2"), 0)
        XCTAssertNil(source.boundaryAfter(Self.p1).chapter)
        XCTAssertTrue(source.boundaryAfter(Self.p1).canNavigate)
    }

    // MARK: - Latch

    func testTheViewportReportingTheSameBoundaryAgainIsOneCrossing() async throws {
        let fixture = await pagesRoute(suspending: false)
        let source = try XCTUnwrap(fixture.pagesModel)
        let router = RecordingHandoffRouter()
        source.handoffRouter = router

        source.requestHandoff(direction: .next, position: .start, trigger: .visibleBoundary, atLoadedEdge: false)
        source.requestHandoff(direction: .next, position: .start, trigger: .visibleBoundary, atLoadedEdge: false)
        XCTAssertEqual(router.events.count, 1)

        // The user leaving and coming back is a new crossing, and a control is always the user's own act.
        source.releaseHandoffLatch()
        source.requestHandoff(direction: .next, position: .start, trigger: .visibleBoundary, atLoadedEdge: false)
        source.requestHandoff(direction: .next, position: .resume, trigger: .chapterControl, atLoadedEdge: false)
        source.requestHandoff(direction: .next, position: .resume, trigger: .chapterControl, atLoadedEdge: false)
        XCTAssertEqual(router.events.count, 4)
    }

    func testAContinuousCrossingStartsFromTheLastLoadedChapterNotTheCurrentOne() async throws {
        let chapters = [readerChapter("c3", 3), readerChapter("c2", 2, text: true), readerChapter("c1", 1)]
        let entry = MediaEntry.manga(Manga(key: "series", title: "Series", viewer: .Webtoon, chapters: chapters))
        let fixture = await makeRouteFixture(entry: entry, chapter: chapters[2], format: .pages)
        let source = try XCTUnwrap(fixture.pagesModel)
        let router = RecordingHandoffRouter()
        source.handoffRouter = router

        source.requestHandoff(direction: .next, position: .start, trigger: .visibleBoundary, atLoadedEdge: true)

        XCTAssertEqual(router.events.first?.origin.key, "c1")
        XCTAssertEqual(router.events.first?.position, .start)
    }

    func testARouteThatIsStillOpeningTakesNoHandoffs() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.suspended = ["p1"]
        let manga = makeMangaReaderSubject(entry: Self.mangaEntry, initialChapter: Self.p1)
        let novel = makeNovelReaderSubject(entry: Self.mangaEntry, initialChapter: Self.p1)
        let session = makeReaderRouteSession(entry: Self.mangaEntry, scope: manga.progress)
        let route = ReaderRouteCoordinator(
            rootID: UUID(), pluginID: "plugin.test", entry: Self.mangaEntry, chapter: Self.p1, format: .pages,
            content: ReaderContentSource(remote: nil), session: session, preparer: preparer,
            presentations: RoutePresentationFake(manga: manga, novel: novel), settings: manga.settings,
            network: RouteNetworkFake()
        )

        guard case .opening = route.phase else { return XCTFail("The first chapter is not on screen yet") }
        XCTAssertNotNil(route.active)
    }
}

/// Holds a task until the test opens it.
@MainActor
final class RouteWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
