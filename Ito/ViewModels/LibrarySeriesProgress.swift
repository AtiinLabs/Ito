import Foundation
import ito_runner

/// Read progress for one Library series: how many of its distinct chapters or episodes are read.
nonisolated struct LibrarySeriesProgress: Equatable, Sendable {
    let readCount: Int
    let totalCount: Int

    /// The Library shows progress only once reading has started and the total is known.
    var isVisible: Bool { totalCount > 0 && readCount > 0 }

    /// The filled share of the progress line, in 0...1.
    var fraction: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, Double(readCount) / Double(totalCount))
    }
}

/// One chapter or episode of a series, reduced to what progress counting needs.
nonisolated struct LibraryChapterReference: Equatable, Sendable {
    /// Chapters and episodes that count as one unit. Anime episodes group by their finite number, so
    /// duplicate uploads of the same episode count once; everything else groups by its key.
    enum Group: Hashable, Sendable {
        case number(Float)
        case key(String)
    }

    let key: String
    let chapterNumber: Float?
    let group: Group

    init(key: String, chapterNumber: Float?, groupsByNumber: Bool) {
        self.key = key
        self.chapterNumber = chapterNumber
        if groupsByNumber, let number = chapterNumber, number.isFinite {
            group = .number(number)
        } else {
            group = .key(key)
        }
    }

    /// The references of a stored payload, in the series' own chapter order.
    @MainActor static func references(in media: DeferredPluginMedia) -> [LibraryChapterReference] {
        switch media {
        case .manga(let manga):
            return (manga.chapterList ?? []).map {
                LibraryChapterReference(key: $0.key, chapterNumber: $0.chapterNumber, groupsByNumber: false)
            }
        case .novel(let novel):
            return (novel.chapterList ?? []).map {
                LibraryChapterReference(key: $0.key, chapterNumber: $0.chapterNumber, groupsByNumber: false)
            }
        case .anime(let anime):
            return (anime.chapterList ?? []).map {
                LibraryChapterReference(key: $0.key, chapterNumber: $0.chapterNumber, groupsByNumber: true)
            }
        }
    }
}

/// Counts a series' read progress from its chapter references.
nonisolated enum LibrarySeriesProgressCalculator {
    /// A group is read when any of its references is read, so the read count never exceeds the total.
    static func progress(
        references: [LibraryChapterReference],
        isRead: (LibraryChapterReference) -> Bool
    ) -> LibrarySeriesProgress {
        var groups = Set<LibraryChapterReference.Group>()
        var readGroups = Set<LibraryChapterReference.Group>()
        for reference in references {
            groups.insert(reference.group)
            if !readGroups.contains(reference.group), isRead(reference) {
                readGroups.insert(reference.group)
            }
        }
        return LibrarySeriesProgress(readCount: readGroups.count, totalCount: groups.count)
    }
}

/// The series the Library's Continue card resumes: the one with the most recent read in History.
nonisolated struct LibraryContinueEntry {
    let item: LibraryItem
    let record: ReadingHistoryRecord
}

enum LibraryContinueSelection {
    /// The record read most recently, or nil when History is empty.
    static func latestRecord(in entries: [HistoryEntry]) -> ReadingHistoryRecord? {
        entries.max { $0.record.readAt < $1.record.readAt }?.record
    }
}

/// Whether the Library shows its Continue card: only in a compact list column that is not split beside a detail.
nonisolated enum LibraryContinueVisibility {
    static func isShown(isCompact: Bool, arrangement: PaneArrangement) -> Bool {
        isCompact && arrangement != .split
    }
}
