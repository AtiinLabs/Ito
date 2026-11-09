import Combine
import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

@MainActor
struct DownloadQueueCoordinatorTests {
    @Test func enqueueBeforeReconciliationIsRefusedAsUnavailable() async throws {
        let fixture = try DownloadWorkerFixture()

        let outcome = await fixture.enqueue(reconcileFirst: false)

        #expect(outcome == .refused(.unavailable))
        #expect(try await fixture.store.jobs().isEmpty)
    }

    @Test func duplicateEnqueueIsAlreadyQueuedAndUnsupportedRequestsAreRefused() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()

        let first = await fixture.enqueue()
        let duplicate = await fixture.enqueue()
        let paywalled = await fixture.enqueue(chapterKey: "chapter-2", paywalled: true)

        #expect(first == .queued)
        #expect(duplicate == .alreadyQueued)
        #expect(paywalled == .refused(.paywalled))
        #expect(try await fixture.store.jobs().count == 1)
    }

    @Test func queuedChaptersPublishAndLeaveTheQueueEmpty() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue(chapterKey: "chapter-1")
        _ = await fixture.enqueue(chapterKey: "chapter-2")

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy(chapterKey: "chapter-1") != nil)
        #expect(try await fixture.copy(chapterKey: "chapter-2") != nil)
        #expect(try await fixture.store.jobs().isEmpty)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func deleteWhileTheLastAssetIsInFlightLeavesNoCopyNoVersionAndNoJob() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        let gate = fixture.fetcher.gate(for: "https://img.test/3.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        try await fixture.center.delete(fixture.edition())
        await gate.release()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() == nil)
        #expect(try await fixture.job() == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func cancelWhileTheLastAssetIsInFlightLeavesNoCopyNoVersionAndNoJob() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        let gate = fixture.fetcher.gate(for: "https://img.test/3.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        try await fixture.center.cancel(fixture.edition())
        await gate.release()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() == nil)
        #expect(try await fixture.job() == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func aMeteredPathMidAttemptWaitsAndTheChapterResumesOnAnUnmeteredPath() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        let gate = fixture.fetcher.gate(for: "https://img.test/2.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        fixture.path.set(NetworkPathSnapshot(status: .satisfied, isExpensive: true))
        await fixture.coordinator.untilIdle()

        let waiting = try await fixture.job()
        #expect(waiting?.state == .waiting)
        #expect(waiting?.waitingReason == .meteredNetwork)
        #expect(try await fixture.copy() == nil)

        await gate.release()
        fixture.path.set(NetworkPathSnapshot(status: .satisfied))
        fixture.coordinator.wake()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() != nil)
        #expect(try await fixture.job() == nil)
    }

    @Test func aRotatedSourceEpochPausesTheChapterWithoutAnyRequestUntilRetried() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        try fixture.rotateEpoch()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        let paused = try await fixture.job()
        #expect(paused?.state == .waiting)
        #expect(paused?.waitingReason == .sourceConfigurationChanged)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
        #expect(fixture.source.listings.count == 0)

        try await fixture.center.retry(fixture.edition())
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() != nil)
    }

    @Test func aSourceEpochChangeDuringTheLastAssetRefusesTheCommit() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        let gate = fixture.fetcher.gate(for: "https://img.test/3.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        try fixture.rotateEpoch()
        await gate.release()
        await fixture.coordinator.untilIdle()

        let paused = try await fixture.job()
        #expect(paused?.state == .waiting)
        #expect(paused?.waitingReason == .sourceConfigurationChanged)
        #expect(try await fixture.copy() == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func aTrustChangeDuringTheAttemptRequeuesAndTheNextAttemptPublishes() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        let gate = fixture.fetcher.gate(for: "https://img.test/3.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        // The commit refuses the stale trust; the chapter is fetched again under the current trust.
        fixture.source.changeTrust()
        await gate.release()
        await fixture.coordinator.untilIdle()

        #expect(fixture.runtimes.runtimeRequests == 2)
        #expect(try await fixture.copy() != nil)
        #expect(try await fixture.job() == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func aRepublishedPluginMidAttemptRequeuesAndTheNextAttemptPublishes() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        let gate = fixture.fetcher.gate(for: "https://img.test/3.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        // Any install or refresh republishes every plugin. The stale attempt requeues instead of asking
        // for a Retry, and the next attempt runs on a fresh runtime.
        fixture.source.republish()
        await gate.release()
        await fixture.coordinator.untilIdle()

        #expect(fixture.runtimes.runtimeRequests == 2)
        #expect(try await fixture.copy() != nil)
        #expect(try await fixture.job() == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func anUninstalledSourceWaitsAsSourceUnavailableWithoutAttempting() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        fixture.runtimes.isInstalled = false

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        let job = try await fixture.job()
        #expect(job?.waitingReason == .sourceUnavailable)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
    }

    @Test func noConnectionWaitsWithoutAnyRequest() async throws {
        let fixture = try DownloadWorkerFixture()
        fixture.path.set(NetworkPathSnapshot(status: .unsatisfied))
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        let job = try await fixture.job()
        #expect(job?.waitingReason == .noConnection)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
    }

    @Test func lockedDeviceWaitsAndResumesWhenProtectedDataReturns() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        await fixture.offline.protectedData.setAvailable(false)

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.job()?.waitingReason == .protectedDataUnavailable)
        #expect(fixture.fetcher.requestedURLs.isEmpty)

        await fixture.offline.protectedData.setAvailable(true)
        fixture.protectedEvents.send(())
        fixture.coordinator.wake()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() != nil)
    }

    @Test func fullStorageWaitsWithoutAnyRequestAndResumesOnAWake() async throws {
        let fixture = try DownloadWorkerFixture()
        fixture.offline.fileSystem.setCapacity(1024)
        _ = await fixture.enqueue()

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.job()?.waitingReason == .insufficientStorage)
        #expect(fixture.fetcher.requestedURLs.isEmpty)

        fixture.offline.fileSystem.setCapacity(10 * 1024 * 1024 * 1024)
        fixture.coordinator.wake()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() != nil)
    }

    @Test func suspendingInterruptsTheAttemptAndForegroundResumesIt() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        let gate = fixture.fetcher.gate(for: "https://img.test/2.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        fixture.coordinator.suspend()
        await fixture.coordinator.untilIdle()

        let interrupted = try await fixture.job()
        #expect(interrupted?.state == .waiting)
        #expect(interrupted?.waitingReason == .appInBackground)
        #expect(try await fixture.copy() == nil)

        await gate.release()
        fixture.coordinator.start()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() != nil)
        #expect(try await fixture.job() == nil)
    }

    @Test func aSuspensionDuringPublishLetsTheFinishedChapterPublish() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        let hold = fixture.offline.fileSystem.holdNext(.moveItem, pathContaining: "/versions/")
        await fixture.startWorker()
        await hold.awaitArrival()

        fixture.coordinator.suspend()
        hold.release()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() != nil)
        #expect(try await fixture.job() == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func aMeteredPathDuringPublishLetsTheFinishedChapterPublish() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        let hold = fixture.offline.fileSystem.holdNext(.moveItem, pathContaining: "/versions/")
        await fixture.startWorker()
        await hold.awaitArrival()

        fixture.path.set(NetworkPathSnapshot(status: .satisfied, isExpensive: true))
        hold.release()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() != nil)
        #expect(try await fixture.job() == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func aSuspensionWhileTheSourceLoadsStartsNoAttempt() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        let load = DownloadTestGate()
        fixture.runtimes.loadGate = load
        await fixture.startWorker()
        await load.awaitArrival()

        fixture.coordinator.suspend()
        await load.release()
        await fixture.coordinator.untilIdle()

        let waiting = try await fixture.job()
        #expect(waiting?.state == .waiting)
        #expect(waiting?.waitingReason == .appInBackground)
        #expect(fixture.source.listings.count == 0)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
        try await fixture.offline.assertInvariants(fixture.store)

        fixture.coordinator.start()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() != nil)
        #expect(try await fixture.job() == nil)
    }

    @Test func aDeleteWhileTheSourceLoadsStartsNoAttempt() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        let load = DownloadTestGate()
        fixture.runtimes.loadGate = load
        await fixture.startWorker()
        await load.awaitArrival()

        try await fixture.center.delete(fixture.edition())
        await load.release()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.job() == nil)
        #expect(try await fixture.copy() == nil)
        #expect(fixture.source.listings.count == 0)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func aListingThatReportsItsCancellationAsAPluginErrorStillWaits() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        let listing = DownloadTestGate()
        fixture.source.setListingGate(listing)
        await fixture.startWorker()
        await listing.awaitArrival()

        fixture.path.set(NetworkPathSnapshot(status: .satisfied, isExpensive: true))
        await fixture.coordinator.untilIdle()

        let waiting = try await fixture.job()
        #expect(waiting?.state == .waiting)
        #expect(waiting?.waitingReason == .meteredNetwork)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func aRepublishDuringTheSourceLoadKeepsTheChapterQueuedAndTheNextLoadPublishes() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = await fixture.enqueue()
        let load = DownloadTestGate()
        fixture.runtimes.loadGate = load
        await fixture.startWorker()
        await load.awaitArrival()

        fixture.source.republish()
        await load.release()
        await fixture.coordinator.untilIdle()

        #expect(fixture.runtimes.runtimeRequests == 2)
        #expect(try await fixture.copy() != nil)
        #expect(try await fixture.job() == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }
}
