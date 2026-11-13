import Foundation
import GRDB
import ito_runner

/// Who the copy was fetched for. Only the public, unscoped authority exists before the host can
/// tell accounts apart; later values widen the schema CHECK in a new migration.
nonisolated enum OfflineAuthorityScope: String, Codable, CaseIterable, Sendable {
    case publicUnscoped
}

/// The exact chapter a stored copy or queued job belongs to. Matching uses the source's chapter
/// key and this scope only, never a chapter number or scanlator.
nonisolated struct OfflineChapterEdition: Codable, Hashable, Sendable {
    let pluginId: String
    let mediaKind: MediaKind
    let canonicalMediaId: String
    let chapterKey: String
    let authorityScope: OfflineAuthorityScope

    init(
        pluginId: String,
        mediaKind: MediaKind,
        canonicalMediaId: String,
        chapterKey: String,
        authorityScope: OfflineAuthorityScope = .publicUnscoped
    ) {
        self.pluginId = pluginId
        self.mediaKind = mediaKind
        self.canonicalMediaId = canonicalMediaId
        self.chapterKey = chapterKey
        self.authorityScope = authorityScope
    }

    /// The edition of one chapter of a series. The one place screens turn a series and a chapter key into
    /// an edition, so the authority scope is chosen in one place when it widens.
    init(media: MediaIdentity, chapterKey: String) {
        self.init(
            pluginId: media.pluginId,
            mediaKind: media.mediaKind,
            canonicalMediaId: media.canonicalMediaId,
            chapterKey: chapterKey
        )
    }

    /// Matches one row of `downloadedChapter` or `downloadJob` by the edition's identity columns.
    var predicate: SQLExpression {
        Column("pluginId") == pluginId
            && Column("mediaKind") == mediaKind.rawValue
            && Column("canonicalMediaId") == canonicalMediaId
            && Column("chapterKey") == chapterKey
            && Column("authorityScope") == authorityScope.rawValue
    }
}

nonisolated enum DownloadedChapterState: String, Codable, CaseIterable, Sendable {
    case verified
    case damaged
}

nonisolated enum DamageReason: String, Codable, CaseIterable, Sendable {
    case manifestMismatch
    case pageMismatch
    case manifestUnreadable
}

nonisolated enum OfflineContentKind: String, Codable, CaseIterable, Sendable {
    case images
    case text
    case mixed
}

/// One verified (or damaged) stored copy of a chapter: the Available Offline inventory.
nonisolated struct DownloadedChapterRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "downloadedChapter"

    var pluginId: String
    var mediaKind: MediaKind
    var canonicalMediaId: String
    var chapterKey: String
    var authorityScope: OfflineAuthorityScope
    var versionId: String
    var state: DownloadedChapterState
    var damageReason: DamageReason?
    var contentKind: OfflineContentKind
    var pageCount: Int
    var byteCount: Int64
    var manifestFormatVersion: Int
    var manifestSHA256: String
    /// JSON `Chapter` without `url` or `paywalled`.
    var chapterSnapshot: Data
    var seriesTitle: String
    /// Provenance only in Milestone 0.
    var sourceEpoch: String?
    var verifiedAt: Date
    /// JSON `OfflineOriginIdentity`; nil while the row has the identity its manifest was written under.
    var originIdentity: Data?

    var edition: OfflineChapterEdition {
        OfflineChapterEdition(
            pluginId: pluginId,
            mediaKind: mediaKind,
            canonicalMediaId: canonicalMediaId,
            chapterKey: chapterKey,
            authorityScope: authorityScope
        )
    }

    /// The identity the immutable manifest was written under. It differs from `edition` only after the
    /// row moved to another series (relink or source remap): the manifest keeps the identity it was
    /// published with, and `originIdentity` names it. An origin that cannot be decoded is ignored, so
    /// the manifest then has to match the row's own identity or the copy is marked damaged.
    var manifestIdentity: OfflineChapterEdition {
        guard let originIdentity,
              let origin = try? JSONDecoder().decode(OfflineOriginIdentity.self, from: originIdentity) else {
            return edition
        }
        return OfflineChapterEdition(
            pluginId: origin.pluginId,
            mediaKind: mediaKind,
            canonicalMediaId: origin.canonicalMediaId,
            chapterKey: chapterKey,
            authorityScope: authorityScope
        )
    }
}

