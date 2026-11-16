import Combine
import ito_runner
import XCTest
@testable import Ito

/// What must hold before a staged destination replaces the visible reader, and what crossings a reader may
/// start. Image states are real (a scripted data loader), and every wait is on an observation callback.
@MainActor
final class ReaderHandoffReadinessTests: XCTestCase {
    private static let x1 = readerChapter("x1", 1, text: true)
    private static let i2 = readerChapter("i2", 2)
    private static let x3 = readerChapter("x3", 3, text: true)
    private static let novelEntry = MediaEntry.novel(Novel(key: "series", title: "Series", chapters: [x3, i2, x1]))
    private static let imageURL = URL(string: "https://img.example.test/i2.png")!

    private func imageRoute(failing: Bool = false) async -> (RouteFixture, ScriptedImageData) {
        let data = ScriptedImageData()
        if failing { data.fail(Self.imageURL) }
        data.holdLoads()
        let preparer = ScriptedChapterPreparer()
        preparer.formats["x1"] = .text
        preparer.formats["x3"] = .text
        preparer.pages["i2"] = [Page(index: 0, content: .url(Self.imageURL.absoluteString))]
        let fixture = await makeRouteFixture(
            entry: Self.novelEntry, chapter: Self.x1, format: .text, preparer: preparer,
            imagePipeline: makeScriptedPipeline(data)
        )
        return (fixture, data)
    }

    private func descriptor() -> ReaderPageImageDescriptor {
        ReaderPageImageDescriptor(pageID: "page", request: URLRequest(url: Self.imageURL))
    }

    // MARK: - Initial image

    /// The staged renderer is mounted under the visible one, so its first image takes its own visible lease in
    /// `onAppear`, right after the destination is staged and long before a remote image is ready.
    func testTheRenderersLeaseArrivingBeforeTheImageIsReadyDoesNotEndTheRoutesObservation() async throws {
        let (fixture, data) = await imageRoute()
        try XCTUnwrap(fixture.textModel).goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(let request, let staged) = fixture.route.phase, case .pages(_, let destination) = staged else {
            return XCTFail("Staged as pages")
        }
        let key = try XCTUnwrap(destination.preparedImageKey)
        let rendererLease = destination.imageSession.acquire(
            try XCTUnwrap(destination.preparedInitialImageDescriptor()), consumer: .visible
        )
        fixture.route.initialImageVisibleLeaseAcquired(requestID: request.id, visitID: staged.visitID)
        XCTAssertEqual(fixture.route.stagedImageHoldCountForTesting, 1, "The image is not ready: the proof stays")

        // Layout alone is not drawable readiness.
        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)
        guard case .staging = fixture.route.phase else { return XCTFail("Layout alone does not commit") }

        let ready = expectation(description: "the first image is ready")
        let observation = destination.imageSession.observe(key) { state in
            if case .ready = state.phase { ready.fulfill() }
        }
        data.releaseLoads()
        await fulfillment(of: [ready], timeout: 5)
        observation.cancel()

