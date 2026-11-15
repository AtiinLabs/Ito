import Foundation
import ito_runner

/// Turns one catalog observation and the accepted baseline into a classification: no database, network or
/// clock. Every identity comparison is on exact UTF-8 bytes.
///
/// The classifier never counts, never reads a number-only read state and never compares a raw
/// `readingOrder` across two responses: the order of one response is reduced to per-response ranks, and
/// only ranks of the accepted snapshot are compared with ranks of the current one for the same positions.
nonisolated enum SubscriptionCatalogClassifier {
    /// More arrivals or revision changes than this in one check are a catalog anomaly, not per-key events.
    static let bulkLimit = 100
    /// The most candidate keys one event holds. A position with more keys keeps the first ones in the event,
    /// whatever reason holds it (a failed gate, `insertedBeforeHighWater` or `tooManyCandidates`); the rest are
    /// still absorbed into the seen set, so they are never new again, and are not approvable.
    static let candidateKeyLimit = 64

    /// Strictly older: an equal date is not evidence against a release.
    private static func isOlder(_ date: Double?, than floor: Double) -> Bool {
        date.map { $0 < floor } ?? false
    }

    /// - Parameter baseline: nil while the subscription waits for its first baseline.
    static func classify(observation: CatalogObservation, baseline: SubscriptionBaselineView?) -> CatalogClassification {
        // A. Admissibility, in this order.
        guard observation.media.mediaKind == .manga || observation.media.mediaKind == .novel else {
            return .rejected(.unsupportedKind)
        }
        guard observation.fingerprint.catalogScope != .unknown else { return .rejected(.unknownScope) }
        guard observation.completeness == .complete else { return .rejected(.incompleteCatalog) }

        let sameScope = baseline.map { $0.fingerprint == observation.fingerprint } ?? false
        guard !observation.rows.isEmpty else {
            // An empty list is an anomaly only against an established baseline of the same scope. It never
            // deletes, resets or advances anything.
            guard sameScope else { return .rejected(.emptyCatalog) }
            return .anomaly(events: [anomaly(.emptyAfterNonempty, digest: observation.catalogDigest)])
        }
        // The runner guarantees unique keys; a violation proves nothing about the catalog.
        guard let analysis = CatalogAnalysis(rows: observation.rows) else { return .rejected(.incompleteCatalog) }

        // C. No baseline: absorb everything, raise nothing.
        guard let baseline else {
            let write = baselineWrite(observation, analysis, baseline: nil, scopeChanged: false)
            return .baseline(write, outcome: .baselineEstablished)
        }
        // D. A different scope re-baselines. The seen set stays cumulative, so no key becomes fresh.
        guard sameScope else {
            let write = baselineWrite(observation, analysis, baseline: baseline, scopeChanged: true)
            return .baseline(write, outcome: .rebaselined)
        }
        // E. Same scope and same catalog.
        if ScanlatorUTF8.bytesEqual(baseline.catalogDigest, observation.catalogDigest) { return .unchanged }

        return advance(observation, analysis, baseline: baseline)
    }

    // MARK: - Same scope, changed catalog

    private static func advance(
        _ observation: CatalogObservation,
        _ analysis: CatalogAnalysis,
        baseline: SubscriptionBaselineView
    ) -> CatalogClassification {
        let rows = observation.rows

        // 1-3. Identity drift, new keys, and every position ever seen (tombstones included).
        var drift = false
        var newIndices: [Int] = []
        for index in rows.indices {
            if let known = baseline.seen[ScanlatorUTF8(value: rows[index].facts.key)] {
                if known.position != analysis.rowPositions[index] { drift = true }
            } else {
                newIndices.append(index)
            }
        }
        let knownPositions = Set(baseline.seen.values.map(\.position))

        // 4-8. Arrivals. 9. Revisions.
        let bulkArrival = newIndices.count > bulkLimit
        var events: [ClassifiedEvent]
        if bulkArrival {
            events = [anomaly(.bulkArrival, digest: observation.catalogDigest)]
        } else {
            events = arrivalEvents(
                rows: rows,
                newIndices: newIndices,
                analysis: analysis,
                baseline: baseline,
                knownPositions: knownPositions,
                drift: drift
            )
        }
        let revisions = revisionEvents(rows: rows, analysis: analysis, baseline: baseline)
        if revisions.count > bulkLimit {
            // One anomaly per observation: its identity is the observed digest, and a bulk arrival already asks
            // for review of this very catalog.
            if !bulkArrival { events.append(anomaly(.bulkRevisionChange, digest: observation.catalogDigest)) }
        } else {
            events += revisions
        }

        // 10. Accept the observation.
        let write = baselineWrite(observation, analysis, baseline: baseline, scopeChanged: false)
        return .advance(write, events: events)
    }

    private static func arrivalEvents(
        rows: [CatalogRowEvidence],
        newIndices: [Int],
        analysis: CatalogAnalysis,
        baseline: SubscriptionBaselineView,
        knownPositions: Set<SubscriptionPositionID>,
        drift: Bool
    ) -> [ClassifiedEvent] {
        var alternates: [ClassifiedEvent] = []
        var forwardOrder: [SubscriptionPositionID] = []
        var forwardRows: [SubscriptionPositionID: [Int]] = [:]
        for index in newIndices {
            let position = analysis.rowPositions[index]
            if knownPositions.contains(position) {
                // A known position never publishes again: the new key is one more edition of it.
                alternates.append(ClassifiedEvent(
                    kind: .newAlternate,
                    identity: SubscriptionEventIdentity(kind: .exact, value: rows[index].facts.key),
                    qualifier: nil,
                    candidateKeys: [rows[index].facts.key],
                    previousRevision: nil,
                    targetRevision: nil,
                    ordinal: analysis.ordinal(of: position),
                    initialDecision: .recorded,
                    reviewReason: nil
                ))
            } else {
                if forwardRows[position] == nil { forwardOrder.append(position) }
                forwardRows[position, default: []].append(index)
            }
        }
        guard !forwardOrder.isEmpty else { return alternates }

        let gate = forwardGate(analysis: analysis, baseline: baseline, knownPositions: knownPositions, drift: drift)
        // The date floor is the newest source date ever accepted: source dates against source dates only.
        let dateFloor = baseline.maxDateUpdated
        let positionEvents = forwardOrder
            .sorted { analysis.ordinal(of: $0) < analysis.ordinal(of: $1) }
            .map { position -> ClassifiedEvent in
                let indices = forwardRows[position] ?? []
                let keys = indices.map { rows[$0].facts.key }
                let ordinal = analysis.ordinal(of: position)
                let reason: SubscriptionReviewReason?
                switch gate {
                case .failed(let failure):
                    reason = failure
                case .open(let highWaterRank):
                    if let rank = analysis.rank[position], rank < highWaterRank {
                        reason = .insertedBeforeHighWater
                    } else if let floor = dateFloor, indices.contains(where: { isOlder(rows[$0].dateUpdated, than: floor) }) {
                        // A date never proves a release is new; an older one proves it is not.
                        reason = .olderThanBaseline
                    } else if indices.count > candidateKeyLimit {
                        reason = .tooManyCandidates
                    } else {
                        reason = nil
                    }
                }
                if let reason {
                    return ClassifiedEvent(
                        kind: .unplacedKey,
                        identity: SubscriptionEventIdentity(kind: .exact, value: keys[0]),
                        qualifier: nil,
                        candidateKeys: Array(keys.prefix(candidateKeyLimit)),
                        previousRevision: nil,
                        targetRevision: nil,
                        ordinal: ordinal,
                        initialDecision: .needsReview,
                        reviewReason: reason
                    )
                }
                return ClassifiedEvent(
                    kind: .newPosition,
                    identity: SubscriptionEventIdentity(kind: position.identityKind, value: position.value),
                    qualifier: nil,
                    candidateKeys: keys,
                    previousRevision: nil,
                    targetRevision: nil,
                    ordinal: ordinal,
                    initialDecision: .undecided,
                    reviewReason: nil
                )
            }
        return alternates + positionEvents
    }

    private enum ForwardGate {
        case failed(SubscriptionReviewReason)
        /// The rank of the accepted high-water position in the current order.
        case open(highWaterRank: Int)
    }

    /// The checks that apply to the whole observation: the first failure holds every forward candidate.
    private static func forwardGate(
        analysis: CatalogAnalysis,
        baseline: SubscriptionBaselineView,
        knownPositions: Set<SubscriptionPositionID>,
        drift: Bool
    ) -> ForwardGate {
        guard analysis.isConfident else { return .failed(.noReliableOrder) }
        guard !drift else { return .failed(.positionIdentityChanged) }
        guard baseline.orderConfidence == .confident, let highWater = baseline.highWater else {
            return .failed(.noBaselineOrder)
        }
        guard let highWaterRank = analysis.rank[highWater] else { return .failed(.highWaterMissing) }

        // The surviving anchors: positions the accepted snapshot ranked and the current response still lists.
        // Taken in the current order, their accepted ranks must strictly increase.
        var acceptedRanks: [SubscriptionPositionID: Int] = [:]
        for seen in baseline.seen.values where seen.present {
            guard let rank = seen.rank else { continue }
            if let existing = acceptedRanks[seen.position], existing != rank { return .failed(.anchorsReordered) }
            acceptedRanks[seen.position] = rank
        }
        var previous: Int?
        for position in analysis.orderedPositions {
            guard let rank = acceptedRanks[position] else { continue }
            if let previous, rank <= previous { return .failed(.anchorsReordered) }
            previous = rank
        }

        // Nothing already seen, present or tombstoned, may sit after the high-water position.
        if knownPositions.contains(where: { (analysis.rank[$0] ?? -1) > highWaterRank }) {
            return .failed(.knownPositionAfterHighWater)
        }
        return .open(highWaterRank: highWaterRank)
    }

    /// A revision event needs a non-empty revision on both sides of the same key. A new revision after none
    /// is recorded silently by the baseline write, and a missing one never changes anything.
    private static func revisionEvents(
        rows: [CatalogRowEvidence],
        analysis: CatalogAnalysis,
        baseline: SubscriptionBaselineView
    ) -> [ClassifiedEvent] {
        rows.indices.compactMap { index -> ClassifiedEvent? in
            let key = rows[index].facts.key
            guard let old = baseline.seen[ScanlatorUTF8(value: key)]?.lastRevision,
                  let new = rows[index].revision,
                  old != new else { return nil }
            return ClassifiedEvent(
                kind: .revisionChanged,
                identity: SubscriptionEventIdentity(kind: .exact, value: key),
                qualifier: new.value,
                candidateKeys: [key],
                previousRevision: old.value,
                targetRevision: new.value,
                ordinal: analysis.ordinal(of: analysis.rowPositions[index]),
                initialDecision: .undecided,
                reviewReason: nil
            )
        }
    }

    // MARK: - Baseline write

    private static func baselineWrite(
        _ observation: CatalogObservation,
        _ analysis: CatalogAnalysis,
        baseline: SubscriptionBaselineView?,
        scopeChanged: Bool
    ) -> BaselineWrite {
        var upserts: [ScanlatorUTF8: SubscriptionBaselineView.SeenKey] = [:]
        for (index, row) in observation.rows.enumerated() {
            let key = ScanlatorUTF8(value: row.facts.key)
            let position = analysis.rowPositions[index]
            upserts[key] = SubscriptionBaselineView.SeenKey(
                position: position,
                // An unknown revision never erases a known one.
                lastRevision: row.revision ?? baseline?.seen[key]?.lastRevision,
                present: true,
                rank: analysis.rank[position]
            )
        }
        return BaselineWrite(
            fingerprint: observation.fingerprint,
            scopeGenerationIncrement: scopeChanged,
            catalogDigest: observation.catalogDigest,
            rowCount: observation.rows.count,
            orderConfidence: analysis.isConfident ? .confident : .ambiguous,
            highWater: analysis.isConfident ? analysis.orderedPositions.last : nil,
            maxDateUpdated: [baseline?.maxDateUpdated, observation.rows.compactMap(\.dateUpdated).max()]
                .compactMap { $0 }
                .max(),
            seenUpserts: upserts
        )
    }

    private static func anomaly(_ reason: SubscriptionReviewReason, digest: String) -> ClassifiedEvent {
        ClassifiedEvent(
            kind: .catalogAnomaly,
            identity: SubscriptionEventIdentity(kind: .catalog, value: digest),
            qualifier: nil,
            candidateKeys: [],
            previousRevision: nil,
            targetRevision: nil,
            ordinal: 0,
            initialDecision: .needsReview,
            reviewReason: reason
        )
    }
}