/// The series identity a copy was first published under, stored as JSON in
/// `downloadedChapter.originIdentity`. The column is NULL while the row still has that identity.
nonisolated struct OfflineOriginIdentity: Codable, Hashable, Sendable {
    let pluginId: String
    let canonicalMediaId: String
}

nonisolated enum DownloadJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case waiting
    case downloading
    case failed
}

/// Why a job is paused without failing. Waiting jobs resume on events, except those that need an
/// explicit Retry (`sourceUnavailable`, `sourceConfigurationChanged`, `restoredPendingReview`).
nonisolated enum DownloadWaitingReason: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case networkUnknown
    case noConnection
    case meteredNetwork
    case lowDataMode
    case insufficientStorage
    case protectedDataUnavailable
    case sourceUnavailable
    case sourceConfigurationChanged
    case restoredPendingReview
    case appInBackground
}

nonisolated extension DownloadWaitingReason {
    /// Reasons that clear only through an explicit user Retry, never through an event.
    static let requiringRetry: Set<DownloadWaitingReason> = [
        .sourceUnavailable,
        .sourceConfigurationChanged,
        .restoredPendingReview
    ]

    var requiresRetry: Bool { Self.requiringRetry.contains(self) }
}

nonisolated enum DownloadFailureReason: String, Codable, CaseIterable, Equatable, Sendable {
    case sourceError
    case network
    case httpStatus
    case emptyChapter
    case tooManyPages
    case assetTooLarge
    case unsupportedImageFormat
    case unsupportedPageLocator
    case requiresInteractiveSource
    case integrityMismatch
    case fileSystem
}

/// One queued, waiting, downloading or failed chapter. Removed on commit, cancel or delete. The frozen
/// series snapshot lives once on its `downloadBatch`, not on each job.
nonisolated struct DownloadJobRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "downloadJob"

    /// Queue order: oldest batch first, then the batch's own reading order. `batchId` keeps two batches
    /// created at the same instant from interleaving their jobs.
    static var queueOrder: [any SQLOrderingTerm] {
        [Column("createdAt"), Column("batchId"), Column("sequence"), Column("id")]
    }

    var id: String
    var batchId: String
    /// Position inside the batch, in reading order.
    var sequence: Int
    var pluginId: String
    var mediaKind: MediaKind
    var canonicalMediaId: String
    var chapterKey: String
    var authorityScope: OfflineAuthorityScope
    /// JSON `Chapter` as the source returned it; `getChapterPages` input.
    var chapterSnapshot: Data
    var seriesTitle: String
    var sourceEpoch: String?
    var state: DownloadJobState
    var waitingReason: DownloadWaitingReason?
    var failureReason: DownloadFailureReason?
    /// The version UUID reserved for the current attempt.
    var stagingVersionId: String?
    var attemptCount: Int
    var createdAt: Date
    var updatedAt: Date

    var edition: OfflineChapterEdition {
        OfflineChapterEdition(
            pluginId: pluginId,
            mediaKind: mediaKind,
            canonicalMediaId: canonicalMediaId,
            chapterKey: chapterKey,
            authorityScope: authorityScope
        )
    }
}

/// Installation binding between the database and its offline directory (single row).
nonisolated struct DownloadStoreRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "downloadStore"

    var id = 1
    var storeId: String
    var createdAt: Date
}

/// What the user asked for when the batch was queued. `single` is one chapter chosen on its own.
nonisolated enum DownloadBatchPreset: String, Codable, CaseIterable, Sendable {
    case single
    case next
    case next5
    case next10
    case unread
    case all
}

