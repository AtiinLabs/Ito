import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// The limits a running coordinator reads each time it looks at the queue head, changed by a test between passes.
private final class LimitsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: AutomaticDownloadLimits

    init(_ limits: AutomaticDownloadLimits) { current = limits }

    var value: AutomaticDownloadLimits {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// The worker and the center under automatic work: the quota gate at dequeue, the center as the catalog sink that wakes
/// the worker, and the commands that stop an attempt. Every transfer is scripted and every wait is an explicit gate.
@MainActor
struct DownloadQueueCoordinatorAutomaticTests {
    private nonisolated static let roomy = AutomaticDownloadLimits(
        queueLimit: 500, quotaBytes: 100 * AutomaticDownloadLimits.bytesPerGiB
    )
    private nonisolated static let media = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)

    private func numbered(_ numbers: some Sequence<Int>) -> [Chapter] {
        SubscriptionLedgerFixture.numbered(numbers)
    }

    /// An enabled rule on the saved series with its baseline accepted from chapters 1...2, through the center.
    private func subscribe(
        _ fixture: DownloadWorkerFixture,
        configuration: SubscriptionConfiguration = SubscriptionConfiguration()
    ) async throws -> String {
        await fixture.coordinator.reconcile()
        try await fixture.offline.database.dbPool.write { db in
            try LibraryItem(
                id: "series-1", title: "Series", coverUrl: nil, pluginId: "plugin.test", isAnime: false,
                pluginType: .manga, rawPayload: Data(), anilistId: nil
            ).insert(db)
        }
        let outcome = try await fixture.center.enableSubscription(SubscriptionEnableRequest(
            media: Self.media, reviewedSourceEpoch: OfflineStoreFixture.epoch, configuration: configuration
        ))
        guard case .enabled(let id, _) = outcome else { throw SubscriptionLedgerFixtureError.notEnabled }
        try await commit(fixture, numbered(1...2), through: fixture.center)
        return id
    }

    /// One check of the series through the sink, the way `UpdateManager` hands it over.
    private func commit(
        _ fixture: DownloadWorkerFixture,
        _ chapters: [Chapter],
        through sink: any SubscriptionCatalogSink
    ) async throws {
        let ticket = try #require(await sink.begin(media: Self.media))
        await sink.commit(ticket, try SubscriptionLedgerFixture.observation(chapters, epoch: ticket.sourceEpoch))
    }

    @Test func automaticJobsWaitForTheDiskQuotaWhileManualJobsRunAndStartOnceThereIsRoom() async throws {
        let limits = LimitsBox(Self.roomy)
        let fixture = try DownloadWorkerFixture(automaticLimits: { limits.value })
        _ = try await subscribe(fixture)
        // Something is saved first, so the stored bytes exist.
        _ = await fixture.enqueue(chapterKey: "saved")
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.copy(chapterKey: "saved") != nil)

        // The quota is now full. An automatic job is queued behind the worker's back (no wake).
        limits.value = AutomaticDownloadLimits(queueLimit: 500, quotaBytes: 1)
        let ticket = try #require(try await fixture.store.beginSubscriptionCheck(
            media: Self.media, capturedEpoch: OfflineStoreFixture.epoch
        ))
        _ = try await fixture.store.commitSubscriptionObservation(
            ticket, try SubscriptionLedgerFixture.observation(numbered(1...3)), limits: Self.roomy
        )
        #expect(try await fixture.job(chapterKey: "c3")?.state == .queued)

        // A manual chapter is started and published; the automatic one is not.
        _ = await fixture.enqueue(chapterKey: "manual")
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.copy(chapterKey: "manual") != nil)
        #expect(try await fixture.copy(chapterKey: "c3") == nil)
        #expect(try await fixture.job(chapterKey: "c3")?.state == .queued)

        // Room appears: the same worker takes it on the next wake.
        limits.value = Self.roomy
        fixture.coordinator.wake()
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.copy(chapterKey: "c3") != nil)
        #expect(try await fixture.job(chapterKey: "c3") == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func theCenterAsSinkCommitsTheObservationAndWakesTheWorkerForWhatItQueued() async throws {
        let fixture = try DownloadWorkerFixture(automaticLimits: { Self.roomy })
        _ = try await subscribe(fixture)
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        try await commit(fixture, numbered(1...3), through: fixture.center)
        await fixture.coordinator.untilIdle()

        // The commit queued c3 and woke the worker, which published it: nothing polled or slept.
        #expect(try await fixture.copy(chapterKey: "c3") != nil)
        #expect(try await fixture.store.jobs().isEmpty)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func aCheckWithoutAnEnabledRuleGetsNoTicketAndAFailureIsRecordedByItsTicket() async throws {
        let fixture = try DownloadWorkerFixture(automaticLimits: { Self.roomy })
        await fixture.coordinator.reconcile()
        #expect(await fixture.center.begin(media: Self.media) == nil)

        let id = try await subscribe(fixture)
        let ticket = try #require(await fixture.center.begin(media: Self.media))
        await fixture.center.fail(ticket, .fetchFailed)

        let record = try await fixture.offline.database.dbPool.read { db in
            try SeriesSubscriptionRecord.fetchOne(db, key: id)
        }
        #expect(record?.lastAttemptOutcome == .fetchFailed)
    }

    @Test func disablingStopsTheRunningAttemptAndLeavesNoCopyNoJobAndNoStaging() async throws {
        let fixture = try DownloadWorkerFixture(automaticLimits: { Self.roomy })
        let id = try await subscribe(fixture)
        let gate = fixture.fetcher.gate(for: "https://img.test/3.jpg")
        await fixture.startWorker()
        try await commit(fixture, numbered(1...3), through: fixture.center)
        await gate.awaitArrival()

        let release = try await fixture.center.disableSubscription(id: id)
        await gate.release()
        await fixture.coordinator.untilIdle()

        #expect(release.removedJobIds.count == 1)
        #expect(try await fixture.copy(chapterKey: "c3") == nil)
        #expect(try await fixture.job(chapterKey: "c3") == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func pausingStopsTheRunningAttemptAndResumingFinishesTheJob() async throws {
        let fixture = try DownloadWorkerFixture(automaticLimits: { Self.roomy })
        let id = try await subscribe(fixture)
        let gate = fixture.fetcher.gate(for: "https://img.test/3.jpg")
        await fixture.startWorker()
        try await commit(fixture, numbered(1...3), through: fixture.center)
        await gate.awaitArrival()

        try await fixture.center.pauseSubscription(id: id)
        await gate.release()
        await fixture.coordinator.untilIdle()

        // The job went back to the queue and a job without an enabled owner is not started.
        #expect(try await fixture.job(chapterKey: "c3")?.state == .queued)
        #expect(try await fixture.copy(chapterKey: "c3") == nil)

        try await fixture.center.resumeSubscription(id: id)
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.copy(chapterKey: "c3") != nil)
        #expect(try await fixture.job(chapterKey: "c3") == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func anEditNeverBypassesTheRunCapAndOnlyTheNextCheckAdmitsTheHeldPositions() async throws {
        let fixture = try DownloadWorkerFixture(automaticLimits: { Self.roomy })
        let id = try await subscribe(fixture, configuration: SubscriptionConfiguration(perRunPositionCap: 1))
        // Three forward positions under a cap of one: one job, two events held by the run cap.
        try await commit(fixture, numbered(1...5), through: fixture.center)
        #expect(try await fixture.store.jobs().count == 1)
        let held = try await fixture.offline.database.dbPool.read { db in
            try SubscriptionEventRecord.filter(Column("decision") == "pending").fetchAll(db)
        }
        #expect(held.count == 2 && held.allSatisfy { $0.pendingReason == .runCap })
        let record = try #require(try await fixture.offline.database.dbPool.read { db in
            try SeriesSubscriptionRecord.fetchOne(db, key: id)
        })

        // The edit decides waiting events again, but the held ones stay held: no new job.
        let outcome = try await fixture.center.editSubscription(SubscriptionEdit(
            subscriptionId: id, expectedConfigGeneration: record.configGeneration,
            configuration: SubscriptionConfiguration(perRunPositionCap: 1, selection: .allUploads)
        ))
        #expect(outcome == .applied(configGeneration: record.configGeneration + 1))
        #expect(try await fixture.store.jobs().count == 1)
        let stillHeld = try await fixture.offline.database.dbPool.read { db in
            try SubscriptionEventRecord.filter(Column("decision") == "pending").fetchCount(db)
        }
        #expect(stillHeld == 2)

        // The next check commit admits exactly one more position.
        try await commit(fixture, numbered(1...5), through: fixture.center)
        #expect(try await fixture.store.jobs().count == 2)
    }
}