        XCTAssertTrue(fixture.pagesModel === destination, "The settled image and the layout commit")
        XCTAssertEqual(fixture.route.stagedImageHoldCountForTesting, 0, "The proof is let go once it served")
        if case .ready = destination.imageSession.state(for: key).phase {} else { XCTFail("The image was reset") }
        XCTAssertEqual(data.requestCount(for: Self.imageURL), 1, "Nothing was fetched again")
        destination.imageSession.release(rendererLease)
    }

    func testAnImageFailingAfterTheRenderersLeaseWasReportedFailsThePresentation() async throws {
        let (fixture, data) = await imageRoute(failing: true)
        let source = try XCTUnwrap(fixture.textModel)
        source.goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(let request, let staged) = fixture.route.phase, case .pages(_, let destination) = staged else {
            return XCTFail("Staged as pages")
        }
        let key = try XCTUnwrap(destination.preparedImageKey)
        let rendererLease = destination.imageSession.acquire(
            try XCTUnwrap(destination.preparedInitialImageDescriptor()), consumer: .visible
        )
        fixture.route.initialImageVisibleLeaseAcquired(requestID: request.id, visitID: staged.visitID)
        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)

        // The route reports the failure itself; waiting on the session would race the route dropping it.
        let failed = expectation(description: "the handoff failed")
        let phases = fixture.route.$phase.sink { phase in
            if case .failed = phase { failed.fulfill() }
        }
        data.releaseLoads()
        await fulfillment(of: [failed], timeout: 5)
        phases.cancel()

        guard case .failed(_, let failure) = fixture.route.phase else { return XCTFail("The failure is shown") }
        XCTAssertEqual(failure, .presentationFailed)
        XCTAssertTrue(fixture.textModel === source, "The source survives")
        XCTAssertFalse(destination.isActive)
        XCTAssertEqual(fixture.route.stagedImageHoldCountForTesting, 0)
        destination.imageSession.release(rendererLease)
    }

    /// The continuous renderer never reports a lease of its own; the route's hold must not outlive the swap.
    func testACommitReleasesTheHoldWhenTheRendererNeverReportsALease() async throws {
        let (fixture, data) = await imageRoute()
        try XCTUnwrap(fixture.textModel).goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(let request, let staged) = fixture.route.phase, case .pages(_, let destination) = staged else {
            return XCTFail("Staged as pages")
        }
        let key = try XCTUnwrap(destination.preparedImageKey)
        let ready = expectation(description: "the first image is ready")
        let observation = destination.imageSession.observe(key) { state in
            if case .ready = state.phase { ready.fulfill() }
        }
        data.releaseLoads()
        await fulfillment(of: [ready], timeout: 5)
        observation.cancel()
        XCTAssertEqual(fixture.route.stagedImageHoldCountForTesting, 1, "No renderer lease yet, so the proof stays")

        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)

        XCTAssertTrue(fixture.pagesModel === destination)
        XCTAssertEqual(fixture.route.stagedImageHoldCountForTesting, 0, "The commit let it go: no lease leaks")
    }

    // MARK: - A text chapter that opens on an illustration

    private func illustratedTextRoute(failing: Bool) async -> (RouteFixture, ScriptedImageData) {
        let data = ScriptedImageData()
        if failing { data.fail(Self.imageURL) }
        data.holdLoads()
        let chapters = [readerChapter("t2", 2, text: true), readerChapter("p1", 1)]
        let entry = MediaEntry.manga(Manga(key: "series", title: "Series", chapters: chapters))
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t2"] = .text
        preparer.pages["t2"] = [
            Page(index: 0, content: .url(Self.imageURL.absoluteString)), Page(index: 1, content: .text("words"))
        ]
        let fixture = await makeRouteFixture(
            entry: entry, chapter: chapters[1], format: .pages, preparer: preparer,
            imagePipeline: makeScriptedPipeline(data)
        )
        return (fixture, data)
    }

    func testATextDestinationOpeningOnAnIllustrationCommitsOnlyOnceItIsReady() async throws {
        let (fixture, data) = await illustratedTextRoute(failing: false)
        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(let request, let staged) = fixture.route.phase, case .text(_, let destination) = staged else {
            return XCTFail("Staged as text")
        }
        let descriptor = try XCTUnwrap(destination.preparedInitialImageDescriptor(), "It opens on the illustration")
        let rendererLease = destination.imageSession.acquire(descriptor, consumer: .visible)
        fixture.route.initialImageVisibleLeaseAcquired(requestID: request.id, visitID: staged.visitID)
        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)
        guard case .staging = fixture.route.phase else { return XCTFail("The image is not ready yet") }
        XCTAssertEqual(fixture.route.stagedImageHoldCountForTesting, 1)

        let ready = expectation(description: "the illustration is ready")
        let observation = destination.imageSession.observe(descriptor.key) { state in
            if case .ready = state.phase { ready.fulfill() }
        }
        data.releaseLoads()
        await fulfillment(of: [ready], timeout: 5)
        observation.cancel()

        XCTAssertTrue(fixture.textModel === destination)
        XCTAssertEqual(fixture.route.stagedImageHoldCountForTesting, 0)
        if case .ready = destination.imageSession.state(for: descriptor.key).phase {} else { XCTFail("The image was reset") }
        XCTAssertEqual(data.requestCount(for: Self.imageURL), 1)
        destination.imageSession.release(rendererLease)
    }

    func testAnIllustrationThatFailsInATextDestinationIsReportedAsAPresentationFailure() async throws {
        let (fixture, data) = await illustratedTextRoute(failing: true)
        let source = try XCTUnwrap(fixture.pagesModel)
        source.goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(let request, let staged) = fixture.route.phase, case .text(_, let destination) = staged else {
            return XCTFail("Staged as text")
        }
        let descriptor = try XCTUnwrap(destination.preparedInitialImageDescriptor())
        let rendererLease = destination.imageSession.acquire(descriptor, consumer: .visible)
        fixture.route.initialImageVisibleLeaseAcquired(requestID: request.id, visitID: staged.visitID)
        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)

        let failed = expectation(description: "the handoff failed")
        let phases = fixture.route.$phase.sink { phase in
            if case .failed = phase { failed.fulfill() }
        }
        data.releaseLoads()
        await fulfillment(of: [failed], timeout: 5)
        phases.cancel()

        guard case .failed(_, let failure) = fixture.route.phase else { return XCTFail("The failure is shown") }
        XCTAssertEqual(failure, .presentationFailed)
        XCTAssertTrue(fixture.pagesModel === source)
        XCTAssertFalse(destination.isActive)
        destination.imageSession.release(rendererLease)
    }

    func testAnImageThatCannotBeLoadedFailsTheHandoffAndTheSourceSurvives() async throws {
        // An offline locator with no offline pipeline fails the moment it is requested, with no remote request.
        let (fixture, data) = await imageRoute()
        fixture.preparer.pages["i2"] = [Page(index: 0, content: .url("\(OfflineAssetLocator.scheme)://token/i2.jpg"))]
        let source = try XCTUnwrap(fixture.textModel)
        source.goToNextChapter()
        await fixture.route.waitForPreparationForTesting()

        guard case .failed(let request, let failure) = fixture.route.phase else { return XCTFail("The failure is shown") }
        XCTAssertEqual(failure, .presentationFailed)
        XCTAssertTrue(fixture.textModel === source)
        guard case .pages(let staledVisit, let destination)? = fixture.presentations.created.last else {
            return XCTFail("A destination was built")
        }
        XCTAssertFalse(destination.isActive, "The destination was dropped")
        XCTAssertEqual(fixture.manga.history.requests.count, 0)
        XCTAssertEqual(fixture.route.stagedImageHoldCountForTesting, 0)
        XCTAssertTrue(data.requested.isEmpty)
        // A layout report of the dropped destination cannot revive it.
        fixture.route.presentationReady(requestID: request.id, visitID: staledVisit)
        XCTAssertTrue(fixture.textModel === source)
    }

    func testCancellingTheRoutesLeaseRemovesOnlyItsOwnObservation() async throws {
        let data = ScriptedImageData()
        let session = ReaderPageImageSession(pipeline: makeScriptedPipeline(data))
        let descriptor = descriptor()
        var settled: [Bool] = []
        let ready = expectation(description: "another consumer's image is ready")
        let other = session.observe(descriptor.key) { state in
            if case .ready = state.phase { ready.fulfill() }
        }
        let otherLease = session.acquire(descriptor, consumer: .visible)
        let hold = ReaderPreparationImageHold(
            requestID: UUID(), visitID: UUID(), session: session, descriptor: descriptor
        ) { settled.append($0) }
        hold.begin()

        hold.release()
        await fulfillment(of: [ready], timeout: 5)

        XCTAssertEqual(settled, [], "A cancelled hold reports nothing")
        if case .ready = session.state(for: descriptor.key).phase {} else { XCTFail("The other consumer lost its image") }
        other.cancel()
        session.release(otherLease)
    }

    func testAnOfflineLocatorNeverReachesTheRemotePipeline() {
        let data = ScriptedImageData()
        let session = ReaderPageImageSession(pipeline: makeScriptedPipeline(data))
        let url = URL(string: "\(OfflineAssetLocator.scheme)://token/page-0.jpg")!
        let offline = ReaderPageImageDescriptor(pageID: "offline", request: URLRequest(url: url))

        let lease = session.acquire(offline, consumer: .visible)

        if case .failed = session.state(for: offline.key).phase {} else { XCTFail("Without an offline pipeline it fails") }
        XCTAssertTrue(data.requested.isEmpty, "The shared remote pipeline was never asked")
        session.release(lease)
    }

    // MARK: - Stale reports

    func testReportsOfAnotherRequestOrVisitCannotCommitOrFailAStagedDestination() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["x1"] = .text
        let fixture = await makeRouteFixture(entry: Self.novelEntry, chapter: Self.x1, format: .text, preparer: preparer)
        try XCTUnwrap(fixture.textModel).goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(let request, let staged) = fixture.route.phase else { return XCTFail("Staged") }

        fixture.route.presentationReady(requestID: UUID(), visitID: staged.visitID)
        fixture.route.presentationReady(requestID: request.id, visitID: UUID())
        fixture.route.presentationFailed(requestID: UUID(), visitID: staged.visitID)
        fixture.route.presentationFailed(requestID: request.id, visitID: UUID())
        guard case .staging = fixture.route.phase else { return XCTFail("Stale reports change nothing") }

        // After a cancel, the cancelled request's own ready report is stale too.
        fixture.route.cancelHandoff()
        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)
        guard case .idle = fixture.route.phase else { return XCTFail("A cancelled request never commits") }
        XCTAssertNotNil(fixture.textModel)
    }

    // MARK: - Selected copy

    func testTheSelectedCopyKeepsItsLeaseAndBytesAfterTheStoreDeletesIt() async throws {
        let real = try await RealAlternativeFixture.make(pages: [OfflineStoreFixture.textPage(0, "Selected words.")])
        let lease = try await real.openLease()
        let destination = try MediaDetailReaderDestination.downloadedAlternative(
            real.candidate, lease: lease,
            of: .manga(Manga(key: "series-1", title: "Series One", chapters: [.upload("a"), .upload("b")])),
            remote: nil, pluginID: "plugin.test"
        )
        guard case .text(_, let content, _, let entry, let chapter) = destination else { return XCTFail("Opens as text") }
        let preparer = MediaDetailReaderChapterPreparer(
            pluginID: "plugin.test", content: content, local: real.store, remoteManga: nil, remoteNovel: nil
        )
        func words(_ prepared: ReaderPreparedChapter) -> String? {
            guard case .text(let text)? = prepared.pages.first?.content else { return nil }
            return text
        }

        let first = try await preparer.prepareChapter(entry: entry, chapter: chapter, operation: makeTestNetworkOperation())
        try await real.store.delete(real.fixture.edition("b"))
        let second = try await preparer.prepareChapter(entry: entry, chapter: chapter, operation: makeTestNetworkOperation())

        XCTAssertEqual(words(first), "Selected words.")
        XCTAssertEqual(words(second), "Selected words.", "The held lease still reads the selected version")
    }

    // MARK: - Crossings a reader may start

    func testTheTextReaderCrossesOnlyAfterTheUserScrolledAndNeverFromAPlacedAnchor() async throws {
        let preparer = ScriptedChapterPreparer()
        preparer.formats["x1"] = .text
        preparer.pages["x1"] = [Page(index: 0, content: .text("one")), Page(index: 1, content: .text("two"))]
        let fixture = await makeRouteFixture(entry: Self.novelEntry, chapter: Self.x1, format: .text, preparer: preparer)
        let source = try XCTUnwrap(fixture.textModel)
        let router = RecordingHandoffRouter()
        source.handoffRouter = router
        let chapterID = try XCTUnwrap(source.loadedChapters.first?.id)

        // The end row is on screen from layout alone (a short chapter): nothing crosses.
        source.continuousHandoffBoundaryAppeared()
        XCTAssertTrue(router.events.isEmpty)

        source.continuousPageAppeared(chapterID: chapterID, pageIndex: 0)
        source.continuousPageDisappeared(chapterID: chapterID, pageIndex: 0)
        source.continuousHandoffBoundaryAppeared()
        source.continuousHandoffBoundaryAppeared()
        XCTAssertEqual(router.events.map(\.trigger), [.visibleBoundary], "The scrolled-to end is one crossing")
        XCTAssertEqual(router.events.first?.position, .start)
    }

    func testANewDestinationDoesNotBounceBackToTheReaderItReplaced() async throws {
        let chapters = [readerChapter("p3", 3), readerChapter("t2", 2, text: true), readerChapter("p1", 1)]
        let entry = MediaEntry.manga(Manga(key: "series", title: "Series", chapters: chapters))
        let preparer = ScriptedChapterPreparer()
        preparer.formats["t2"] = .text
        preparer.pages["t2"] = [Page(index: 0, content: .text("one")), Page(index: 1, content: .text("two"))]
        let fixture = await makeRouteFixture(entry: entry, chapter: chapters[2], format: .pages, preparer: preparer)
        try XCTUnwrap(fixture.pagesModel).goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(let request, let staged) = fixture.route.phase else { return XCTFail("Staged") }
        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)
        let destination = try XCTUnwrap(fixture.textModel)
        let loaded = try XCTUnwrap(destination.loadedChapters.first)

        // The new reader lays itself out, reporting what its rows do in the order the live view does. Its
        // previous chapter is the one it replaced and its next is another page chapter, both handoffs.
        destination.continuousChapterTitleAppeared(loaded)
        destination.continuousPageAppeared(chapterID: loaded.id, pageIndex: 0)
        destination.continuousPageAppeared(chapterID: loaded.id, pageIndex: 1)
        destination.continuousChapterEndAppeared(chapterID: loaded.id)
        destination.continuousHandoffBoundaryAppeared()
        guard case .idle = fixture.route.phase else { return XCTFail("Nothing started from the new reader's layout") }
        XCTAssertEqual(preparer.callCount("p1"), 1, "The replaced chapter was not requested again")
        XCTAssertEqual(preparer.callCount("p3"), 0)

        // Only the user scrolling opens the next crossing.
        destination.continuousPageDisappeared(chapterID: loaded.id, pageIndex: 0)
        destination.continuousHandoffBoundaryAppeared()
        guard case .preparing(let crossing) = fixture.route.phase else { return XCTFail("The user's scroll crosses") }
        XCTAssertEqual(crossing.chapter.key, "p3")
        XCTAssertEqual(crossing.event.direction, .next)
        fixture.route.cancelHandoff()
    }

    // MARK: - Direction is logical

    func testPagedDirectionsStayLogicalWhetherTheViewerReadsLeftOrRight() async throws {
        let chapters = [readerChapter("t3", 3, text: true), readerChapter("m2", 2), readerChapter("t1", 1, text: true)]
        for viewer in [Manga.Viewer.Rtl, .Ltr] {
            let entry = MediaEntry.manga(Manga(key: "series", title: "Series", viewer: viewer, chapters: chapters))
            let preparer = ScriptedChapterPreparer()
            preparer.formats["t1"] = .text
            preparer.formats["t3"] = .text
            let fixture = await makeRouteFixture(entry: entry, chapter: chapters[1], format: .pages, preparer: preparer)
            let source = try XCTUnwrap(fixture.pagesModel)
            let router = RecordingHandoffRouter()
            source.handoffRouter = router

            source.goToNextChapter()
            source.goToPreviousChapter()
            source.setPagedIndex(source.pagedPages.count)
            source.setPagedIndex(-1)

            XCTAssertEqual(router.events.map(\.direction), [.next, .previous, .next, .previous], "\(viewer)")
            XCTAssertEqual(router.events.map(\.position), [.resume, .resume, .start, .end], "\(viewer)")
        }
    }
}