/// The positions of one response and their order within it.
private nonisolated struct CatalogAnalysis {
    /// The position of each row, by the row's index.
    let rowPositions: [SubscriptionPositionID]
    /// Positions earliest first. Meaningful only when `isConfident`: otherwise it is the source's own sequence.
    let orderedPositions: [SubscriptionPositionID]
    /// Every row declares a reading order and the order is confident.
    let isConfident: Bool
    /// Each position's index in the reading order; empty unless `isConfident`. Never compared across responses.
    let rank: [SubscriptionPositionID: Int]
    private let sourceIndex: [SubscriptionPositionID: Int]

    /// Nil when two rows share an exact key.
    init?(rows: [CatalogRowEvidence]) {
        var keys = Set<ScanlatorUTF8>()
        for row in rows {
            if !keys.insert(ScanlatorUTF8(value: row.facts.key)).inserted { return nil }
        }

        let facts = rows.map(\.facts)
        let resolved = EditionPositionResolver.positions(of: facts)
        let positions = resolved.map { SubscriptionPositionID($0.key) }
        let order = ChapterReadingOrder.order(positions: resolved.map { $0.members.map { facts[$0] } })

        rowPositions = facts.map { SubscriptionPositionID(EditionPositionKey($0)) }
        orderedPositions = order.order.map { positions[$0] }
        let confident = facts.allSatisfy { $0.readingOrder != nil } && order.confidence == .confident
        isConfident = confident
        rank = confident
            ? Dictionary(uniqueKeysWithValues: order.order.enumerated().map { (positions[$0.element], $0.offset) })
            : [:]
        sourceIndex = Dictionary(uniqueKeysWithValues: positions.enumerated().map { ($0.element, $0.offset) })
    }

    /// A stable sort key for events: reading rank when known, source order otherwise.
    func ordinal(of position: SubscriptionPositionID) -> Int {
        rank[position] ?? sourceIndex[position] ?? 0
    }
}