/// The frozen request behind one or more jobs: the series snapshot, the preset, the edition selection
/// and the catalog digest the plan was made from. Written once at enqueue and never updated; it is
/// removed in the transaction that removes its last job.
nonisolated struct DownloadBatchRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "downloadBatch"

    /// The edition selection of a chapter queued on its own, and of every job queued before batches
    /// existed: follow the source's list.
    static let sourceListSelection = Data(#"{"formatVersion":1,"kind":"sourceList"}"#.utf8)

    var id: String
    var pluginId: String
    var mediaKind: MediaKind
    var canonicalMediaId: String
    var preset: DownloadBatchPreset
    /// Versioned `EditionSelection` JSON. The store keeps these bytes as given and never reads them.
    var selection: Data
    /// SHA-256 hex of the chapter list the plan was made from; nil when no plan was involved.
    var catalogDigest: String?
    /// JSON `MediaEntry` frozen at enqueue.
    var entrySnapshot: Data
    var createdAt: Date
}

/// A job together with the series snapshot of its batch: everything an attempt needs.
nonisolated struct DownloadJobWork: Sendable {
    let job: DownloadJobRecord
    /// JSON `MediaEntry` frozen on the job's batch.
    let entrySnapshot: Data
}

/// A chapter the user deleted on purpose. A later automatic download must not bring it back until the
/// user downloads it again, which clears the record.
nonisolated struct DownloadSuppressionRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "downloadSuppression"

    var pluginId: String
    var mediaKind: MediaKind
    var canonicalMediaId: String
    var chapterKey: String
    var authorityScope: OfflineAuthorityScope
    var suppressedAt: Date
}

nonisolated enum SeriesEditionPreferenceError: Error, Equatable {
    /// Stored bytes are not a selection this build understands.
    case unreadable
    /// A remembered choice cannot recreate or outlive its saved Library scope.
    case seriesNotSaved
    /// The source's settings or account changed after the choice was reviewed, so it is not stored.
    case sourceChanged
}

/// The scanlators a user chose to download for one series, when they asked to remember the choice.
/// Installation-local, like the queue: it is not a backup component.
nonisolated struct SeriesEditionPreferenceRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "seriesEditionPreference"

    var pluginId: String
    var mediaKind: MediaKind
    var canonicalMediaId: String
    /// `EditionSelection` JSON, as `EditionSelection.storageData()` wrote it.
    var selection: Data
    var updatedAt: Date

    /// The stored choice for a series, or nil when none was remembered. Throws `unreadable` when a choice is
    /// stored but this build cannot read it: that is not "no choice", and it is never read as another one.
    static func selection(for media: MediaIdentity, in db: Database) throws -> EditionSelection? {
        let record = try SeriesEditionPreferenceRecord.fetchOne(
            db,
            key: ["pluginId": media.pluginId, "mediaKind": media.mediaKind.rawValue, "canonicalMediaId": media.canonicalMediaId]
        )
        guard let record else { return nil }
        do {
            return try JSONDecoder().decode(EditionSelection.self, from: record.selection)
        } catch {
            throw SeriesEditionPreferenceError.unreadable
        }
    }

    /// Stores `selection` as the series' choice, replacing an earlier one.
    static func save(_ selection: EditionSelection, for media: MediaIdentity, at date: Date, in db: Database) throws {
        try SeriesEditionPreferenceRecord(
            pluginId: media.pluginId,
            mediaKind: media.mediaKind,
            canonicalMediaId: media.canonicalMediaId,
            selection: try selection.storageData(),
            updatedAt: date
        ).save(db)
    }
}

