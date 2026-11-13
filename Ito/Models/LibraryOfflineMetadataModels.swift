import Foundation
import GRDB
import ito_runner

/// Which chapters a source's catalog covers. The cases and their order match the runner's catalog scope, so
/// a source that reports it maps case for case. A value this build does not recognise is `unknown`.
nonisolated enum LibraryCatalogScope: String, Codable, CaseIterable, Sendable {
    case unknown
    /// What the source shows by default: it may leave out hidden, filtered or collapsed uploads.
    case visible
    /// Every upload the source could download.
    case allEligible

    init(reported value: String?) {
        self = value.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

/// Whether the source says the catalog it returned is the whole of its scope. It is kept apart from the
/// scope: a complete list of what is visible is not a complete series.
nonisolated enum LibraryCatalogCompleteness: String, Codable, CaseIterable, Sendable {
    case unknown
    case partial
    case complete

    init(reported value: String?) {
        self = value.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

/// How a source described the catalog saved with a Library item.
nonisolated struct LibraryCatalogDescription: Equatable, Sendable {
    var scope: LibraryCatalogScope
    var completeness: LibraryCatalogCompleteness

    /// What every source reports until it can say more.
    static let unknown = LibraryCatalogDescription(scope: .unknown, completeness: .unknown)

    /// Whether the catalog can back a claim about the entire series: every eligible upload, and the source
    /// says it returned all of them.
    var coversEntireSeries: Bool {
        scope == .allEligible && completeness == .complete
    }
}

extension LibraryCatalogDescription {
    /// Maps the runner's catalog case for case, with no default, so a runner case this build does not know
    /// breaks the build here instead of being guessed. A missing catalog says nothing: it is `unknown`.
    init(_ catalog: ChapterCatalog?) {
        guard let catalog else {
            self = .unknown
            return
        }
        self.init(scope: Self.libraryScope(catalog.scope), completeness: Self.libraryCompleteness(catalog.completeness))
    }

    private static func libraryScope(_ scope: CatalogScope) -> LibraryCatalogScope {
        switch scope {
        case .unknown: return .unknown
        case .visible: return .visible
        case .allEligible: return .allEligible
        }
    }

    private static func libraryCompleteness(_ completeness: CatalogCompleteness) -> LibraryCatalogCompleteness {
        switch completeness {
        case .unknown: return .unknown
        case .partial: return .partial
        case .complete: return .complete
        }
    }
}

/// When the details saved with a Library item were last refreshed from their source, and for which
/// payload. Installation-local: it is not a backup component, so a restored payload has no state and its
/// age is unknown.
nonisolated struct LibrarySnapshotStateRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "librarySnapshotState"

    var pluginId: String
    var mediaKind: MediaKind
    var canonicalMediaId: String
    /// SHA-256 hex digest of the `libraryItem.rawPayload` this state describes. A different payload
    /// (a restore, a relink, a save of another snapshot) makes the rest of the row say nothing.
    var payloadSHA256: String
    var refreshedAt: Date
    var catalogScope: LibraryCatalogScope
    var catalogCompleteness: LibraryCatalogCompleteness
    /// The number of chapter rows in the payload; never zero.
    var chapterRowCount: Int

    var media: MediaIdentity {
        MediaIdentity(pluginId: pluginId, canonicalMediaId: canonicalMediaId, mediaKind: mediaKind)
    }

    var catalog: LibraryCatalogDescription {
        LibraryCatalogDescription(scope: catalogScope, completeness: catalogCompleteness)
    }

    /// Whether this state can back an "entire series" claim, as far as the saved catalog goes: a complete
    /// catalog over every eligible upload, with at least one chapter. An empty catalog is never complete.
    /// Whether the payload and the age still qualify is the caller's check.
    var coversEntireSeries: Bool {
        chapterRowCount > 0 && catalog.coversEntireSeries
    }
}

/// What a series' saved details say about its catalog, for the "entire series offline" claim: the freshness
/// record, the digest of the payload saved now, and the chapter rows of that saved payload. The claim is about
/// the saved catalog, never about the list a later load returned, so the rows come from the payload itself.
nonisolated struct LibrarySnapshotBasis: Equatable, Sendable {
    let snapshot: SeriesOfflineSnapshot
    /// SHA-256 hex digest of the `libraryItem.rawPayload` saved now.
    let currentPayloadSHA256: String
    /// The chapter rows of the saved payload.
    let catalog: [ChapterFacts]
}

extension LibrarySnapshotStateRecord {
    /// The freshness `SeriesOfflineCoverage` reads. A catalog is `complete` only when it covers the entire
    /// series (`coversEntireSeries`); a complete catalog of what the source shows by default is not that.
    var offlineSnapshot: SeriesOfflineSnapshot {
        let scope: SeriesCatalogScope
        if coversEntireSeries {
            scope = .complete
        } else if catalogCompleteness == .partial {
            scope = .partial
        } else if catalogScope == .visible {
            scope = .visible
        } else {
            scope = .unknown
        }
        return SeriesOfflineSnapshot(catalogScope: scope, payloadSHA256: payloadSHA256, refreshedAt: refreshedAt)
    }
}

/// A durable cover kept with a Library item, captured from the cover the Library card already displayed.
nonisolated struct LibraryCoverThumbnailRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "libraryCoverThumbnail"

    /// The largest encoded thumbnail the table accepts.
    static let maximumByteCount = 262_144
    /// The largest pixel size the table accepts.
    static let maximumPixelWidth = 1024
    static let maximumPixelHeight = 1536

    var libraryItemId: String
    /// SHA-256 hex digest of the cover address the image was displayed for.
    var coverURLSHA256: String
    var imageData: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var storedAt: Date
}

/// Names the saved details a detail load started from. A refresh may replace them only while they are still
/// those details.
nonisolated struct LibrarySnapshotToken: Equatable, Sendable {
    let itemID: String
    let media: MediaIdentity
    /// SHA-256 hex digest of the item's `rawPayload` when the token was read.
    let payloadSHA256: String
}

nonisolated enum LibrarySnapshotReplaceOutcome: Equatable, Sendable {
    /// The refreshed details are now the saved ones.
    case replaced
    /// The item was removed, relinked, restored, saved again or replaced since the token was read.
    case stale
    /// The refreshed list has no chapters, so it is not evidence about the series and nothing is saved.
    case rejectedIncomplete
}

/// What the Library needs from the two small proof tables to judge "entire series offline". It is read in an
/// observation of its own, so a refresh that changes only its time, or a policy change, never refetches a payload.
nonisolated struct LibraryOfflineProofSnapshot: Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case loading
        case available
        case unavailable
    }

    let availability: Availability
    /// The freshness record of each saved series, one per series.
    let states: [MediaIdentity: LibrarySnapshotStateRecord]
    /// The raw remembered edition choice of each series. A choice is judged by its reader, never here, so
    /// bytes this build cannot read stay bytes and fail closed there.
    let preferences: [MediaIdentity: Data]

    static let loading = LibraryOfflineProofSnapshot(availability: .loading, states: [:], preferences: [:])
    static let unavailable = LibraryOfflineProofSnapshot(availability: .unavailable, states: [:], preferences: [:])
}
