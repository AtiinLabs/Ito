import Foundation
import ito_runner

/// Where one displayed chapter sits on the series' reading thread.
enum ChapterThreadRole: Equatable {
    case read
    case unread
    /// The unit the series' Resume opens. It is marked even when it is already read, as when a finished series
    /// is read again.
    case upNext

    var accessibilityValue: String {
        switch self {
        case .read:
            String(localized: "Read", comment: "Accessibility value of a chapter row on the series page that has been read.")
        case .unread:
            String(localized: "Unread", comment: "Accessibility value of a chapter row on the series page that has not been read.")
        case .upNext:
            String(localized: "Up next", comment: "Accessibility value of the chapter row on the series page that Resume opens.")
        }
    }
}

/// How one row draws its part of the thread: its own role and whether the thread above and below it exists and is filled.
/// Filled runs from a read unit to the next one, so the thread shows how far the reading has come in the order on screen.
struct ChapterThreadStep: Equatable {
    let role: ChapterThreadRole
    let hasLeadingThread: Bool
    let leadingFilled: Bool
    let hasTrailingThread: Bool
    let trailingFilled: Bool
}

/// Pure decisions behind the series page's reading thread. The rows are in the order the screen shows them,
/// so the thread follows a descending or ascending sort alike.
enum ChapterThreadLayout {
    /// The role of each row. `upNextKey` marks at most one row: the first with that key. A key that no row has marks none.
    static func roles(for rows: [(key: String, isRead: Bool)], upNextKey: String?) -> [ChapterThreadRole] {
        let upNextIndex = upNextKey.flatMap { key in rows.firstIndex { $0.key == key } }
        return rows.indices.map { index in
            if index == upNextIndex { return .upNext }
            return rows[index].isRead ? .read : .unread
        }
    }

    /// The thread segments and knot of each row, from the roles in screen order.
    static func steps(for roles: [ChapterThreadRole]) -> [ChapterThreadStep] {
        roles.indices.map { index in
            ChapterThreadStep(
                role: roles[index],
                hasLeadingThread: index > 0,
                leadingFilled: index > 0 && roles[index - 1] == .read,
                hasTrailingThread: index < roles.count - 1,
                trailingFilled: roles[index] == .read
            )
        }
    }

    /// The number a unit is shown by, such as "Chapter 12" or "Episode 3". A unit without a number shows a dash.
    static func numberLabel<C: ChapterDisplayable>(for chapter: C) -> String {
        let isEpisode = chapter is Anime.Episode
        guard let number = chapter.chapterNumber else {
            return isEpisode
                ? String(localized: "Episode —", comment: "Series page 'Up next' card: an episode the source gave no number for.")
                : String(localized: "Chapter —", comment: "Series page 'Up next' card: a chapter the source gave no number for.")
        }
        let text = number.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(number)) : String(number)
        return isEpisode
            ? String(localized: "Episode \(text)", comment: "Series page 'Up next' card: an episode number, such as Episode 3.")
            : String(localized: "Chapter \(text)", comment: "Series page 'Up next' card: a chapter number, such as Chapter 12.")
    }
}