/// What a caller asks for when it queues several chapters of one series at once. `chapters` are the
/// frozen source values in reading order; the store never fetches anything itself.
nonisolated struct DownloadBatchRequest: Sendable {
    let pluginId: String
    let mediaKind: MediaKind
    let canonicalMediaId: String
    let entry: MediaEntry
    let seriesTitle: String
    let preset: DownloadBatchPreset
    /// Versioned `EditionSelection` JSON, encoded by the caller. It must be a JSON object.
    let selection: Data
    /// SHA-256 hex digest (64 characters) of the chapter list the plan was made from, if any.
    let catalogDigest: String?
    let chapters: [Chapter]
    /// The source epoch the user reviewed this batch under. When set, the store refuses the whole request in
    /// its write transaction unless the source's epoch is still this one; nil takes the epoch of the moment.
    var reviewedSourceEpoch: String?
    /// The remembered edition policy the plan was made under. When set, the store refuses the whole request in
    /// the same write transaction unless the stored policy is still exactly this one, so a screen holding an
    /// older copy of the series' policy cannot queue under it. Nil does not check.
    var reviewedPolicy: ReviewedEditionPolicy?
}

/// What the series' remembered edition policy was when a batch was reviewed.
nonisolated enum ReviewedEditionPolicy: Equatable, Sendable {
    /// No policy was remembered.
    case none
    /// A policy was stored that this build cannot read.
    case unreadable
    case selection(EditionSelection)
}

/// How each requested chapter was settled. The counts add up to the number of chapters requested
/// unless `refusal` is set, which refuses the whole request before any chapter is examined.
nonisolated struct DownloadBatchOutcome: Equatable, Sendable {
    /// Jobs inserted.
    var queued = 0
    /// Chapters that already have a verified copy.
    var alreadySaved = 0
    /// Chapters that already have a job, including a repeat inside the request.
    var alreadyQueued = 0
    /// Chapters marked locked by the source; they are never queued.
    var refusedLocked = 0
    /// Chapters whose stored copy is damaged: it has to be deleted before the chapter can be queued.
    var blockedDamaged = 0
    /// Set when the request as a whole was refused.
    var refusal: DownloadRefusal?
    /// The batch row, present only when at least one job was queued.
    var batchId: String?

    static func refused(_ refusal: DownloadRefusal) -> DownloadBatchOutcome {
        DownloadBatchOutcome(refusal: refusal)
    }
}

/// What a bulk delete removed.
nonisolated struct DownloadDeleteSummary: Equatable, Sendable {
    var removedCopies = 0
    var removedJobs = 0
}

/// What a caller asks for when it queues a chapter. `chapter` and `entry` are the frozen source
/// values; the store never fetches them itself.
nonisolated struct DownloadEnqueueRequest: Sendable {
    let pluginId: String
    let mediaKind: MediaKind
    let canonicalMediaId: String
    let entry: MediaEntry
    let chapter: Chapter
    let seriesTitle: String
    /// The `PluginCompletionScope` epoch captured for this source. Nil when it could not be read,
    /// which refuses the request.
    let sourceEpoch: String?

    var edition: OfflineChapterEdition {
        OfflineChapterEdition(
            pluginId: pluginId,
            mediaKind: mediaKind,
            canonicalMediaId: canonicalMediaId,
            chapterKey: chapter.key
        )
    }
}

nonisolated enum DownloadRefusal: Equatable, Sendable {
    case paywalled
    case unsupportedKind
    case unavailable
    /// The source's settings or account changed after the batch was reviewed; nothing was queued.
    case sourceChanged
    /// The series' remembered edition policy changed after the batch was reviewed; nothing was queued.
    case policyChanged
}

nonisolated enum DownloadEnqueueOutcome: Equatable, Sendable {
    case queued
    case alreadyQueued
    case alreadyDownloaded
    case refused(DownloadRefusal)
}

/// Where a failed or interrupted attempt leaves its job.
nonisolated enum DownloadAttemptOutcome: Equatable, Sendable {
    case queued
    case waiting(DownloadWaitingReason)
    case failed(DownloadFailureReason)
}
