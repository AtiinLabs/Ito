import CryptoKit
import Foundation

/// What a Maintain Next N subscription reads from the store: the exact read state of its series.
nonisolated struct SubscriptionReadState: Sendable, Equatable {
    /// Exact keys of chapters marked read.
    var readKeys: Set<ScanlatorUTF8> = []
    /// The exact key of the last chapter read.
    var lastReadKey: String?
    /// Whether the series has read markers that carry a chapter number only.
    var hasNumberOnlyMarkers = false
}

/// Turns the accepted catalog, the exact read state and the window size into the events of a Maintain Next N
/// subscription. It reuses the manual `next` window of `DownloadPresetResolver`: saved and queued positions count
/// toward N, and nothing outside the window is ever removed. Pure: no database, no clock.
nonisolated enum SubscriptionWindowPlanner {
    /// The event identity of a review that is about the whole window rather than one position.
    static let readStateIdentity = "readState"
    static let orderIdentity = "order"
    static let noAnchor = "none"

    /// SHA-256 hex of the exact anchor key, or `"none"`. A window position that was cancelled under one anchor stays
    /// cancelled until the anchor moves, because the event identity includes this qualifier.
    static func anchorQualifier(_ anchorKey: String?) -> String {
        guard let anchorKey else { return noAnchor }
        return SHA256.hash(data: Data(anchorKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The anchor of a window: the last chapter read, when the catalog still lists it.
    static func anchorKey(in rows: [CatalogRowEvidence], readState: SubscriptionReadState) -> String? {
        guard let last = readState.lastReadKey else { return nil }
        let target = ScanlatorUTF8(value: last)
        return rows.contains { ScanlatorUTF8(value: $0.facts.key) == target } ? last : nil
    }

    static func events(
        rows: [CatalogRowEvidence],
        selection: EditionSelection,
        windowSize: Int,
        readState: SubscriptionReadState,
        stored: [ScanlatorUTF8: StoredEditionState]
    ) -> [ClassifiedEvent] {
        // The anchor is a position the catalog still lists. Anything else is no anchor.
        let anchor = anchorKey(in: rows, readState: readState)
        let qualifier = anchorQualifier(anchor)

        func review(_ identity: String, _ reason: SubscriptionReviewReason) -> [ClassifiedEvent] {
            [ClassifiedEvent(
                kind: .window,
                identity: SubscriptionEventIdentity(kind: .catalog, value: identity),
                qualifier: qualifier,
                candidateKeys: [],
                previousRevision: nil,
                targetRevision: nil,
                ordinal: 0,
                initialDecision: .needsReview,
                reviewReason: reason
            )]
        }

        // A read state that is only chapter numbers says nothing about which exact rows were read.
        if readState.readKeys.isEmpty, anchor == nil, readState.hasNumberOnlyMarkers {
            return review(readStateIdentity, .numberOnlyReadState)
        }
        guard let count = DownloadPositionCount(windowSize) else { return [] }

        let planRows = rows.map { row in
            DownloadPlanRow(
                facts: row.facts,
                isRead: readState.readKeys.contains(ScanlatorUTF8(value: row.facts.key)),
                stored: stored[ScanlatorUTF8(value: row.facts.key)] ?? StoredEditionState.none
            )
        }
        let plan = DownloadPresetResolver.plan(
            rows: planRows, window: .next(count), selection: selection, anchorKey: anchor
        )
        if plan.issues.contains(.orderingAmbiguous) || plan.issues.contains(.anchorNotInSelection) {
            return review(orderIdentity, .windowOrderAmbiguous)
        }

        var order: [EditionPositionKey] = []
        var keys: [EditionPositionKey: [String]] = [:]
        for index in plan.toQueue {
            let facts = planRows[index].facts
            let position = EditionPositionKey(facts)
            if keys[position] == nil { order.append(position) }
            keys[position, default: []].append(facts.key)
        }
        return order.enumerated().map { ordinal, position in
            let identity: SubscriptionEventIdentity
            switch SubscriptionPositionID(position) {
            case .logical(let id): identity = SubscriptionEventIdentity(kind: .logical, value: id.value)
            case .exact(let id): identity = SubscriptionEventIdentity(kind: .exact, value: id.value)
            }
            return ClassifiedEvent(
                kind: .window,
                identity: identity,
                qualifier: qualifier,
                candidateKeys: Array((keys[position] ?? []).prefix(SubscriptionCatalogClassifier.candidateKeyLimit)),
                previousRevision: nil,
                targetRevision: nil,
                ordinal: ordinal,
                initialDecision: .undecided,
                reviewReason: nil
            )
        }
    }
}
