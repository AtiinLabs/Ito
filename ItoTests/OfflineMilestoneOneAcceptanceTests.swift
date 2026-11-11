import Foundation
import GRDB
import Testing
import UIKit
import ito_runner
@testable import Ito

/// Milestone 1 behaviour that the release build depends on. The production composition resolves its offline
/// root. A three-chapter batch that loses Wi-Fi waits for a metered network and fails nothing. A path that clears
/// while the queue is marked is readmitted in order. A chapter that a saved Library snapshot lists reads from its
/// copy without a remote loader. The attempt in flight finishes under a background grant, or is left waiting for
/// the foreground when the grant expires or is refused. Waits are event-driven and end on cancellation, under a
/// time limit.
@MainActor
struct OfflineMilestoneOneAcceptanceTests {
    private static let manga = Manga(key: "series-1", title: "Series One")
    private static let coverURL = "https://example.test/cover-series-1.jpg"

    private struct RootUnavailable: Error {}

    @Test func productionComposesTheOfflineStoreOnlyWhenTheRootResolves() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-m1-\(UUID().uuidString)", isDirectory: true)

        #expect(DurableStateBootstrap.production(resolveOfflineRoot: { root }).offlineChapterStore != nil)
        #expect(DurableStateBootstrap.production(resolveOfflineRoot: { throw RootUnavailable() }).offlineChapterStore == nil)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aBatchThatLosesWiFiWaitsForAMeteredNetworkAndFailsNothing() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        let outcome = await fixture.center.enqueueBatch(Self.batch(["chapter-1", "chapter-2", "chapter-3"]))
        #expect(outcome.queued == 3)
        let gate = fixture.fetcher.gate(for: "https://img.test/2.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        fixture.path.set(NetworkPathSnapshot(status: .satisfied, isExpensive: true))
        await fixture.coordinator.untilIdle()

        let jobs = try await fixture.store.jobs()
        #expect(jobs.count == 3)
        #expect(jobs.allSatisfy { $0.state == .waiting && $0.waitingReason == .meteredNetwork })
        #expect(!jobs.contains { $0.state == .failed })
        // Only the chapter already in flight started network work: the queued two never reached the runtime.
        #expect(fixture.runtimes.runtimeRequests == 1)
        #expect(fixture.fetcher.requestedURLs.count == 2)
        #expect(try await fixture.offline.rowCount("downloadedChapter") == 0)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aPathThatClearsWhileTheQueueIsBeingMarkedIsReadmittedAndDownloadedInOrder() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        fixture.path.set(NetworkPathSnapshot(status: .satisfied, isExpensive: true))
        _ = await fixture.center.enqueueBatch(Self.batch(["chapter-1", "chapter-2", "chapter-3"]))
        // The coordinator's start-up path read ran during the reconcile above, so the reads counted below belong to
        // the first pass only.
        // Within the first pass: the readmission reads the path first, then the admission reads it. The path
        // clears right after the admission read, so the update lands while the queue is being marked.
        fixture.path.runAfterRead(readsFromNow: 2) {
            fixture.path.set(NetworkPathSnapshot(status: .satisfied))
        }

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.store.jobs().isEmpty)
        #expect(try await fixture.copy(chapterKey: "chapter-1") != nil)
        #expect(try await fixture.copy(chapterKey: "chapter-2") != nil)
        #expect(try await fixture.copy(chapterKey: "chapter-3") != nil)
        #expect(fixture.source.listedRequestsSnapshot.map(\.chapter.key) == ["chapter-1", "chapter-2", "chapter-3"])
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aPathThatClearsAfterTheQueueIsMarkedDownloadsItInOrder() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        fixture.path.set(NetworkPathSnapshot(status: .satisfied, isExpensive: true))
        _ = await fixture.center.enqueueBatch(Self.batch(["chapter-1", "chapter-2", "chapter-3"]))
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        let marked = try await fixture.store.jobs()
        #expect(marked.count == 3)
        #expect(marked.allSatisfy { $0.state == .waiting && $0.waitingReason == .meteredNetwork })
        #expect(fixture.runtimes.runtimeRequests == 0)

