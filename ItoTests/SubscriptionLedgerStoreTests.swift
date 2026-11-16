import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

private typealias Fixture = SubscriptionLedgerFixture

private func numbered(
    _ numbers: some Sequence<Int>,
    revision: String? = nil,
    scanlator: (id: String, name: String)? = nil
) -> [Chapter] {
    Fixture.numbered(numbers, revision: revision, scanlator: scanlator)
}

private let groupA: (id: String, name: String) = ("ga", "A")
private let groupB: (id: String, name: String) = ("gb", "B")

private struct AbortedOnPurpose: Error {}

/// The ledger's core against a migrated database: baselines, classification, admission and the compare-and-swap of
/// concurrent checks. Case names C1... follow the contract's matrix. Every test reads SQL state, uses the injected fixed
/// clock and awaits each call explicitly.
struct SubscriptionLedgerStoreTests {
    // MARK: - C1, C2: baselines

    @Test func c1_firstEnableOnFiveHundredRowsEstablishesABaselineAndNothingElse() async throws {
        let f = try await Fixture()
        try await f.enable()

        let outcome = try await f.check(numbered(1...500))

        #expect(outcome.outcome == .baselineEstablished)
        #expect(outcome.createdEventIds.isEmpty)
        #expect(outcome.queuedJobs == 0)
        #expect(try await f.events().isEmpty)
        #expect(try await f.jobs().isEmpty)
        #expect(try await f.seenCount(present: true) == 500)
        let baseline = try #require(try await f.baseline())
        #expect(baseline.rowCount == 500)
        #expect(baseline.revision == 1)
        #expect(baseline.acceptedTicket == 1)
        #expect(baseline.scopeGeneration == 1)
        #expect(baseline.catalogScope == .allEligible)
        #expect(baseline.orderConfidence == .confident)
        #expect(baseline.highWater == .logical(ScanlatorUTF8(value: "u500")))
        let subscription = try await f.subscription()
        #expect(subscription.lastAttemptOutcome == .baselineEstablished)
        #expect(subscription.lastSuccessAt != nil)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c2_aCatalogThatProvesNothingLeavesTheRuleWaitingWithItsOutcomeCode() async throws {
        let f = try await Fixture()
        try await f.enable()
        let chapters = numbered(1...3)

        #expect(try await f.check(chapters, completeness: .partial).outcome == .incompleteCatalog)
        #expect(try await f.subscription().lastAttemptOutcome == .incompleteCatalog)
        #expect(try await f.check(chapters, scope: .unknown).outcome == .unknownScope)
        #expect(try await f.subscription().lastAttemptOutcome == .unknownScope)
        #expect(try await f.check([]).outcome == .emptyCatalog)
        #expect(try await f.subscription().lastAttemptOutcome == .emptyCatalog)
        // A fetch that produced no observation is recorded by its ticket.
        try await f.store.recordSubscriptionCheckFailure(try await f.begin(), .fetchFailed)
        #expect(try await f.subscription().lastAttemptOutcome == .fetchFailed)

        #expect(try await f.baseline() == nil)
        #expect(try await f.events().isEmpty)
        #expect(try await f.seenCount() == 0)
        #expect(try await f.subscription().lastSuccessAt == nil)
        // The rule still waits: the first good catalog is its baseline.
        #expect(try await f.check(chapters).outcome == .baselineEstablished)
    }

    // MARK: - C3 to C5: forward events and alternates

