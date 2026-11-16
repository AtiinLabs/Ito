import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

private typealias Fixture = SubscriptionLedgerFixture

private func numbered(_ numbers: some Sequence<Int>, scanlator: (id: String, name: String)? = nil) -> [Chapter] {
    Fixture.numbered(numbers, scanlator: scanlator)
}

private let groupA: (id: String, name: String) = ("ga", "A")
private let groupB: (id: String, name: String) = ("gb", "B")

/// Job ownership and the queue: caps, the dequeue gate, shared requests, pause, disable, deletion, edits, backfill,
/// the window of Maintain Next N, and the rules that follow a series when it moves or goes away. Every test ends with
/// the J1 invariant: no job without an owner.
struct SubscriptionLedgerOwnershipTests {
    // MARK: - Helpers

    private func manualRequest(_ keys: [String]) -> DownloadBatchRequest {
        OfflineStoreFixture.batchRequest(chapterKeys: keys, preset: .next5)
    }

    private func suppressionCount(_ f: Fixture) async throws -> Int {
        try await f.pool.read { db in try DownloadSuppressionRecord.fetchCount(db) }
    }

    private func openEvents(_ f: Fixture) async throws -> [SubscriptionEventRecord] {
        try await f.events().filter { $0.decision.isOpen }
    }

    // MARK: - C19: caps and the dequeue gate

    @Test func c19_aFullQueueHoldsEventsPendingAndADrainAdmitsThemWhenThereIsRoom() async throws {
        let f = try await Fixture()
        let id = try await f.enable().id
        try await f.check(numbered(1...2))
        let tight = AutomaticDownloadLimits(queueLimit: 2, quotaBytes: Fixture.roomy.quotaBytes)

        let outcome = try await f.check(numbered(1...5), limits: tight)

        #expect(outcome.queuedJobs == 2)
        #expect(outcome.pendingCount == 1)
        #expect(try await f.jobs().map(\.chapterKey).sorted() == ["c3", "c4"])
        let held = try #require(try await f.events(.newPosition).first { $0.decision == .pending })
        #expect(held.pendingReason == .queueCap && held.identityValue == "u5")

        // Unlike a run-cap event, it is drained without waiting for the next check.
        let drained = try await f.store.drainSubscriptionEvents(subscriptionId: id, limits: Fixture.roomy)
        #expect(drained.queuedJobs == 1)
        #expect(try await f.jobs().count == 3)
        #expect(try await f.events(.newPosition).allSatisfy { $0.decision == .enqueued })
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c19_aFullQuotaHoldsEventsPendingUntilADrainWithRoom() async throws {
        let f = try await Fixture()
        let id = try await f.enable().id
        try await f.check(numbered(1...2))
        let starved = AutomaticDownloadLimits(queueLimit: 500, quotaBytes: 1)

        let outcome = try await f.check(numbered(1...3), limits: starved)

        #expect(outcome.queuedJobs == 0)
        #expect(try await f.events(.newPosition).first?.pendingReason == .quota)
        #expect(try await f.jobs().isEmpty)
        #expect(try await f.store.drainSubscriptionEvents(subscriptionId: id, limits: Fixture.roomy).queuedJobs == 1)
    }

    @Test func c19_aSubscriptionAttachesToAnExistingJobEvenWhenTheQueueIsFull() async throws {
        let f = try await Fixture()
        let askA = EditionSelection.preferred(primary: ScanlatorRef(id: "ga", name: "A"), fallback: .ask)
        let id = try await f.enable(SubscriptionConfiguration(selection: askA)).id
        let base = numbered(1...3, scanlator: groupA)
        try await f.check(base)
        try await f.check(base + [Fixture.chapter("c4b", unit: "u4", order: 40, group: groupB)])
        let event = try #require(try await f.events(.newPosition).first)
        #expect(event.decision == .needsChoice)
        // A person queued that very upload meanwhile.
        _ = try await f.store.enqueueBatch(manualRequest(["c4b"]), sourceEpoch: OfflineStoreFixture.epoch)
        let existing = try #require(try await f.jobs().first)
        let subscription = try await f.subscription()
        let full = AutomaticDownloadLimits(queueLimit: 1, quotaBytes: Fixture.roomy.quotaBytes)

        let outcome = try await f.store.resolveSubscriptionEvent(
            SubscriptionEventResolution(
                eventId: event.id, incarnation: subscription.incarnation,
                configGeneration: subscription.configGeneration, candidateRevision: 1, action: .approve(keys: ["c4b"])
            ),
            limits: full
        )

        #expect(outcome.queuedJobs == 0)
        #expect(outcome.attachedJobs == 1)
        #expect(try await f.jobs().count == 1)
        let owners = try await f.owners(of: existing.id)
        #expect(owners.map(\.ownerKind) == [.manual, .subscription])
        #expect(owners.last?.subscriptionId == id)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c19_aFullDiskQuotaStopsAutomaticJobsFromStartingButNeverManualOnes() async throws {
        let f = try await Fixture()
        let id = try await f.enable().id
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...3))
        let automatic = try #require(try await f.jobs().first)

        // With room, the automatic job is next, owned by its subscription alone.
        let next = try #require(try await f.store.nextQueuedJob(automaticAdmitted: true))
        #expect(next.job.id == automatic.id)
        #expect(next.ownership == DownloadJobOwnership(manualRequestIds: [], subscriptionIds: [id]))
        // Without room it stays queued and is not started.
        #expect(try await f.store.nextQueuedJob(automaticAdmitted: false) == nil)
        #expect(try await f.store.job(id: automatic.id)?.state == .queued)

