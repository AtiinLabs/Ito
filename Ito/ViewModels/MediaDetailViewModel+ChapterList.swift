import Foundation
import ito_runner

extension MediaDetailViewModel {
    /// The listed chapters after the filter and sort order, without the saved-only rows.
    var listedDisplayedChapters: [M.Chapter] {
        guard let chapters = media.chapterList else { return [] }
        let filtered: [M.Chapter]
        switch filterOption {
        case .all: filtered = chapters
        case .unread: filtered = chapters.filter { !isRead($0) }
        case .read: filtered = chapters.filter { isRead($0) }
        }
        switch sortOrder {
        case .descending:
            return filtered.sorted { ($0.chapterNumber ?? -Float.infinity) > ($1.chapterNumber ?? -Float.infinity) }
        case .ascending:
            return filtered.sorted { ($0.chapterNumber ?? Float.infinity) < ($1.chapterNumber ?? Float.infinity) }
        case .dateDescending:
            return filtered.sorted { ($0.dateUpload ?? "") > ($1.dateUpload ?? "") }
        case .dateAscending:
            return filtered.sorted { ($0.dateUpload ?? "") < ($1.dateUpload ?? "") }
        }
    }

    /// The listed chapters, then the saved editions the list no longer has. Absence from the list is not
    /// deletion: those copies stay readable and deletable.
    var displayedChapters: [M.Chapter] {
        let listed = listedDisplayedChapters
        let savedOnly = downloadBatch.savedOnlyChapters.compactMap { $0 as? M.Chapter }.filter { chapter in
            switch filterOption {
            case .all: true
            case .unread: !isRead(chapter)
            case .read: isRead(chapter)
            }
        }
        guard !savedOnly.isEmpty else { return listed }
        let ascending = sortOrder == .ascending || sortOrder == .dateAscending
        return listed + savedOnly.sorted {
            ascending
                ? ($0.chapterNumber ?? Float.infinity) < ($1.chapterNumber ?? Float.infinity)
                : ($0.chapterNumber ?? -Float.infinity) > ($1.chapterNumber ?? -Float.infinity)
        }
    }

    /// Whether the screen offers to link the series to a source: it is saved, a source can be searched and
    /// the list has no chapters. Saved editions listed below it do not replace the offer.
    var offersRelinkBanner: Bool {
        isSaved && canRelink && (media.chapterList ?? []).isEmpty
    }

    /// The number of saved editions the list does not have, for the count beside the title.
    var savedOnlyChapterCount: Int { downloadBatch.savedOnlyChapters.count }
}
