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
}

struct MediaDetailRouteContext<M: MediaDisplayable> {
    /// Loads the series from its installed source. nil on a saved-only route, which refreshes nothing.
    let loadDetails: ((M) async throws -> M)?
    /// Searches for relink targets. nil disables relinking.
    let searchForRelink: ((String) async throws -> [M])?
    let makeReaderDestination: (M, M.Chapter) -> MediaDetailReaderDestination
    /// Whether a chapter has a verified offline copy. A saved-only route opens only those chapters.
    var isChapterAvailableOffline: ((M.Chapter) async -> Bool)?
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
