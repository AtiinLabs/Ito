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
