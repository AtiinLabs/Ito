import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// V2: a queued job that only automatic work asked for is shown as held when its rule is paused or the space for automatic
/// downloads is used up, and as queued otherwise. A job a person also asked for is never held.
struct SubscriptionHeldStateTests {
    private func seed(_ f: SubscriptionLedgerFixture) async throws -> DownloadJobRecord {
        try await f.enable()
        try await f.check(SubscriptionLedgerFixture.numbered(1...2))
        try await f.check(SubscriptionLedgerFixture.numbered(1...3))
        return try #require(try await f.jobs().first { $0.chapterKey == "c3" })
    }

    private func state(
        _ f: SubscriptionLedgerFixture,
        admitted: Bool = true
    ) async throws -> (ChapterDownloadState, DownloadListRow) {
        let (jobs, owners) = try await f.pool.read { db in
            (try DownloadJobRecord.fetchAll(db), try DownloadOwnerFact.readAll(db))
        }
        let job = try #require(jobs.first { $0.chapterKey == "c3" })
        let states = DownloadCenter.states(
            copies: [], jobs: jobs, progress: [:], owners: owners, automaticAdmitted: admitted
        )
        let shown = try #require(states[f.media]?["c3"])
        let row = DownloadListRow(
            edition: job.edition, title: nil, number: nil, volume: nil, scanlator: nil, state: shown, byteCount: 0,
            jobID: job.id
        )
        return (shown, row)
    }

    @Test func anAutomaticOnlyJobOfAnEnabledRuleIsQueuedAndOfAPausedRuleIsHeld() async throws {
        let f = try await SubscriptionLedgerFixture()
        let job = try await seed(f)
        #expect(try await f.owners(of: job.id).allSatisfy { $0.ownerKind == .subscription })

        let (running, _) = try await state(f)
        #expect(running == .queued)

        _ = try await f.store.pauseSubscription(id: try await f.subscription().id)
        let (paused, row) = try await state(f)
        #expect(paused == .held(.automaticRulePaused))
        #expect(!row.canRetry, "A held job has nothing to retry: it waits for its rule")
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func anEnabledRuleWhoseSpaceIsUsedUpHoldsItsQueuedJobForSpace() async throws {
        let f = try await SubscriptionLedgerFixture()
        _ = try await seed(f)

        let (full, row) = try await state(f, admitted: false)
        #expect(full == .held(.automaticSpaceFull))
        #expect(!row.canRetry)
        // A paused rule is reported as paused before it is reported as full.
        _ = try await f.store.pauseSubscription(id: try await f.subscription().id)
        #expect(try await state(f, admitted: false).0 == .held(.automaticRulePaused))
    }

    @Test func aJobAPersonAlsoAskedForIsNeverHeldWhateverTheRuleOrTheSpaceDo() async throws {
        let f = try await SubscriptionLedgerFixture()
        _ = try await seed(f)
        let attach = try await f.store.enqueueBatch(
            DownloadBatchRequest(
                pluginId: f.media.pluginId, mediaKind: f.media.mediaKind, canonicalMediaId: f.media.canonicalMediaId,
                entry: .manga(Manga(key: f.media.canonicalMediaId, title: "Series")), seriesTitle: "Series",
                provenance: .builtIn(.next5), selection: DownloadBatchRecord.sourceListSelection,
                catalogDigest: String(repeating: "c", count: 64), chapters: [OfflineStoreFixture.chapter("c3")]
            ),
            sourceEpoch: OfflineStoreFixture.epoch
        )
        #expect(attach.alreadyQueued == 1)
        _ = try await f.store.pauseSubscription(id: try await f.subscription().id)

        #expect(try await state(f, admitted: false).0 == .queued)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func aJobWithNoKnownOwnerIsNeverClaimedToBeHeld() throws {
        var job = DownloadJobRecordFixture.job()
        job.state = .queued
        #expect(DownloadCenter.state(of: job, progress: nil, owners: nil, automaticAdmitted: false) == .queued)
        #expect(DownloadCenter.state(of: job, progress: nil, owners: [], automaticAdmitted: false) == .queued)
    }

    @Test func anAutomaticOnlyJobThatWaitsForMeteredDataSaysSoButAManualOneKeepsItsOwnWords() throws {
        var job = DownloadJobRecordFixture.job()
        job.state = .waiting
        job.waitingReason = .meteredNetwork
        let automatic = [DownloadOwnerFact(kind: .subscription, subscriptionState: .enabled, isCurrent: true)]
        let manual = [DownloadOwnerFact(kind: .manual, subscriptionState: nil, isCurrent: false)]

        #expect(DownloadCenter.state(of: job, progress: nil, owners: automatic) == .held(.automaticMeteredNotAllowed))
        #expect(DownloadCenter.state(of: job, progress: nil, owners: manual + automatic) == .waiting(.meteredNetwork))
        #expect(DownloadCenter.state(of: job, progress: nil, owners: manual) == .waiting(.meteredNetwork))
        job.waitingReason = .noConnection
        #expect(DownloadCenter.state(of: job, progress: nil, owners: automatic) == .waiting(.noConnection))
        #expect(DownloadHoldReason.automaticMeteredNotAllowed.localizedTitle
            == "Waiting for Wi-Fi — automatic downloads use cellular data only when Settings allows it")
    }

    @Test func aHeldChapterCountsAsQueuedAndNeverAsActiveInTheSummaries() {
        let summary = SeriesDownloadSummary(states: [
            "a": .held(.automaticRulePaused), "b": .held(.automaticSpaceFull), "c": .queued, "d": .downloaded
        ])
        #expect(summary == SeriesDownloadSummary(saved: 1, queued: 3, failed: 0, damaged: 0))
        #expect(StoredEditionState(.held(.automaticRulePaused)) == .queued)
    }

    @Test func theOverviewRowsOfTheDownloadsScreenShowTheHeldState() async throws {
        let f = try await SubscriptionLedgerFixture()
        _ = try await seed(f)
        _ = try await f.store.pauseSubscription(id: try await f.subscription().id)

        let snapshot = try await f.pool.read { db in try DownloadsSnapshot.read(db, automaticQuotaBytes: 1 << 40) }
        let row = try #require(snapshot.inProgress.flatMap(\.rows).first { $0.edition.chapterKey == "c3" })
        #expect(row.state == .held(.automaticRulePaused))
        #expect(!row.canRetry)

        let full = try await f.pool.read { db in try DownloadsSnapshot.read(db, automaticQuotaBytes: 0) }
        // The rule is paused, which is reported before the space.
        #expect(full.inProgress.flatMap(\.rows).first { $0.edition.chapterKey == "c3" }?.state == .held(.automaticRulePaused))
    }
}

/// A job record with every column at a harmless value.
enum DownloadJobRecordFixture {
    static func job() -> DownloadJobRecord {
        DownloadJobRecord(
            id: UUID().uuidString, batchId: UUID().uuidString, sequence: 0, pluginId: "plugin.test", mediaKind: .manga,
            canonicalMediaId: "series-1", chapterKey: "c1", authorityScope: .publicUnscoped,
            chapterSnapshot: Data(), seriesTitle: "Series", sourceEpoch: nil, state: .queued, waitingReason: nil,
            failureReason: nil, stagingVersionId: nil, attemptCount: 0, createdAt: Date(), updatedAt: Date()
        )
    }
}
