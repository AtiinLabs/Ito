import CryptoKit
import Foundation
import ito_runner

// Immutable evidence and result types for the subscription catalog classifier. They are plain values:
// no database, network or clock. Every identifier a later ledger compares (chapter keys, logical unit IDs,
// revisions, source epochs) is compared on its exact UTF-8 bytes, never by Unicode canonical equivalence.

extension ScanlatorUTF8 {
    /// Whether two strings hold the same UTF-8 bytes. `String ==` would equate canonically equivalent text.
    nonisolated static func bytesEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}

// MARK: - Fixed reason codes

/// What one catalog check concluded. Raw values are the stored codes: they carry no user content. It is an
/// `Error` so an observation that cannot be made is a `Result` failure.
nonisolated enum SubscriptionCheckOutcome: String, Error, Codable, CaseIterable, Sendable {
    case baselineEstablished, rebaselined, advanced, unchanged
    case incompleteCatalog, unknownScope, emptyCatalog, oversizedCatalog, unsupportedKind
    case sourceChanged, superseded, paused, disabled, seriesNotSaved, selectionUnreadable, fetchFailed
}

/// Why an event needs a person to look at it instead of being decided automatically.
nonisolated enum SubscriptionReviewReason: String, Codable, CaseIterable, Sendable {
    case noReliableOrder, noBaselineOrder, highWaterMissing, anchorsReordered, positionIdentityChanged
    case knownPositionAfterHighWater, insertedBeforeHighWater, olderThanBaseline, tooManyCandidates
    case bulkArrival, bulkRevisionChange, emptyAfterNonempty
    case selectionUnresolved, numberOnlyReadState, windowOrderAmbiguous
}

nonisolated enum SubscriptionEventKind: String, Codable, CaseIterable, Sendable {
    case newPosition, newAlternate, revisionChanged, unplacedKey, catalogAnomaly, backfill, window
}

nonisolated enum SubscriptionIdentityKind: String, Codable, CaseIterable, Sendable {
    case logical, exact, catalog
}

nonisolated enum SubscriptionDecision: String, Codable, CaseIterable, Sendable {
    case undecided, pending, awaitingEdition, needsChoice, needsReview, locked
    case enqueued, satisfied, recorded, suppressed, blockedDamaged
    case dismissed, revoked, superseded

    /// Open decisions still await a decision or a user; the rest are terminal.
    var isOpen: Bool {
        switch self {
        case .undecided, .pending, .awaitingEdition, .needsChoice, .needsReview, .locked: true
        case .enqueued, .satisfied, .recorded, .suppressed, .blockedDamaged, .dismissed, .revoked, .superseded: false
        }
    }
}

/// Why a decision waits for admission capacity instead of enqueueing now.
nonisolated enum SubscriptionPendingReason: String, Codable, CaseIterable, Sendable {
    case runCap, queueCap, quota
}

// MARK: - Positions

/// The persisted form of `EditionPositionKey`: a kind tag plus the exact bytes of the ID.
nonisolated enum SubscriptionPositionID: Hashable, Sendable {
    case logical(ScanlatorUTF8)
    case exact(ScanlatorUTF8)

    init(_ key: EditionPositionKey) {
        switch key {
        case .logical(let unit): self = .logical(unit)
        case .exact(let chapterKey): self = .exact(chapterKey)
        }
    }

    /// `"logical"` or `"exact"`.
    var kind: String { identityKind.rawValue }

    var identityKind: SubscriptionIdentityKind {
        switch self {
        case .logical: .logical
        case .exact: .exact
        }
    }

    var value: String {
        switch self {
        case .logical(let id), .exact(let id): id.value
        }
    }
}

// MARK: - Observation

