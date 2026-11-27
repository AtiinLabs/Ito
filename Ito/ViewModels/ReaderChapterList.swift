import Foundation
import ito_runner

/// One row of the reader's chapter list.
struct ReaderChapterListRow: Identifiable {
    enum Availability: Equatable {
        case current
        case opensHere
        case opensInOtherReader
        case locked
        case notDownloaded
    }

    /// The chapter's place in the route's list, stable for the route's snapshot.
    let id: Int
    let chapter: Chapter
    let isRead: Bool
    let availability: Availability

    var isSelectable: Bool {
        switch availability {
        case .current, .opensHere, .opensInOtherReader: true
        case .locked, .notDownloaded: false
        }
    }
}

@MainActor
enum ReaderChapterList {
    /// Rows in the series page's default order: highest number first, unnumbered after, ties in list order.
    /// The current row is the one byte-identical to `current`; every other row takes its availability from
    /// `boundary`, which resolves what picking that chapter would do.
    static func rows(
        chapters: [Chapter],
        current: Chapter,
        isRead: (Chapter) -> Bool,
        boundary: (Chapter) -> ReaderChapterBoundary<Chapter>
    ) -> [ReaderChapterListRow] {
        let currentToken = ChapterToken(current)
        let order = chapters.indices.sorted { lhs, rhs in
            precedes(chapters[lhs], at: lhs, chapters[rhs], at: rhs)
        }
        return order.map { index in
            let chapter = chapters[index]
            let availability: ReaderChapterListRow.Availability =
                ChapterToken(chapter).isByteIdentical(to: currentToken)
                ? .current
                : availability(of: boundary(chapter))
            return ReaderChapterListRow(
                id: index,
                chapter: chapter,
                isRead: isRead(chapter),
                availability: availability
            )
        }
    }

    /// How a row's chapter opens from this reader. `.end` and `.groupConsent` never come from a pick's boundary;
    /// they map to `.locked` so they fail closed.
    static func availability(of boundary: ReaderChapterBoundary<Chapter>) -> ReaderChapterListRow.Availability {
        switch boundary {
        case .chapter: .opensHere
        case .handoff: .opensInOtherReader
        case .locked, .end, .groupConsent: .locked
        case .notAvailableOffline: .notDownloaded
        }
    }

    /// Series-page order: a higher chapter number comes first, an unnumbered chapter follows every numbered one,
    /// and chapters with equal numbers keep their list order.
    private static func precedes(_ lhs: Chapter, at lhsIndex: Int, _ rhs: Chapter, at rhsIndex: Int) -> Bool {
        switch (lhs.chapterNumber, rhs.chapterNumber) {
        case let (left?, right?) where left != right: left > right
        case (_?, nil): true
        case (nil, _?): false
        default: lhsIndex < rhsIndex
        }
    }
}
