import Foundation
import Testing
import ito_runner
@testable import Ito

// The classifier is pure, so every case here feeds real observations (built by `CatalogObservation.make`,
// the same factory production uses) through `SubscriptionCatalogClassifier.classify`. `Harness` plays the
// part of the store: it applies an accepted write to the baseline exactly as `BaselineWrite` documents.
// Case names C1...C14 follow the ledger contract's test table.

private func logical(_ id: String) -> SubscriptionPositionID { .logical(ScanlatorUTF8(value: id)) }
private func exact(_ key: String) -> SubscriptionPositionID { .exact(ScanlatorUTF8(value: key)) }
private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

/// One chapter: reading order `order`, optional logical unit, revision and date.
private func row(
    _ key: String,
    _ order: Int64?,
    unit: String? = nil,
    revision: String? = nil,
    date: Double? = nil,
    volume: Double? = nil,
    number: Double? = nil
) -> Chapter {
    Chapter(
        key: key,
        volume: volume,
        chapter: number,
        dateUpdated: date,
        logicalUnitID: unit,
        readingOrder: order,
        revision: revision
    )
}

/// Chapters `c<n>` in logical unit `u<n>` at reading order `n * 10`, listed newest first.
private func numbered(
    _ numbers: some Sequence<Int>,
    units: Bool = true,
    revision: String? = nil,
    date: ((Int) -> Double?)? = nil
) -> [Chapter] {
    numbers.sorted(by: >).map { number in
        row(
            "c\(number)",
            Int64(number) * 10,
            unit: units ? "u\(number)" : nil,
            revision: revision,
            date: date?(number)
        )
    }
}

private func observe(
    _ chapters: [Chapter],
    scope: CatalogScope = .allEligible,
    completeness: CatalogCompleteness = .complete,
    epoch: String = "epoch-1",
    version: String = "1.0.0",
    kind: MediaKind = .manga
) throws -> CatalogObservation {
    let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "series", mediaKind: kind)
    let catalog = ChapterCatalog(scope: scope, completeness: completeness)
    let entry: MediaEntry = kind == .novel
        ? .novel(Novel(key: "series", title: "Series", chapters: chapters, catalog: catalog))
        : .manga(Manga(key: "series", title: "Series", chapters: chapters, catalog: catalog))
    return try CatalogObservation.make(media: media, entry: entry, pluginVersion: version, sourceEpoch: epoch).get()
}

private func events(_ classification: CatalogClassification) -> [ClassifiedEvent] {
    switch classification {
    case .advance(_, let events), .anomaly(let events): events
    case .rejected, .unchanged, .baseline: []
    }
}

private func write(_ classification: CatalogClassification) -> BaselineWrite? {
    switch classification {
    case .baseline(let write, _), .advance(let write, _): write
    case .rejected, .unchanged, .anomaly: nil
    }
}

/// The store, reduced to what the classifier reads back: the accepted baseline.
private struct Harness {
    var view: SubscriptionBaselineView?

    /// Classifies against the current baseline, then accepts the write the way the store does.
    @discardableResult
    mutating func accept(_ observation: CatalogObservation) -> CatalogClassification {
        let classification = SubscriptionCatalogClassifier.classify(observation: observation, baseline: view)
        guard let accepted = write(classification) else { return classification }
        // Every seen key not in the write becomes a tombstone; every key in it is present.
        var seen = (view?.seen ?? [:]).mapValues {
            SubscriptionBaselineView.SeenKey(position: $0.position, lastRevision: $0.lastRevision, present: false, rank: nil)
        }
        for (key, value) in accepted.seenUpserts { seen[key] = value }
        view = SubscriptionBaselineView(
            incarnation: 1,
            revision: (view?.revision ?? 0) + 1,
            acceptedTicket: (view?.acceptedTicket ?? 0) + 1,
            scopeGeneration: (view?.scopeGeneration ?? 1) + (accepted.scopeGenerationIncrement ? 1 : 0),
            fingerprint: accepted.fingerprint,
            catalogDigest: accepted.catalogDigest,
            rowCount: accepted.rowCount,
            orderConfidence: accepted.orderConfidence,
            highWater: accepted.highWater,
            maxDateUpdated: accepted.maxDateUpdated,
            seen: seen
        )
        return classification
    }

    /// A harness whose baseline was accepted from `chapters`.
    static func baselined(_ chapters: [Chapter], epoch: String = "epoch-1") throws -> Harness {
        var harness = Harness()
        harness.accept(try observe(chapters, epoch: epoch))
        return harness
    }
}

struct SubscriptionCatalogClassifierTests {
    // MARK: - Observation factory

    @Test func factoryNormalizesRevisionDateAndScope() throws {
        let observation = try observe([
            row("a", 10, revision: ""),
            row("b", 20, revision: "r2"),
            row("c", 30, date: 1_234)
        ])
        #expect(observation.rows.map(\.revision) == [nil, ScanlatorUTF8(value: "r2"), nil])
        #expect(observation.rows.map(\.dateUpdated) == [nil, nil, 1_234])
        // A non-finite date is no date at all.
        #expect(CatalogRowEvidence(chapter: row("d", 40, date: .nan)).dateUpdated == nil)
        #expect(CatalogRowEvidence(chapter: row("e", 50, date: .infinity)).dateUpdated == nil)
        #expect(observation.fingerprint.catalogScope == .allEligible)
        #expect(observation.fingerprint.chapterABI == 3)
        #expect(observation.fingerprint.acquisition == "mediaUpdate")
        #expect(observation.completeness == .complete)
        #expect(observation.chapters.map(\.key) == ["a", "b", "c"])
        #expect(!observation.entrySnapshot.isEmpty)
    }

    @Test func factoryDigestFollowsTheChaptersAlone() throws {
        let first = try observe(numbered(1...3))
        let again = try observe(numbered(1...3), epoch: "epoch-2")
        let revised = try observe(numbered(1...3, revision: "r1"))
        #expect(first.catalogDigest.count == 64)
        #expect(first.catalogDigest == again.catalogDigest)
        #expect(first.catalogDigest != revised.catalogDigest)
    }

    @Test func factoryRefusesWhatCannotBeObserved() throws {
        let anime = MediaIdentity(pluginId: "plugin", canonicalMediaId: "series", mediaKind: .anime)
        let animeResult = CatalogObservation.make(
            media: anime,
            entry: .anime(Anime(key: "series", title: "Series")),
            pluginVersion: "1",
            sourceEpoch: "e"
        )
        #expect(animeResult.failureValue == .unsupportedKind)

        let mangaMedia = MediaIdentity(pluginId: "plugin", canonicalMediaId: "series", mediaKind: .manga)
        let wrongKind = CatalogObservation.make(
            media: mangaMedia,
            entry: .novel(Novel(key: "series", title: "Series", chapters: [], catalog: nil)),
            pluginVersion: "1",
            sourceEpoch: "e"
        )
        #expect(wrongKind.failureValue == .unsupportedKind)

        let noList = CatalogObservation.make(
            media: mangaMedia,
            entry: .manga(Manga(key: "series", title: "Series")),
            pluginVersion: "1",
            sourceEpoch: "e"
        )
        #expect(noList.failureValue == .incompleteCatalog)

        let oversized = CatalogObservation.make(
            media: mangaMedia,
            entry: .manga(Manga(
                key: "series",
                title: "Series",
                chapters: (0...CatalogLimits.chapters).map { row("k\($0)", Int64($0)) },
                catalog: ChapterCatalog(scope: .allEligible, completeness: .complete)
            )),
            pluginVersion: "1",
            sourceEpoch: "e"
        )
        #expect(oversized.failureValue == .oversizedCatalog)
    }

