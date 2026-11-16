import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// V6 to V8: the review of waiting events and of unread chapters, over a real store. What the sheets show is what the
/// ledger holds, and what a decision did is what the store's outcome says.
@MainActor
struct SubscriptionReviewModelTests {
    private typealias Fixture = SubscriptionLedgerFixture
    private let groupA = (id: "ga", name: "A")
    private let groupB = (id: "gb", name: "B")
    private let groupC = (id: "gc", name: "C")

    private var base: [Chapter] { Fixture.numbered(1...3, scanlator: groupA) }

    /// A rule that asks before switching groups, with one new chapter that only group B uploaded.
    private func needsChoice() async throws -> (Fixture, StoreBackedAutomaticDownloads, String) {
        let f = try await Fixture()
        let askA = EditionSelection.preferred(primary: ScanlatorRef(id: "ga", name: "A"), fallback: .ask)
        let id = try await f.enable(SubscriptionConfiguration(selection: askA)).id
        try await f.check(base)
        try await f.check(base + [Fixture.chapter("c4b", title: "Four", unit: "u4", order: 40, group: groupB)])
        return (f, StoreBackedAutomaticDownloads(f), id)
    }

    // MARK: - V6

    @Test func v6_aChoiceListsItsCandidatesAndApprovingASubsetQueuesThemWithTheRulesOwnership() async throws {
        let (f, service, id) = try await needsChoice()
        let model = SubscriptionEventReviewModel(subscriptionId: id, service: service)
        #expect(model.phase == .loading)
        await model.load().value

        let event = try #require(model.events.first)
        #expect(model.phase == .loaded && model.events.count == 1)
        #expect(event.canApprove && event.decision == .needsChoice && event.reviewReason == nil)
        #expect(event.candidates.map(\.key) == ["c4b"])
        #expect(event.candidates.first?.scanlator == "B")
        #expect(event.candidates.first?.title == "Four")
        #expect(!model.canApprove(event), "Nothing is ticked yet")

        model.toggle("c4b", in: event)
        #expect(model.isSelected("c4b", in: event) && model.canApprove(event))
        await model.approve(event).value

        #expect(model.report == .queued(1))
        #expect(model.events.isEmpty, "The event was decided, so it no longer waits")
        let job = try #require(try await f.jobs().first)
        #expect(job.chapterKey == "c4b")
        let owner = try #require(try await f.owners(of: job.id).first)
        #expect(owner.ownerKind == .subscription && owner.subscriptionId == id && owner.eventId == event.eventId)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func v6_anAlternateThatArrivesBeforeTheApprovalMakesItStaleAndTheReloadShowsTheNewCandidate() async throws {
        let (f, service, id) = try await needsChoice()
        let model = SubscriptionEventReviewModel(subscriptionId: id, service: service)
        await model.load().value
        let seen = try #require(model.events.first)
        model.toggle("c4b", in: seen)

        // Group C uploads the same chapter: the candidate list the person is looking at grows to revision 2.
        try await f.check(base + [
            Fixture.chapter("c4b", unit: "u4", order: 40, group: groupB),
            Fixture.chapter("c4c", unit: "u4", order: 40, group: groupC)
        ])

        await model.approve(seen).value
        #expect(model.report == .changedSinceOpened)
        #expect(try await f.jobs().isEmpty, "A stale approval queues nothing")
        let reloaded = try #require(model.events.first)
        #expect(reloaded.candidateRevision == 2 && seen.candidateRevision == 1)
        #expect(Set(reloaded.candidates.map(\.key)) == ["c4b", "c4c"])
        #expect(model.isSelected("c4b", in: reloaded), "A ticked row that is still a candidate stays ticked")

        await model.approve(reloaded).value
        #expect(model.report == .queued(1))
        let job = try #require(try await f.jobs().first)
        #expect(job.chapterKey == "c4b")
        #expect(try await f.owners(of: job.id).first?.subscriptionId == id)
    }

