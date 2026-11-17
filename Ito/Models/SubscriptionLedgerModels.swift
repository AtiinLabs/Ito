import Foundation
import GRDB
import ito_runner

// The records of the durable catalog ledger (v27). Every enum mirrors the closed list of its CHECK constraint, so a
// value the database would refuse cannot be built; `SubscriptionLedgerSchemaTests` compares each case list with the
// stored constraint. Identifiers, chapter keys and revisions are exact UTF-8 bytes: they are never normalized.

nonisolated enum SubscriptionState: String, Codable, CaseIterable, Sendable {
    case enabled, paused, disabled
}

nonisolated enum SubscriptionPauseReason: String, Codable, CaseIterable, Sendable {
    case user, sourceRemapped, restored
}

nonisolated enum SubscriptionMode: String, Codable, CaseIterable, Sendable {
    case newReleases, newAndFillUnread, maintainNextUnread
}

nonisolated enum SubscriptionReplacementRule: String, Codable, CaseIterable, Sendable {
    case off, sameKeyReliableRevision
}

nonisolated enum SubscriptionAcquisition: String, Codable, CaseIterable, Sendable {
    case mediaUpdate
}

nonisolated enum SubscriptionOrderConfidence: String, Codable, CaseIterable, Sendable {
    case confident, ambiguous

    init(_ confidence: ChapterReadingOrder.Confidence) {
        switch confidence {
        case .confident: self = .confident
        case .ambiguous: self = .ambiguous
        }
    }

    var confidence: ChapterReadingOrder.Confidence {
        switch self {
        case .confident: .confident
        case .ambiguous: .ambiguous
        }
    }
}

/// The kinds a stored position can have: a logical unit ID or, without one, an exact chapter key.
nonisolated enum SubscriptionPositionKind: String, Codable, CaseIterable, Sendable {
    case logical, exact
}

nonisolated extension SubscriptionPositionID {
    init(kind: SubscriptionPositionKind, value: String) {
        switch kind {
        case .logical: self = .logical(ScanlatorUTF8(value: value))
        case .exact: self = .exact(ScanlatorUTF8(value: value))
        }
    }

    var positionKind: SubscriptionPositionKind {
        switch self {
        case .logical: .logical
        case .exact: .exact
        }
    }
}

nonisolated enum DownloadOwnerKind: String, Codable, CaseIterable, Sendable {
    case manual, subscription
}

/// One automatic rule for a series: its configuration, its lifecycle generations and the outcome of the last check.
/// `incarnation` changes when the rule is re-created or its evidence is discarded; `configGeneration` changes with
/// every edit. Both guard a write that was prepared before the change.
nonisolated struct SeriesSubscriptionRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "seriesSubscription"

    var id: String
    var pluginId: String
    var mediaKind: MediaKind
    var canonicalMediaId: String
    var state: SubscriptionState
    var pauseReason: SubscriptionPauseReason?
    var mode: SubscriptionMode
    var windowSize: Int?
    var perRunPositionCap: Int
    /// `EditionSelection.storageData()`, kept as stored: an unreadable choice is not read as another one.
    var selection: Data
    var replacementRule: SubscriptionReplacementRule
    var incarnation: Int64
    var configGeneration: Int64
    var nextCheckTicket: Int64
    var lastAttemptAt: Date?
    var lastAttemptOutcome: SubscriptionCheckOutcome?
    var lastSuccessAt: Date?
    var createdAt: Date
    var updatedAt: Date

    var media: MediaIdentity {
        MediaIdentity(pluginId: pluginId, canonicalMediaId: canonicalMediaId, mediaKind: mediaKind)
    }

    /// The configured selection, or nil when the stored bytes are not one this build reads.
    var decodedSelection: EditionSelection? {
        try? SeriesEditionPreferenceRecord.decodeSelection(selection)
    }

    static func forMedia(_ media: MediaIdentity) -> QueryInterfaceRequest<SeriesSubscriptionRecord> {
        filter(
            Column("pluginId") == media.pluginId
                && Column("mediaKind") == media.mediaKind.rawValue
                && Column("canonicalMediaId") == media.canonicalMediaId
        )
    }
}

