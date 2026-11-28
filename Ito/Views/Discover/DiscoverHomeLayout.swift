import Foundation

/// The arrangement of the Discover home: which trending items the banner hero pages through, which shelves the home
/// shows, and how many shelves share a row. These are pure decisions; the views draw their results.
nonisolated enum DiscoverHeroSelection {
    /// The most items the banner hero pages through.
    static let limit = 5

    /// The first trending items that have banner artwork, in AniList's order, up to `limit`. Items without a banner
    /// are skipped because the hero's artwork is the banner.
    static func items(from trending: [DiscoverMedia]) -> [DiscoverMedia] {
        Array(
            trending
                .lazy
                .filter { media in
                    guard let banner = media.bannerImage else { return false }
                    return !banner.isEmpty
                }
                .prefix(limit)
        )
    }
}

/// The shelves below the hero, in display order.
nonisolated enum DiscoverShelfKind: Equatable, CaseIterable {
    case trending
    case seasonal
    case popular
    case topRated
}

struct DiscoverShelf: Equatable, Identifiable {
    let kind: DiscoverShelfKind
    let items: [DiscoverMedia]

    var id: DiscoverShelfKind { kind }
}

nonisolated enum DiscoverShelfLayout {
    /// The non-empty shelves in display order. The seasonal shelf is anime-only.
    static func shelves(for content: DiscoverHomeContent, mediaType: DiscoverMediaType) -> [DiscoverShelf] {
        let candidates = [
            DiscoverShelf(kind: .trending, items: content.trending),
            DiscoverShelf(kind: .seasonal, items: mediaType == .anime ? content.seasonal : []),
            DiscoverShelf(kind: .popular, items: content.popular),
            DiscoverShelf(kind: .topRated, items: content.topRated)
        ]
        return candidates.filter { !$0.items.isEmpty }
    }

    /// Wide width shares each row between two shelves; regular and compact give each shelf its own row.
    static func columns(for widthClass: WidthClass) -> Int {
        widthClass == .wide ? 2 : 1
    }

    /// Groups elements into rows of `columns`, keeping their order. The last row may be shorter.
    static func rows<Element>(_ elements: [Element], columns: Int) -> [[Element]] {
        guard columns > 1 else { return elements.map { [$0] } }
        return stride(from: 0, to: elements.count, by: columns).map { start in
            Array(elements[start..<min(start + columns, elements.count)])
        }
    }
}

nonisolated enum DiscoverHeroMetrics {
    /// Seconds the hero waits on a page before it advances on its own.
    static let autoAdvanceInterval: TimeInterval = 6

    /// The named coordinate space of the Discover home's scroll view, used to tell whether the hero is on screen.
    static let coordinateSpaceName = "discover-home"

    /// The hero's height for its width, kept between 260 and 360 points.
    static func height(forWidth width: CGFloat) -> CGFloat {
        min(max(width * 0.45, 260), 360)
    }
}