/// One catalog row as the classifier sees it: the ordering facts, the revision and the upload date.
nonisolated struct CatalogRowEvidence: Sendable, Equatable {
    let facts: ChapterFacts
    /// The source's content token. Absent when the source gave none or an empty one.
    let revision: ScanlatorUTF8?
    /// Seconds since 1970-01-01 UTC; finite values only. Evidence of age, never of order.
    let dateUpdated: Double?

    init(facts: ChapterFacts, revision: ScanlatorUTF8?, dateUpdated: Double?) {
        self.facts = facts
        self.revision = revision
        self.dateUpdated = dateUpdated
    }

    /// An empty revision identifies nothing, and a non-finite date is not a date.
    init(chapter: Chapter) {
        self.init(
            facts: ChapterFacts(chapter),
            revision: chapter.revision.flatMap { $0.isEmpty ? nil : ScanlatorUTF8(value: $0) },
            dateUpdated: chapter.dateUpdated.flatMap { $0.isFinite ? $0 : nil }
        )
    }
}

/// Everything that makes two catalog observations comparable. A change in any field re-baselines.
nonisolated struct SubscriptionScopeFingerprint: Equatable, Sendable {
    static let mediaUpdateAcquisition = "mediaUpdate"
    static let supportedChapterABI = 3

    let acquisition: String
    let sourceEpoch: String
    /// `InstalledPlugin.info.version`, captured together with the runner that produced the catalog.
    let pluginVersion: String
    let chapterABI: Int
    let catalogScope: LibraryCatalogScope

    static func == (lhs: Self, rhs: Self) -> Bool {
        ScanlatorUTF8.bytesEqual(lhs.acquisition, rhs.acquisition)
            && ScanlatorUTF8.bytesEqual(lhs.sourceEpoch, rhs.sourceEpoch)
            && ScanlatorUTF8.bytesEqual(lhs.pluginVersion, rhs.pluginVersion)
            && lhs.chapterABI == rhs.chapterABI
            && lhs.catalogScope == rhs.catalogScope
    }
}

/// One successful chapter-list response, reduced to what classification and a later job freeze need.
nonisolated struct CatalogObservation: Sendable {
    let media: MediaIdentity
    let fingerprint: SubscriptionScopeFingerprint
    let completeness: LibraryCatalogCompleteness
    /// Source order. Exact keys are unique: the runner validates them.
    let rows: [CatalogRowEvidence]
    /// The same rows in the same order, frozen into jobs.
    let chapters: [Chapter]
    /// `JSONEncoder().encode(entry)` as returned, the same snapshot a manual batch freezes.
    let entrySnapshot: Data
    /// SHA-256 hex of `JSONEncoder(.sortedKeys).encode(chapters)`.
    let catalogDigest: String

    /// Reduces `entry` to an observation, or says why it cannot be one. Anime, an entry of another kind than
    /// `media`, and a missing chapter list are not observable; a catalog over `CatalogLimits` is not stored.
    static func make(
        media: MediaIdentity,
        entry: MediaEntry,
        pluginVersion: String,
        sourceEpoch: String
    ) -> Result<CatalogObservation, SubscriptionCheckOutcome> {
        guard media.mediaKind == .manga || media.mediaKind == .novel, entry.kind == media.mediaKind else {
            return .failure(.unsupportedKind)
        }
        let listing: (chapters: [Chapter]?, catalog: ChapterCatalog?)
        switch entry {
        case .manga(let manga): listing = (manga.chapters, manga.catalog)
        case .novel(let novel): listing = (novel.chapters, novel.catalog)
        case .anime: return .failure(.unsupportedKind)
        }
        guard let chapters = listing.chapters else { return .failure(.incompleteCatalog) }
        guard chapters.count <= CatalogLimits.chapters else { return .failure(.oversizedCatalog) }

        let snapshot: Data
        let digestInput: Data
        do {
            snapshot = try JSONEncoder().encode(entry)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            digestInput = try encoder.encode(chapters)
        } catch {
            return .failure(.fetchFailed)
        }
        guard snapshot.count <= CatalogLimits.responseBytes else { return .failure(.oversizedCatalog) }

        let description = LibraryCatalogDescription(listing.catalog)
        return .success(CatalogObservation(
            media: media,
            fingerprint: SubscriptionScopeFingerprint(
                acquisition: SubscriptionScopeFingerprint.mediaUpdateAcquisition,
                sourceEpoch: sourceEpoch,
                pluginVersion: pluginVersion,
                chapterABI: SubscriptionScopeFingerprint.supportedChapterABI,
                catalogScope: description.scope
            ),
            completeness: description.completeness,
            rows: chapters.map { CatalogRowEvidence(chapter: $0) },
            chapters: chapters,
            entrySnapshot: snapshot,
            catalogDigest: SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
        ))
    }
}

