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

    @Test func aPluginThatSwallowsAWebViewRefusalStillFailsTheChapter() async throws {
        let fixture = try DownloadWorkerFixture()
        fixture.source.setListingHook { modules in
            _ = try? await modules.webview.loadUrl(request: WebviewRequest(url: "https://source.test/login", script: nil))
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
            ))
            _ = try? await modules.net.fetch(request: NetRequest(
                url: "https://api.test/pages", method: "GET", headers: [:], body: nil
            ))
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