    @Test func aDecisionThatTheStoreCouldNotWriteSaysSoAndReloads() async throws {
        let (_, _, id) = try await needsChoice()
        let service = FakeAutomaticDownloads()
        service.commandError = AutomaticDownloadsError.unavailable
        service.attentionResult = SubscriptionAttention(
            events: [SubscriptionEventReview(
                eventId: "e1", kind: .newPosition, identityKind: .exact, decision: .needsChoice, reviewReason: nil,
                candidates: [SubscriptionCandidateRow(key: "k", title: nil, number: nil, volume: nil, scanlator: nil, isLocked: false)],
                incarnation: 1, configGeneration: 1, candidateRevision: 1
            )],
            totalCount: 3
        )
        let model = SubscriptionEventReviewModel(subscriptionId: id, service: service)
        await model.load().value
        #expect(model.hiddenCount == 2)
        let event = try #require(model.events.first)
        model.toggle("k", in: event)

        await model.approve(event).value

        #expect(model.failedToDecide && model.report == nil)
        #expect(model.busyEventId == nil)
        #expect(service.attentionReads == 2, "It reads what the store holds after any outcome")
    }

    @Test func aSelectionIsLimitedToTheEventsOwnCandidates() async throws {
        let (_, service, id) = try await needsChoice()
        let model = SubscriptionEventReviewModel(subscriptionId: id, service: service)
        await model.load().value
        let event = try #require(model.events.first)
        model.toggle("not-a-candidate", in: event)
        #expect(model.selectedKeys(for: event).isEmpty)
        model.toggle("c4b", in: event)
        model.toggle("c4b", in: event)
        #expect(model.selectedKeys(for: event).isEmpty, "A second tap unticks")
    }

    // MARK: - V7

    private func insertReview(
        _ f: Fixture, ruleId: String, kind: SubscriptionEventKind, identityKind: SubscriptionIdentityKind,
        identity: String, reason: SubscriptionReviewReason, keys: [String]
    ) async throws -> String {
        let id = UUID().uuidString
        try await f.write { db in
            try SubscriptionEventRecord(
                id: id, subscriptionId: ruleId, incarnation: 1, kind: kind, identityKind: identityKind,
                identityValue: identity, qualifier: kind == .window ? "none" : nil, decision: .needsReview, pendingReason: nil,
                reviewReason: reason, candidateKeys: SubscriptionEventRecord.encode(keys: keys), candidateRevision: 1,
                approvedKeys: nil, decidedKeys: nil, previousRevision: nil, targetRevision: nil, ordinal: 0,
                observedCatalogDigest: String(repeating: "d", count: 64), configGeneration: 1, scopeGeneration: 1,
                createdAt: Date(), decidedAt: nil
            ).insert(db)
        }
        return id
    }

    @Test func v7_aCatalogAnomalyAndAWindowReviewOfferOnlyDismissalAndDismissingEndsThem() async throws {
        let f = try await Fixture()
        let ruleId = try await f.enable().id
        try await f.check(Fixture.numbered(1...3))
        let anomaly = try await insertReview(
            f, ruleId: ruleId, kind: .catalogAnomaly, identityKind: .catalog, identity: String(repeating: "a", count: 64),
            reason: .emptyAfterNonempty, keys: []
        )
        let window = try await insertReview(
            f, ruleId: ruleId, kind: .window, identityKind: .catalog, identity: "readState", reason: .numberOnlyReadState,
            keys: []
        )
        let service = StoreBackedAutomaticDownloads(f)
        let model = SubscriptionEventReviewModel(subscriptionId: ruleId, service: service)
        await model.load().value
        #expect(model.events.count == 2)
        for event in model.events {
            #expect(!event.canApprove, "Approve is never offered for \(event.kind)")
            #expect(event.reviewReason != nil)
            model.toggle("anything", in: event)
            #expect(model.selectedKeys(for: event).isEmpty && !model.canApprove(event))
            await model.approve(event).value
        }
        // An approval that was never offered is never sent.
        #expect(try await f.events().allSatisfy { $0.decision == .needsReview || $0.decision == .recorded })

        for event in model.events { await model.dismiss(event).value }

        #expect(model.events.isEmpty && model.report == nil)
        let decisions = try await f.pool.read { db in
            try SubscriptionEventRecord.filter([anomaly, window].contains(Column("id"))).fetchAll(db).map(\.decision)
        }
        #expect(decisions == [.dismissed, .dismissed])
        #expect(try await f.jobs().isEmpty)
    }

