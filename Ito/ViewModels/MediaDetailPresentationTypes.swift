import Foundation
import ito_runner

enum ChapterSortOrder: String, CaseIterable {
    case descending = "High to Low"
    case ascending = "Low to High"
    case dateDescending = "Newest First"
    case dateAscending = "Oldest First"

    var icon: String {
        switch self {
        case .descending: return "arrow.down.to.line"
        case .ascending: return "arrow.up.to.line"
        case .dateDescending: return "calendar.badge.clock"
        case .dateAscending: return "calendar"
        }
    }

    var localizedTitle: String {
        switch self {
        case .descending: return String(localized: "High to Low")
        case .ascending: return String(localized: "Low to High")
        case .dateDescending: return String(localized: "Newest First")
        case .dateAscending: return String(localized: "Oldest First")
        }
    }
}

enum ChapterFilterOption: String, CaseIterable {
    case all = "All"
    case unread = "Unread/Unwatched"
    case read = "Read/Watched"

    var icon: String {
        switch self {
        case .all: return "list.bullet"
        case .unread: return "circle"
        case .read: return "checkmark.circle.fill"
        }
    }

    var localizedTitle: String {
        switch self {
        case .all: return String(localized: "All")
        case .unread: return String(localized: "Unread/Unwatched")
        case .read: return String(localized: "Read/Watched")
        }
    }
}

/// Where a reader's chapters come from. A verified local copy is used first; the installed source
/// reads anything else. Saved-only routes have no installed source.
struct ReaderContentSource {
    /// nil when the plugin is missing or cannot be loaded.
    let remote: ItoRunner?
    /// Where this opening reads its chapter from. Never stored.
    var preference: ReaderContentPreference = .localFirst
}

enum MediaDetailReaderDestination: Identifiable {
    case pages(
        id: UUID,
        content: ReaderContentSource,
        pluginID: String,
        entry: MediaEntry,
        chapter: Chapter
    )
    case anime(
        id: UUID,
        runner: ItoRunner,
        pluginID: String,
        media: Anime,
        episode: Anime.Episode
    )
    /// A text chapter, retaining the catalog entry's kind for history and completion.
    case text(
        id: UUID,
        content: ReaderContentSource,
        pluginID: String,
        entry: MediaEntry,
        chapter: Chapter
    )

    var id: UUID {
        switch self {
        case .pages(let id, _, _, _, _),
             .anime(let id, _, _, _, _),
             .text(let id, _, _, _, _):
            return id
        }
    }
}

extension MediaDetailReaderDestination {
    /// The chapter's format selects the reader; its catalog identity is unchanged.
    static func reading(
        _ chapter: Chapter,
        of entry: MediaEntry,
        content: ReaderContentSource,
        pluginID: String
    ) -> Self {
        if entry.contentKind(of: chapter) == .text {
            return .text(id: UUID(), content: content, pluginID: pluginID, entry: entry, chapter: chapter)
        }
        return .pages(id: UUID(), content: content, pluginID: pluginID, entry: entry, chapter: chapter)
    }

    /// The reader for one explicitly chosen saved copy. Its format is the copy's saved form, never the
    /// catalog's: a manga copy saved as text opens the text reader and a novel copy saved as images opens
    /// pages, while the entry keeps its own kind for history and completion. The entry handed to the reader
    /// lists the saved descriptor, so the reader keeps the chosen version; it is a copy for this opening and
    /// is never stored. A chapter the live catalog does not list opens alone, with no neighbors.
    static func downloadedAlternative(
        _ candidate: DownloadedChapterAlternative,
        lease: OfflineChapterLease,
        of entry: MediaEntry,
        remote: ItoRunner?,
        pluginID: String
    ) throws -> Self {
        guard entry.kind != .anime else { throw DownloadedAlternativeError.unsupportedMediaKind }
        let edition = candidate.edition
        guard pluginID.utf8.elementsEqual(edition.pluginId.utf8),
              entry.kind == edition.mediaKind,
              entry.key.utf8.elementsEqual(edition.canonicalMediaId.utf8),
              candidate.chapter.key.utf8.elementsEqual(edition.chapterKey.utf8),
              lease.versionId == candidate.versionID,
              lease.edition.isByteIdentical(to: edition),
              lease.manifest.contentKind == candidate.contentKind else {
            throw DownloadedAlternativeError.selectionChanged
        }
        var chapter = candidate.chapter
        let readsText: Bool
        switch lease.manifest.contentKind {
        case .text: readsText = true
        case .images: readsText = false
        case .mixed: readsText = (chapter.kind ?? entry.kind.defaultContentKind) == .text
        }
        chapter.kind = readsText ? .text : .images
        let pinned = entry.pinning(chapter)
        let content = ReaderContentSource(
            remote: remote,
            preference: .localOnly(chapterKey: chapter.key, lease: lease)
        )
        if readsText {
            return .text(id: UUID(), content: content, pluginID: pluginID, entry: pinned, chapter: chapter)
        }
        return .pages(id: UUID(), content: content, pluginID: pluginID, entry: pinned, chapter: chapter)
    }

