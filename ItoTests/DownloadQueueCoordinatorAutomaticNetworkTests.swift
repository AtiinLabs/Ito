import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// Counts the writes to the job table, so a test can say a pass of the worker wrote nothing.
nonisolated final class JobWriteCounter: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var changes = 0

    var count: Int { lock.withLock { changes } }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == "downloadJob"
    }

    func databaseDidChange(with event: DatabaseEvent) {
        lock.withLock { changes += 1 }
    }

    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}

/// What network rule a job runs under follows who asked for it. A job only rules asked for is automatic: it never
/// holds, mints or borrows a metered-data consent and never blocks the head of the queue. A job a person also asked for
/// keeps the manual rule and its batch. Every transfer is scripted and every wait is an explicit gate.
@MainActor
struct DownloadQueueCoordinatorAutomaticNetworkTests {
    private nonisolated static let roomy = AutomaticDownloadLimits(
        queueLimit: 500, quotaBytes: 100 * AutomaticDownloadLimits.bytesPerGiB
    )
    private nonisolated static let media = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)
    private static let expensive = NetworkPathSnapshot(status: .satisfied, isExpensive: true)
    private static let unmetered = NetworkPathSnapshot(status: .satisfied)

    private func setMode(_ mode: NetworkDownloadMode, on fixture: DownloadWorkerFixture) {
        var configuration = NetworkPolicyConfiguration.defaults
        configuration.downloadMode = mode
        fixture.networkContexts.policy.apply(configuration)
    }

    /// An enabled rule on the saved series with its baseline accepted, then one check that queues chapter c3 for the
    /// rule alone.
    private func queueAutomaticChapter(_ fixture: DownloadWorkerFixture) async throws -> DownloadJobRecord {
        await fixture.coordinator.reconcile()
        try await fixture.offline.database.dbPool.write { db in
            try LibraryItem(
                id: "series-1", title: "Series", coverUrl: nil, pluginId: "plugin.test", isAnime: false,
                pluginType: .manga, rawPayload: Data(), anilistId: nil
            ).insert(db)
        }
        let outcome = try await fixture.center.enableSubscription(SubscriptionEnableRequest(
            media: Self.media, reviewedSourceEpoch: OfflineStoreFixture.epoch, configuration: SubscriptionConfiguration()
        ))
        guard case .enabled = outcome else { throw SubscriptionLedgerFixtureError.notEnabled }
        for numbers in [1...2, 1...3] {
            let ticket = try #require(await fixture.center.begin(media: Self.media))
            await fixture.center.commit(
                ticket, try SubscriptionLedgerFixture.observation(SubscriptionLedgerFixture.numbered(numbers), epoch: ticket.sourceEpoch)
            )
        }
        return try #require(try await fixture.job(chapterKey: "c3"))
    }

    private func manualBatch(_ keys: [String]) -> DownloadBatchRequest {
        DownloadBatchRequest(
            pluginId: "plugin.test", mediaKind: .manga, canonicalMediaId: "series-1",
            entry: .manga(Manga(key: "series-1", title: "Series One")), seriesTitle: "Series One",
            provenance: .builtIn(.next5), selection: DownloadBatchRecord.sourceListSelection,
            catalogDigest: String(repeating: "c", count: 64),
            chapters: keys.map { OfflineStoreFixture.chapter($0) }
        )
    }

    private func hasConsent(_ fixture: DownloadWorkerFixture, batchId: String) -> Bool {
        guard let id = UUID(uuidString: batchId) else { return false }
        return fixture.networkContexts.policy.hasValidConsent(
            fixture.networkContexts.consentBinding(batchID: id, pluginID: "plugin.test")
        )
    }

    // MARK: - A2

    @Test func anAutomaticJobWaitsForTheMeteredPathWithoutHoldingTheQueueOrAnyConsentAndAConsentedManualBatchRunsBeside() async throws {
        let fixture = try DownloadWorkerFixture(automaticLimits: { Self.roomy })
        setMode(.askMetered, on: fixture)
        fixture.path.set(Self.expensive)
        let auto = try await queueAutomaticChapter(fixture)

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        // Waiting for the rule's own condition: no runtime was even requested, and no consent exists for its batch.
        let waiting = try #require(try await fixture.store.job(id: auto.id))
        #expect(waiting.state == .waiting && waiting.waitingReason == .meteredNetwork)
        #expect(fixture.runtimes.runtimeRequests == 0)
        #expect(!hasConsent(fixture, batchId: auto.batchId))

        // A person confirms a batch of their own, after the rule's job: it runs, with its own batch and grant.
        let manual = await fixture.center.enqueueBatch(manualBatch(["m1"]), confirmedMeteredUse: true)
        #expect(manual.queued == 1)
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.copy(chapterKey: "m1") != nil)
        let manualOperation = try #require(fixture.runtimes.operations.first)
        #expect(manualOperation.purpose == .manualBulkDownload)
        #expect(manualOperation.batchID == manual.batchId.flatMap(UUID.init(uuidString:)))
        #expect(manualOperation.scopedGrant != nil)
        // The rule's job is still waiting, and nothing about the person's confirmation reached it.
        #expect(try await fixture.store.job(id: auto.id)?.waitingReason == .meteredNetwork)
        #expect(!hasConsent(fixture, batchId: auto.batchId))

        // On an unmetered path the same job runs, as automatic work: no batch, no grant.
        fixture.path.set(Self.unmetered)
        fixture.coordinator.wake()
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.copy(chapterKey: "c3") != nil)
        #expect(fixture.runtimes.operations.count == 2)
        let automatic = try #require(fixture.runtimes.operations.last)
        #expect(automatic.purpose == .automaticBulkDownload)
        #expect(automatic.batchID == nil)
        #expect(automatic.scopedGrant == nil)
        #expect(!hasConsent(fixture, batchId: auto.batchId))
        try await fixture.offline.assertInvariants(fixture.store)
    }

    // MARK: - A3

    @Test func theSameJobRunsWhenMeteredDataIsAllowedAndOtherwiseHoldsTheWholeQueue() async throws {
        // Allowed: the rule's job and a person's chapter both run on an expensive path.
        let allowed = try DownloadWorkerFixture(automaticLimits: { Self.roomy })
        setMode(.allowMetered, on: allowed)
        allowed.path.set(Self.expensive)
        _ = try await queueAutomaticChapter(allowed)
        _ = await allowed.enqueue(chapterKey: "manual")
        await allowed.startWorker()
        await allowed.coordinator.untilIdle()
        #expect(try await allowed.copy(chapterKey: "c3") != nil)
        #expect(try await allowed.copy(chapterKey: "manual") != nil)

        // Unmetered only: the condition is the same for everyone, so every queued job waits.
        let unmeteredOnly = try DownloadWorkerFixture(automaticLimits: { Self.roomy })
        setMode(.unmeteredOnly, on: unmeteredOnly)
        unmeteredOnly.path.set(Self.expensive)
        _ = try await queueAutomaticChapter(unmeteredOnly)
        _ = await unmeteredOnly.enqueue(chapterKey: "manual")
        await unmeteredOnly.startWorker()
        await unmeteredOnly.coordinator.untilIdle()
        #expect(try await unmeteredOnly.job(chapterKey: "c3")?.waitingReason == .meteredNetwork)
        #expect(try await unmeteredOnly.job(chapterKey: "manual")?.waitingReason == .meteredNetwork)
        #expect(unmeteredOnly.runtimes.runtimeRequests == 0)

        // Low Data Mode is never overridden: every queued job waits, whatever the mode.
        let lowData = try DownloadWorkerFixture(automaticLimits: { Self.roomy })
        setMode(.allowMetered, on: lowData)
        lowData.path.set(NetworkPathSnapshot(status: .satisfied, isConstrained: true))
        _ = try await queueAutomaticChapter(lowData)
        _ = await lowData.enqueue(chapterKey: "manual")
        await lowData.startWorker()
        await lowData.coordinator.untilIdle()
        #expect(try await lowData.job(chapterKey: "c3")?.waitingReason == .lowDataMode)
        #expect(try await lowData.job(chapterKey: "manual")?.waitingReason == .lowDataMode)
        #expect(lowData.runtimes.runtimeRequests == 0)
    }

    // MARK: - A5

    @Test func aWaitingAutomaticJobIsNotReadmittedAgainAndAgainUntilTheRuleMayUseThePath() async throws {
        let fixture = try DownloadWorkerFixture(automaticLimits: { Self.roomy })
        setMode(.askMetered, on: fixture)
        fixture.path.set(Self.expensive)
        let auto = try await queueAutomaticChapter(fixture)
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.store.job(id: auto.id)?.waitingReason == .meteredNetwork)

        // A consent a batch could hold would readmit a batch's waiting jobs, but never the rule's: it writes nothing.
        let counter = JobWriteCounter()
        fixture.offline.database.dbPool.add(transactionObserver: counter, extent: .observerLifetime)
        for _ in 0..<3 {
            fixture.coordinator.wake()
            await fixture.coordinator.untilIdle()
        }
        #expect(counter.count == 0)
        #expect(try await fixture.store.job(id: auto.id)?.state == .waiting)

        // The path the rule may use: now it is readmitted and runs.
        fixture.path.set(Self.unmetered)
        fixture.coordinator.wake()
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.copy(chapterKey: "c3") != nil)
        #expect(counter.count > 0)
    }

    // MARK: - A6

    @Test func aJobAPersonAlsoAskedForKeepsTheManualRuleAndItsBatchAndWaitsForThatBatchsConsentAlone() async throws {
        let fixture = try DownloadWorkerFixture(automaticLimits: { Self.roomy })
        setMode(.askMetered, on: fixture)
        fixture.path.set(Self.expensive)
        let auto = try await queueAutomaticChapter(fixture)
        // A person asks for the chapter the rule already queued: it attaches, and the job now has both owners.
        let attach = await fixture.center.enqueueBatch(manualBatch(["c3"]))
        #expect(attach.alreadyQueued == 1)
        #expect(try await fixture.store.nextQueuedJob(automaticAdmitted: true)?.ownership.manualRequestIds.count == 1)
        // And a batch of their own, confirmed for the metered path.
        fixture.networkContexts.policy.enterForeground()
        let consented = await fixture.center.enqueueBatch(manualBatch(["m1"]), confirmedMeteredUse: true)
        #expect(consented.queued == 1)

        await fixture.startWorker()
        await fixture.coordinator.untilIdle()

        // The job waits as a person's job would for the consent of its own (automatic) batch, which has none...
        let mixed = try #require(try await fixture.store.job(id: auto.id))
        #expect(mixed.state == .waiting && mixed.waitingReason == .meteredNetwork)
        #expect(!hasConsent(fixture, batchId: auto.batchId))
        // ...and holds only that batch: the person's confirmed batch ran beside it.
        #expect(try await fixture.copy(chapterKey: "m1") != nil)
        #expect(fixture.runtimes.operations.count == 1)

        // On an unmetered path it runs under the manual rule and its own batch, never as automatic work.
        fixture.path.set(Self.unmetered)
        fixture.coordinator.wake()
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.copy(chapterKey: "c3") != nil)
        let operation = try #require(fixture.runtimes.operations.last)
        #expect(operation.purpose == .manualBulkDownload)
        #expect(operation.batchID == UUID(uuidString: auto.batchId))
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func aPersonAskingForAnAttemptInFlightNeverPromotesItsPurposeMidFlight() async throws {
        let fixture = try DownloadWorkerFixture(automaticLimits: { Self.roomy })
        setMode(.askMetered, on: fixture)
        let auto = try await queueAutomaticChapter(fixture)
        let gate = fixture.fetcher.gate(for: "https://img.test/2.jpg")

        await fixture.startWorker()
        await gate.awaitArrival()
        // The attempt started as automatic work. A person now asks for the same chapter.
        let attach = await fixture.center.enqueueBatch(manualBatch(["c3"]))
        #expect(attach.alreadyQueued == 1)
        await gate.release()
        await fixture.coordinator.untilIdle()

        // The attempt finished under the context it started with.
        #expect(try await fixture.copy(chapterKey: "c3") != nil)
        #expect(fixture.runtimes.operations.count == 1)
        let operation = try #require(fixture.runtimes.operations.first)
        #expect(operation.purpose == .automaticBulkDownload)
        #expect(operation.batchID == nil)
        #expect(operation.scopedGrant == nil)
        #expect(!hasConsent(fixture, batchId: auto.batchId))
        try await fixture.offline.assertInvariants(fixture.store)
    }
}