    @Test func aPositionReviewWithCandidatesCanBeApprovedButAnAlternateCannot() {
        let row = SubscriptionCandidateRow(key: "k", title: nil, number: nil, volume: nil, scanlator: nil, isLocked: false)
        func review(_ kind: SubscriptionEventKind, _ identity: SubscriptionIdentityKind, keys: [SubscriptionCandidateRow]) -> SubscriptionEventReview {
            SubscriptionEventReview(
                eventId: "e", kind: kind, identityKind: identity, decision: .needsReview, reviewReason: .bulkArrival,
                candidates: keys, incarnation: 1, configGeneration: 1, candidateRevision: 1
            )
        }
        #expect(review(.unplacedKey, .exact, keys: [row]).canApprove)
        #expect(review(.newPosition, .logical, keys: [row]).canApprove)
        #expect(review(.window, .exact, keys: [row]).canApprove)
        #expect(!review(.newAlternate, .exact, keys: [row]).canApprove)
        #expect(!review(.catalogAnomaly, .catalog, keys: [row]).canApprove)
        #expect(!review(.window, .catalog, keys: [row]).canApprove)
        #expect(!review(.unplacedKey, .exact, keys: []).canApprove)
    }

    // MARK: - V8

    private func fillRule() async throws -> (Fixture, StoreBackedAutomaticDownloads, String) {
        let f = try await Fixture()
        let id = try await f.enable(SubscriptionConfiguration(mode: .newAndFillUnread)).id
        try await f.check(Fixture.numbered(1...6))
        return (f, StoreBackedAutomaticDownloads(f), id)
    }

    private func markRead(_ f: Fixture, _ keys: [String]) async throws {
        let media = f.media
        try await f.write { db in
            for key in keys {
                try ReadProgressKeyRecord(
                    pluginId: media.pluginId, canonicalMediaId: media.canonicalMediaId, mediaKind: media.mediaKind,
                    chapterKey: key, markedAt: nil, provenance: nil
                ).save(db)
            }
        }
    }

    @Test func v8_thePreviewListsExactUnreadPositionsInReadingOrderAndApprovingQueuesThem() async throws {
        let (f, service, id) = try await fillRule()
        try await markRead(f, ["c1", "c2"])
        #expect(try await f.jobs().isEmpty, "The first chapter list queues nothing")

        let model = SubscriptionBackfillModel(subscriptionId: id, service: service)
        #expect(model.phase == .loading)
        await model.load().value

        let preview = try #require(model.preview)
        #expect(model.phase == .loaded)
        #expect(preview.positions == [["c3"], ["c4"], ["c5"], ["c6"]])
        #expect(preview.truncatedCount == 0)
        #expect(Set(preview.rows.keys) == ["c3", "c4", "c5", "c6"])
        #expect(model.selected == [0, 1, 2, 3], "Everything is ticked when the list opens")

        model.toggle(3)
        await model.approve().value

        #expect(model.report == .queued(3))
        #expect(Set(try await f.jobs().map(\.chapterKey)) == ["c3", "c4", "c5"])
        let queued = try #require(try await f.jobs().first)
        let owner = try #require(try await f.owners(of: queued.id).first)
        #expect(owner.subscriptionId == id)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func v8_aBaselineThatAdvancedBetweenThePreviewAndTheApprovalIsStaleAndThePreviewIsReloaded() async throws {
        let (f, service, id) = try await fillRule()
        try await markRead(f, ["c1", "c2"])
        let model = SubscriptionBackfillModel(subscriptionId: id, service: service)
        await model.load().value
        let stale = try #require(model.preview)

        // The source lists a new chapter: the accepted baseline moves on, and c7 is queued by the check itself.
        try await f.check(Fixture.numbered(1...7))
        #expect(try await f.baseline()?.revision != stale.baselineRevision)

        await model.approve().value
        #expect(model.report == .changedSinceOpened)
        #expect(try await f.jobs().map(\.chapterKey) == ["c7"], "A stale approval queued nothing")
        let fresh = try #require(model.preview)
        #expect(fresh.baselineRevision != stale.baselineRevision)
        #expect(fresh.positions == [["c3"], ["c4"], ["c5"], ["c6"]], "c7 is queued already, so it is not offered")

        await model.approve().value
        #expect(model.report == .queued(4))
        #expect(Set(try await f.jobs().map(\.chapterKey)) == ["c3", "c4", "c5", "c6", "c7"])
    }

