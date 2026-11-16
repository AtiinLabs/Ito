import Foundation
import Testing
import ito_runner
@testable import Ito

// Admission is pure: each case builds the event, the accepted rows and the store's state by hand and reads the
// decision. The rules are the contract's, in its order: mode gate, liveness, approved keys or resolution,
// suppression, caps, replacement.

private let strictA = EditionSelection.preferred(primary: ScanlatorRef(id: "ga", name: "A"), fallback: .strict)
private let askA = EditionSelection.preferred(primary: ScanlatorRef(id: "ga", name: "A"), fallback: .ask)

private func chapter(
    _ key: String,
    unit: String? = nil,
    group: String? = nil,
    locked: Bool = false,
    revision: String? = nil
) -> Chapter {
    Chapter(
        key: key,
        scanlator: group.map { $0.uppercased() },
        scanlatorID: group.map { "g\($0)" },
        paywalled: locked ? true : nil,
        logicalUnitID: unit,
        readingOrder: 10,
        revision: revision
    )
}

private func subscription(
    mode: SubscriptionMode = .newReleases,
    window: Int? = nil,
    rule: SubscriptionReplacementRule = .off
) -> SeriesSubscriptionRecord {
    SeriesSubscriptionRecord(
        id: UUID().uuidString, pluginId: "plugin.test", mediaKind: .manga, canonicalMediaId: "series-1",
        state: .enabled, pauseReason: nil, mode: mode, windowSize: mode == .maintainNextUnread ? (window ?? 3) : nil,
        perRunPositionCap: 5, selection: Data(), replacementRule: rule, incarnation: 1, configGeneration: 1,
        nextCheckTicket: 1, lastAttemptAt: nil, lastAttemptOutcome: nil, lastSuccessAt: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}

private func event(
    _ kind: SubscriptionEventKind = .newPosition,
    candidates: [String],
    approved: [String]? = nil,
    previousRevision: String? = nil,
    identityKind: SubscriptionIdentityKind = .logical,
    reviewReason: SubscriptionReviewReason? = nil
) -> SubscriptionEventRecord {
    SubscriptionEventRecord(
        id: UUID().uuidString, subscriptionId: "s", incarnation: 1, kind: kind, identityKind: identityKind,
        identityValue: "u1", qualifier: kind == .revisionChanged ? "r2" : nil, decision: .undecided,
        pendingReason: nil, reviewReason: reviewReason,
        candidateKeys: SubscriptionEventRecord.encode(keys: candidates), candidateRevision: 1,
        approvedKeys: approved.map { SubscriptionEventRecord.encode(keys: $0) }, decidedKeys: nil,
        previousRevision: previousRevision, targetRevision: kind == .revisionChanged ? "r2" : nil,
        ordinal: 0, observedCatalogDigest: String(repeating: "d", count: 64), configGeneration: 1,
        scopeGeneration: 1, createdAt: Date(timeIntervalSince1970: 0), decidedAt: nil
    )
}

private func context(
    _ rows: [Chapter],
    selection: EditionSelection? = .sourceList,
    stored: [String: StoredEditionState] = [:],
    suppressed: Set<String> = [],
    installed: [String: InstalledCopyEvidence] = [:],
    mode: SubscriptionMode = .newReleases,
    rule: SubscriptionReplacementRule = .off,
    jobCount: Int = 0,
    autoOnly: Int = 0,
    storedBytes: Int64 = 0,
    limits: AutomaticDownloadLimits = AutomaticDownloadLimits(queueLimit: 100, quotaBytes: 1 << 40),
    runCap: Int? = 5
) -> AdmissionContext {
    AdmissionContext(
        subscription: subscription(mode: mode, rule: rule),
        selection: selection,
        baselineRows: rows.map { CatalogRowEvidence(chapter: $0) },
        stored: Dictionary(uniqueKeysWithValues: stored.map { (ScanlatorUTF8(value: $0.key), $0.value) }),
        suppressed: Set(suppressed.map { ScanlatorUTF8(value: $0) }),
        installed: Dictionary(uniqueKeysWithValues: installed.map { (ScanlatorUTF8(value: $0.key), $0.value) }),
        jobCount: jobCount,
        autoOnlyOutstandingJobs: autoOnly,
        storedBytes: storedBytes,
        limits: limits,
        runCapRemaining: runCap
    )
}

struct SubscriptionAdmissionTests {
    // MARK: - 1. Mode gate

    @Test func modeGateRecordsSupersedesOrAdmitsByKindAndMode() {
        let rows = [chapter("a", unit: "u1")]
        let new = event(candidates: ["a"])
        #expect(SubscriptionAdmission.decide(new, context(rows, mode: .newReleases)) == .enqueue(keys: ["a"]))
        #expect(SubscriptionAdmission.decide(new, context(rows, mode: .newAndFillUnread)) == .enqueue(keys: ["a"]))
        #expect(SubscriptionAdmission.decide(new, context(rows, mode: .maintainNextUnread)) == .recorded)

        let window = event(.window, candidates: ["a"])
        #expect(SubscriptionAdmission.decide(window, context(rows, mode: .maintainNextUnread)) == .enqueue(keys: ["a"]))
        #expect(SubscriptionAdmission.decide(window, context(rows, mode: .newReleases)) == .superseded)

        let backfill = event(.backfill, candidates: ["a"], approved: ["a"])
        #expect(SubscriptionAdmission.decide(backfill, context(rows, mode: .newAndFillUnread)) == .enqueue(keys: ["a"]))
        #expect(SubscriptionAdmission.decide(backfill, context(rows, mode: .newReleases)) == .superseded)

        let revision = event(.revisionChanged, candidates: ["a"], previousRevision: "r1")
        #expect(SubscriptionAdmission.decide(revision, context(rows, rule: .off)) == .recorded)
    }

    @Test func alternatesAndReviewsNeverEnqueueOnTheirOwn() {
        let rows = [chapter("a", unit: "u1")]
        #expect(SubscriptionAdmission.decide(event(.newAlternate, candidates: ["a"], identityKind: .exact), context(rows)) == .recorded)
        #expect(
            SubscriptionAdmission.decide(
                event(.catalogAnomaly, candidates: [], identityKind: .catalog, reviewReason: .emptyAfterNonempty),
                context(rows)
            ) == .needsReview(.emptyAfterNonempty)
        )
        // A review about the whole window rather than one position.
        #expect(
            SubscriptionAdmission.decide(
                event(.window, candidates: [], identityKind: .catalog, reviewReason: .numberOnlyReadState),
                context(rows, mode: .maintainNextUnread)
            ) == .needsReview(.numberOnlyReadState)
        )
        let unplaced = event(.unplacedKey, candidates: ["a"], identityKind: .exact, reviewReason: .insertedBeforeHighWater)
        #expect(SubscriptionAdmission.decide(unplaced, context(rows)) == .needsReview(.insertedBeforeHighWater))
        // Only an explicit approval admits it.
        let approved = event(.unplacedKey, candidates: ["a"], approved: ["a"], identityKind: .exact)
        #expect(SubscriptionAdmission.decide(approved, context(rows)) == .enqueue(keys: ["a"]))
    }

    // MARK: - 2. Liveness

    @Test func aKeyOutsideTheAcceptedCatalogSupersedesTheEvent() {
        let rows = [chapter("a", unit: "u1")]
        #expect(SubscriptionAdmission.decide(event(candidates: ["gone"]), context(rows)) == .superseded)
        #expect(SubscriptionAdmission.decide(event(candidates: ["a", "gone"]), context(rows)) == .superseded)
        #expect(SubscriptionAdmission.decide(event(candidates: []), context(rows)) == .superseded)
        // Approved keys are held to the same rule.
        #expect(SubscriptionAdmission.decide(event(candidates: ["a"], approved: ["gone"]), context(rows)) == .superseded)
    }

    // MARK: - 3. Edition

    @Test func strictSelectionWaitsForItsGroupAndAsksOnlyWhenTheUserSaidSo() {
        let onlyB = [chapter("b", unit: "u1", group: "b")]
        #expect(SubscriptionAdmission.decide(event(candidates: ["b"]), context(onlyB, selection: strictA)) == .awaitingEdition)
        #expect(
            SubscriptionAdmission.decide(event(candidates: ["b"]), context(onlyB, selection: askA))
                == .needsChoice(candidates: ["b"])
        )
        // A locked alternative is not offered as a choice.
        let lockedB = [chapter("b", unit: "u1", group: "b", locked: true), chapter("a-elsewhere", unit: "u9", group: "a")]
        #expect(SubscriptionAdmission.decide(event(candidates: ["b"]), context(lockedB, selection: askA)) == .awaitingEdition)
        // Once the group's own upload is a candidate, it is chosen.
        let both = [chapter("b", unit: "u1", group: "b"), chapter("a", unit: "u1", group: "a")]
        #expect(SubscriptionAdmission.decide(event(candidates: ["b", "a"]), context(both, selection: strictA)) == .enqueue(keys: ["a"]))
    }

    @Test func aSelectionTheCatalogCannotResolveNeedsReview() {
        let rows = [chapter("b", unit: "u1", group: "b")]
        let missing = EditionSelection.scanlators([ScanlatorRef(id: "never-listed", name: "X")])
        #expect(SubscriptionAdmission.decide(event(candidates: ["b"]), context(rows, selection: missing)) == .needsReview(.selectionUnresolved))
        #expect(SubscriptionAdmission.decide(event(candidates: ["b"]), context(rows, selection: nil)) == .needsReview(.selectionUnresolved))
    }

    @Test func approvedKeysAreUsedVerbatimWhateverTheSelectionWouldPick() {
        let both = [chapter("b", unit: "u1", group: "b"), chapter("a", unit: "u1", group: "a")]
        let approved = event(candidates: ["b", "a"], approved: ["b"])
        #expect(SubscriptionAdmission.decide(approved, context(both, selection: strictA)) == .enqueue(keys: ["b"]))
    }

    @Test func storedStateSettlesTheEventBeforeAnyQueueing() {
        let rows = [chapter("a", unit: "u1")]
        #expect(SubscriptionAdmission.decide(event(candidates: ["a"]), context(rows, stored: ["a": .verified])) == .satisfied(keys: ["a"]))
        #expect(SubscriptionAdmission.decide(event(candidates: ["a"]), context(rows, stored: ["a": .queued])) == .satisfied(keys: ["a"]))
        #expect(SubscriptionAdmission.decide(event(candidates: ["a"]), context(rows, stored: ["a": .damaged])) == .blockedDamaged)
        let locked = [chapter("a", unit: "u1", locked: true)]
        #expect(SubscriptionAdmission.decide(event(candidates: ["a"]), context(locked)) == .locked)
        // An approved key that already has a job gains the subscription as an owner instead.
        let approved = event(candidates: ["a"], approved: ["a"])
        #expect(SubscriptionAdmission.decide(approved, context(rows, stored: ["a": .queued])) == .enqueue(keys: ["a"]))
        #expect(SubscriptionAdmission.decide(approved, context(rows, stored: ["a": .verified])) == .satisfied(keys: ["a"]))
    }

    // MARK: - 4. Suppression

    @Test func aDeletedKeyIsSuppressedAndNeverFallsThroughToAnotherGroup() {
        let both = [chapter("b", unit: "u1", group: "b"), chapter("a", unit: "u1", group: "a")]
        // Source order puts B first, so B is chosen under the source list; it was deleted.
        #expect(
            SubscriptionAdmission.decide(event(candidates: ["b", "a"]), context(both, selection: .sourceList, suppressed: ["b"]))
                == .suppressed
        )
        let approved = event(candidates: ["b", "a"], approved: ["a"])
        #expect(SubscriptionAdmission.decide(approved, context(both, suppressed: ["a"])) == .suppressed)
    }

    // MARK: - 5. Caps

    @Test func capsApplyInTheContractOrder() {
        let rows = [chapter("a", unit: "u1")]
        let limits = AutomaticDownloadLimits(queueLimit: 10, quotaBytes: 10 * AutomaticDownloadLimits.estimatedJobBytes)
        // The run cap is checked first, then the queue, then the quota.
        #expect(SubscriptionAdmission.decide(event(candidates: ["a"]), context(rows, limits: limits, runCap: 0)) == .pending(.runCap))
        #expect(
            SubscriptionAdmission.decide(event(candidates: ["a"]), context(rows, jobCount: 10, limits: limits, runCap: 0))
                == .pending(.runCap)
        )
        #expect(
            SubscriptionAdmission.decide(event(candidates: ["a"]), context(rows, jobCount: 10, limits: limits))
                == .pending(.queueCap)
        )
        #expect(
            SubscriptionAdmission.decide(event(candidates: ["a"]), context(rows, autoOnly: 10, limits: limits))
                == .pending(.quota)
        )
        #expect(
            SubscriptionAdmission.decide(
                event(candidates: ["a"]),
                context(rows, storedBytes: 9 * AutomaticDownloadLimits.estimatedJobBytes + 1, limits: limits)
            ) == .pending(.quota)
        )
        #expect(SubscriptionAdmission.decide(event(candidates: ["a"]), context(rows, jobCount: 9, limits: limits)) == .enqueue(keys: ["a"]))
        // The run cap is exempt when the caller passes none, as approvals and drains do.
        #expect(
            SubscriptionAdmission.decide(event(candidates: ["a"]), context(rows, limits: limits, runCap: nil)) == .enqueue(keys: ["a"])
        )
    }

    @Test func attachingToExistingJobsPassesTheQueueAndQuotaCaps() {
        let rows = [chapter("a", unit: "u1")]
        let full = AutomaticDownloadLimits(queueLimit: 10, quotaBytes: 1)
        let approved = event(candidates: ["a"], approved: ["a"])
        #expect(
            SubscriptionAdmission.decide(approved, context(rows, stored: ["a": .queued], jobCount: 50, storedBytes: 1 << 20, limits: full))
                == .enqueue(keys: ["a"])
        )
        // A new job under the same caps does not.
        #expect(
            SubscriptionAdmission.decide(approved, context(rows, jobCount: 50, limits: full)) == .pending(.queueCap)
        )
    }

    @Test func allEditionsCountsPositionsForTheRunCapAndJobsForTheQueueCap() {
        let rows = [
            chapter("a", unit: "u1", group: "a"), chapter("b", unit: "u1", group: "b"), chapter("c", unit: "u1", group: "c")
        ]
        let limits = AutomaticDownloadLimits(queueLimit: 2, quotaBytes: 1 << 40)
        // One position, three jobs: the queue cap sees three, the run cap saw one.
        #expect(
            SubscriptionAdmission.decide(
                event(candidates: ["a", "b", "c"]),
                context(rows, selection: .allUploads, limits: limits, runCap: 1)
            ) == .pending(.queueCap)
        )
        #expect(
            SubscriptionAdmission.decide(
                event(candidates: ["a", "b", "c"]),
                context(rows, selection: .allUploads, limits: AutomaticDownloadLimits(queueLimit: 3, quotaBytes: 1 << 40), runCap: 1)
            ) == .enqueue(keys: ["a", "b", "c"])
        )
    }

    // MARK: - 6. Replacement

    @Test func aRevisionReplacesOnlyTheMatchingVerifiedCopyUnderTheCurrentEpoch() {
        let rows = [chapter("a", unit: "u1", revision: "r2")]
        let revision = event(.revisionChanged, candidates: ["a"], previousRevision: "r1", identityKind: .exact)
        let current = InstalledCopyEvidence(isVerified: true, revision: "r1", sourceEpochIsCurrent: true)
        func decide(_ installed: InstalledCopyEvidence?, stored: StoredEditionState = .verified, suppressed: Set<String> = []) -> AdmissionDecision {
            SubscriptionAdmission.decide(
                revision,
                context(
                    rows, stored: ["a": stored], suppressed: suppressed,
                    installed: installed.map { ["a": $0] } ?? [:], rule: .sameKeyReliableRevision
                )
            )
        }
        #expect(decide(current) == .enqueue(keys: ["a"]))
        #expect(decide(InstalledCopyEvidence(isVerified: true, revision: "other", sourceEpochIsCurrent: true)) == .superseded)
        #expect(decide(InstalledCopyEvidence(isVerified: true, revision: nil, sourceEpochIsCurrent: true)) == .superseded)
        #expect(decide(InstalledCopyEvidence(isVerified: true, revision: "r1", sourceEpochIsCurrent: false)) == .superseded)
        #expect(decide(nil) == .superseded)
        #expect(decide(current, stored: .none) == .superseded)
        #expect(decide(current, stored: .damaged) == .blockedDamaged)
        #expect(decide(current, suppressed: ["a"]) == .suppressed)
    }

    @Test func aRevisionOfAGroupTheSelectionDoesNotAdmitIsOnlyRecorded() {
        let rows = [chapter("b", unit: "u1", group: "b", revision: "r2"), chapter("a", unit: "u2", group: "a")]
        let revision = event(.revisionChanged, candidates: ["b"], previousRevision: "r1", identityKind: .exact)
        let installed = InstalledCopyEvidence(isVerified: true, revision: "r1", sourceEpochIsCurrent: true)
        let decision = SubscriptionAdmission.decide(
            revision,
            context(rows, selection: strictA, stored: ["b": .verified], installed: ["b": installed], rule: .sameKeyReliableRevision)
        )
        #expect(decision == .recorded)
    }

    @Test func aReplacementCountsTowardTheRunAndQueueCaps() {
        let rows = [chapter("a", unit: "u1", revision: "r2")]
        let revision = event(.revisionChanged, candidates: ["a"], previousRevision: "r1", identityKind: .exact)
        let installed = ["a": InstalledCopyEvidence(isVerified: true, revision: "r1", sourceEpochIsCurrent: true)]
        let limits = AutomaticDownloadLimits(queueLimit: 1, quotaBytes: 1 << 40)
        #expect(
            SubscriptionAdmission.decide(
                revision, context(rows, stored: ["a": .verified], installed: installed, rule: .sameKeyReliableRevision, runCap: 0)
            ) == .pending(.runCap)
        )
        #expect(
            SubscriptionAdmission.decide(
                revision,
                context(rows, stored: ["a": .verified], installed: installed, rule: .sameKeyReliableRevision, jobCount: 1, limits: limits)
            ) == .pending(.queueCap)
        )
    }

    // MARK: - Context

    @Test func recordingAnEnqueueUpdatesTheCountsTheNextEventSees() {
        let rows = [chapter("a", unit: "u1"), chapter("b", unit: "u2")]
        var ctx = context(rows, limits: AutomaticDownloadLimits(queueLimit: 1, quotaBytes: 1 << 40), runCap: 1)
        #expect(SubscriptionAdmission.decide(event(candidates: ["a"]), ctx) == .enqueue(keys: ["a"]))
        ctx.apply(enqueued: ["a"], created: 1)
        #expect(ctx.jobCount == 1)
        #expect(ctx.autoOnlyOutstandingJobs == 1)
        #expect(ctx.runCapRemaining == 0)
        #expect(SubscriptionAdmission.decide(event(candidates: ["b"]), ctx) == .pending(.runCap))
        // The enqueued key is now a job, so a repeat is satisfied rather than queued twice.
        #expect(SubscriptionAdmission.decide(event(candidates: ["a"]), ctx) == .satisfied(keys: ["a"]))
        ctx.runCapRemaining = nil
        #expect(SubscriptionAdmission.decide(event(candidates: ["b"]), ctx) == .pending(.queueCap))
    }

    @Test func positionKeysCompareAsExactBytes() {
        // The two spellings are canonically equivalent as Swift strings but are different keys.
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let rows = [chapter(composed, unit: "u1")]
        #expect(SubscriptionAdmission.decide(event(candidates: [decomposed]), context(rows)) == .superseded)
        #expect(SubscriptionAdmission.decide(event(candidates: [composed]), context(rows)) == .enqueue(keys: [composed]))
    }
}