    @Test func c3_aNewLogicalUnitAfterTheHighWaterIsOneEventAndOneAutomaticJob() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...10))

        let outcome = try await f.check(numbered(1...11))

        #expect(outcome.outcome == .advanced)
        let event = try #require(try await f.events().first)
        #expect(try await f.events().count == 1)
        #expect(event.kind == .newPosition)
        #expect(event.identityKind == .logical && event.identityValue == "u11")
        #expect(event.decision == .enqueued)
        #expect(event.decided == ["c11"])
        #expect(outcome.createdEventIds == [event.id])
        #expect(outcome.queuedJobs == 1)

        let job = try #require(try await f.jobs().first)
        #expect(try await f.jobs().count == 1)
        #expect(job.chapterKey == "c11")
        #expect(job.sourceEpoch == OfflineStoreFixture.epoch)
        let owner = try #require(try await f.owners(of: job.id).first)
        #expect(try await f.owners(of: job.id).count == 1)
        #expect(owner.ownerKind == .subscription)
        #expect(owner.eventId == event.id)
        #expect(owner.subscriptionId == (try await f.subscription()).id)
        #expect(owner.subscriptionIncarnation == 1)

        let batch = try #require(try await f.pool.read { db in try DownloadBatchRecord.fetchOne(db, key: job.batchId) })
        #expect(batch.preset == .automatic)
        #expect(batch.provenance == .automatic)
        #expect(batch.selection == (try await f.subscription()).selection)
        #expect(batch.catalogDigest == (try await f.baseline())?.catalogDigest)
        #expect(try await f.batchPresets() == [.automatic])
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c4_anUnchangedCountWithOneSwappedKeyIsStillOneEventFromTheKeyDiff() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...5))

        // Five rows before and after: c1 left, c6 arrived.
        let outcome = try await f.check(numbered(2...6))

        #expect(outcome.createdEventIds.count == 1)
        #expect(try await f.events().map(\.identityValue) == ["u6"])
        #expect(try await f.jobs().map(\.chapterKey) == ["c6"])
        #expect(try await f.seenCount(present: false) == 1)
        #expect(try await f.seenCount(present: true) == 5)
    }

    @Test func c5_aNewKeyOfAKnownUnitIsOnlyRecordedAndNeverReplacesOrAddsAnEdition() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...3))
        // Group B publishes unit 4 first: that is the new release.
        try await f.check(numbered(1...3) + [Fixture.chapter("c4b", unit: "u4", order: 40, group: groupB)])
        #expect(try await f.jobs().map(\.chapterKey) == ["c4b"])

        // Group A uploads the same unit later.
        let outcome = try await f.check(
            numbered(1...3) + [
                Fixture.chapter("c4a", unit: "u4", order: 40, group: groupA),
                Fixture.chapter("c4b", unit: "u4", order: 40, group: groupB)
            ]
        )

        let alternate = try #require(try await f.events(.newAlternate).first)
        #expect(alternate.decision == .recorded)
        #expect(alternate.identityKind == .exact && alternate.identityValue == "c4a")
        #expect(outcome.queuedJobs == 0)
        // B stays queued, and A was not added.
        #expect(try await f.jobs().map(\.chapterKey) == ["c4b"])
        #expect(try await f.events(.newPosition).count == 1)
    }

    // MARK: - C6, C7: editions

    @Test func c6_strictGroupWaitsForItsUploadAndTheAlternateCompletesTheEvent() async throws {
        let f = try await Fixture()
        let strictA = EditionSelection.preferred(primary: ScanlatorRef(id: "ga", name: "A"), fallback: .strict)
        try await f.enable(SubscriptionConfiguration(selection: strictA))
        let base = numbered(1...3, scanlator: groupA)
        try await f.check(base)

        // The unit arrives as B only.
        try await f.check(base + [Fixture.chapter("c4b", unit: "u4", order: 40, group: groupB)])
        let waiting = try #require(try await f.events(.newPosition).first)
        #expect(waiting.decision == .awaitingEdition)
        #expect(waiting.candidateRevision == 1)
        #expect(try await f.jobs().isEmpty)

        // Then A uploads it: it joins the waiting event, whose candidate revision grows.
        try await f.check(base + [
            Fixture.chapter("c4a", unit: "u4", order: 40, group: groupA),
            Fixture.chapter("c4b", unit: "u4", order: 40, group: groupB)
        ])
        let done = try #require(try await f.events(.newPosition).first)
        #expect(done.id == waiting.id)
        #expect(done.candidates == ["c4b", "c4a"])
        #expect(done.candidateRevision == 2)
        #expect(done.decision == .enqueued)
        #expect(done.decided == ["c4a"])
        #expect(try await f.jobs().map(\.chapterKey) == ["c4a"])
        #expect(try await f.events(.newAlternate).first?.decision == .recorded)
    }

    @Test func c7_askFallbackNeedsAChoiceThatOnlyTheCurrentCandidateRevisionCanResolve() async throws {
        let f = try await Fixture()
        let askA = EditionSelection.preferred(primary: ScanlatorRef(id: "ga", name: "A"), fallback: .ask)
        let id = try await f.enable(SubscriptionConfiguration(selection: askA)).id
        let base = numbered(1...3, scanlator: groupA)
        try await f.check(base)

        let outcome = try await f.check(base + [Fixture.chapter("c4b", unit: "u4", order: 40, group: groupB)])
        let event = try #require(try await f.events(.newPosition).first)
        #expect(event.decision == .needsChoice)
        #expect(outcome.needsAttentionEventIds == [event.id])
        let subscription = try await f.subscription()
        func resolution(revision: Int64, keys: [String]) -> SubscriptionEventResolution {
            SubscriptionEventResolution(
                eventId: event.id, incarnation: subscription.incarnation,
                configGeneration: subscription.configGeneration, candidateRevision: revision, action: .approve(keys: keys)
            )
        }

        // A sheet that saw another candidate list, a key that is no candidate, and another generation are refused.
        let stale = try await f.store.resolveSubscriptionEvent(resolution(revision: 2, keys: ["c4b"]), limits: Fixture.roomy)
        #expect(stale.refusal == .stale)
        let invalid = try await f.store.resolveSubscriptionEvent(resolution(revision: 1, keys: ["c1"]), limits: Fixture.roomy)
        #expect(invalid.refusal == .invalidKeys)
        let otherGeneration = try await f.store.resolveSubscriptionEvent(
            SubscriptionEventResolution(
                eventId: event.id, incarnation: subscription.incarnation,
                configGeneration: subscription.configGeneration + 1, candidateRevision: 1, action: .approve(keys: ["c4b"])
            ),
            limits: Fixture.roomy
        )
        #expect(otherGeneration.refusal == .stale)
        #expect(try await f.jobs().isEmpty)
        #expect(try await f.events(.newPosition).first?.decision == .needsChoice)

        let approved = try await f.store.resolveSubscriptionEvent(resolution(revision: 1, keys: ["c4b"]), limits: Fixture.roomy)
        #expect(approved.refusal == nil)
        #expect(approved.queuedJobs == 1)
        let resolved = try #require(try await f.events(.newPosition).first)
        #expect(resolved.decision == .enqueued)
        #expect(resolved.approved == ["c4b"])
        let job = try #require(try await f.jobs().first)
        #expect(job.chapterKey == "c4b")
        #expect(try await f.owners(of: job.id).first?.eventId == event.id)
        #expect(try await f.owners(of: job.id).first?.subscriptionId == id)
    }

    @Test func dismissingAnOpenEventEndsItWithoutQueueingAnything() async throws {
        let f = try await Fixture()
        let askA = EditionSelection.preferred(primary: ScanlatorRef(id: "ga", name: "A"), fallback: .ask)
        try await f.enable(SubscriptionConfiguration(selection: askA))
        let base = numbered(1...3, scanlator: groupA)
        try await f.check(base)
        try await f.check(base + [Fixture.chapter("c4b", unit: "u4", order: 40, group: groupB)])
        let event = try #require(try await f.events(.newPosition).first)
        let subscription = try await f.subscription()

        let outcome = try await f.store.resolveSubscriptionEvent(
            SubscriptionEventResolution(
                eventId: event.id, incarnation: subscription.incarnation,
                configGeneration: subscription.configGeneration, candidateRevision: 1, action: .dismiss
            ),
            limits: Fixture.roomy
        )

        #expect(outcome.refusal == nil)
        #expect(try await f.events(.newPosition).first?.decision == .dismissed)
        #expect(try await f.jobs().isEmpty)
        // A dismissed event is terminal: it cannot be resolved again.
        let again = try await f.store.resolveSubscriptionEvent(
            SubscriptionEventResolution(
                eventId: event.id, incarnation: subscription.incarnation,
                configGeneration: subscription.configGeneration, candidateRevision: 1, action: .approve(keys: ["c4b"])
            ),
            limits: Fixture.roomy
        )
        #expect(again.refusal == .eventNotOpen)
    }

    // MARK: - C8 to C10: review instead of guessing

    /// Establishes a baseline from `before`, then observes `after`, and returns the single event it raised.
    private func reviewed(before: [Chapter], after: [Chapter]) async throws -> (event: SubscriptionEventRecord, f: Fixture) {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(before)
        let outcome = try await f.check(after)
        #expect(outcome.outcome == .advanced)
        let events = try await f.events()
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.decision == .needsReview)
        #expect(try await f.jobs().isEmpty)
        // The baseline moved all the same.
        #expect(try await f.baseline()?.revision == 2)
        return (event, f)
    }

    @Test func c8_aKeyInsertedBeforeTheHighWaterNeedsReview() async throws {
        let (event, _) = try await reviewed(
            before: numbered([1, 2, 4, 5]),
            after: numbered(1...5)
        )
        #expect(event.kind == .unplacedKey)
        #expect(event.reviewReason == .insertedBeforeHighWater)
        #expect(event.identityKind == .exact && event.identityValue == "c3")
    }

    @Test func c8_aKeyOlderThanTheBaselineDateNeedsReview() async throws {
        let dated = (1...3).reversed().map { Fixture.chapter("c\($0)", unit: "u\($0)", order: Int64($0) * 10, date: 1_000) }
        let (event, _) = try await reviewed(
            before: dated,
            after: [Fixture.chapter("c4", unit: "u4", order: 40, date: 500)] + dated
        )
        #expect(event.reviewReason == .olderThanBaseline)
    }

    @Test func c8_aTombstonedPositionAfterTheHighWaterNeedsReview() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...5))
        // c5 leaves: its position becomes a tombstone and the high-water moves back to unit 4.
        try await f.check(numbered(1...4))
        // Unit 5 returns under another key while a new unit 6 arrives: a known position now sits after the high-water.
        try await f.check(numbered(1...4) + [
            Fixture.chapter("c5x", unit: "u5", order: 50), Fixture.chapter("c6", unit: "u6", order: 60)
        ])
        let unplaced = try await f.events(.unplacedKey)
        #expect(unplaced.map(\.identityValue) == ["c6"])
        #expect(unplaced.first?.reviewReason == .knownPositionAfterHighWater)
        #expect(try await f.jobs().isEmpty)
    }

    @Test func c8_reorderedAnchorsNeedReview() async throws {
        let before = numbered(1...4)
        let swapped = [
            Fixture.chapter("c5", unit: "u5", order: 50), Fixture.chapter("c4", unit: "u4", order: 40),
            Fixture.chapter("c3", unit: "u3", order: 20), Fixture.chapter("c2", unit: "u2", order: 30),
            Fixture.chapter("c1", unit: "u1", order: 10)
        ]
        let (event, _) = try await reviewed(before: before, after: swapped)
        #expect(event.reviewReason == .anchorsReordered)
    }

    @Test func c8_aMissingHighWaterNeedsReview() async throws {
        let (event, _) = try await reviewed(
            before: numbered(1...4),
            after: numbered(1...3) + [Fixture.chapter("c5", unit: "u5", order: 50)]
        )
        #expect(event.reviewReason == .highWaterMissing)
    }

    @Test func c8_noSourceReadingOrderNeedsReview() async throws {
        let unordered = (1...4).reversed().map { Fixture.chapter("c\($0)", unit: "u\($0)") }
        let (event, _) = try await reviewed(
            before: numbered(1...3),
            after: unordered
        )
        #expect(event.reviewReason == .noReliableOrder)
    }

    @Test func c8_aBaselineWithoutAnOrderNeedsReviewForTheNextKey() async throws {
        let unordered = (1...3).reversed().map { Fixture.chapter("c\($0)") }
        let (event, _) = try await reviewed(
            before: unordered,
            after: [Fixture.chapter("c4", order: 40)] + unordered.map { Fixture.chapter($0.key, order: Int64($0.key.dropFirst())! * 10) }
        )
        #expect(event.reviewReason == .noBaselineOrder)
    }

    @Test func c8_aPositionThatChangedIdentityNeedsReview() async throws {
        let (event, _) = try await reviewed(
            before: numbered(1...3),
            after: [Fixture.chapter("c4", unit: "u4", order: 40), Fixture.chapter("c3", unit: "u3", order: 30),
                    Fixture.chapter("c2", unit: "u2", order: 20), Fixture.chapter("c1", unit: "u1-renamed", order: 10)]
        )
        #expect(event.reviewReason == .positionIdentityChanged)
    }

    @Test func c9_aTombstonedKeyThatReturnsIsNeverNewAnywhere() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...5))
        try await f.check(numbered(2...5))
        #expect(try await f.seenCount(present: false) == 1)

        // c1 returns, and c5 (after the high-water of that moment) was never gone.
        let outcome = try await f.check(numbered(1...5))

        #expect(outcome.outcome == .advanced)
        #expect(outcome.createdEventIds.isEmpty)
        #expect(try await f.events().isEmpty)
        #expect(try await f.jobs().isEmpty)
        #expect(try await f.seenCount(present: false) == 0)
    }

    @Test func c10_aVolumeResetWithDistinctSourceOrderIsAForwardEvent() async throws {
        let f = try await Fixture()
        try await f.enable()
        // Volume 1 chapters 1 and 2, volume 2 chapter 1: the chapter number resets, the source order does not.
        let before = [
            Fixture.chapter("v2c1", unit: "u3", order: 30, volume: 2, number: 1),
            Fixture.chapter("v1c2", unit: "u2", order: 20, volume: 1, number: 2),
            Fixture.chapter("v1c1", unit: "u1", order: 10, volume: 1, number: 1)
        ]
        try await f.check(before)

        try await f.check([Fixture.chapter("v2c2", unit: "u4", order: 40, volume: 2, number: 2)] + before)

        #expect(try await f.events(.newPosition).map(\.identityValue) == ["u4"])
        #expect(try await f.jobs().map(\.chapterKey) == ["v2c2"])
    }

    @Test func c10_positionsThatShareASourceOrderAreAmbiguousAndNeedReview() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...3))

        // Two different units claim reading position 50: a shared order is no evidence of an order.
        try await f.check(numbered(1...3) + [
            Fixture.chapter("c5", unit: "u5", order: 50), Fixture.chapter("c5-split", unit: "u5-split", order: 50)
        ])

        let events = try await f.events()
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.kind == .unplacedKey && $0.reviewReason == .noReliableOrder })
        #expect(try await f.jobs().isEmpty)
    }

    // MARK: - C11: revisions

    @Test func c11_aRevisionChangeIsAnEventOnlyWithARevisionOnBothSides() async throws {
        let f = try await Fixture()
        try await f.enable(SubscriptionConfiguration(replacementRule: .off))
        let before = numbered(1...3, revision: "r1")
        try await f.check(before)

        // Both sides known and different: an event, recorded while the rule is off.
        try await f.check(numbered(1...3, revision: "r1").map {
            $0.key == "c2" ? Fixture.chapter("c2", unit: "u2", order: 20, revision: "r2") : $0
        })
        let event = try #require(try await f.events(.revisionChanged).first)
        #expect(try await f.events(.revisionChanged).count == 1)
        #expect(event.decision == .recorded)
        #expect(event.previousRevision == "r1" && event.targetRevision == "r2" && event.qualifier == "r2")
        #expect(try await f.jobs().isEmpty)
    }

    @Test func c11_aMissingOrFirstRevisionNeverChangesAnything() async throws {
        let f = try await Fixture()
        try await f.enable(SubscriptionConfiguration(replacementRule: .sameKeyReliableRevision))
        try await f.check([
            Fixture.chapter("c2", unit: "u2", order: 20, revision: "r1"), Fixture.chapter("c1", unit: "u1", order: 10)
        ])

        // c2 loses its revision (unknown is not a change); c1 gains its first one (recorded silently).
        try await f.check([
            Fixture.chapter("c2", unit: "u2", order: 20), Fixture.chapter("c1", unit: "u1", order: 10, revision: "r9")
        ])

        #expect(try await f.events().isEmpty)
        let revisions = try await f.pool.read { db in
            try SubscriptionSeenKeyRecord.fetchAll(db).reduce(into: [String: String?]()) { $0[$1.chapterKey] = $1.lastRevision }
        }
        #expect(revisions["c2"] == "r1")
        #expect(revisions["c1"] == "r9")
    }

    @Test func c11_withTheRuleOnAVerifiedCopyIsReplacedUnderTheEventsAuthority() async throws {
        let f = try await Fixture()
        let id = try await f.enable(SubscriptionConfiguration(replacementRule: .sameKeyReliableRevision)).id
        let installed = Fixture.chapter("c2", unit: "u2", order: 20, revision: "r1")
        try await f.check([installed, Fixture.chapter("c1", unit: "u1", order: 10)])
        let versionId = try await f.publishedCopy(installed)

        let outcome = try await f.check([
            Fixture.chapter("c2", unit: "u2", order: 20, revision: "r2"), Fixture.chapter("c1", unit: "u1", order: 10)
        ])

        let event = try #require(try await f.events(.revisionChanged).first)
        // The seen revision of c2 was unset at baseline? It was r1, so this is an event, and it was admitted.
        #expect(event.decision == .enqueued)
        #expect(outcome.queuedJobs == 1)
        let job = try #require(try await f.jobs().first)
        let intent = try #require(try await f.store.replacementIntent(jobID: job.id))
        #expect(intent.authorizationId == event.id)
        #expect(intent.expectedVersionId == versionId)
        #expect(intent.expectedRevision == "r1" && intent.targetRevision == "r2")
        let owner = try #require(try await f.owners(of: job.id).first)
        #expect(try await f.owners(of: job.id).count == 1)
        #expect(owner.ownerKind == .subscription && owner.subscriptionId == id && owner.eventId == event.id)
        // The manual batch of the saved copy left with its job; only the automatic replacement's remains.
        #expect(try await f.batchPresets() == [.automatic])
        // The old copy is untouched until the replacement publishes.
        #expect(try await f.store.verifiedEdition(for: OfflineChapterEdition(media: f.media, chapterKey: "c2"))?.versionId == versionId)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func c11_aCopyWithAnotherRevisionIsNotReplacedByTheRule() async throws {
        let f = try await Fixture()
        try await f.enable(SubscriptionConfiguration(replacementRule: .sameKeyReliableRevision))
        try await f.check([Fixture.chapter("c2", unit: "u2", order: 20, revision: "r1")])
        // The saved copy carries r0: it is not the copy the event saw, so the rule does not replace it.
        try await f.publishedCopy(Fixture.chapter("c2", unit: "u2", order: 20, revision: "r0"))

        try await f.check([Fixture.chapter("c2", unit: "u2", order: 20, revision: "r2")])

        #expect(try await f.events(.revisionChanged).first?.decision == .superseded)
        #expect(try await f.jobs().isEmpty)
    }

    // MARK: - C12, C13, C14: scope, anomalies, bulk

    @Test func c12_aChangedScopeRebaselinesAbsorbsNewKeysAndRaisesNoEvent() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...3))

        // The plugin updated: a new version is a new scope. Unit 4 is absorbed, not announced.
        let rebaselined = try await f.check(numbered(1...4), version: "2.0.0")
        #expect(rebaselined.outcome == .rebaselined)
        #expect(try await f.baseline()?.scopeGeneration == 2)
        #expect(try await f.baseline()?.pluginVersion == "2.0.0")
        #expect(try await f.events().isEmpty)
        #expect(try await f.jobs().isEmpty)

        // The same catalog under the same scope is unchanged, and a visible scope is another scope again.
        #expect(try await f.check(numbered(1...4), version: "2.0.0").outcome == .unchanged)
        #expect(try await f.check(numbered(1...4), scope: .visible, version: "2.0.0").outcome == .rebaselined)
        #expect(try await f.baseline()?.scopeGeneration == 3)
        #expect(try await f.baseline()?.catalogScope == .visible)
    }

    @Test func c12_aRotatedSourceEpochRebaselinesUnderTheNewEpoch() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...3))
        try f.base.rotateEpoch(to: OfflineStoreFixture.rotatedEpoch)

        let ticket = try await f.begin(epoch: OfflineStoreFixture.rotatedEpoch)
        let observation = try Fixture.observation(numbered(1...4), epoch: OfflineStoreFixture.rotatedEpoch)
        let outcome = try await f.store.commitSubscriptionObservation(ticket, observation, limits: Fixture.roomy)

        #expect(outcome.outcome == .rebaselined)
        #expect(try await f.baseline()?.sourceEpoch == OfflineStoreFixture.rotatedEpoch)
        #expect(try await f.events().isEmpty)
    }

    @Test func c12_openEventsAreDecidedAgainOrSupersededByARebaseline() async throws {
        let f = try await Fixture()
        let strictA = EditionSelection.preferred(primary: ScanlatorRef(id: "ga", name: "A"), fallback: .strict)
        try await f.enable(SubscriptionConfiguration(selection: strictA))
        let base = numbered(1...3, scanlator: groupA)
        try await f.check(base)
        let withB = base + [Fixture.chapter("c4b", unit: "u4", order: 40, group: groupB)]
        try await f.check(withB)
        #expect(try await f.events(.newPosition).first?.decision == .awaitingEdition)

        // Still listed under the new scope: it waits again. No longer listed: it is superseded.
        try await f.check(withB, version: "2.0.0")
        #expect(try await f.events(.newPosition).first?.decision == .awaitingEdition)
        try await f.check(base, version: "3.0.0")
        #expect(try await f.events(.newPosition).first?.decision == .superseded)
        #expect(try await f.jobs().isEmpty)
    }

    @Test func c13_aCompleteEmptyCatalogAfterANonEmptyOneIsAnAnomalyAndChangesNothing() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...3))
        let before = try #require(try await f.baseline())

        let outcome = try await f.check([])

        #expect(outcome.outcome == .advanced)
        let event = try #require(try await f.events().first)
        #expect(try await f.events().count == 1)
        #expect(event.kind == .catalogAnomaly && event.identityKind == .catalog)
        #expect(event.decision == .needsReview && event.reviewReason == .emptyAfterNonempty)
        #expect(outcome.needsAttentionEventIds == [event.id])
        // Nothing was deleted or reset.
        #expect(try await f.baseline() == before)
        #expect(try await f.seenCount(present: true) == 3)
        #expect(try await f.jobs().isEmpty)
        // The same observation again raises nothing new.
        try await f.check([])
        #expect(try await f.events().count == 1)
    }

    @Test func c14_aHundredAndFiftyNewPositionsAreOneBulkAnomalyAndAreAbsorbed() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...5))

        let outcome = try await f.check(numbered(1...155))

        let events = try await f.events()
        #expect(events.count == 1)
        #expect(events.first?.kind == .catalogAnomaly)
        #expect(events.first?.reviewReason == .bulkArrival)
        #expect(outcome.queuedJobs == 0)
        #expect(try await f.jobs().isEmpty)
        // The keys are seen, so they are never new again.
        #expect(try await f.seenCount(present: true) == 155)
        #expect(try await f.check(numbered(1...155)).outcome == .unchanged)
    }

    // MARK: - C15, C16, C17: concurrency and atomicity

    @Test func c15_aNewerTicketThatCommittedFirstSupersedesTheOlderOneWithoutWrites() async throws {
        let f = try await Fixture()
        try await f.enable()
        let older = try await f.begin()
        let newer = try await f.begin()
        #expect(newer.ticket == older.ticket + 1)

        let accepted = try await f.store.commitSubscriptionObservation(
            newer, try Fixture.observation(numbered(1...3), epoch: newer.sourceEpoch), limits: Fixture.roomy
        )
        #expect(accepted.outcome == .baselineEstablished)
        let before = try #require(try await f.baseline())
        let attempt = try await f.subscription().lastAttemptAt

        let late = try await f.store.commitSubscriptionObservation(
            older, try Fixture.observation(numbered(1...9), epoch: older.sourceEpoch), limits: Fixture.roomy
        )

        #expect(late.outcome == .superseded)
        #expect(try await f.baseline() == before)
        #expect(try await f.events().isEmpty)
        #expect(try await f.jobs().isEmpty)
        #expect(try await f.subscription().lastAttemptAt == attempt)
    }

    @Test func c15_anOlderTicketThatCommittedFirstIsTheBaselineTheNewerOneIsJudgedAgainst() async throws {
        let f = try await Fixture()
        try await f.enable()
        let older = try await f.begin()
        let newer = try await f.begin()

        let first = try await f.store.commitSubscriptionObservation(
            older, try Fixture.observation(numbered(1...3), epoch: older.sourceEpoch), limits: Fixture.roomy
        )
        #expect(first.outcome == .baselineEstablished)
        let second = try await f.store.commitSubscriptionObservation(
            newer, try Fixture.observation(numbered(1...4), epoch: newer.sourceEpoch), limits: Fixture.roomy
        )

        // Classified from the committed baseline, not rebaselined and not overwritten.
        #expect(second.outcome == .advanced)
        #expect(try await f.events(.newPosition).map(\.identityValue) == ["u4"])
        #expect(try await f.baseline()?.revision == 2)
        #expect(try await f.baseline()?.acceptedTicket == newer.ticket)
    }

    @Test func c16_anEpochThatRotatedBetweenBeginAndCommitWritesOnlyTheAttempt() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...3))
        let ticket = try await f.begin()
        let before = try #require(try await f.baseline())
        try f.base.rotateEpoch(to: OfflineStoreFixture.rotatedEpoch)

        let outcome = try await f.store.commitSubscriptionObservation(
            ticket, try Fixture.observation(numbered(1...6), epoch: ticket.sourceEpoch), limits: Fixture.roomy
        )

        #expect(outcome.outcome == .sourceChanged)
        #expect(try await f.subscription().lastAttemptOutcome == .sourceChanged)
        #expect(try await f.baseline() == before)
        #expect(try await f.events().isEmpty)
        #expect(try await f.jobs().isEmpty)
    }

    @Test func c17_aTransactionThatAbortsAfterClassificationLeavesNothingAndReplayWritesExactlyOnce() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(numbered(1...3))
        let ticket = try await f.begin()
        let observation = try Fixture.observation(numbered(1...4), epoch: ticket.sourceEpoch)
        let before = try #require(try await f.baseline())
        let pool = f.pool

        // The same transaction body the store runs, aborted after it classified and queued: a crash before commit.
        await #expect(throws: AbortedOnPurpose.self) {
            try await pool.write { db in
                _ = try OfflineChapterStore.commitObservation(
                    ticket, observation, limits: Fixture.roomy, now: OfflineStoreFixture.fixedDate, in: db
                )
                throw AbortedOnPurpose()
            }
        }
        #expect(try await f.baseline() == before)
        #expect(try await f.events().isEmpty)
        #expect(try await f.jobs().isEmpty)
        #expect(try await f.seenCount() == 3)

        // Replaying the same ticket after the crash commits exactly one event and one job.
        let replay = try await f.store.commitSubscriptionObservation(ticket, observation, limits: Fixture.roomy)
        #expect(replay.queuedJobs == 1)
        #expect(try await f.events().count == 1)
        #expect(try await f.jobs().count == 1)
        // A second delivery of that ticket, and a fresh check of the same catalog, add nothing.
        #expect(try await f.store.commitSubscriptionObservation(ticket, observation, limits: Fixture.roomy).outcome == .superseded)
        #expect(try await f.check(numbered(1...4)).outcome == .unchanged)
        #expect(try await f.events().count == 1)
        #expect(try await f.jobs().count == 1)
        try await f.expectEveryJobHasAnOwner()
    }

    // MARK: - C18: run cap

    @Test func c18_theRunCapHoldsBackTheRestUntilTheNextCheckCommit() async throws {
        let f = try await Fixture()
        let id = try await f.enable(SubscriptionConfiguration(perRunPositionCap: 5)).id
        try await f.check(numbered(1...2))

        let outcome = try await f.check(numbered(1...10))

        #expect(try await f.events(.newPosition).count == 8)
        #expect(outcome.queuedJobs == 5)
        #expect(outcome.pendingCount == 3)
        // The earliest positions in reading order are admitted first.
        #expect(try await f.jobs().map(\.chapterKey).sorted() == ["c3", "c4", "c5", "c6", "c7"])
        let pending = try await f.events(.newPosition).filter { $0.decision == .pending }
        #expect(pending.map(\.identityValue).sorted() == ["u10", "u8", "u9"])
        #expect(pending.allSatisfy { $0.pendingReason == .runCap })

        // A drain leaves run-cap events alone: only a check commit admits them.
        let drained = try await f.store.drainSubscriptionEvents(subscriptionId: id, limits: Fixture.roomy)
        #expect(drained.queuedJobs == 0)
        #expect(try await f.jobs().count == 5)

        // The next check commit, even of an unchanged catalog, admits the rest under a fresh run cap.
        let next = try await f.check(numbered(1...10))
        #expect(next.outcome == .unchanged)
        #expect(next.queuedJobs == 3)
        #expect(next.pendingCount == 0)
        #expect(try await f.jobs().count == 8)
        try await f.expectEveryJobHasAnOwner()
    }
}
