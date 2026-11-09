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

/// One queued, waiting, downloading or failed chapter. Removed on commit, cancel or delete.
nonisolated struct DownloadJobRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "downloadJob"

    var id: String
    var pluginId: String
    var mediaKind: MediaKind
    var canonicalMediaId: String
    var chapterKey: String
    var authorityScope: OfflineAuthorityScope
    /// JSON `MediaEntry` frozen at enqueue.
    var entrySnapshot: Data
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