        fixture.path.set(NetworkPathSnapshot(status: .satisfied))
        fixture.coordinator.wake()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.store.jobs().isEmpty)
        #expect(fixture.source.listedRequestsSnapshot.map(\.chapter.key) == ["chapter-1", "chapter-2", "chapter-3"])
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aChapterThatASavedSnapshotListsReadsFromItsCopyWithoutARemoteLoader() async throws {
        let fixture = try DownloadWorkerFixture(pages: [
            Page(index: 0, content: .url("https://img.test/1.jpg")),
            Page(index: 1, content: .url("https://img.test/2.jpg"))
        ])
        let pageBytes = [OfflineStoreFixture.jpeg("page-1"), OfflineStoreFixture.jpeg("page-2")]
        fixture.fetcher.setResponse(.data(pageBytes[0]), for: "https://img.test/1.jpg")
        fixture.fetcher.setResponse(.data(pageBytes[1]), for: "https://img.test/2.jpg")

        // The Library row's snapshot decodes with no plugin installed. It is the series the chapter below is read for.
        let snapshot = LibraryItem(
            id: "manga-abi2", title: "Tower of Dusk", coverUrl: Self.coverURL,
            pluginId: DownloadWorkerFixture.plugin, isAnime: false, pluginType: .manga,
            rawPayload: try PersistedDataFixtures.data("persisted-library-manga-widened-literals.json"),
            anilistId: nil
        )
        guard case .manga(let saved) = try await JSONDeferredPluginPayloadDecoder().decode(snapshot) else {
            Issue.record("The saved snapshot decodes as a manga")
            return
        }
        #expect(saved.key == snapshot.id)
        let listed = try #require(saved.chapters?.first { $0.key == "ch-001" })

        // The listed chapter downloads through the worker, under the snapshot's own identity and entry.
        await fixture.coordinator.reconcile()
        let request = DownloadBatchRequest(
            pluginId: DownloadWorkerFixture.plugin,
            mediaKind: .manga,
            canonicalMediaId: saved.key,
            entry: .manga(saved),
            seriesTitle: saved.title,
            preset: .next5,
            selection: DownloadBatchRecord.sourceListSelection,
            catalogDigest: String(repeating: "c", count: 64),
            chapters: [listed]
        )
        #expect(await fixture.center.enqueueBatch(request).queued == 1)
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()
        let edition = OfflineChapterEdition(
            pluginId: DownloadWorkerFixture.plugin,
            mediaKind: .manga,
            canonicalMediaId: saved.key,
            chapterKey: listed.key
        )
        #expect(try await fixture.store.verifiedEdition(for: edition) != nil)

        // The saved entry lists the chapter, and its pages are served from the copy through the offline loader only.
        #expect(saved.chapters?.contains { $0.key == listed.key } == true)
        let loader = ResolvingMangaPageLoader(pluginID: DownloadWorkerFixture.plugin, local: fixture.store, remote: nil)
        let pages = try await loader.pages(for: .manga(saved), chapter: listed, operation: makeTestNetworkOperation())
        let assets = OfflineAssetDataLoader(reader: fixture.store)
        var served: [Data] = []
        for page in pages {
            served.append(try await OfflineReadingTestSupport.load(assets, URLRequest(url: try Self.offlineURL(page))))
        }
        #expect(served == pageBytes)

        // The durable cover is captured from the Library card and read back for the Downloads manager.
        try await fixture.offline.database.dbPool.write { db in try snapshot.insert(db) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        }
        let encoded = try #require(LibraryCoverThumbnailEncoder.encode(image))
        let thumbnails = LibraryCoverThumbnailStore(database: fixture.offline.database.dbPool)
        #expect(try await thumbnails.store(encoded, itemID: snapshot.id, coverUrl: Self.coverURL) == .stored)
        let covers = LibraryCoverThumbnails(store: thumbnails)
        let cover = try #require(await LibraryDownloadsThumbnails(covers: covers).thumbnail(for: snapshot))
        #expect(cover.image.size == CGSize(width: 20, height: 30))
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func theAttemptInFlightFinishesUnderABackgroundGrantAndNothingNewStarts() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        let grants = ManualBackgroundExecutionGranting()
        _ = await fixture.center.enqueueBatch(Self.batch(["chapter-1", "chapter-2"]))
        let gate = fixture.fetcher.gate(for: "https://img.test/2.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        fixture.coordinator.suspend(allowingInFlightCompletion: grants)
        #expect(grants.grantsBegun == 1)
        #expect(grants.grantsEnded == 0)
        await gate.release()
        await fixture.coordinator.untilIdle()
        await grants.awaitEnded()

        #expect(try await fixture.copy(chapterKey: "chapter-1") != nil)
        #expect(try await fixture.job(chapterKey: "chapter-1") == nil)
        let untouched = try #require(try await fixture.job(chapterKey: "chapter-2"))
        #expect(untouched.state == .queued)
        #expect(try await fixture.copy(chapterKey: "chapter-2") == nil)
        #expect(fixture.fetcher.requestedURLs.count == DownloadWorkerFixture.defaultPages.count)
        #expect(grants.grantsEnded == 1)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func expiringTheBackgroundGrantLeavesTheInFlightChapterWaitingForTheForeground() async throws {
        let fixture = try DownloadWorkerFixture()
        let grants = ManualBackgroundExecutionGranting()
        _ = await fixture.enqueue()
        let gate = fixture.fetcher.gate(for: "https://img.test/2.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        fixture.coordinator.suspend(allowingInFlightCompletion: grants)
        grants.expire()
        await fixture.coordinator.untilIdle()
        await grants.awaitEnded()

        let interrupted = try #require(try await fixture.job())
        #expect(interrupted.state == .waiting)
        #expect(interrupted.waitingReason == .appInBackground)
        #expect(try await fixture.copy() == nil)
        #expect(grants.grantsEnded == 1)

        await gate.release()
        fixture.coordinator.start()
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.copy() != nil)
        #expect(try await fixture.job() == nil)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aGrantExpiringAfterAForegroundRestartDoesNotCancelTheAttemptTheNewLoopOwns() async throws {
        let fixture = try DownloadWorkerFixture()
        let grants = ManualBackgroundExecutionGranting()
        _ = await fixture.enqueue()
        let gate = fixture.fetcher.gate(for: "https://img.test/2.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        fixture.coordinator.suspend(allowingInFlightCompletion: grants)
        #expect(grants.grantsEnded == 0)
        // Back in the foreground while the attempt is still gated: the new loop waits behind the retired one.
        fixture.coordinator.start()
        grants.expire()
        await grants.awaitEnded()
        await gate.release()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() != nil)
        #expect(try await fixture.job() == nil)
        #expect(grants.grantsEnded == 1)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aRefusedGrantInterruptsTheInFlightChapterAsWaitingNotFailed() async throws {
        let fixture = try DownloadWorkerFixture()
        let grants = ManualBackgroundExecutionGranting(refusesGrants: true)
        _ = await fixture.enqueue()
        let gate = fixture.fetcher.gate(for: "https://img.test/2.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        fixture.coordinator.suspend(allowingInFlightCompletion: grants)
        await fixture.coordinator.untilIdle()

        let interrupted = try #require(try await fixture.job())
        #expect(interrupted.state == .waiting)
        #expect(interrupted.waitingReason == .appInBackground)
        #expect(try await fixture.copy() == nil)
        #expect(grants.grantsBegun == 1)
        #expect(grants.grantsEnded == 1)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func suspendingWithoutAnAttemptInFlightAsksForNoGrant() async throws {
        let fixture = try DownloadWorkerFixture()
        let grants = ManualBackgroundExecutionGranting()

        // A worker that was never started.
        fixture.coordinator.suspend(allowingInFlightCompletion: grants)
        #expect(grants.grantsBegun == 0)

        // A started worker with nothing queued, idle between passes.
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()
        fixture.coordinator.suspend(allowingInFlightCompletion: grants)
        #expect(grants.grantsBegun == 0)
    }

    private static func batch(_ keys: [String]) -> DownloadBatchRequest {
        DownloadBatchRequest(
            pluginId: DownloadWorkerFixture.plugin,
            mediaKind: .manga,
            canonicalMediaId: "series-1",
            entry: .manga(manga),
            seriesTitle: manga.title,
            preset: .next5,
            selection: DownloadBatchRecord.sourceListSelection,
            catalogDigest: String(repeating: "c", count: 64),
            chapters: keys.map { OfflineStoreFixture.chapter($0) }
        )
    }

    private static func offlineURL(_ page: Page) throws -> URL {
        guard case .url(let locator) = page.content else {
            throw OfflineStoreFixtureError.notPublished
        }
        let url = try #require(URL(string: locator))
        #expect(url.scheme == OfflineAssetLocator.scheme)
        return url
    }
}
