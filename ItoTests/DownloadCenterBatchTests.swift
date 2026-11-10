import Combine
import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// The batch and bulk commands of `DownloadCenter`, with a worker running real attempts against the
/// scripted source.
@MainActor
struct DownloadCenterBatchTests {
    private static let series = MediaIdentity(
        pluginId: DownloadWorkerFixture.plugin,
        canonicalMediaId: "series-1",
        mediaKind: .manga
    )

    private static func request(
        _ keys: [String],
        pluginId: String = DownloadWorkerFixture.plugin
    ) -> DownloadBatchRequest {
        DownloadBatchRequest(
            pluginId: pluginId,
            mediaKind: .manga,
            canonicalMediaId: "series-1",
            entry: .manga(Manga(key: "series-1", title: "Series One")),
            seriesTitle: "Series One",
            preset: .next5,
            selection: DownloadBatchRecord.sourceListSelection,
            catalogDigest: String(repeating: "c", count: 64),
            chapters: keys.map { OfflineStoreFixture.chapter($0) }
        )
    }

    @Test func aBatchDownloadsEveryChapterFromItsOneFrozenSnapshotAndLeavesNoBatchRow() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()

        let outcome = await fixture.center.enqueueBatch(Self.request(["chapter-2", "chapter-1"]))
        #expect(outcome.queued == 2)
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy(chapterKey: "chapter-1") != nil)
        #expect(try await fixture.copy(chapterKey: "chapter-2") != nil)
        #expect(try await fixture.store.jobs().isEmpty)
        #expect(try await fixture.offline.rowCount("downloadBatch") == 0)
        #expect(fixture.source.listings.count == 2)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func aBatchForASourceWithoutAnEpochIsRefusedAsUnavailableAndQueuesNothing() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()

        let outcome = await fixture.center.enqueueBatch(Self.request(["chapter-1"], pluginId: "plugin.unknown"))

        #expect(outcome.refusal == .unavailable)
        #expect(try await fixture.offline.rowCount("downloadJob") == 0)
        #expect(try await fixture.offline.rowCount("downloadBatch") == 0)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func deletingTheSeriesWhileTheFirstChapterIsInFlightLeavesNothingAndNeverStartsTheRest() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        _ = await fixture.center.enqueueBatch(Self.request(["chapter-1", "chapter-2", "chapter-3"]))
        let gate = fixture.fetcher.gate(for: "https://img.test/3.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        try await fixture.center.deleteMedia(Self.series, suppress: false)
        await gate.release()
        await fixture.coordinator.untilIdle()

        for key in ["chapter-1", "chapter-2", "chapter-3"] {
            #expect(try await fixture.copy(chapterKey: key) == nil)
        }
        #expect(try await fixture.store.jobs().isEmpty)
        #expect(try await fixture.offline.rowCount("downloadBatch") == 0)
        #expect(fixture.source.listings.count == 1)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func cancellingTheBatchJobsWhileOneIsInFlightLeavesNothingAndKeepsNoCopy() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        _ = await fixture.center.enqueueBatch(Self.request(["chapter-1", "chapter-2"]))
        let ids = try await fixture.store.jobs().map(\.id)
        let gate = fixture.fetcher.gate(for: "https://img.test/3.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        try await fixture.center.cancel(jobIDs: ids)
        await gate.release()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy(chapterKey: "chapter-1") == nil)
        #expect(try await fixture.copy(chapterKey: "chapter-2") == nil)
        #expect(try await fixture.store.jobs().isEmpty)
        #expect(try await fixture.offline.rowCount("downloadBatch") == 0)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aJobRemovedBehindTheCentersBackStopsItsAttemptBeforeTheNextAsset() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        _ = await fixture.center.enqueueBatch(Self.request(["chapter-1"]))
        fixture.center.startObserving(scheduling: ImmediateValueObservationScheduler())
        let gate = fixture.fetcher.gate(for: "https://img.test/2.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()
        for await states in fixture.center.$states.values {
            if case .downloading? = states[Self.series]?["chapter-1"] { break }
        }

        // As a relink or a restore does: the rows go without any call to the center or the coordinator.
        try await fixture.offline.database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM downloadJob")
            try db.execute(sql: "DELETE FROM downloadBatch")
        }
        // The gate is never released, so the attempt can only be cancelled by the center after it saw
        // the job gone. The time limit turns a missing cancel into a failure instead of a hang.
        await gate.awaitCancellation()
        #expect(await !gate.wasReleased)
        await fixture.coordinator.untilIdle()

        #expect(!fixture.fetcher.requestedURLs.contains("https://img.test/3.jpg"))
        #expect(try await fixture.copy() == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    /// A snapshot taken before the job was queued can reach the center after its attempt has started. The
    /// center confirms against the store, so the live attempt is not cancelled and the chapter is saved.
    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aSnapshotThatPredatesTheRunningJobDoesNotCancelItsAttempt() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        let scheduler = HeldObservationScheduler()
        fixture.center.startObserving(scheduling: scheduler)
        // The observation's first value is the empty queue. It is held, and it was read before the enqueue.
        let stale = await scheduler.nextPublication()
        _ = await fixture.center.enqueueBatch(Self.request(["chapter-1"]))
        let gate = fixture.fetcher.gate(for: "https://img.test/3.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        stale.run()
        await gate.release()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.copy() != nil)
        #expect(try await fixture.store.jobs().isEmpty)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func bulkRetryRequeuesPausedChaptersUnderTheCurrentEpochAndTheWorkerFinishesThem() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        _ = await fixture.center.enqueueBatch(Self.request(["chapter-1", "chapter-2"]))
        let jobs = try await fixture.store.jobs()
        for job in jobs {
            try await fixture.store.setWaiting(jobID: job.id, reason: .sourceUnavailable)
        }
        try fixture.rotateEpoch()

        try await fixture.center.retry(jobIDs: jobs.map(\.id))

        let retried = try await fixture.store.jobs()
        #expect(retried.allSatisfy { $0.state == .queued && $0.sourceEpoch == OfflineStoreFixture.rotatedEpoch })
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.copy(chapterKey: "chapter-1") != nil)
        #expect(try await fixture.copy(chapterKey: "chapter-2") != nil)
    }

    @Test func bulkDeleteOfDownloadedChaptersCanRecordThemAsDeliberatelyDeleted() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        _ = await fixture.center.enqueueBatch(Self.request(["chapter-1", "chapter-2", "chapter-3"]))
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        let summary = try await fixture.center.delete(
            [fixture.edition(chapterKey: "chapter-1"), fixture.edition(chapterKey: "chapter-2")],
            suppress: true
        )

        #expect(summary.removedCopies == 2)
        #expect(try await fixture.copy(chapterKey: "chapter-1") == nil)
        #expect(try await fixture.copy(chapterKey: "chapter-3") != nil)
        #expect(try await fixture.offline.rowCount("downloadSuppression") == 2)
        try await fixture.offline.assertInvariants(fixture.store)
    }
}

