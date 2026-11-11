import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

@MainActor
struct DownloadAttemptTests {
    @Test func aPublishedChapterKeepsItsTextAndImagePagesInOrder() async throws {
        let pages = [
            Page(index: 0, content: .text("First line")),
            Page(index: 1, content: .url("https://img.test/2.jpg"))
        ]
        let fixture = try DownloadWorkerFixture(pages: pages)
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        let copy = try #require(try await fixture.copy())
        #expect(copy.pageCount == 2)
        #expect(copy.contentKind == .mixed)
        #expect(fixture.fetcher.requestedURLs == ["https://img.test/2.jpg"])
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func anImageLocatorFromTheSamePluginIsResolvedByTheLazyImageRunner() async throws {
        let pages = [Page(index: 0, content: .url("ito://plugin.test/https://img.test/1.jpg"))]
        let fixture = try DownloadWorkerFixture(pages: pages)
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() != nil)
        #expect(fixture.source.imageRunnerCreations.count == 1)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func everyExportOfAnAttemptRunsUnderTheJobsBatchAndItsFrozenEpoch() async throws {
        let pages = [
            Page(index: 0, content: .text("First line")),
            Page(index: 1, content: .url("ito://plugin.test/https://img.test/2.jpg"))
        ]
        let fixture = try DownloadWorkerFixture(pages: pages)
        _ = await fixture.enqueue()
        let queued = try #require(try await fixture.job())
        let batch = try #require(UUID(uuidString: queued.batchId))
        let epoch = try #require(queued.sourceEpoch)

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        let operations = fixture.runtimes.operations
        let operation = try #require(operations.first)
        #expect(operations.count == 1)
        #expect(operation.purpose == .manualBulkDownload)
        #expect(operation.batchID == batch)
        #expect(fixture.runtimes.frozenScopes == [epoch])

        // One page listing, then the image runner's request and bytes exports (origins are read only when a request resolves).
        let contexts = fixture.source.contexts.snapshot
        #expect(contexts.count == 3)
        let scope = try #require(PluginNetworkScopeID.uuid(epoch: epoch))
        for context in contexts {
            #expect(context.operationID == operation.operationID)
            #expect(context.batchID == batch)
            #expect(context.purpose == .manualBulkDownload)
            #expect(context.sourceID == DownloadWorkerFixture.plugin)
            #expect(context.authorizationScope == scope)
        }
        #expect(Set(contexts.map(\.generation)).count == contexts.count)
        #expect(try await fixture.copy() != nil)
    }

