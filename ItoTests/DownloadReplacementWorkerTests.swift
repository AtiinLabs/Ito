import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// Replacement jobs through the worker. A replacement that no longer applies ends once, its runtime is built at most
/// once, the saved copy stays, and the ordinary jobs behind it still run. Everything waits on `untilIdle`; nothing sleeps.
@MainActor
struct DownloadReplacementWorkerTests {
    /// Queues a replacement of the published chapter-1 copy, as the detail screen's confirmation does.
    private func queueReplacement(_ fixture: DownloadWorkerFixture) async throws {
        let preview = try await fixture.confirmablePreview()
        #expect(await fixture.center.replace(preview) == .queued)
    }

    /// Queues chapter-2 as an ordinary download, placed after the replacement in queue order. Every job of a
    /// fixture shares one fixed clock, so the order is pinned here rather than left to the batch identifiers.
    private func enqueueOrdinaryBehind(_ fixture: DownloadWorkerFixture) async throws {
        #expect(await fixture.enqueue(chapterKey: "chapter-2") == .queued)
        try await fixture.offline.database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE downloadJob SET createdAt = ? WHERE chapterKey = 'chapter-2'",
                arguments: [OfflineStoreFixture.fixedDate.addingTimeInterval(60)]
            )
        }
    }

    @Test func aDamagedOldCopyWhileQueuedEndsTheReplacementOnceAndTheOrdinaryJobBehindItRuns() async throws {
        let fixture = try DownloadWorkerFixture()
        let old = try await fixture.offline.publishedEdition(fixture.store)
        try await queueReplacement(fixture)
        try await enqueueOrdinaryBehind(fixture)
        try await fixture.store.markDamaged(versionId: old, reason: .pageMismatch)

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        // One runtime for the replacement that ends, one for the ordinary job. The queue never picks the replacement again.
        #expect(fixture.runtimes.runtimeRequests == 2)
        let ended = try #require(try await fixture.job())
        #expect(ended.state == .failed)
        #expect(ended.failureReason == .replacementStale)
        #expect(try await fixture.offline.rowCount("downloadReplacementIntent") == 0)
        #expect(fixture.offline.fileSystem.exists(fixture.offline.versionURL(old)))
        #expect(try await fixture.copy(chapterKey: "chapter-2") != nil)
        #expect(try await fixture.store.nextQueuedJob() == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func aRotatedEpochEndsAQueuedReplacementBeforeAnyRuntimeIsBuilt() async throws {
        let fixture = try DownloadWorkerFixture()
        let old = try await fixture.offline.publishedEdition(fixture.store)
        try await queueReplacement(fixture)
        try fixture.rotateEpoch()
        // The ordinary job is captured under the rotated epoch, so it can run.
        #expect(await fixture.enqueue(chapterKey: "chapter-2") == .queued)
        try await fixture.offline.database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE downloadJob SET createdAt = ? WHERE chapterKey = 'chapter-2'",
                arguments: [OfflineStoreFixture.fixedDate.addingTimeInterval(60)]
            )
        }

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        // Only the ordinary job builds a runtime: the replacement ended on its frozen epoch before any load.
        #expect(fixture.runtimes.runtimeRequests == 1)
        let ended = try #require(try await fixture.job())
        #expect(ended.state == .failed)
        #expect(ended.failureReason == .replacementStale)
        #expect(ended.sourceEpoch == OfflineStoreFixture.epoch)
        #expect(try await fixture.copy()?.versionId == old)
        #expect(try await fixture.copy(chapterKey: "chapter-2") != nil)
    }

    @Test func aRestoredReplacementResumedAfterAnEpochChangeEndsWithoutAnyRuntime() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = try await fixture.offline.publishedEdition(fixture.store)
        try await queueReplacement(fixture)
        // A restore pauses every job until it is reviewed; the user then resumes it under a changed source.
        try await fixture.offline.database.dbPool.write { db in
            try db.execute(sql: "UPDATE downloadJob SET state = 'waiting', waitingReason = 'restoredPendingReview'")
        }
        try fixture.rotateEpoch()

        try await fixture.center.retry(fixture.edition())
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        #expect(fixture.runtimes.runtimeRequests == 0)
        #expect(try await fixture.job()?.failureReason == .replacementStale)
        #expect(try await fixture.copy() != nil)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
    }

    @Test func aReplacementWithoutRoomForItsOldCopyWaitsWhileTheOrdinaryJobBehindItRuns() async throws {
        let fixture = try DownloadWorkerFixture()
        let old = try await fixture.offline.publishedEdition(fixture.store)
        let oldBytes = try #require(try await fixture.copy()).byteCount
        try await queueReplacement(fixture)
        try await enqueueOrdinaryBehind(fixture)
        // Enough for a new copy above the reserve, but not for the old copy it replaces as well.
        fixture.offline.fileSystem.setCapacity(OfflineChapterStore.reserveBytes + oldBytes / 2)

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        let waiting = try #require(try await fixture.job())
        #expect(waiting.state == .waiting)
        #expect(waiting.waitingReason == .insufficientStorage)
        #expect(try await fixture.copy(chapterKey: "chapter-2") != nil)
        #expect(try await fixture.copy()?.versionId == old)

        // Another pass with the same room does not readmit it.
        fixture.coordinator.wake()
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.job()?.state == .waiting)
        #expect(fixture.offline.fileSystem.exists(fixture.offline.versionURL(old)))

        fixture.offline.fileSystem.setCapacity(10 * 1024 * 1024 * 1024)
        fixture.coordinator.wake()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.job() == nil)
        #expect(try await fixture.copy()?.versionId != old)
        try await fixture.offline.assertInvariants(fixture.store)
    }
}