    /// The same reader opened with another content preference. An episode has no stored form, so it is
    /// returned unchanged.
    func preferring(_ preference: ReaderContentPreference) -> Self {
        switch self {
        case .pages(let id, var content, let pluginID, let entry, let chapter):
            content.preference = preference
            return .pages(id: id, content: content, pluginID: pluginID, entry: entry, chapter: chapter)
        case .text(let id, var content, let pluginID, let entry, let chapter):
            content.preference = preference
            return .text(id: id, content: content, pluginID: pluginID, entry: entry, chapter: chapter)
        case .anime:
            return self
        }
    }
}

struct MediaDetailRouteContext<M: MediaDisplayable> {
    /// Loads the series from its installed source. nil on a saved-only route, which refreshes nothing.
    let loadDetails: ((M, PluginNetworkOperation) async throws -> M)?
    /// Searches for relink targets. nil disables relinking.
    let searchForRelink: ((String, UUID) async throws -> [M])?
    let makeReaderDestination: (M, M.Chapter) -> MediaDetailReaderDestination
    /// Opens one saved copy that was chosen from the series' downloaded alternatives. The reader is chosen from
    /// the copy's own saved form, so it needs no catalog chapter.
    let makeDownloadedAlternativeDestination: (
        M,
        DownloadedChapterAlternative,
        OfflineChapterLease
    ) throws -> MediaDetailReaderDestination
    /// Whether a chapter has a verified offline copy. A saved-only route opens only those chapters.
    var isChapterAvailableOffline: ((M.Chapter) async -> Bool)?
    /// The stored copies of a series, for the saved-only rows of a runner route. It is asked for the series
    /// shown now, which a relink changes. Nil where no offline store is composed.
    var inventoryChapters: ((MediaIdentity) async -> [DownloadedChapterRecord])?
}

/// The one saved-copy choice the series screen can present, tied to this screen's state when it began.
struct DownloadedAlternativeContext {
    /// Stable across the presentation's phases; the sheet reports back with it.
    let id: UUID
    let anchor: OfflineChapterAlternativeAnchor
    let mediaIdentity: MediaIdentity
    let detailGeneration: UInt64
    /// nil is an observed absent epoch, not a failed read.
    let sourceEpoch: String?
}

enum DownloadedAlternativeFailure: Equatable {
    case selection(DownloadedAlternativeError)
    case read(OfflineReadError)
}

/// What the saved-copy chooser shows. The candidates are frozen when they were listed; nothing else caches them.
enum DownloadedAlternativeSelectorState {
    case idle
    case loading(DownloadedAlternativeContext)
    case choosing(
        context: DownloadedAlternativeContext,
        candidates: [DownloadedChapterAlternative],
        selectedCandidateID: String?,
        failure: DownloadedAlternativeFailure?
    )
    case acquiring(
        context: DownloadedAlternativeContext,
        candidates: [DownloadedChapterAlternative],
        selectedCandidateID: String
    )
    case failed(DownloadedAlternativeContext, DownloadedAlternativeFailure)
    /// The copy is leased and its reader prepared; the sheet is closing and the reader opens once it has.
    case handingOff(DownloadedAlternativeContext)

    var context: DownloadedAlternativeContext? {
        switch self {
        case .idle: nil
        case .loading(let context), .failed(let context, _), .handingOff(let context): context
        case .choosing(let context, _, _, _), .acquiring(let context, _, _): context
        }
    }
}

struct MediaDetailTrackerSheetIntent: Identifiable, Equatable {
    let id: UUID
    let mediaIdentity: MediaIdentity
    let title: String
    let isAnime: Bool
}

struct MediaDetailCategoryAssignmentIntent: Identifiable, Equatable {
    let itemID: String
    var id: String { itemID }
}

struct MediaDetailRelinkPresentation: Identifiable, Equatable {
    let id: UUID
    let mediaKey: String
}

/// What a series' detail screen says above its chapters when it shows saved details instead of fresh ones.
struct MediaDetailOfflineNotice: Equatable {
    enum Kind: Equatable {
        /// The details could not be loaded and the device is offline.
        case offline
        /// The series opened without a source that could refresh it.
        case savedOnly
    }

    let kind: Kind
    /// When the saved details were last refreshed from their source; nil when that is not known.
    let refreshedAt: Date?

    /// Shared: formatters are expensive to make, and this runs on every refresh of the line.
    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.formattingContext = .middleOfSentence
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return formatter
    }()

    /// "Updated 3 hours ago", or nil when the age is not known. A saved payload that no refresh wrote,
    /// such as one restored from a backup, has no date rather than a wrong one. A date ahead of `now`
    /// (a clock that moved back) reads as now, never as the future.
    func updatedText(
        relativeTo now: Date,
        formatter: RelativeDateTimeFormatter = MediaDetailOfflineNotice.relativeFormatter
    ) -> String? {
        guard let refreshedAt else { return nil }
        let relative = formatter.localizedString(for: min(refreshedAt, now), relativeTo: now)
        return String(
            localized: "Updated \(relative)",
            comment: "Line under a notice about saved series details. The placeholder is a relative time such as '3 hours ago'."
        )
    }
}