        // The gate itself: stored bytes against the quota.
        #expect(try await f.store.automaticQuotaAdmits(Fixture.roomy))
        try await f.publishedCopy(Fixture.chapter("saved"))
        #expect(try await f.store.automaticQuotaAdmits(AutomaticDownloadLimits(queueLimit: 500, quotaBytes: 1)) == false)

        // A manual job is dequeued whatever the quota says.
        _ = try await f.store.enqueueBatch(manualRequest(["m1"]), sourceEpoch: OfflineStoreFixture.epoch)
        let manual = try #require(try await f.store.nextQueuedJob(automaticAdmitted: false))
        #expect(manual.job.chapterKey == "m1")
        #expect(manual.ownership.subscriptionIds.isEmpty && manual.ownership.manualRequestIds.count == 1)
        try await f.expectEveryJobHasAnOwner()
    }

    // MARK: - C20: shared requests

    @Test func c20_aManualRequestForAnAutomaticJobAttachesAndChangesNothingElse() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...3))
        let job = try #require(try await f.jobs().first)
        let signatures = try await f.jobSignatures()
        let batches = try await f.batchPresets()

        let outcome = try await f.store.enqueueBatch(manualRequest(["c3"]), sourceEpoch: OfflineStoreFixture.epoch)

        #expect(outcome.queued == 0 && outcome.alreadyQueued == 1)
        #expect(outcome.batchId == nil)
        let requestId = try #require(outcome.requestId)
        #expect(try await f.jobSignatures() == signatures)
        #expect(try await f.batchPresets() == batches)
        let owners = try await f.owners(of: job.id)
        #expect(owners.map(\.ownerKind) == [.subscription, .manual])
        #expect(owners.last?.manualRequestId == requestId)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c20_aSubscriptionRequestForAManualJobAttachesAndAnOwnerIsNeverAddedTwice() async throws {
        let f = try await Fixture()
        let id = try await f.enable().id
        try await f.check(numbered(1...2))
        let manual = try await f.store.enqueueBatch(manualRequest(["m1"]), sourceEpoch: OfflineStoreFixture.epoch)
        let job = try #require(try await f.jobs().first)
        let chapter = Fixture.chapter("m1")
        let prepared = PreparedDownloadBatch(
            pluginId: f.media.pluginId, mediaKind: .manga, canonicalMediaId: f.media.canonicalMediaId,
            entrySnapshot: Data("{}".utf8), seriesTitle: "Series", provenance: .automatic,
            selection: DownloadBatchRecord.sourceListSelection, catalogDigest: nil, chapters: [chapter, chapter],
            chapterSnapshots: [try JSONEncoder().encode(chapter), try JSONEncoder().encode(chapter)],
            batchId: UUID().uuidString, jobIds: [UUID().uuidString, UUID().uuidString], sourceEpoch: OfflineStoreFixture.epoch
        )
        let owner = DownloadRequestOwner.subscription(id: id, incarnation: 1, eventId: UUID().uuidString)

        let result = try await f.pool.write { db in
            try OfflineChapterStore.insertBatch(prepared, owner: owner, now: OfflineStoreFixture.fixedDate, in: db)
        }
        #expect(result.dispositions == [.attached(jobId: job.id), .repeatedInRequest])
        #expect(result.outcome.queued == 0 && result.outcome.alreadyQueued == 2)
        #expect(result.outcome.requestId == prepared.batchId)
        #expect(try await f.owners(of: job.id).map(\.ownerKind) == [.manual, .subscription])
        #expect(manual.batchId != nil)

        // The same owner asking again finds its row.
        let again = try await f.pool.write { db in
            try OfflineChapterStore.insertBatch(prepared, owner: owner, now: OfflineStoreFixture.fixedDate, in: db)
        }
        #expect(again.dispositions == [.alreadyOwned(jobId: job.id), .repeatedInRequest])
        #expect(try await f.owners(of: job.id).count == 2)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func aSubscriptionRequestNeverClearsADeletionRecordAndAManualOneDoes() async throws {
        let f = try await Fixture()
        let id = try await f.enable().id
        try await f.write { db in
            try DownloadSuppressionRecord(
                pluginId: "plugin.test", mediaKind: .manga, canonicalMediaId: "series-1", chapterKey: "gone",
                authorityScope: .publicUnscoped, suppressedAt: OfflineStoreFixture.fixedDate
            ).insert(db)
        }
        let chapter = Fixture.chapter("gone")
        let prepared = PreparedDownloadBatch(
            pluginId: f.media.pluginId, mediaKind: .manga, canonicalMediaId: f.media.canonicalMediaId,
            entrySnapshot: Data("{}".utf8), seriesTitle: "Series", provenance: .automatic,
            selection: DownloadBatchRecord.sourceListSelection, catalogDigest: nil, chapters: [chapter],
            chapterSnapshots: [try JSONEncoder().encode(chapter)], batchId: UUID().uuidString,
            jobIds: [UUID().uuidString], sourceEpoch: OfflineStoreFixture.epoch
        )

        let automatic = try await f.pool.write { db in
            try OfflineChapterStore.insertBatch(
                prepared, owner: .subscription(id: id, incarnation: 1, eventId: UUID().uuidString),
                now: OfflineStoreFixture.fixedDate, in: db
            )
        }
        #expect(automatic.dispositions == [.suppressed])
        #expect(automatic.outcome.suppressed == 1 && automatic.outcome.queued == 0)
        #expect(automatic.outcome.batchId == nil)
        #expect(try await suppressionCount(f) == 1)
        #expect(try await f.jobs().isEmpty)

        let manual = try await f.store.enqueueBatch(manualRequest(["gone"]), sourceEpoch: OfflineStoreFixture.epoch)
        #expect(manual.queued == 1)
        #expect(try await suppressionCount(f) == 0)
    }

    // MARK: - C21: pause

    @Test func c21_pauseReturnsItsRunningJobsAndKeepsEverythingElse() async throws {
        let f = try await Fixture()
        let id = try await f.enable().id
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...3))
        let job = try #require(try await f.jobs().first)
        let before = try await f.subscription()
        let attempt = try await f.store.beginAttempt(jobID: job.id)

        let running = try await f.store.pauseSubscription(id: id)

        #expect(running == [job.id])
        let paused = try await f.subscription()
        #expect(paused.state == .paused && paused.pauseReason == .user)
        #expect(paused.configGeneration == before.configGeneration && paused.incarnation == before.incarnation)
        #expect(try await f.owners(of: job.id).count == 1)
        // Pause keeps the intent: the attempt that was already running may still publish.
        try await attempt.append(OfflineStoreFixture.imagePage(0))
        let outcome = try await f.store.publish(attempt, commitGuard: { _ in true })
        guard case .published = outcome else {
            Issue.record("a paused owner's attempt must still publish, got \(outcome)")
            return
        }
        #expect(try await f.store.verifiedEdition(for: OfflineChapterEdition(media: f.media, chapterKey: "c3")) != nil)
        #expect(try await f.jobs().isEmpty)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c21_aPausedSubscriptionsJobStaysQueuedButIsNotStartedAndResumeStartsItAgain() async throws {
        let f = try await Fixture()
        let id = try await f.enable().id
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...3))
        let job = try #require(try await f.jobs().first)
        let attempt = try await f.store.beginAttempt(jobID: job.id)
        #expect(try await f.store.pauseSubscription(id: id) == [job.id])

        // The caller cancels the attempt: the job goes back to the queue.
        try await f.store.abandonAttempt(jobID: job.id, versionId: attempt.versionId, outcome: .queued)
        #expect(try await f.store.job(id: job.id)?.state == .queued)
        #expect(try await f.store.nextQueuedJob(automaticAdmitted: true) == nil)
        await #expect(throws: OfflineStoreError.self) { try await f.store.beginAttempt(jobID: job.id) }
        #expect(try await f.store.job(id: job.id)?.state == .queued)

        // While paused, no check begins and a late commit writes nothing; the baseline does not move.
        let baseline = try #require(try await f.baseline())
        #expect(try await f.store.beginSubscriptionCheck(media: f.media, capturedEpoch: OfflineStoreFixture.epoch) == nil)

        try await f.store.resumeSubscription(id: id)
        #expect(try await f.subscription().state == .enabled)
        #expect(try await f.baseline() == baseline)
        #expect(try await f.store.nextQueuedJob(automaticAdmitted: true)?.job.id == job.id)
    }

    @Test func c21_aLateCommitOfAPausedSubscriptionWritesNothing() async throws {
        let f = try await Fixture()
        let id = try await f.enable().id
        try await f.check(numbered(1...3))
        let ticket = try await f.begin()
        _ = try await f.store.pauseSubscription(id: id)
        let baseline = try #require(try await f.baseline())

        let outcome = try await f.store.commitSubscriptionObservation(
            ticket, try Fixture.observation(numbered(1...9), epoch: ticket.sourceEpoch), limits: Fixture.roomy
        )

        #expect(outcome.outcome == .paused)
        #expect(try await f.baseline() == baseline)
        #expect(try await f.events().isEmpty)
        #expect(try await f.jobs().isEmpty)
    }

    @Test func c21_aJobAManualRequestAlsoOwnsIsNotReturnedForCancellation() async throws {
        let f = try await Fixture()
        let id = try await f.enable().id
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...3))
        _ = try await f.store.enqueueBatch(manualRequest(["c3"]), sourceEpoch: OfflineStoreFixture.epoch)
        let job = try #require(try await f.jobs().first)
        _ = try await f.store.beginAttempt(jobID: job.id)

        #expect(try await f.store.pauseSubscription(id: id).isEmpty)
        // A manual owner keeps the job eligible whatever the subscription does.
        #expect(try await f.owners(of: job.id).count == 2)
    }

    // MARK: - C22: disable and delete

    @Test func c22_disableRemovesSoleOwnedJobsKeepsSharedOnesAndFilesAndRevokesOpenEvents() async throws {
        let f = try await Fixture()
        let id = try await f.enable(SubscriptionConfiguration(perRunPositionCap: 1)).id
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...4))
        // c3 was admitted, c4 waits under the run cap. A person also asked for c3, and saved something else.
        _ = try await f.store.enqueueBatch(manualRequest(["c3"]), sourceEpoch: OfflineStoreFixture.epoch)
        try await f.check(numbered(1...4))
        let saved = try await f.publishedCopy(Fixture.chapter("kept"))
        let shared = try #require(try await f.jobs().first { $0.chapterKey == "c3" })
        let sole = try #require(try await f.jobs().first { $0.chapterKey == "c4" })
        #expect(try await openEvents(f).isEmpty)
        let generation = try await f.subscription().configGeneration
        let attempt = try await f.store.beginAttempt(jobID: sole.id)
        // Its pages are staged before the rule is disabled; the late commit is what is refused.
        try await attempt.append(OfflineStoreFixture.imagePage(0))

        let release = try await f.store.disableSubscription(id: id)

        #expect(release.removedJobIds == [sole.id])
        #expect(try await f.jobs().map(\.id) == [shared.id])
        #expect(try await f.owners(of: shared.id).map(\.ownerKind) == [.manual])
        let disabled = try await f.subscription()
        #expect(disabled.state == .disabled && disabled.pauseReason == nil)
        #expect(disabled.configGeneration == generation + 1)
        #expect(try await f.baseline() == nil)
        #expect(try await f.seenCount() == 0)
        // Files are never touched.
        #expect(try await f.store.verifiedEdition(for: OfflineChapterEdition(media: f.media, chapterKey: "kept"))?.versionId == saved)
        // The attempt that was running for the released job cannot publish.
        let outcome = try await f.store.publish(attempt, commitGuard: { _ in true })
        guard case .refused(.jobGone) = outcome else {
            Issue.record("a released job must be refused as gone, got \(outcome)")
            return
        }
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c22_disableRevokesOpenEventsAndANewIncarnationStartsFromANewBaseline() async throws {
        let f = try await Fixture()
        let id = try await f.enable(SubscriptionConfiguration(perRunPositionCap: 1)).id
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...4))
        let waiting = try await openEvents(f)
        #expect(waiting.count == 1 && waiting.first?.decision == .pending)
        let ticket = try await f.begin()

        _ = try await f.store.disableSubscription(id: id)

        #expect(try await f.events(.newPosition).map(\.decision).sorted { $0.rawValue < $1.rawValue } == [.enqueued, .revoked])
        #expect(try await f.jobs().isEmpty)
        // A check that began before the disable commits to a disabled rule and writes nothing.
        let late = try await f.store.commitSubscriptionObservation(
            ticket, try Fixture.observation(numbered(1...9), epoch: ticket.sourceEpoch), limits: Fixture.roomy
        )
        #expect(late.outcome == .disabled)
        #expect(try await f.store.beginSubscriptionCheck(media: f.media, capturedEpoch: OfflineStoreFixture.epoch) == nil)

        // Enabling again is a new incarnation that waits for its own baseline: nothing old is announced.
        let again = try await f.store.enableSubscription(SubscriptionEnableRequest(
            media: f.media, reviewedSourceEpoch: OfflineStoreFixture.epoch, configuration: SubscriptionConfiguration()
        ))
        #expect(again == .enabled(id: id, incarnation: 2))
        #expect(try await f.subscription().configGeneration == 3)
        #expect(try await f.check(numbered(1...9)).outcome == .baselineEstablished)
        #expect(try await f.events(.newPosition).count == 2)
        #expect(try await f.jobs().isEmpty)
    }

    @Test func c22_aJobAnotherSubscriptionAlsoOwnsSurvivesTheDisableWithThatOwner() async throws {
        let f = try await Fixture()
        let first = try await f.enable().id
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...3))
        let job = try #require(try await f.jobs().first)
        let otherMedia = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-2", mediaKind: .manga)
        let second = try await f.enable(media: otherMedia).id
        try await f.write { db in
            try OfflineChapterStore.attachOwner(
                .subscription(id: second, incarnation: 1, eventId: UUID().uuidString),
                toJob: job.id, now: OfflineStoreFixture.fixedDate, in: db
            )
        }
        #expect(try await f.owners(of: job.id).count == 2)

        let release = try await f.store.disableSubscription(id: first)

        #expect(release.removedJobIds.isEmpty)
        #expect(try await f.jobs().map(\.id) == [job.id])
        #expect(try await f.owners(of: job.id).compactMap(\.subscriptionId) == [second])
        // And the remaining owner may start it.
        #expect(try await f.store.nextQueuedJob(automaticAdmitted: true)?.job.id == job.id)

        // Deleting the other one removes the job it alone holds now, and the rows with it.
        let deleted = try await f.store.deleteSubscription(id: second)
        #expect(deleted.removedJobIds == [job.id])
        #expect(try await f.jobs().isEmpty)
        #expect(try await f.store.subscription(for: otherMedia) == nil)
        try await f.expectEveryJobHasAnOwner()
    }

    // MARK: - C23: deletion and suppression

    @Test func c23_deletingAQueuedOnlyJobSuppressesItAndNoAutomaticRequestClearsTheRecord() async throws {
        let f = try await Fixture()
        try await f.enable(SubscriptionConfiguration(mode: .newAndFillUnread))
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...3))
        let edition = OfflineChapterEdition(media: f.media, chapterKey: "c3")
        #expect(try await f.jobs().count == 1)

        // Delete Download of a chapter that is only queued: the record is written in the same transaction.
        try await f.store.delete(edition)

        #expect(try await f.jobs().isEmpty)
        #expect(try await suppressionCount(f) == 1)
        #expect(try await f.pool.read { db in try DownloadBatchRecord.fetchCount(db) } == 0)

        // A later automatic request for the same key (an approved backfill) is suppressed and clears nothing.
        let subscription = try await f.subscription()
        let baseline = try #require(try await f.baseline())
        let outcome = try await f.store.approveSubscriptionBackfill(
            SubscriptionBackfillApproval(
                subscriptionId: subscription.id, incarnation: subscription.incarnation,
                configGeneration: subscription.configGeneration, baselineRevision: baseline.revision,
                catalogDigest: baseline.catalogDigest, positions: [["c3"]]
            ),
            limits: Fixture.roomy
        )
        #expect(outcome.refusal == nil && outcome.queuedJobs == 0)
        #expect(try await f.events(.backfill).first?.decision == .suppressed)
        #expect(try await suppressionCount(f) == 1)
        #expect(try await f.jobs().isEmpty)

        // Only an explicit manual Download clears it.
        let manual = try await f.store.enqueueBatch(manualRequest(["c3"]), sourceEpoch: OfflineStoreFixture.epoch)
        #expect(manual.queued == 1)
        #expect(try await suppressionCount(f) == 0)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c23_cancelWithoutDeleteWritesNoRecordAndTheEventStaysEnqueued() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...3))
        let job = try #require(try await f.jobs().first)

        try await f.store.cancel(jobID: job.id)

        #expect(try await f.jobs().isEmpty)
        #expect(try await suppressionCount(f) == 0)
        #expect(try await f.events(.newPosition).first?.decision == .enqueued)
        // The key is seen, so the next check does not create it again.
        #expect(try await f.check(numbered(1...3)).outcome == .unchanged)
        #expect(try await f.jobs().isEmpty)
        try await f.expectEveryJobHasAnOwner()
    }

    // MARK: - C24: edit

    @Test func c24_anEditDecidesWaitingEventsAgainKeepsJobsAndRefusesAStaleSheet() async throws {
        let f = try await Fixture()
        let strictA = EditionSelection.preferred(primary: ScanlatorRef(id: "ga", name: "A"), fallback: .strict)
        let id = try await f.enable(SubscriptionConfiguration(selection: strictA)).id
        let base = numbered(1...3, scanlator: groupA)
        try await f.check(base)
        let withA = base + [Fixture.chapter("c4a", unit: "u4", order: 40, group: groupA)]
        try await f.check(withA)
        try await f.check(withA + [Fixture.chapter("c5b", unit: "u5", order: 50, group: groupB)])
        let existing = try #require(try await f.jobs().first)
        #expect(existing.chapterKey == "c4a")
        let waiting = try #require(try await f.events(.newPosition).first { $0.identityValue == "u5" })
        #expect(waiting.decision == .awaitingEdition)
        let generation = try await f.subscription().configGeneration

        // A configuration the database would refuse, and a generation the editor did not see.
        #expect(
            try await f.store.editSubscription(SubscriptionEdit(
                subscriptionId: id, expectedConfigGeneration: generation,
                configuration: SubscriptionConfiguration(mode: .maintainNextUnread, windowSize: nil)
            )) == .invalidConfiguration
        )
        #expect(
            try await f.store.editSubscription(SubscriptionEdit(
                subscriptionId: id, expectedConfigGeneration: generation + 7, configuration: SubscriptionConfiguration()
            )) == .stale
        )
        #expect(try await f.subscription().configGeneration == generation)

        let edit = SubscriptionEdit(
            subscriptionId: id, expectedConfigGeneration: generation,
            configuration: SubscriptionConfiguration(selection: .sourceList)
        )
        let signatures = try await f.jobSignatures()
        #expect(try await f.store.editSubscription(edit) == .applied(configGeneration: generation + 1))
        // The waiting event starts over; the job that already existed is untouched.
        #expect(try await f.events(.newPosition).first { $0.id == waiting.id }?.decision == .undecided)
        #expect(try await f.jobSignatures() == signatures)
        // The sheet that made this edit is now stale too.
        #expect(try await f.store.editSubscription(edit) == .stale)

        let drained = try await f.store.drainSubscriptionEvents(subscriptionId: id, limits: Fixture.roomy)
        #expect(drained.queuedJobs == 1)
        #expect(try await f.events(.newPosition).first { $0.id == waiting.id }?.decision == .enqueued)
        #expect(Set(try await f.jobs().map(\.chapterKey)) == ["c4a", "c5b"])
        #expect(try await f.jobSignatures().contains(signatures[0]))
        try await f.expectEveryJobHasAnOwner()
    }

    // MARK: - C26, C27, C30: moves, restores and the owner invariant

    @Test func c26_aRelinkInsideOnePluginMovesTheRuleToTheNewSeriesPausedAndWithoutEvidence() async throws {
        let f = try await Fixture()
        let id = try await f.enable(SubscriptionConfiguration(perRunPositionCap: 1)).id
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...4))
        #expect(try await f.jobs().count == 1)
        #expect(try await openEvents(f).count == 1)

        _ = try await LibrarySourceRemapper(dbPool: f.pool).relink(
            pluginId: "plugin.test", mediaKind: .manga, possibleSourceItemIds: ["series-1"],
            destinationItemId: "series-2", title: "Relinked", coverUrl: nil, rawPayload: Data("relinked".utf8)
        )

        let moved = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-2", mediaKind: .manga)
        let subscription = try #require(try await f.store.subscription(for: moved))
        #expect(subscription.id == id)
        #expect(subscription.state == .paused && subscription.pauseReason == .sourceRemapped)
        #expect(subscription.incarnation == 2 && subscription.configGeneration == 2)
        #expect(try await f.store.subscription(for: f.media) == nil)
        #expect(try await f.baseline() == nil)
        #expect(try await f.seenCount() == 0)
        #expect(try await openEvents(f).isEmpty)
        #expect(try await f.events(.newPosition).map(\.decision).sorted { $0.rawValue < $1.rawValue } == [.enqueued, .revoked])
        #expect(try await f.jobs().isEmpty)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c26_aRemapToAnotherPluginReleasesTheRule() async throws {
        let f = try await Fixture()
        let id = try await f.enable().id
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...3))
        #expect(try await f.jobs().count == 1)

        _ = try await LibrarySourceRemapper(dbPool: f.pool).remap(
            oldPluginId: "plugin.test", newPluginId: "plugin.other", affectedItemIds: ["series-1"]
        )

        #expect(try await f.store.subscription(for: f.media) == nil)
        #expect(try await f.pool.read { db in try SeriesSubscriptionRecord.fetchOne(db, key: id) } == nil)
        #expect(try await f.pool.read { db in try SubscriptionEventRecord.fetchCount(db) } == 0)
        #expect(try await f.jobs().isEmpty)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c26_aRelinkOntoASeriesWithItsOwnRuleReleasesTheOldOne() async throws {
        let f = try await Fixture()
        let first = try await f.enable().id
        try await f.check(numbered(1...2))
        let destination = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-2", mediaKind: .manga)
        let second = try await f.enable(media: destination).id

        // The destination keeps its own rule; the source's is released and deleted.
        let media = f.media
        try await f.write { db in
            _ = try OfflineChapterStore.rekeyMedia(in: db, from: media, to: destination, now: OfflineStoreFixture.fixedDate)
        }

        #expect(try await f.store.subscription(for: destination)?.id == second)
        #expect(try await f.pool.read { db in try SeriesSubscriptionRecord.fetchOne(db, key: first) } == nil)
        #expect(try await f.store.subscription(for: destination)?.incarnation == 1)
    }

    @Test @MainActor func c26_removingTheSeriesFromTheLibraryReleasesTheRuleAndItsSoleOwnedJobs() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...3))
        _ = try await f.store.enqueueBatch(manualRequest(["m1"]), sourceEpoch: OfflineStoreFixture.epoch)
        #expect(try await f.jobs().count == 2)

        try await LibraryManager(dbPool: f.pool).removeItemDurably(media: f.media)

        #expect(try await f.store.subscription(for: f.media) == nil)
        // The automatic job is gone with the rule; the manual one stays.
        #expect(try await f.jobs().map(\.chapterKey) == ["m1"])
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c27_aDatabaseFromAnotherInstallationQuarantinesEveryRuleAndReleasesItsOwners() async throws {
        let f = try await Fixture()
        let id = try await f.enable(SubscriptionConfiguration(perRunPositionCap: 1)).id
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...4))
        let manual = try await f.store.enqueueBatch(manualRequest(["m1"]), sourceEpoch: OfflineStoreFixture.epoch)
        #expect(manual.queued == 1)
        #expect(try await f.jobs().count == 2)
        let before = try await f.subscription()

        // The store's marker names another installation: the database was copied here.
        try f.base.fileSystem.writeFile(Data("another-installation".utf8), to: f.base.storeIdentifierURL)
        let restarted = f.base.makeStore()
        guard case .completed(let details) = await restarted.reconcile() else {
            Issue.record("reconciliation must complete")
            return
        }

        #expect(details.restoredJobs == 1)
        let subscription = try await f.subscription()
        #expect(subscription.id == id)
        #expect(subscription.state == .paused && subscription.pauseReason == .restored)
        #expect(subscription.incarnation == before.incarnation + 1)
        #expect(subscription.configGeneration == before.configGeneration + 1)
        #expect(try await f.baseline() == nil)
        #expect(try await f.seenCount() == 0)
        #expect(try await openEvents(f).isEmpty)
        let jobs = try await f.jobs()
        #expect(jobs.map(\.chapterKey) == ["m1"])
        #expect(jobs.first?.state == .waiting && jobs.first?.waitingReason == .restoredPendingReview)
        #expect(try await f.pool.read { db in
            try DownloadJobOwnerRecord.filter(Column("subscriptionId") != nil).fetchCount(db)
        } == 0)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c30_aJobWithoutAnOwnerIsSweptAtReconciliationWithItsBatch() async throws {
        let f = try await Fixture()
        // Something wrote the tables around the store: a batch and a job nobody asked for.
        let batchId = UUID().uuidString
        let jobId = UUID().uuidString
        try await f.write { db in
            try DownloadBatchRecord(
                id: batchId, pluginId: "plugin.test", mediaKind: .manga, canonicalMediaId: "series-1",
                preset: .single, selection: DownloadBatchRecord.sourceListSelection, catalogDigest: nil,
                entrySnapshot: Data("{}".utf8), createdAt: OfflineStoreFixture.fixedDate
            ).insert(db)
            try DownloadJobRecord(
                id: jobId, batchId: batchId, sequence: 0, pluginId: "plugin.test", mediaKind: .manga,
                canonicalMediaId: "series-1", chapterKey: "orphan", authorityScope: .publicUnscoped,
                chapterSnapshot: Data("{}".utf8), seriesTitle: "Series", sourceEpoch: OfflineStoreFixture.epoch,
                state: .queued, waitingReason: nil, failureReason: nil, stagingVersionId: nil, attemptCount: 0,
                createdAt: OfflineStoreFixture.fixedDate, updatedAt: OfflineStoreFixture.fixedDate
            ).insert(db)
        }

        guard case .completed(let details) = await f.base.makeStore().reconcile() else {
            Issue.record("reconciliation must complete")
            return
        }

        #expect(details.removedOwnerlessJobs == 1)
        #expect(try await f.jobs().isEmpty)
        #expect(try await f.pool.read { db in try DownloadBatchRecord.fetchCount(db) } == 0)
        try await f.expectEveryJobHasAnOwner()
    }

    // MARK: - C28: Maintain Next N

    private func readState(_ f: Fixture, read: [String], last: String?, numbers: [Double] = []) async throws {
        let media = f.media
        try await f.write { db in
            for key in read {
                try ReadProgressKeyRecord(
                    pluginId: media.pluginId, canonicalMediaId: media.canonicalMediaId, mediaKind: media.mediaKind,
                    chapterKey: key, markedAt: nil, provenance: nil
                ).save(db)
            }
            for number in numbers {
                try ReadProgressNumberRecord(
                    pluginId: media.pluginId, canonicalMediaId: media.canonicalMediaId, mediaKind: media.mediaKind,
                    chapterNumber: number, markedAt: nil, provenance: nil
                ).save(db)
            }
            if let last {
                try MediaReadProgressRecord(
                    pluginId: media.pluginId, canonicalMediaId: media.canonicalMediaId, mediaKind: media.mediaKind,
                    lastReadChapterKey: last, updatedAt: nil, provenance: nil, lastReadPosition: nil, readerViewer: nil
                ).save(db)
            }
        }
    }

    @Test func c28_theWindowFollowsTheExactAnchorAndACancelledPositionStaysCancelledUntilTheAnchorMoves() async throws {
        let f = try await Fixture()
        try await f.enable(SubscriptionConfiguration(mode: .maintainNextUnread, windowSize: 2))
        try await readState(f, read: ["c1", "c2"], last: "c2")

        // The first baseline of a maintain rule already keeps its window: that is what the mode is for.
        try await f.check(numbered(1...6))
        let first = try await f.events(.window)
        #expect(first.map(\.identityValue) == ["u3", "u4"])
        #expect(first.allSatisfy { $0.decision == .enqueued })
        #expect(Set(first.compactMap(\.qualifier)).count == 1)
        #expect(try await f.jobs().map(\.chapterKey).sorted() == ["c3", "c4"])
        #expect(try await f.events(.newPosition).isEmpty)

        // Cancel one: under the same anchor it stays cancelled, however often the rule checks.
        let cancelled = try #require(try await f.jobs().first { $0.chapterKey == "c3" })
        try await f.store.cancel(jobID: cancelled.id)
        try await f.check(numbered(1...6))
        try await f.check(numbered(1...7))
        #expect(try await f.jobs().map(\.chapterKey) == ["c4"])
        // A forward release is recorded, not downloaded: maintain mode keeps a window, not a feed.
        #expect(try await f.events(.newPosition).map(\.decision) == [.recorded])

        // Reading moves the anchor: the window follows it and c3, now read, is not brought back.
        try await readState(f, read: ["c3"], last: "c3")
        try await f.check(numbered(1...7))
        let moved = try await f.events(.window).filter { $0.identityValue == "u5" }
        #expect(moved.count == 1 && moved.first?.decision == .enqueued)
        #expect(Set(try await f.jobs().map(\.chapterKey)) == ["c4", "c5"])
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c28_aReadStateThatIsOnlyChapterNumbersNeedsReviewInsteadOfGuessing() async throws {
        let f = try await Fixture()
        try await f.enable(SubscriptionConfiguration(mode: .maintainNextUnread, windowSize: 2))
        try await readState(f, read: [], last: nil, numbers: [1, 2])

        try await f.check(numbered(1...4))

        let events = try await f.events(.window)
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.identityKind == .catalog && event.identityValue == "readState")
        #expect(event.decision == .needsReview && event.reviewReason == .numberOnlyReadState)
        #expect(try await f.jobs().isEmpty)
    }

    @Test func c28_aCatalogWithoutAReliableOrderNeedsReviewForItsWindow() async throws {
        let f = try await Fixture()
        try await f.enable(SubscriptionConfiguration(mode: .maintainNextUnread, windowSize: 2))
        try await readState(f, read: ["c1"], last: "c1")
        let unordered = (1...4).reversed().map { Fixture.chapter("c\($0)", unit: "u\($0)") }

        try await f.check(unordered)

        let event = try #require(try await f.events(.window).first)
        #expect(try await f.events(.window).count == 1)
        #expect(event.decision == .needsReview && event.reviewReason == .windowOrderAmbiguous)
        #expect(try await f.jobs().isEmpty)
    }

    // MARK: - C29: backfill approval

    @Test func c29_aStaleBackfillWritesNothingAndACurrentOneCreatesExactlyTheReviewedEvents() async throws {
        let f = try await Fixture()
        let id = try await f.enable(SubscriptionConfiguration(mode: .newAndFillUnread, perRunPositionCap: 1)).id
        try await f.check(numbered(1...3))
        let subscription = try await f.subscription()
        let baseline = try #require(try await f.baseline())
        func approval(
            revision: Int64? = nil, digest: String? = nil, generation: Int64? = nil, positions: [[String]]
        ) -> SubscriptionBackfillApproval {
            SubscriptionBackfillApproval(
                subscriptionId: id, incarnation: subscription.incarnation,
                configGeneration: generation ?? subscription.configGeneration,
                baselineRevision: revision ?? baseline.revision, catalogDigest: digest ?? baseline.catalogDigest,
                positions: positions
            )
        }

        // Stale baseline revision, digest or generation: nothing is written.
        for stale in [
            approval(revision: baseline.revision + 1, positions: [["c1"]]),
            approval(digest: String(repeating: "0", count: 64), positions: [["c1"]]),
            approval(generation: subscription.configGeneration + 1, positions: [["c1"]])
        ] {
            let outcome = try await f.store.approveSubscriptionBackfill(stale, limits: Fixture.roomy)
            #expect(outcome.refusal == .stale)
        }
        // A key the accepted catalog does not list, and positions that mix keys of two units, are refused.
        #expect(try await f.store.approveSubscriptionBackfill(approval(positions: [["nope"]]), limits: Fixture.roomy).refusal == .invalidKeys)
        #expect(try await f.store.approveSubscriptionBackfill(approval(positions: [["c1", "c2"]]), limits: Fixture.roomy).refusal == .invalidKeys)
        #expect(try await f.events().isEmpty)
        #expect(try await f.jobs().isEmpty)

        // The reviewed positions are admitted past the run cap of one, but the queue cap still applies.
        let tight = AutomaticDownloadLimits(queueLimit: 2, quotaBytes: Fixture.roomy.quotaBytes)
        let outcome = try await f.store.approveSubscriptionBackfill(
            approval(positions: [["c1"], ["c2"], ["c3"]]), limits: tight
        )

        #expect(outcome.refusal == nil)
        #expect(outcome.createdEventIds.count == 3)
        #expect(outcome.queuedJobs == 2)
        let events = try await f.events(.backfill)
        #expect(events.map(\.identityValue) == ["u1", "u2", "u3"])
        #expect(events.map(\.approved) == [["c1"], ["c2"], ["c3"]])
        #expect(events.map(\.decision) == [.enqueued, .enqueued, .pending])
        #expect(events.last?.pendingReason == .queueCap)
        #expect(Set(try await f.jobs().map(\.chapterKey)) == ["c1", "c2"])
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c29_backfillNeedsTheFillUnreadMode() async throws {
        let f = try await Fixture()
        let id = try await f.enable(SubscriptionConfiguration(mode: .newReleases)).id
        try await f.check(numbered(1...3))
        let subscription = try await f.subscription()
        let baseline = try #require(try await f.baseline())

        let outcome = try await f.store.approveSubscriptionBackfill(
            SubscriptionBackfillApproval(
                subscriptionId: id, incarnation: subscription.incarnation, configGeneration: subscription.configGeneration,
                baselineRevision: baseline.revision, catalogDigest: baseline.catalogDigest, positions: [["c1"]]
            ),
            limits: Fixture.roomy
        )

        #expect(outcome.refusal == .unsupportedMode)
        #expect(try await f.events().isEmpty)
    }

    // MARK: - Enable

    @Test func enableCreatesAWaitingRuleAndRefusesAnythingUnreviewed() async throws {
        let f = try await Fixture()
        let request = SubscriptionEnableRequest(
            media: f.media, reviewedSourceEpoch: OfflineStoreFixture.epoch, configuration: SubscriptionConfiguration()
        )
        // The series must be saved first.
        #expect(try await f.store.enableSubscription(request) == .refused(.seriesNotSaved))
        try await f.saveSeries()
        // The rule is stored only under the source epoch it was reviewed under.
        #expect(
            try await f.store.enableSubscription(SubscriptionEnableRequest(
                media: f.media, reviewedSourceEpoch: OfflineStoreFixture.rotatedEpoch, configuration: SubscriptionConfiguration()
            )) == .refused(.sourceChanged)
        )
        #expect(
            try await f.store.enableSubscription(SubscriptionEnableRequest(
                media: f.media, reviewedSourceEpoch: OfflineStoreFixture.epoch,
                configuration: SubscriptionConfiguration(mode: .maintainNextUnread, windowSize: nil)
            )) == .refused(.invalidConfiguration)
        )
        let anime = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .anime)
        #expect(
            try await f.store.enableSubscription(SubscriptionEnableRequest(
                media: anime, reviewedSourceEpoch: OfflineStoreFixture.epoch, configuration: SubscriptionConfiguration()
            )) == .refused(.unsupportedKind)
        )

        guard case .enabled(let id, let incarnation) = try await f.store.enableSubscription(request) else {
            Issue.record("a reviewed rule must be enabled")
            return
        }
        #expect(incarnation == 1)
        let subscription = try await f.subscription()
        #expect(subscription.state == .enabled && subscription.configGeneration == 1 && subscription.nextCheckTicket == 1)
        #expect(subscription.decodedSelection == .sourceList)
        // No event and no job exists yet, and enabling again changes nothing.
        #expect(try await f.events().isEmpty)
        #expect(try await f.jobs().isEmpty)
        #expect(try await f.baseline() == nil)
        #expect(try await f.store.enableSubscription(request) == .alreadyExists(id: id))
    }

    @Test func everyEntryPointNeedsAReconciledStoreAndWritesNothingOtherwise() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let media = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)
        await #expect(throws: OfflineStoreError.reconciliationPending) {
            try await store.enableSubscription(SubscriptionEnableRequest(
                media: media, reviewedSourceEpoch: OfflineStoreFixture.epoch, configuration: SubscriptionConfiguration()
            ))
        }
        await #expect(throws: OfflineStoreError.reconciliationPending) {
            try await store.beginSubscriptionCheck(media: media, capturedEpoch: OfflineStoreFixture.epoch)
        }
        await #expect(throws: OfflineStoreError.reconciliationPending) {
            try await store.drainSubscriptionEvents(subscriptionId: UUID().uuidString, limits: Fixture.roomy)
        }
        await #expect(throws: OfflineStoreError.reconciliationPending) { try await store.pauseSubscription(id: UUID().uuidString) }
        await #expect(throws: OfflineStoreError.reconciliationPending) { try await store.disableSubscription(id: UUID().uuidString) }
        #expect(try await fixture.rowCount("seriesSubscription") == 0)
    }

    @Test func aFailureOfAPausedRuleOrOfACheckOlderThanTheBaselineRecordsNothing() async throws {
        let f = try await Fixture()
        let id = try await f.enable().id
        let older = try await f.begin()
        try await f.check(numbered(1...3))
        let attempt = try await f.subscription().lastAttemptAt

        // The baseline already accepted a newer check: this one proves nothing about it.
        try await f.store.recordSubscriptionCheckFailure(older, .fetchFailed)
        #expect(try await f.subscription().lastAttemptOutcome == .baselineEstablished)
        #expect(try await f.subscription().lastAttemptAt == attempt)

        // A paused rule is not checked, so a late failure writes nothing either.
        let newer = try await f.begin()
        _ = try await f.store.pauseSubscription(id: id)
        try await f.store.recordSubscriptionCheckFailure(newer, .fetchFailed)
        #expect(try await f.subscription().lastAttemptOutcome == .baselineEstablished)
    }
}