    @Test func missingCatalogDescriptionIsAnUnknownScope() throws {
        let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "series", mediaKind: .manga)
        let observation = try CatalogObservation.make(
            media: media,
            entry: .manga(Manga(key: "series", title: "Series", chapters: [row("a", 10)], catalog: nil)),
            pluginVersion: "1",
            sourceEpoch: "e"
        ).get()
        #expect(observation.fingerprint.catalogScope == .unknown)
        #expect(observation.completeness == .unknown)
        #expect(SubscriptionCatalogClassifier.classify(observation: observation, baseline: nil) == .rejected(.unknownScope))
    }

    // MARK: - C1: first baseline

    @Test func c1FirstCatalogOfFiveHundredRowsEstablishesABaselineWithoutEvents() throws {
        let observation = try observe(numbered(1...500))
        let classification = SubscriptionCatalogClassifier.classify(observation: observation, baseline: nil)
        guard case .baseline(let write, let outcome) = classification else {
            Issue.record("Expected a baseline, got \(classification)")
            return
        }
        #expect(outcome == .baselineEstablished)
        #expect(write.seenUpserts.count == 500)
        #expect(write.rowCount == 500)
        #expect(!write.scopeGenerationIncrement)
        #expect(write.orderConfidence == .confident)
        #expect(write.highWater == logical("u500"))
        #expect(write.catalogDigest == observation.catalogDigest)
        #expect(write.fingerprint == observation.fingerprint)
        #expect(write.seenUpserts[ScanlatorUTF8(value: "c1")]?.rank == 0)
        #expect(write.seenUpserts[ScanlatorUTF8(value: "c500")]?.rank == 499)
        #expect(write.seenUpserts.values.allSatisfy { $0.present })
    }

    @Test func c1FirstVisibleScopeCatalogOfFiveHundredRowsEstablishesABaselineWithoutEvents() throws {
        let observation = try observe(numbered(1...500), scope: .visible)
        let classification = SubscriptionCatalogClassifier.classify(observation: observation, baseline: nil)
        guard case .baseline(let write, let outcome) = classification else {
            Issue.record("Expected a baseline, got \(classification)")
            return
        }
        #expect(outcome == .baselineEstablished)
        #expect(write.fingerprint.catalogScope == .visible)
        #expect(write.fingerprint == observation.fingerprint)
        #expect(write.seenUpserts.count == 500)
        #expect(write.rowCount == 500)
        #expect(!write.scopeGenerationIncrement)
        #expect(write.orderConfidence == .confident)
        #expect(write.highWater == logical("u500"))
        #expect(write.catalogDigest == observation.catalogDigest)
        #expect(write.seenUpserts[ScanlatorUTF8(value: "c1")]?.rank == 0)
        #expect(write.seenUpserts[ScanlatorUTF8(value: "c500")]?.rank == 499)
        #expect(write.seenUpserts.values.allSatisfy { $0.present })
    }

    @Test func firstBaselineWithoutADeclaredOrderHasNoHighWater() throws {
        let chapters = [row("b", nil, number: 2), row("a", 10, number: 1)]
        let classification = SubscriptionCatalogClassifier.classify(observation: try observe(chapters), baseline: nil)
        let accepted = try #require(write(classification))
        #expect(accepted.orderConfidence == .ambiguous)
        #expect(accepted.highWater == nil)
        #expect(accepted.seenUpserts.values.allSatisfy { $0.rank == nil })
        #expect(accepted.seenUpserts.count == 2)
    }

    @Test func firstBaselineRecordsTheNewestSourceDateAndRevisions() throws {
        let classification = SubscriptionCatalogClassifier.classify(
            observation: try observe([row("a", 10, revision: "r1", date: 5), row("b", 20, date: 9)]),
            baseline: nil
        )
        let accepted = try #require(write(classification))
        #expect(accepted.maxDateUpdated == 9)
        #expect(accepted.seenUpserts[ScanlatorUTF8(value: "a")]?.lastRevision == ScanlatorUTF8(value: "r1"))
        #expect(accepted.seenUpserts[ScanlatorUTF8(value: "b")]?.lastRevision == nil)
    }

    // MARK: - C2: nothing is accepted without proof

    @Test func c2PartialUnknownScopeEmptyAndUnsupportedObservationsNeverBecomeABaseline() throws {
        let chapters = numbered(1...3)
        let cases: [(CatalogObservation, SubscriptionCheckOutcome)] = [
            (try observe(chapters, completeness: .partial), .incompleteCatalog),
            (try observe(chapters, completeness: .unknown), .incompleteCatalog),
            (try observe(chapters, scope: .unknown), .unknownScope),
            // Scope is judged before completeness.
            (try observe(chapters, scope: .unknown, completeness: .partial), .unknownScope),
            (try observe([]), .emptyCatalog)
        ]
        for (observation, expected) in cases {
            #expect(SubscriptionCatalogClassifier.classify(observation: observation, baseline: nil) == .rejected(expected))
        }

        let baselined = try Harness.baselined(chapters)
        for (observation, expected) in cases where expected != .emptyCatalog {
            #expect(
                SubscriptionCatalogClassifier.classify(observation: observation, baseline: baselined.view)
                    == .rejected(expected)
            )
        }
    }

    @Test func visibleScopeMayBaselineLikeAnyOther() throws {
        let classification = SubscriptionCatalogClassifier.classify(
            observation: try observe(numbered(1...3), scope: .visible),
            baseline: nil
        )
        guard case .baseline(let write, .baselineEstablished) = classification else {
            Issue.record("Expected a baseline, got \(classification)")
            return
        }
        #expect(write.fingerprint.catalogScope == .visible)
    }

    @Test func animeObservationsAreRejectedBeforeAnythingElse() throws {
        let valid = try observe(numbered(1...3))
        let anime = CatalogObservation(
            media: MediaIdentity(pluginId: "plugin", canonicalMediaId: "series", mediaKind: .anime),
            fingerprint: valid.fingerprint,
            completeness: .unknown,
            rows: valid.rows,
            chapters: valid.chapters,
            entrySnapshot: valid.entrySnapshot,
            catalogDigest: valid.catalogDigest
        )
        #expect(SubscriptionCatalogClassifier.classify(observation: anime, baseline: nil) == .rejected(.unsupportedKind))
    }

    @Test func rowsThatShareAnExactKeyProveNothing() throws {
        let observation = try observe([row("a", 10), row("a", 20)])
        #expect(SubscriptionCatalogClassifier.classify(observation: observation, baseline: nil) == .rejected(.incompleteCatalog))
    }

    // MARK: - Unchanged

    @Test func sameScopeAndCatalogChangeNothing() throws {
        var harness = try Harness.baselined(numbered(1...5))
        #expect(harness.accept(try observe(numbered(1...5))) == .unchanged)
        // The listing order of the same rows is part of the digest, so it is not "unchanged".
        #expect(harness.accept(try observe(Array(numbered(1...5).reversed()))) != .unchanged)
    }

    // MARK: - C3: forward events

    @Test func c3ANewLogicalUnitAfterTheHighWaterIsOneNewPosition() throws {
        var harness = try Harness.baselined(numbered(1...5))
        let classification = harness.accept(try observe(numbered(1...6)))

        #expect(events(classification) == [
            ClassifiedEvent(
                kind: .newPosition,
                identity: SubscriptionEventIdentity(kind: .logical, value: "u6"),
                qualifier: nil,
                candidateKeys: ["c6"],
                previousRevision: nil,
                targetRevision: nil,
                ordinal: 5,
                initialDecision: .undecided,
                reviewReason: nil
            )
        ])
        let accepted = try #require(write(classification))
        #expect(accepted.highWater == logical("u6"))
        #expect(accepted.seenUpserts.count == 6)
        #expect(!accepted.scopeGenerationIncrement)
    }

    @Test func aPositionWithoutALogicalUnitIsItsOwnExactPosition() throws {
        var harness = try Harness.baselined(numbered(1...3, units: false))
        let classification = harness.accept(try observe(numbered(1...4, units: false)))
        let event = try #require(events(classification).first)
        #expect(event.kind == .newPosition)
        #expect(event.identity == SubscriptionEventIdentity(kind: .exact, value: "c4"))
        #expect(write(classification)?.highWater == exact("c4"))
    }

    @Test func rowsWithTheSameNumberAreNeverMergedIntoOnePosition() throws {
        var harness = try Harness.baselined(numbered(1...3, units: false))
        let split = numbered(1...3, units: false) + [row("c4b", 45, number: 4), row("c4a", 40, number: 4)]
        let classification = harness.accept(try observe(split))
        let published = events(classification)
        #expect(published.map(\.kind) == [.newPosition, .newPosition])
        #expect(published.map(\.candidateKeys) == [["c4a"], ["c4b"]])
        #expect(published.map(\.ordinal) == [3, 4])
    }

    @Test func forwardEventsComeInReadingOrderWhateverTheSourceListingOrder() throws {
        var harness = try Harness.baselined(numbered(1...2))
        let classification = harness.accept(try observe([row("c3", 30, unit: "u3")] + numbered(1...2) + [row("c5", 50, unit: "u5"), row("c4", 40, unit: "u4")]))
        #expect(events(classification).map(\.identity.value) == ["u3", "u4", "u5"])
        #expect(write(classification)?.highWater == logical("u5"))
    }

    @Test func severalForwardPositionsOfAnUnorderedResponseKeepSourceOrderAndSourceIndexOrdinals() throws {
        var harness = try Harness.baselined(numbered(1...3))
        // No reading order at all: the events follow the source listing, and ordinals are source indices.
        let unordered = [row("c6", nil, unit: "u6"), row("c4", nil, unit: "u4"), row("c5", nil, unit: "u5")]
            + numbered(1...3).map { row($0.key, nil, unit: $0.logicalUnitID) }
        let published = events(harness.accept(try observe(unordered)))
        #expect(published.map(\.kind) == [.unplacedKey, .unplacedKey, .unplacedKey])
        #expect(published.map(\.reviewReason) == [.noReliableOrder, .noReliableOrder, .noReliableOrder])
        #expect(published.map(\.identity.value) == ["c6", "c4", "c5"])
        #expect(published.map(\.ordinal) == [0, 1, 2])
    }

    // MARK: - C4: the key diff decides, not the count

    @Test func c4AnUnchangedCountWithOneKeySwappedIsOneEventFromTheKeyDiff() throws {
        var harness = try Harness.baselined(numbered(1...5))
        let swapped = numbered(2...6)
        #expect(swapped.count == 5)
        let classification = harness.accept(try observe(swapped))
        #expect(events(classification).map(\.kind) == [.newPosition])
        #expect(events(classification).first?.candidateKeys == ["c6"])
        let accepted = try #require(write(classification))
        #expect(accepted.rowCount == 5)
        #expect(accepted.seenUpserts[ScanlatorUTF8(value: "c1")] == nil)
    }

    @Test func aChangedCatalogWithNoNewKeyIsNoEvent() throws {
        var harness = try Harness.baselined(numbered(1...3))
        // The same keys with new dates: the digest changes, the key set does not.
        let classification = harness.accept(try observe(numbered(1...3, date: { Double($0) })))
        #expect(events(classification).isEmpty)
        #expect(write(classification) != nil)
    }

    // MARK: - C5: alternate editions

    @Test func c5AKnownLogicalUnitWithANewKeyIsAnAlternateNotARelease() throws {
        var harness = try Harness.baselined(numbered(1...5))
        let classification = harness.accept(try observe(numbered(1...5) + [row("alt5", 50, unit: "u5")]))
        #expect(events(classification) == [
            ClassifiedEvent(
                kind: .newAlternate,
                identity: SubscriptionEventIdentity(kind: .exact, value: "alt5"),
                qualifier: nil,
                candidateKeys: ["alt5"],
                previousRevision: nil,
                targetRevision: nil,
                ordinal: 4,
                initialDecision: .recorded,
                reviewReason: nil
            )
        ])
        #expect(write(classification)?.highWater == logical("u5"))
    }

    @Test func aLateUploadOfAUnitAnotherGroupPublishedFirstIsAnAlternate() throws {
        var harness = try Harness.baselined(numbered(1...5))
        let first = harness.accept(try observe(numbered(1...5) + [row("b6", 60, unit: "u6")]))
        #expect(events(first).map(\.kind) == [.newPosition])
        let second = harness.accept(try observe(numbered(1...5) + [row("b6", 60, unit: "u6"), row("a6", 60, unit: "u6")]))
        #expect(events(second).map(\.kind) == [.newAlternate])
        #expect(events(second).first?.candidateKeys == ["a6"])
        #expect(events(second).first?.initialDecision == .recorded)
    }

    @Test func anAlternateOfATombstonedPositionIsStillAnAlternate() throws {
        var harness = try Harness.baselined(numbered(1...3))
        harness.accept(try observe(numbered([1, 3])))
        let classification = harness.accept(try observe(numbered([1, 3]) + [row("alt2", 20, unit: "u2")]))
        #expect(events(classification).map(\.kind) == [.newAlternate])
    }

    @Test func aNewAlternateInTheSameCheckAsAnIdentityDriftIsStillRecorded() throws {
        let drifted = [row("c3", 30, unit: "u3"), row("c2", 20), row("c1", 10, unit: "u1")]
        var alone = try Harness.baselined(numbered(1...3))
        let onlyAlternate = alone.accept(try observe(drifted + [row("alt3", 30, unit: "u3")]))
        #expect(events(onlyAlternate).map(\.kind) == [.newAlternate])
        #expect(events(onlyAlternate).first?.initialDecision == .recorded)

        // A forward candidate beside it is held by the drift; the alternate is not.
        var withForward = try Harness.baselined(numbered(1...3))
        let published = events(withForward.accept(try observe(drifted + [row("alt3", 30, unit: "u3"), row("c4", 40, unit: "u4")])))
        #expect(published.map(\.kind) == [.newAlternate, .unplacedKey])
        #expect(published.map(\.reviewReason) == [nil, .positionIdentityChanged])
        #expect(published.map(\.initialDecision) == [.recorded, .needsReview])
    }

    // MARK: - C8: review reasons

    @Test func c8AKeyInsertedBeforeTheHighWaterIsReviewedNotPublished() throws {
        var harness = try Harness.baselined(numbered([1, 2, 4, 5]))
        let classification = harness.accept(try observe(numbered(1...5)))
        try expectUnplaced(classification, key: "c3", reason: .insertedBeforeHighWater)
        // The baseline advances: the key is seen now and never fresh again.
        #expect(write(classification)?.seenUpserts[ScanlatorUTF8(value: "c3")] != nil)
        #expect(harness.accept(try observe(numbered(1...5))) == .unchanged)
    }

    @Test func c8ADateOlderThanTheBaselineIsReviewed() throws {
        // An undated baseline has no date evidence, so a dated new row is a normal forward event; the device
        // clock plays no part.
        var undated = try Harness.baselined(numbered(1...5))
        let dated = numbered(1...5) + [row("c6", 60, unit: "u6", date: 1_000)]
        #expect(events(undated.accept(try observe(dated))).map(\.kind) == [.newPosition])

        // Older than the newest source date ever accepted.
        var future = try Harness.baselined(numbered(1...5, date: { $0 == 5 ? 2_000_000_000 : nil }))
        let behind = numbered(1...5, date: { $0 == 5 ? 2_000_000_000 : nil }) + [row("c6", 60, unit: "u6", date: 1_900_000_000)]
        try expectUnplaced(future.accept(try observe(behind)), key: "c6", reason: .olderThanBaseline)
    }

    @Test func aDateEqualToTheNewestAcceptedDateIsNotOlder() throws {
        var harness = try Harness.baselined(numbered(1...5, date: { $0 == 5 ? 2_000 : nil }))
        let equal = numbered(1...5, date: { $0 == 5 ? 2_000 : nil }) + [row("c6", 60, unit: "u6", date: 2_000)]
        let published = events(harness.accept(try observe(equal)))
        #expect(published.map(\.kind) == [.newPosition])
        #expect(published.first?.reviewReason == nil)
    }

    @Test func aDateAfterTheBaselineOrNoDateAtAllDoesNotBlockAForwardEvent() throws {
        var dated = try Harness.baselined(numbered(1...5, date: { _ in 1_000 }))
        let newer = numbered(1...5, date: { _ in 1_000 }) + [row("c6", 60, unit: "u6", date: 1_700_000_100)]
        #expect(events(dated.accept(try observe(newer))).map(\.kind) == [.newPosition])

        // A missing date cannot invent chronology, but it is not evidence against the order either.
        var undated = try Harness.baselined(numbered(1...5))
        #expect(events(undated.accept(try observe(numbered(1...6)))).map(\.kind) == [.newPosition])
    }

    @Test func acceptedDatesNeverMoveBackwards() throws {
        var harness = try Harness.baselined(numbered(1...3, date: { Double($0) * 1_000 }))
        let classification = harness.accept(try observe(numbered(1...3, date: { Double($0) })))
        #expect(write(classification)?.maxDateUpdated == 3_000)
    }

    @Test func c8AReappearingTombstoneAfterTheHighWaterHoldsEveryForwardCandidate() throws {
        var harness = try Harness.baselined(numbered(1...3))
        #expect(events(harness.accept(try observe(numbered([1, 3])))).isEmpty)

        let reappeared = [row("c4", 50, unit: "u4"), row("c2", 40, unit: "u2")] + numbered([1, 3])
        let classification = harness.accept(try observe(reappeared))
        try expectUnplaced(classification, key: "c4", reason: .knownPositionAfterHighWater)
        #expect(events(classification).count == 1)
    }

    @Test func c8ReorderedAnchorsHoldEveryForwardCandidate() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let reordered = [row("c4", 40, unit: "u4"), row("c3", 30, unit: "u3"), row("c1", 20, unit: "u1"), row("c2", 10, unit: "u2")]
        try expectUnplaced(harness.accept(try observe(reordered)), key: "c4", reason: .anchorsReordered)
    }

    @Test func c8AMissingHighWaterHoldsEveryForwardCandidate() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let classification = harness.accept(try observe(numbered([1, 2, 4])))
        try expectUnplaced(classification, key: "c4", reason: .highWaterMissing)
        #expect(write(classification)?.seenUpserts[ScanlatorUTF8(value: "c3")] == nil)
    }

    @Test func c8ARowWithoutAReadingOrderMakesTheWholeResponseUnorderable() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let classification = harness.accept(try observe(numbered(1...3) + [row("c4", nil, unit: "u4")]))
        try expectUnplaced(classification, key: "c4", reason: .noReliableOrder)
        let accepted = try #require(write(classification))
        #expect(accepted.orderConfidence == .ambiguous)
        #expect(accepted.highWater == nil)
        #expect(accepted.seenUpserts.values.allSatisfy { $0.rank == nil })
    }

    @Test func c8ABaselineWithoutAnOrderHoldsForwardCandidatesUntilAnOrderedBaselineExists() throws {
        var harness = try Harness.baselined(numbered(1...3).map { row($0.key, nil, unit: $0.logicalUnitID) })
        #expect(harness.view?.highWater == nil)

        try expectUnplaced(harness.accept(try observe(numbered(1...4))), key: "c4", reason: .noBaselineOrder)
        // That check accepted an ordered catalog, so the next release is placeable.
        #expect(harness.view?.highWater == logical("u4"))
        #expect(events(harness.accept(try observe(numbered(1...5)))).map(\.kind) == [.newPosition])
    }

    @Test func c8ADriftingPositionIdentityHoldsEveryForwardCandidate() throws {
        var harness = try Harness.baselined(numbered(1...3, units: false))
        // c2 now declares a logical unit: its position is no longer the one that was accepted.
        let drifted = [row("c4", 40), row("c3", 30), row("c2", 20, unit: "u2"), row("c1", 10)]
        let classification = harness.accept(try observe(drifted))
        try expectUnplaced(classification, key: "c4", reason: .positionIdentityChanged)
        // The seen position is updated so the drift is reported once.
        #expect(harness.view?.seen[ScanlatorUTF8(value: "c2")]?.position == logical("u2"))
        #expect(events(harness.accept(try observe(drifted + [row("c5", 50)]))).map(\.kind) == [.newPosition])
    }

    @Test func c8APositionWithMoreThanSixtyFourKeysIsReviewedWithTheFirstSixtyFour() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let crowd = (1...65).map { row("x\($0)", 40, unit: "ux") }
        let classification = harness.accept(try observe(numbered(1...3) + crowd))
        let event = try #require(events(classification).first)
        #expect(events(classification).count == 1)
        #expect(event.kind == .unplacedKey)
        #expect(event.reviewReason == .tooManyCandidates)
        #expect(event.identity == SubscriptionEventIdentity(kind: .exact, value: "x1"))
        #expect(event.candidateKeys == (1...64).map { "x\($0)" })
    }

    @Test func aPositionOfExactlySixtyFourKeysIsStillPublishable() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let crowd = (1...64).map { row("x\($0)", 40, unit: "ux") }
        let published = events(harness.accept(try observe(numbered(1...3) + crowd)))
        #expect(published.map(\.kind) == [.newPosition])
        #expect(published.first?.candidateKeys.count == 64)
    }

    @Test func eachCandidatePositionIsJudgedOnItsOwnOnceTheWholeResponseIsTrusted() throws {
        var harness = try Harness.baselined(numbered([1, 2, 4, 5]))
        let classification = harness.accept(try observe(numbered(1...6)))
        let published = events(classification)
        #expect(published.map(\.kind) == [.unplacedKey, .newPosition])
        #expect(published.map(\.reviewReason) == [.insertedBeforeHighWater, nil])
        #expect(published.map(\.identity.value) == ["c3", "u6"])
    }

    @Test func moreThanSixtyFourKeysUnderAGateFailureKeepTheFirstSixtyFourAndAbsorbEveryKey() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let crowd = (1...65).map { row("x\($0)", 40, unit: "ux") }
        // The accepted high-water position is gone, which holds every forward candidate.
        let classification = harness.accept(try observe(numbered([1, 2]) + crowd))
        let published = events(classification)
        #expect(published.count == 1)
        #expect(published.first?.kind == .unplacedKey)
        #expect(published.first?.reviewReason == .highWaterMissing)
        #expect(published.first?.candidateKeys == (1...64).map { "x\($0)" })
        // The sixty-fifth key is absorbed: seen, never new again, and not a candidate of any event.
        #expect(write(classification)?.seenUpserts[ScanlatorUTF8(value: "x65")] != nil)
        #expect(harness.view?.seen[ScanlatorUTF8(value: "x65")]?.present == true)
    }

    @Test func moreThanSixtyFourKeysBeforeTheHighWaterKeepTheFirstSixtyFourAndAbsorbEveryKey() throws {
        var harness = try Harness.baselined(numbered([1, 2, 4, 5]))
        let crowd = (1...65).map { row("x\($0)", 25, unit: "ux") }
        let classification = harness.accept(try observe(numbered([1, 2, 4, 5]) + crowd))
        let published = events(classification)
        #expect(published.count == 1)
        #expect(published.first?.reviewReason == .insertedBeforeHighWater)
        #expect(published.first?.candidateKeys == (1...64).map { "x\($0)" })
        #expect(write(classification)?.seenUpserts[ScanlatorUTF8(value: "x65")] != nil)
        #expect(harness.accept(try observe(numbered([1, 2, 4, 5]) + crowd)) == .unchanged)
    }

    // MARK: - First failing check wins

    @Test func noReliableOrderOutranksAnIdentityDrift() throws {
        var harness = try Harness.baselined(numbered(1...3, units: false))
        let response = [row("c4", nil), row("c3", 30), row("c2", 20, unit: "u2"), row("c1", 10)]
        try expectUnplaced(harness.accept(try observe(response)), key: "c4", reason: .noReliableOrder)
    }

    @Test func anIdentityDriftOutranksAMissingBaselineOrder() throws {
        var harness = try Harness.baselined(numbered(1...3, units: false).map { row($0.key, nil) })
        let response = [row("c4", 40), row("c3", 30), row("c2", 20, unit: "u2"), row("c1", 10)]
        try expectUnplaced(harness.accept(try observe(response)), key: "c4", reason: .positionIdentityChanged)
    }

    @Test func aMissingBaselineOrderOutranksAMissingHighWaterKey() throws {
        var harness = try Harness.baselined(numbered(1...3).map { row($0.key, nil, unit: $0.logicalUnitID) })
        try expectUnplaced(harness.accept(try observe(numbered([1, 2, 4]))), key: "c4", reason: .noBaselineOrder)
    }

    @Test func aMissingHighWaterOutranksReorderedAnchors() throws {
        var harness = try Harness.baselined(numbered(1...3))
        // c3 is gone and c1 / c2 swapped places.
        let response = [row("c4", 40, unit: "u4"), row("c1", 20, unit: "u1"), row("c2", 10, unit: "u2")]
        try expectUnplaced(harness.accept(try observe(response)), key: "c4", reason: .highWaterMissing)
    }

    @Test func reorderedAnchorsOutrankAKnownPositionAfterTheHighWater() throws {
        var harness = try Harness.baselined(numbered(1...3))
        harness.accept(try observe(numbered([1, 3])))
        // c3 and c1 swapped, and the tombstoned c2 returned after the high-water position.
        let response = [
            row("c4", 50, unit: "u4"), row("c2", 40, unit: "u2"), row("c1", 20, unit: "u1"), row("c3", 10, unit: "u3")
        ]
        try expectUnplaced(harness.accept(try observe(response)), key: "c4", reason: .anchorsReordered)
    }

    @Test func aTombstoneReturningBetweenAnchorsBeforeTheHighWaterIsNotReorderedAnchors() throws {
        var harness = try Harness.baselined(numbered(1...5))
        harness.accept(try observe(numbered([1, 2, 4, 5])))
        let classification = harness.accept(try observe(numbered(1...6)))
        let published = events(classification)
        // Only the genuinely new key is an event; c3 is a returning key, and is neither an anchor nor an arrival.
        #expect(published.map(\.kind) == [.newPosition])
        #expect(published.first?.identity == SubscriptionEventIdentity(kind: .logical, value: "u6"))
        #expect(published.first?.reviewReason == nil)
        #expect(harness.view?.seen[ScanlatorUTF8(value: "c3")]?.present == true)
        #expect(harness.view?.seen[ScanlatorUTF8(value: "c3")]?.rank == 2)
    }

    // MARK: - C9: nothing seen is ever new again

    @Test func c9ATombstonedKeyThatReturnsIsNotNewWhereverItSits() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let gone = harness.accept(try observe(numbered([1, 3])))
        #expect(events(gone).isEmpty)
        #expect(harness.view?.seen[ScanlatorUTF8(value: "c2")]?.present == false)
        #expect(harness.view?.seen[ScanlatorUTF8(value: "c2")]?.rank == nil)

        // Back in place.
        #expect(events(harness.accept(try observe(numbered(1...3)))).isEmpty)
        // Gone again, then back after the high-water position.
        harness.accept(try observe(numbered([1, 3])))
        let after = [row("c2", 40, unit: "u2")] + numbered([1, 3])
        #expect(events(harness.accept(try observe(after))).isEmpty)
    }

    @Test func aTombstonedKeyThatReturnsWithANewRevisionIsARevisionChange() throws {
        var harness = try Harness.baselined(numbered(1...3, revision: "r1"))
        harness.accept(try observe(numbered([1, 3], revision: "r1")))
        // The tombstone keeps its last known revision.
        #expect(harness.view?.seen[ScanlatorUTF8(value: "c2")]?.lastRevision == ScanlatorUTF8(value: "r1"))

        let back = [row("c3", 30, unit: "u3", revision: "r1"), row("c2", 20, unit: "u2", revision: "r2"), row("c1", 10, unit: "u1", revision: "r1")]
        let published = events(harness.accept(try observe(back)))
        #expect(published.map(\.kind) == [.revisionChanged])
        #expect(published.first?.identity == SubscriptionEventIdentity(kind: .exact, value: "c2"))
        #expect(published.first?.previousRevision == "r1")
        #expect(published.first?.targetRevision == "r2")
        #expect(published.first?.qualifier == "r2")
        #expect(published.first?.ordinal == 1)
    }

    @Test func tombstonesOutliveTheCatalogsThatDroppedThem() throws {
        var harness = try Harness.baselined(numbered(1...3))
        harness.accept(try observe(numbered([1, 3])))
        harness.accept(try observe(numbered([1, 3, 4])))
        harness.accept(try observe(numbered([1, 4])))
        #expect(events(harness.accept(try observe(numbered(1...4)))).isEmpty)
        #expect(harness.view?.seen.count == 4)
    }

    // MARK: - C10: volumes, splits, shared orders

    @Test func c10VolumeResetsAndSameNumberSplitsWithDistinctOrdersAreOrdinaryForwardEvents() throws {
        let base = [
            row("v2c1", 30, volume: 2, number: 1),
            row("v1c2", 20, volume: 1, number: 2),
            row("v1c1", 10, volume: 1, number: 1)
        ]
        var harness = try Harness.baselined(base)
        let next = [row("v2c2", 40, volume: 2, number: 2), row("v2c2b", 45, volume: 2, number: 2)] + base
        let classification = harness.accept(try observe(next))
        #expect(events(classification).map(\.kind) == [.newPosition, .newPosition])
        #expect(events(classification).map(\.candidateKeys) == [["v2c2"], ["v2c2b"]])
    }

    @Test func c10AnOrderSharedByTwoPositionsMakesTheResponseUnorderable() throws {
        let base = numbered(1...3, units: false)
        var harness = try Harness.baselined(base)
        let classification = harness.accept(try observe([row("dup", 30)] + base))
        try expectUnplaced(classification, key: "dup", reason: .noReliableOrder)
        #expect(write(classification)?.orderConfidence == .ambiguous)
    }

    @Test func uploadsOfOneUnitMayShareAnOrderButNotDisagreeOnIt() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let agreeing = harness.accept(try observe(numbered(1...3) + [row("alt3", 30, unit: "u3"), row("c4", 40, unit: "u4")]))
        #expect(events(agreeing).map(\.kind) == [.newAlternate, .newPosition])

        let disagreeing = harness.accept(try observe(numbered(1...4) + [row("alt3", 30, unit: "u3"), row("alt3b", 35, unit: "u3"), row("c5", 50, unit: "u5")]))
        #expect(events(disagreeing).map(\.kind) == [.newAlternate, .unplacedKey])
        #expect(events(disagreeing).last?.reviewReason == .noReliableOrder)
    }

    @Test func readingOrderIntegersAreNeverComparedAcrossResponses() throws {
        var harness = try Harness.baselined(numbered(1...5))
        // Every integer is shifted by a thousand; only the order inside the response matters.
        let shifted = numbered(1...6).map { row($0.key, ($0.readingOrder ?? 0) + 1_000, unit: $0.logicalUnitID) }
        let classification = harness.accept(try observe(shifted))
        #expect(events(classification).map(\.kind) == [.newPosition])
        #expect(write(classification)?.seenUpserts[ScanlatorUTF8(value: "c6")]?.rank == 5)
    }

    @Test func chapterNumbersNeverPlaceAKeyAcrossResponses() throws {
        var harness = try Harness.baselined(numbered(1...5))
        // Number 99 would be "newest" by number; the declared order says it sits before the high-water mark.
        let classification = harness.accept(try observe(numbered(1...5) + [row("late99", 25, unit: "u99", number: 99)]))
        try expectUnplaced(classification, key: "late99", reason: .insertedBeforeHighWater)
    }

    // MARK: - C11: revisions

    @Test func c11OnlyTwoNonEmptyDifferentRevisionsOfTheSameKeyAreAChange() throws {
        var harness = try Harness.baselined(numbered(1...3, revision: "r1"))
        let next = [
            row("c3", 30, unit: "u3", revision: "r1"),
            row("c2", 20, unit: "u2", revision: nil),
            row("c1", 10, unit: "u1", revision: "r2")
        ]
        let classification = harness.accept(try observe(next))
        #expect(events(classification) == [
            ClassifiedEvent(
                kind: .revisionChanged,
                identity: SubscriptionEventIdentity(kind: .exact, value: "c1"),
                qualifier: "r2",
                candidateKeys: ["c1"],
                previousRevision: "r1",
                targetRevision: "r2",
                ordinal: 0,
                initialDecision: .undecided,
                reviewReason: nil
            )
        ])
        let accepted = try #require(write(classification))
        #expect(accepted.seenUpserts[ScanlatorUTF8(value: "c1")]?.lastRevision == ScanlatorUTF8(value: "r2"))
        // An unknown revision never erases a known one.
        #expect(accepted.seenUpserts[ScanlatorUTF8(value: "c2")]?.lastRevision == ScanlatorUTF8(value: "r1"))
    }

    @Test func c11ARevisionAppearingForTheFirstTimeIsRecordedSilently() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let learned = harness.accept(try observe(numbered(1...3, revision: "r1")))
        #expect(events(learned).isEmpty)
        #expect(harness.view?.seen[ScanlatorUTF8(value: "c2")]?.lastRevision == ScanlatorUTF8(value: "r1"))
        // From then on it is evidence.
        #expect(events(harness.accept(try observe(numbered(1...3, revision: "r2")))).count == 3)
    }

    @Test func c11AnEmptyOrMissingRevisionIsNotAChange() throws {
        var harness = try Harness.baselined(numbered(1...3, revision: "r1"))
        #expect(events(harness.accept(try observe(numbered(1...3, revision: "")))).isEmpty)
        #expect(events(harness.accept(try observe(numbered(1...3, revision: nil)))).isEmpty)
        #expect(harness.view?.seen[ScanlatorUTF8(value: "c1")]?.lastRevision == ScanlatorUTF8(value: "r1"))
    }

    @Test func c11ADateChangeAloneIsNotARevision() throws {
        var harness = try Harness.baselined(numbered(1...3, revision: "r1", date: { _ in 1_000 }))
        let classification = harness.accept(try observe(numbered(1...3, revision: "r1", date: { _ in 2_000 })))
        #expect(events(classification).isEmpty)
    }

    @Test func revisionsAreComparedOnTheirExactBytes() throws {
        var harness = try Harness.baselined(numbered(1...1, revision: "caf\u{E9}"))
        let classification = harness.accept(try observe(numbered(1...1, revision: "cafe\u{301}")))
        let event = try #require(events(classification).first)
        #expect(event.kind == .revisionChanged)
        #expect(bytes(try #require(event.previousRevision)) == bytes("caf\u{E9}"))
        #expect(bytes(try #require(event.targetRevision)) == bytes("cafe\u{301}"))
    }

    @Test func aRevisionChangeAndANewKeyInOneCheckAreBothReportedArrivalsFirst() throws {
        var harness = try Harness.baselined(numbered(1...3, revision: "r1"))
        let next = numbered(1...3, revision: "r1").map { $0.key == "c1" ? row("c1", 10, unit: "u1", revision: "r2") : $0 }
            + [row("c4", 40, unit: "u4")]
        #expect(events(harness.accept(try observe(next))).map(\.kind) == [.newPosition, .revisionChanged])
    }

    @Test func revisionBulkGuardCollapsesMoreThanOneHundredChangesIntoOneAnomaly() throws {
        var harness = try Harness.baselined(numbered(1...150, revision: "a"))
        let classification = harness.accept(try observe(numbered(1...150, revision: "b")))
        let published = events(classification)
        #expect(published.count == 1)
        #expect(published.first?.kind == .catalogAnomaly)
        #expect(published.first?.reviewReason == .bulkRevisionChange)
        #expect(published.first?.initialDecision == .needsReview)
        // The new revisions are still absorbed.
        #expect(write(classification)?.seenUpserts.values.allSatisfy { $0.lastRevision == ScanlatorUTF8(value: "b") } == true)
    }

    @Test func exactlyOneHundredRevisionChangesAreStillIndividualEvents() throws {
        var harness = try Harness.baselined(numbered(1...150, revision: "a"))
        let next = (1...150).sorted(by: >).map { row("c\($0)", Int64($0) * 10, unit: "u\($0)", revision: $0 <= 100 ? "b" : "a") }
        let published = events(harness.accept(try observe(next)))
        #expect(published.count == 100)
        #expect(published.allSatisfy { $0.kind == .revisionChanged && $0.qualifier == "b" })
    }

    // MARK: - C12: scope changes

    @Test func c12AnyScopeChangeRebaselinesWithoutEventsAndKeepsEveryKeySeen() throws {
        let rotations: [(String, () throws -> CatalogObservation)] = [
            ("epoch", { try observe(numbered(1...4), epoch: "epoch-2") }),
            ("plugin version", { try observe(numbered(1...4), version: "2.0.0") }),
            ("catalog scope", { try observe(numbered(1...4), scope: .visible) })
        ]
        for (name, make) in rotations {
            var harness = try Harness.baselined(numbered(1...3))
            let classification = harness.accept(try make())
            guard case .baseline(let write, let outcome) = classification else {
                Issue.record("\(name): expected a rebaseline, got \(classification)")
                continue
            }
            #expect(outcome == .rebaselined, "\(name)")
            #expect(write.scopeGenerationIncrement, "\(name)")
            // The new key is absorbed, never published.
            #expect(write.seenUpserts[ScanlatorUTF8(value: "c4")] != nil, "\(name)")
            #expect(harness.view?.scopeGeneration == 2, "\(name)")
        }
    }

    @Test func aScopeChangeIsJudgedBeforeTheDigestSoEqualCatalogsStillRebaseline() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let classification = harness.accept(try observe(numbered(1...3), epoch: "epoch-2"))
        guard case .baseline(_, .rebaselined) = classification else {
            Issue.record("Expected a rebaseline, got \(classification)")
            return
        }
    }

    @Test func afterARebaselineOnlyLaterKeysAreNewAndOldTombstonesStayStale() throws {
        var harness = try Harness.baselined(numbered(1...3))
        // c2 is absent at the rebaseline: it becomes a tombstone, not a forgotten key.
        harness.accept(try observe(numbered([1, 3, 4]), epoch: "epoch-2"))
        #expect(harness.view?.seen[ScanlatorUTF8(value: "c2")]?.present == false)
        #expect(harness.view?.highWater == logical("u4"))

        let classification = harness.accept(try observe(numbered(1...5), epoch: "epoch-2"))
        #expect(events(classification).map(\.identity.value) == ["u5"])
    }

    @Test func aRebaselineRecomputesTheOrderEvidenceFromTheNewScope() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let unordered = [row("c4", nil, unit: "u4")] + numbered(1...3).map { row($0.key, nil, unit: $0.logicalUnitID) }
        harness.accept(try observe(unordered, epoch: "epoch-2"))
        #expect(harness.view?.orderConfidence == .ambiguous)
        #expect(harness.view?.highWater == nil)
        #expect(harness.view?.scopeGeneration == 2)
    }

    @Test func scopeRotationsAreComparedOnExactBytes() throws {
        var harness = try Harness.baselined(numbered(1...3), epoch: "caf\u{E9}")
        let classification = harness.accept(try observe(numbered(1...3), epoch: "cafe\u{301}"))
        guard case .baseline(_, .rebaselined) = classification else {
            Issue.record("Expected a rebaseline, got \(classification)")
            return
        }
    }

    @Test func aPluginVersionThatDiffersOnlyInByteFormRebaselines() throws {
        var harness = Harness()
        harness.accept(try observe(numbered(1...3), version: "caf\u{E9}"))
        let classification = harness.accept(try observe(numbered(1...3), version: "cafe\u{301}"))
        guard case .baseline(let write, .rebaselined) = classification else {
            Issue.record("Expected a rebaseline, got \(classification)")
            return
        }
        #expect(write.scopeGenerationIncrement)
        #expect(harness.view?.scopeGeneration == 2)
    }

    // MARK: - C13: empty catalogs

    @Test func c13ACompleteEmptyCatalogAfterANonEmptyOneIsAnAnomalyThatLeavesTheBaselineAlone() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let before = harness.view
        let empty = try observe([])
        let classification = harness.accept(empty)

        #expect(classification == .anomaly(events: [
            ClassifiedEvent(
                kind: .catalogAnomaly,
                identity: SubscriptionEventIdentity(kind: .catalog, value: empty.catalogDigest),
                qualifier: nil,
                candidateKeys: [],
                previousRevision: nil,
                targetRevision: nil,
                ordinal: 0,
                initialDecision: .needsReview,
                reviewReason: .emptyAfterNonempty
            )
        ]))
        #expect(harness.view?.catalogDigest == before?.catalogDigest)
        #expect(harness.view?.seen == before?.seen)
        #expect(harness.view?.revision == before?.revision)
        // The old catalog coming back is simply unchanged: nothing was deleted or reset.
        #expect(harness.accept(try observe(numbered(1...3))) == .unchanged)
    }

    @Test func anEmptyCatalogWithoutAComparableBaselineIsRejected() throws {
        let empty = try observe([])
        #expect(SubscriptionCatalogClassifier.classify(observation: empty, baseline: nil) == .rejected(.emptyCatalog))

        let baselined = try Harness.baselined(numbered(1...3))
        let otherScope = try observe([], epoch: "epoch-2")
        #expect(SubscriptionCatalogClassifier.classify(observation: otherScope, baseline: baselined.view) == .rejected(.emptyCatalog))

        let partial = try observe([], completeness: .partial)
        #expect(SubscriptionCatalogClassifier.classify(observation: partial, baseline: baselined.view) == .rejected(.incompleteCatalog))
    }

    // MARK: - C14: bulk arrival

    @Test func c14OneHundredFiftyNewPositionsAreOneBulkAnomalyAndAllKeysAreAbsorbed() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let classification = harness.accept(try observe(numbered(1...153)))
        let published = events(classification)
        #expect(published.count == 1)
        #expect(published.first?.kind == .catalogAnomaly)
        #expect(published.first?.reviewReason == .bulkArrival)
        #expect(published.first?.candidateKeys.isEmpty == true)
        #expect(write(classification)?.seenUpserts.count == 153)
        #expect(events(harness.accept(try observe(numbered(1...153)))).isEmpty)
    }

    @Test func theBulkLimitIsOneHundredNewKeysInclusive() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let atLimit = events(harness.accept(try observe(numbered(1...103))))
        #expect(atLimit.count == 100)
        #expect(atLimit.allSatisfy { $0.kind == .newPosition })
        #expect(atLimit.map(\.ordinal) == Array(3..<103))

        var overLimit = try Harness.baselined(numbered(1...3))
        let published = events(overLimit.accept(try observe(numbered(1...104))))
        #expect(published.map(\.reviewReason) == [.bulkArrival])
    }

    @Test func aBulkArrivalOfAlternatesIsAlsoOneAnomalyWithNoPerKeyEvents() throws {
        var harness = try Harness.baselined(numbered(1...3))
        let alternates = (0..<101).map { row("alt\($0)", 10, unit: "u1") }
        let published = events(harness.accept(try observe(numbered(1...3) + alternates)))
        #expect(published.map(\.kind) == [.catalogAnomaly])
        #expect(published.first?.reviewReason == .bulkArrival)
    }

    @Test func aBulkArrivalStillReportsItsAnomalyOnceWhenRevisionsAlsoMoveInBulk() throws {
        var harness = try Harness.baselined(numbered(1...120, revision: "a"))
        let next = numbered(1...250, revision: "b")
        let published = events(harness.accept(try observe(next)))
        #expect(published.map(\.kind) == [.catalogAnomaly])
        #expect(published.first?.reviewReason == .bulkArrival)
    }

    // MARK: - Byte-exact identity

    @Test func chapterKeysThatDifferOnlyByUnicodeNormalizationAreDifferentKeys() throws {
        let precomposed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(precomposed == decomposed)
        var harness = try Harness.baselined([row(precomposed, 10)])
        let classification = harness.accept(try observe([row(decomposed, 20), row(precomposed, 10)]))

        let published = events(classification)
        #expect(published.map(\.kind) == [.newPosition])
        let identity = try #require(published.first?.identity)
        #expect(bytes(identity.value) == bytes(decomposed))
        #expect(harness.view?.seen.count == 2)
    }

    @Test func logicalUnitsThatDifferOnlyByNormalizationAreDifferentPositions() throws {
        var harness = try Harness.baselined([row("k1", 10, unit: "u\u{E9}")])
        let classification = harness.accept(try observe([row("k2", 20, unit: "ue\u{301}"), row("k1", 10, unit: "u\u{E9}")]))
        let event = try #require(events(classification).first)
        #expect(event.kind == .newPosition)
        #expect(event.identity.kind == .logical)
        #expect(bytes(event.identity.value) == bytes("ue\u{301}"))
        #expect(write(classification)?.highWater == logical("ue\u{301}"))
    }

    @Test func positionIdentifiersExposeTheirTagAndExactBytes() {
        #expect(SubscriptionPositionID(.logical(ScanlatorUTF8(value: "u1"))) == logical("u1"))
        #expect(logical("same").kind == "logical")
        #expect(exact("same").kind == "exact")
        #expect(logical("same") != exact("same"))
        #expect(bytes(logical("e\u{301}").value) == bytes("e\u{301}"))
        #expect(logical("\u{E9}") != logical("e\u{301}"))
    }

    // MARK: - Fixed codes

    @Test func storedCodesMatchTheLedgerCheckLists() {
        #expect(SubscriptionEventKind.allCases.map(\.rawValue) == [
            "newPosition", "newAlternate", "revisionChanged", "unplacedKey", "catalogAnomaly", "backfill", "window"
        ])
        #expect(SubscriptionIdentityKind.allCases.map(\.rawValue) == ["logical", "exact", "catalog"])
        #expect(SubscriptionDecision.allCases.map(\.rawValue) == [
            "undecided", "pending", "awaitingEdition", "needsChoice", "needsReview", "locked",
            "enqueued", "satisfied", "recorded", "suppressed", "blockedDamaged",
            "dismissed", "revoked", "superseded"
        ])
        #expect(SubscriptionDecision.allCases.filter(\.isOpen).map(\.rawValue) == [
            "undecided", "pending", "awaitingEdition", "needsChoice", "needsReview", "locked"
        ])
        #expect(SubscriptionCheckOutcome.allCases.map(\.rawValue) == [
            "baselineEstablished", "rebaselined", "advanced", "unchanged",
            "incompleteCatalog", "unknownScope", "emptyCatalog", "oversizedCatalog", "unsupportedKind",
            "sourceChanged", "superseded", "paused", "disabled", "seriesNotSaved", "selectionUnreadable", "fetchFailed"
        ])
        #expect(SubscriptionReviewReason.allCases.map(\.rawValue) == [
            "noReliableOrder", "noBaselineOrder", "highWaterMissing", "anchorsReordered", "positionIdentityChanged",
            "knownPositionAfterHighWater", "insertedBeforeHighWater", "olderThanBaseline", "tooManyCandidates",
            "bulkArrival", "bulkRevisionChange", "emptyAfterNonempty",
            "selectionUnresolved", "numberOnlyReadState", "windowOrderAmbiguous"
        ])
    }

    @Test func pendingReasonsMatchTheLedgerCheckList() {
        #expect(SubscriptionPendingReason.allCases.map(\.rawValue) == ["runCap", "queueCap", "quota"])
    }

    @Test func storedCodesRoundTripThroughJSONAsTheirRawValues() throws {
        func roundTrip<Code: Codable & Equatable & RawRepresentable>(_ codes: [Code]) throws where Code.RawValue == String {
            for code in codes {
                let data = try JSONEncoder().encode(code)
                #expect(String(bytes: data, encoding: .utf8) == "\"\(code.rawValue)\"")
                #expect(try JSONDecoder().decode(Code.self, from: data) == code)
            }
        }
        try roundTrip(SubscriptionCheckOutcome.allCases)
        try roundTrip(SubscriptionReviewReason.allCases)
        try roundTrip(SubscriptionPendingReason.allCases)
        try roundTrip(SubscriptionEventKind.allCases)
        try roundTrip(SubscriptionIdentityKind.allCases)
        try roundTrip(SubscriptionDecision.allCases)
    }

    // MARK: - Helpers

    /// Exactly one event, an `unplacedKey` for `key` held for `reason`.
    private func expectUnplaced(
        _ classification: CatalogClassification,
        key: String,
        reason: SubscriptionReviewReason,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let published = events(classification)
        #expect(published.count == 1, sourceLocation: sourceLocation)
        let event = try #require(published.first, sourceLocation: sourceLocation)
        #expect(event.kind == .unplacedKey, sourceLocation: sourceLocation)
        #expect(event.identity == SubscriptionEventIdentity(kind: .exact, value: key), sourceLocation: sourceLocation)
        #expect(event.candidateKeys == [key], sourceLocation: sourceLocation)
        #expect(event.initialDecision == .needsReview, sourceLocation: sourceLocation)
        #expect(event.reviewReason == reason, sourceLocation: sourceLocation)
        #expect(write(classification) != nil, sourceLocation: sourceLocation)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