    @Test func v8_numberOnlyReadMarkersRefuseThePreviewWithTheirReasonAndNothingIsListed() async throws {
        let (f, service, id) = try await fillRule()
        let media = f.media
        try await f.write { db in
            try ReadProgressNumberRecord(
                pluginId: media.pluginId, canonicalMediaId: media.canonicalMediaId, mediaKind: media.mediaKind,
                chapterNumber: 2, markedAt: nil, provenance: nil
            ).save(db)
        }
        let model = SubscriptionBackfillModel(subscriptionId: id, service: service)

        await model.load().value

        #expect(model.phase == .refused(.numberOnlyReadState))
        #expect(model.preview == nil && !model.canApprove)
        #expect(SubscriptionBackfillRefusal.numberOnlyReadState.localizedExplanation.contains("chapter numbers"))
    }

    @Test func aRuleThatDoesNotFillUnreadChaptersOrHasNoBaselineRefusesThePreview() async throws {
        let f = try await Fixture()
        let plain = try await f.enable().id
        let service = StoreBackedAutomaticDownloads(f)
        await #expect(throws: SubscriptionBackfillRefusal.unavailable) { try await service.backfillPreview(subscriptionId: plain) }
        try await f.check(Fixture.numbered(1...3))
        await #expect(throws: SubscriptionBackfillRefusal.unsupportedMode) { try await service.backfillPreview(subscriptionId: plain) }
    }

    @Test func approvingNothingIsNotOfferedAndAnExactKeyThePreviewDoesNotKnowIsRefusedByTheStore() async throws {
        let (f, service, id) = try await fillRule()
        let model = SubscriptionBackfillModel(subscriptionId: id, service: service)
        await model.load().value
        for index in model.selected { model.toggle(index) }
        #expect(!model.canApprove)
        await model.approve().value
        #expect(try await f.jobs().isEmpty)

        let preview = try #require(model.preview)
        let outcome = try await service.approveBackfill(SubscriptionBackfillApproval(
            subscriptionId: id, incarnation: preview.incarnation, configGeneration: preview.configGeneration,
            baselineRevision: preview.baselineRevision, catalogDigest: preview.catalogDigest, positions: [["nope"]]
        ))
        #expect(SubscriptionCommitReport(outcome) == .invalidChoice)
    }

    @Test func theCommitReportSaysWhatTheStoreDidAndNothingElse() {
        var queued = SubscriptionCommitOutcome(.advanced)
        queued.queuedJobs = 2
        #expect(SubscriptionCommitReport(queued) == .queued(2))
        var attached = SubscriptionCommitOutcome(.advanced)
        attached.attachedJobs = 1
        #expect(SubscriptionCommitReport(attached) == .alreadyQueued)
        var waiting = SubscriptionCommitOutcome(.advanced)
        waiting.pendingCount = 3
        #expect(SubscriptionCommitReport(waiting) == .waitingForRoom)
        #expect(SubscriptionCommitReport(SubscriptionCommitOutcome(.advanced)) == .nothingToQueue)
        #expect(SubscriptionCommitReport(SubscriptionCommitOutcome(.superseded, refusal: .stale)) == .changedSinceOpened)
        #expect(SubscriptionCommitReport(SubscriptionCommitOutcome(.superseded, refusal: .eventNotOpen)) == .changedSinceOpened)
        #expect(SubscriptionCommitReport(SubscriptionCommitOutcome(.superseded, refusal: .invalidKeys)) == .invalidChoice)
        #expect(SubscriptionCommitReport(SubscriptionCommitOutcome(.sourceChanged)) == .sourceChanged)
        #expect(SubscriptionCommitReport(SubscriptionCommitOutcome(.selectionUnreadable)) == .selectionUnreadable)
        #expect(SubscriptionCommitReport(SubscriptionCommitOutcome(.incompleteCatalog)) == .catalogUnreadable)
        let all: [SubscriptionCommitReport] = [
            .queued(1), .alreadyQueued, .waitingForRoom, .nothingToQueue, .changedSinceOpened, .notAvailable,
            .invalidChoice, .notSupported, .sourceChanged, .selectionUnreadable, .catalogUnreadable
        ]
        #expect(all.allSatisfy { !$0.text.isEmpty && !$0.text.contains("%") })
        #expect(all.filter(\.isRefusal).count == 7)
        #expect(!SubscriptionCommitReport.waitingForRoom.text.lowercased().contains("will be queued"),
                "Chapters that wait are never promised")
    }
}
