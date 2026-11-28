import CoreGraphics
import Foundation

/// Layout rules for the novel reader that depend only on the window size and the font size.
nonisolated enum NovelReaderLayout {
    /// Space between the text and the edge of its page.
    static let pageInset: CGFloat = 16
    /// Space between the two pages of a spread.
    static let spreadGutter: CGFloat = 32
    /// Space between a spread's two-page block and the edges of the safe area.
    static let spreadMargin: CGFloat = 44

    /// The widest line of text at a font size. The width grows with the font so that lines keep
    /// roughly the same number of characters, and it stays between 600 and 680 points. The 600 point
    /// floor keeps phone-width windows exactly as wide as before.
    static func readableTextWidth(fontSize: Double) -> CGFloat {
        min(680, max(600, CGFloat(fontSize) * 34))
    }

    /// The width of one page's text, given the width available inside the safe area. A spread
    /// keeps the spread margin on each side and splits the rest into two pages with the gutter
    /// between them. A single column keeps the page inset on each side.
    static func pageTextWidth(availableWidth: CGFloat, fontSize: Double, spread: Bool) -> CGFloat {
        let contentWidth = spread
            ? max(0, availableWidth - 2 * spreadMargin)
            : max(0, availableWidth - 2 * pageInset)
        let columnWidth = spread ? max(0, (contentWidth - spreadGutter) / 2) : contentWidth
        return min(columnWidth, readableTextWidth(fontSize: fontSize))
    }

    /// Two pages share a window only in the wide width class.
    static func showsSpread(widthClass: WidthClass) -> Bool {
        widthClass == .wide
    }

    /// Groups `count` pages into the ranges shown together, in order. Page `i` shares a spread with
    /// page `i + 1` only when `canShare(i)` is true and the spread layout is on. Otherwise each page
    /// stands alone. `canShare` is never called with an index at or past `count - 1`.
    static func spreads(count: Int, spread: Bool, canShare: (Int) -> Bool) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while start < count {
            let end = spread && start + 1 < count && canShare(start) ? start + 2 : start + 1
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    /// The position in `spreads` of the range that contains `page`.
    static func spreadIndex(containing page: Int, in spreads: [Range<Int>]) -> Int? {
        spreads.firstIndex { $0.contains(page) }
    }
}