// MARK: - Accepted baseline

/// The accepted baseline as read inside the commit transaction.
nonisolated struct SubscriptionBaselineView: Sendable {
    struct SeenKey: Sendable, Equatable {
        let position: SubscriptionPositionID
        let lastRevision: ScanlatorUTF8?
        /// False for a tombstone: the key was seen once and is absent from the accepted catalog.
        let present: Bool
        /// The key's position rank within the accepted catalog's order. Meaningful only inside that
        /// snapshot, and only when `present`.
        let rank: Int?
    }

    let incarnation: Int64
    let revision: Int64
    let acceptedTicket: Int64
    let scopeGeneration: Int64
    let fingerprint: SubscriptionScopeFingerprint
    let catalogDigest: String
    let rowCount: Int
    let orderConfidence: ChapterReadingOrder.Confidence
    /// The last reading position of the accepted order; nil unless that order was confident.
    let highWater: SubscriptionPositionID?
    /// The largest source date ever accepted: the only date evidence. It is a source date, never compared with
    /// the device clock.
    let maxDateUpdated: Double?
    /// Exact key bytes to evidence, tombstones included.
    let seen: [ScanlatorUTF8: SeenKey]
}

// MARK: - Classification result

nonisolated struct SubscriptionEventIdentity: Sendable, Equatable {
    let kind: SubscriptionIdentityKind
    let value: String
}

nonisolated struct ClassifiedEvent: Sendable, Equatable {
    let kind: SubscriptionEventKind
    let identity: SubscriptionEventIdentity
    let qualifier: String?
    /// Exact keys in source order, at most `SubscriptionCatalogClassifier.candidateKeyLimit`. A position that
    /// lists more keys keeps only the first ones here; the rest are absorbed into the seen set without being
    /// reviewable or approvable.
    let candidateKeys: [String]
    let previousRevision: String?
    let targetRevision: String?
    let ordinal: Int
    /// `.undecided`, `.needsReview` or `.recorded`.
    let initialDecision: SubscriptionDecision
    let reviewReason: SubscriptionReviewReason?
}

/// What the store writes when it accepts an observation. Every present key is upserted; every other
/// seen key becomes a tombstone (`present = false`, `rank = nil`).
nonisolated struct BaselineWrite: Sendable, Equatable {
    let fingerprint: SubscriptionScopeFingerprint
    let scopeGenerationIncrement: Bool
    let catalogDigest: String
    let rowCount: Int
    let orderConfidence: ChapterReadingOrder.Confidence
    let highWater: SubscriptionPositionID?
    let maxDateUpdated: Double?
    let seenUpserts: [ScanlatorUTF8: SubscriptionBaselineView.SeenKey]
}

nonisolated enum CatalogClassification: Sendable, Equatable {
    /// The observation proves nothing: record the attempt only.
    case rejected(SubscriptionCheckOutcome)
    /// Same scope and same catalog as the baseline: touch the success time only.
    case unchanged
    /// First baseline or a re-baseline (`.baselineEstablished` / `.rebaselined`). Never any events.
    case baseline(BaselineWrite, outcome: SubscriptionCheckOutcome)
    /// The accepted baseline moves forward; `events` may be empty.
    case advance(BaselineWrite, events: [ClassifiedEvent])
    /// A genuinely empty catalog after a non-empty one: raise the events and leave the baseline untouched.
    case anomaly(events: [ClassifiedEvent])
}