    @Test func aChapterWithoutImageLocatorsNeverCreatesAnImageRunner() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() != nil)
        #expect(fixture.source.imageRunnerCreations.count == 0)
    }

    @Test func anImageLocatorNamingAnotherPluginFailsTheChapter() async throws {
        let pages = [Page(index: 0, content: .url("ito://other.plugin/https://img.test/1.jpg"))]
        let fixture = try DownloadWorkerFixture(pages: pages)
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        let failed = try await fixture.job()
        #expect(failed?.state == .failed)
        #expect(failed?.failureReason == .unsupportedPageLocator)
        #expect(fixture.source.imageRunnerCreations.count == 0)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
    }

    @Test func aPageSchemeOtherThanImageLocatorsOrHTTPFailsTheChapter() async throws {
        let pages = [Page(index: 0, content: .url("file:///private/etc/hosts"))]
        let fixture = try DownloadWorkerFixture(pages: pages)
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.job()?.failureReason == .unsupportedPageLocator)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
    }

    @Test func aChapterWithNoPagesFailsAsEmpty() async throws {
        let fixture = try DownloadWorkerFixture(pages: [])
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.job()?.failureReason == .emptyChapter)
    }

    @Test func aChapterOverTwoThousandPagesFailsBeforeAnyRequest() async throws {
        let pages = (0..<2_001).map { Page(index: Int32($0), content: .url("https://img.test/\($0).jpg")) }
        let fixture = try DownloadWorkerFixture(pages: pages)
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.job()?.failureReason == .tooManyPages)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
    }

    @Test func aTextPageOverTheCapFailsAsTooLarge() async throws {
        let oversized = String(repeating: "a", count: 8 * 1_024 * 1_024 + 1)
        let fixture = try DownloadWorkerFixture(pages: [Page(index: 0, content: .text(oversized))])
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.job()?.failureReason == .assetTooLarge)
    }

    @Test func anImageResponseThatIsNotAnImageFailsAsUnsupported() async throws {
        let fixture = try DownloadWorkerFixture()
        fixture.fetcher.setResponse(.data(Data("<html>Blocked</html>".utf8)), for: "https://img.test/1.jpg")
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.job()?.failureReason == .unsupportedImageFormat)
        #expect(try await fixture.copy() == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aPluginThatSwallowsAWebViewRefusalStillFailsTheChapter() async throws {
        let fixture = try DownloadWorkerFixture()
        fixture.source.setListingHook { modules in
            _ = try? await modules.webview.loadUrl(request: WebviewRequest(url: "https://source.test/login", script: nil), context: makeTestNetworkContext())
        }
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        let failed = try await fixture.job()
        #expect(failed?.state == .failed)
        #expect(failed?.failureReason == .requiresInteractiveSource)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
        #expect(try await fixture.copy() == nil)
    }

    @Test func aPluginThatSwallowsANetworkDenialGetsWaitingAndItsPagesAreDiscarded() async throws {
        let fixture = try DownloadWorkerFixture()
        let path = fixture.path
        fixture.source.setListingHook { modules in
            path.set(NetworkPathSnapshot(status: .satisfied, isExpensive: true))
            _ = try? await modules.net.fetch(request: NetRequest(
                url: "https://api.test/chapters", method: "GET", headers: [:], body: nil
            ), context: makeTestNetworkContext())
            _ = try? await modules.net.fetch(request: NetRequest(
                url: "https://api.test/pages", method: "GET", headers: [:], body: nil
            ), context: makeTestNetworkContext())
        }
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        let waiting = try await fixture.job()
        #expect(waiting?.state == .waiting)
        #expect(waiting?.waitingReason == .meteredNetwork)
        #expect(fixture.inner.calls.count == 0)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
        #expect(try await fixture.copy() == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    /// The denial comes from the export's web view, on an unmetered path, so no path change can explain the
    /// outcome. The recorder's handler cancels the attempt before `run` checks for a denial. Checking cancellation
    /// first would requeue the attempt; the one-shot hook then lets the second attempt publish, which fails here.
    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aWebViewDenialRecordedDuringAnExportFailsTheAttemptEvenThoughItCancelsIt() async throws {
        let page = WebviewRequest(url: "https://source.test/login", script: nil)
        let wasm = TestWasm.build(TestWasm.Fixture.abi2(try TestWasm.openingWebView(page)))
        let fixture = try DownloadWorkerFixture()
        let listingHooks = DownloadCallCounter()
        fixture.source.setListingHook { modules in
            // One-shot: a requeued attempt lists again and must not open the page a second time.
            let earlier = listingHooks.count
            listingHooks.increment()
            guard earlier == 0 else { return }

            let runner = ItoRunner()
            await runner.setNetModule(modules.net)
            await runner.setWebviewModule(modules.webview)
            do {
                try await runner.loadPlugin(fromBytes: wasm)
                _ = try await runner.markCompleted(
                    kind: .manga, mediaKey: "media", unitKey: "unit",
                    context: makeTestNetworkContext(purpose: .manualBulkDownload)
                )
            } catch {
                // However the refused export ends, the attempt's outcome is the recorded denial.
            }
        }
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        let failed = try await fixture.job()
        #expect(failed?.state == .failed)
        #expect(failed?.failureReason == .requiresInteractiveSource)
        #expect(fixture.source.listings.count == 1)
        #expect(try await fixture.copy() == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func aDiskFullMidAssetRemovesTheStagingAndKeepsVerifiedCopies() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue(chapterKey: "chapter-1")
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()
        let verified = try #require(try await fixture.copy(chapterKey: "chapter-1"))

        fixture.offline.fileSystem.failNext(.writeFile, pathContaining: "p0001", with: .noSpace)
        _ = await fixture.enqueue(chapterKey: "chapter-2")
        fixture.coordinator.wake()
        await fixture.coordinator.untilIdle()

        let waiting = try await fixture.job(chapterKey: "chapter-2")
        #expect(waiting?.state == .waiting)
        #expect(waiting?.waitingReason == .insufficientStorage)
        #expect(fixture.offline.fileSystem.childNames(of: fixture.offline.stagingURL).isEmpty)
        #expect(try await fixture.copy(chapterKey: "chapter-1")?.versionId == verified.versionId)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func aRetryAfterAFailureRefreezesTheEpochAndDownloadsAgain() async throws {
        let fixture = try DownloadWorkerFixture(pages: [])
        _ = await fixture.enqueue()
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.job()?.state == .failed)

        fixture.source.setPages(DownloadWorkerFixture.defaultPages)
        try await fixture.center.retry(fixture.edition())
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() != nil)
    }
}
