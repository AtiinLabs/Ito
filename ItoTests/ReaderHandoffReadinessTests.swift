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

    func testTheRoutesImageLeaseHandsOverToTheRenderersOwnWithoutResettingOrRefetching() async throws {
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

        // Layout alone is not drawable readiness: the image has not been proven yet.
        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)
        guard case .staging = fixture.route.phase else { return XCTFail("Layout alone does not commit") }

        data.releaseLoads()
        await fulfillment(of: [ready], timeout: 5)
        observation.cancel()
        XCTAssertTrue(fixture.pagesModel === destination, "The proven image and the layout together commit")
        XCTAssertEqual(data.requestCount(for: Self.imageURL), 1)

        // The renderer's own visible lease arrives, then the route's lease goes: the image stays ready.
        let lease = destination.imageSession.acquire(descriptor(), consumer: .visible)
        fixture.route.initialImageVisibleLeaseAcquired(requestID: request.id, visitID: staged.visitID)
        XCTAssertEqual(fixture.route.stagedImageHoldCountForTesting, 0)
        if case .ready = destination.imageSession.state(for: key).phase {} else { XCTFail("The image was reset") }
        XCTAssertEqual(data.requestCount(for: Self.imageURL), 1, "Nothing was fetched again")
        destination.imageSession.release(lease)
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

    func testLayoutRestoresNewRowsAndSettlingNeverStartACrossing() async throws {
        let chapters = [readerChapter("c3", 3, text: true), readerChapter("c2", 2), readerChapter("c1", 1)]
        let entry = MediaEntry.manga(Manga(key: "series", title: "Series", viewer: .Webtoon, chapters: chapters))
        let preparer = ScriptedChapterPreparer()
        preparer.formats["c3"] = .text
        preparer.pages["c2"] = [Page(index: 0, content: .text("a")), Page(index: 1, content: .text("b"))]
        let fixture = await makeRouteFixture(entry: entry, chapter: chapters[1], format: .pages, preparer: preparer)
        let source = try XCTUnwrap(fixture.pagesModel)
        let router = RecordingHandoffRouter()
        source.handoffRouter = router
        let ids = source.flatPages.map(\.id)

        // First layout, a restore, rows arriving and the viewport settling are not the user crossing.
        source.continuousViewportChanged(ids)
        source.continuousViewportChanged([ids[0]])
        source.appendNextChapter()
        source.continuousViewportSettled()
        XCTAssertTrue(router.events.isEmpty && router.preparedEvents.isEmpty)

        // The viewport reporting the end again is one crossing; leaving the edge makes the next arrival new.
        source.requestHandoff(direction: .next, position: .start, trigger: .visibleBoundary, atLoadedEdge: true)
        source.continuousViewportChanged([ids[1]])
        source.requestHandoff(direction: .next, position: .start, trigger: .visibleBoundary, atLoadedEdge: true)
        XCTAssertEqual(router.events.count, 1)
        source.continuousViewportChanged([ids[0]])
        source.requestHandoff(direction: .next, position: .start, trigger: .visibleBoundary, atLoadedEdge: true)
        XCTAssertEqual(router.events.count, 2)
    }

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
        let (fixture, _) = await imageRoute()
        fixture.preparer.pages["i2"] = [Page(index: 0, content: .text("a page of text"))]
        try XCTUnwrap(fixture.textModel).goToNextChapter()
        await fixture.route.waitForPreparationForTesting()
        guard case .staging(let request, let staged) = fixture.route.phase else { return XCTFail("Staged") }
        fixture.route.presentationReady(requestID: request.id, visitID: staged.visitID)
        let destination = try XCTUnwrap(fixture.pagesModel)

        destination.continuousViewportSettled()
        destination.setPagedIndex(0)

        guard case .idle = fixture.route.phase else { return XCTFail("Nothing started from the new reader") }
        XCTAssertEqual(fixture.preparer.callCount("x1"), 1, "The replaced chapter was not requested again")
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