/// Holds every publication of a `ValueObservation` until the test runs it, including the initial value,
/// so a test chooses when the center sees a snapshot.
nonisolated private final class HeldObservationScheduler: ValueObservationMainActorScheduler, @unchecked Sendable {
    nonisolated struct Publication: @unchecked Sendable {
        let action: @MainActor () -> Void

        @MainActor
        func run() {
            action()
        }
    }

    private let lock = NSLock()
    private var publications: [Publication] = []
    private var continuations: [CheckedContinuation<Publication, Never>] = []

    func immediateInitialValue() -> Bool { false }

    func scheduleOnMainActor(_ action: @escaping @MainActor () -> Void) {
        let publication = Publication(action: action)
        lock.lock()
        if continuations.isEmpty {
            publications.append(publication)
            lock.unlock()
        } else {
            let continuation = continuations.removeFirst()
            lock.unlock()
            continuation.resume(returning: publication)
        }
    }

    /// The oldest publication not yet taken, waiting for it if none has been scheduled.
    func nextPublication() async -> Publication {
        await withCheckedContinuation { continuation in
            lock.lock()
            if publications.isEmpty {
                continuations.append(continuation)
                lock.unlock()
            } else {
                let publication = publications.removeFirst()
                lock.unlock()
                continuation.resume(returning: publication)
            }
        }
    }
}