/// The one accepted catalog snapshot of a subscription. `revision` grows with every accepted write;
/// `acceptedTicket` is the check that produced it, so an observation started before it never replaces it.
nonisolated struct SubscriptionBaselineRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "subscriptionBaseline"

    var subscriptionId: String
    var incarnation: Int64
    var revision: Int64
    var acceptedTicket: Int64
    var scopeGeneration: Int64
    var acquisition: SubscriptionAcquisition
    var sourceEpoch: String
    var pluginVersion: String
    var chapterABI: Int
    var catalogScope: LibraryCatalogScope
    var catalogDigest: String
    var rowCount: Int
    var orderConfidence: SubscriptionOrderConfidence
    var highWaterKind: SubscriptionPositionKind?
    var highWaterValue: String?
    /// The largest source date ever accepted: the only date evidence, never compared with the device clock.
    var maxDateUpdated: Double?
    var tombstonesTruncated: Bool
    /// `JSONEncoder().encode(MediaEntry)` as the source returned it. The frozen series snapshot of automatic jobs.
    var entrySnapshot: Data
    var acceptedAt: Date

    var fingerprint: SubscriptionScopeFingerprint {
        SubscriptionScopeFingerprint(
            acquisition: acquisition.rawValue,
            sourceEpoch: sourceEpoch,
            pluginVersion: pluginVersion,
            chapterABI: chapterABI,
            catalogScope: catalogScope
        )
    }

    var highWater: SubscriptionPositionID? {
        guard let highWaterKind, let highWaterValue else { return nil }
        return SubscriptionPositionID(kind: highWaterKind, value: highWaterValue)
    }
}

/// A chapter key the subscription has ever seen. A key that left the accepted catalog stays as a tombstone
/// (`presentInAccepted == false`), so a key that returns is never new.
nonisolated struct SubscriptionSeenKeyRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "subscriptionSeenKey"

    var subscriptionId: String
    var chapterKey: String
    var positionKind: SubscriptionPositionKind
    var positionValue: String
    var lastRevision: String?
    var presentInAccepted: Bool
    var acceptedRank: Int?
    var firstSeenScopeGeneration: Int64
    var firstSeenAt: Date

    var evidence: SubscriptionBaselineView.SeenKey {
        SubscriptionBaselineView.SeenKey(
            position: SubscriptionPositionID(kind: positionKind, value: positionValue),
            lastRevision: lastRevision.map { ScanlatorUTF8(value: $0) },
            present: presentInAccepted,
            rank: acceptedRank
        )
    }
}

/// One thing the ledger noticed in a catalog, and what became of it. Its identity is unique per subscription
/// incarnation, so a replayed observation records nothing twice.
nonisolated struct SubscriptionEventRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "subscriptionEvent"

    var id: String
    var subscriptionId: String
    var incarnation: Int64
    var kind: SubscriptionEventKind
    var identityKind: SubscriptionIdentityKind
    var identityValue: String
    var qualifier: String?
    var decision: SubscriptionDecision
    var pendingReason: SubscriptionPendingReason?
    var reviewReason: SubscriptionReviewReason?
    /// JSON `[String]`, at most 64 exact keys in source order.
    var candidateKeys: Data
    var candidateRevision: Int64
    /// JSON `[String]` that is a subset of `candidateKeys`: set only by an explicit approval.
    var approvedKeys: Data?
    /// JSON `[String]` that were enqueued, attached or already saved.
    var decidedKeys: Data?
    var previousRevision: String?
    var targetRevision: String?
    var ordinal: Int
    var observedCatalogDigest: String
    var configGeneration: Int64
    var scopeGeneration: Int64
    var createdAt: Date
    var decidedAt: Date?
    /// When the decision to notify about this event was taken, whether or not a notification was posted. Only the
    /// attention claim writes it, so each event is claimed once; every insert leaves it nil.
    var notifiedAt: Date?

    var candidates: [String] { Self.keys(candidateKeys) }
    var approved: [String]? { approvedKeys.map(Self.keys) }
    var decided: [String]? { decidedKeys.map(Self.keys) }

    static func encode(keys: [String]) -> Data {
        (try? JSONEncoder().encode(keys)) ?? Data("[]".utf8)
    }

    static func keys(_ data: Data) -> [String] {
        (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

/// Who asked for a job. A job lives while it has a live owner. A manual owner is one explicit request (its batch);
/// a subscription owner is one event of one subscription incarnation. Completed files have no owner.
nonisolated struct DownloadJobOwnerRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "downloadJobOwner"

    var jobId: String
    var ownerKind: DownloadOwnerKind
    var manualRequestId: String?
    var subscriptionId: String?
    var subscriptionIncarnation: Int64?
    var eventId: String?
    var attachedAt: Date
}

/// The owners of one job, for the network policy: the manual requests and the subscriptions that asked for it.
nonisolated struct DownloadJobOwnership: Sendable, Equatable {
    var manualRequestIds: [String] = []
    var subscriptionIds: [String] = []
}
