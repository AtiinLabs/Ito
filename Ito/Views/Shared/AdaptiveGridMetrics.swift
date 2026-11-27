import SwiftUI

/// Column count and cell width for grids that follow the width they are given.
///
/// Grids take their width from the container they sit in, not from the device model,
/// so a folded or unfolded foldable, an iPad split view, and a phone each get the
/// number of columns that fits the space actually available.
nonisolated enum AdaptiveGridMetrics {
    /// Cells never shrink below this so titles and posters stay legible.
    static let minimumCellWidth: CGFloat = 100
    /// Cells stay within this range when a count exists that keeps them there.
    static let maximumCellWidth: CGFloat = 160
    /// Among the counts that keep cells in range, the one closest to this width wins.
    static let preferredCellWidth: CGFloat = 130

    /// The number of columns for `width`, choosing the count whose cell is closest to `preferredCellWidth`.
    ///
    /// Only counts whose cell stays within `minimumCellWidth...maximumCellWidth` are considered.
    /// When no count fits that range (a width falling between two counts), the widest count
    /// that keeps cells at or above the minimum is used instead.
    static func columnCount(forWidth width: CGFloat, spacing: CGFloat) -> Int {
        let largest = largestCount(forWidth: width, spacing: spacing)
        var best: (count: Int, distance: CGFloat)?
        for count in 1...largest {
            let cell = cellWidth(forWidth: width, columns: count, spacing: spacing)
            guard (minimumCellWidth...maximumCellWidth).contains(cell) else { continue }
            let distance = abs(cell - preferredCellWidth)
            if let current = best, current.distance <= distance { continue }
            best = (count, distance)
        }
        return best?.count ?? largest
    }

    /// The width of one cell when `width` is divided into `columns` columns separated by `spacing`.
    static func cellWidth(forWidth width: CGFloat, columns: Int, spacing: CGFloat) -> CGFloat {
        let available = max(0, width) - spacing * CGFloat(columns - 1)
        return available / CGFloat(columns)
    }

    /// Fixed-width grid items for `width`, ready for `LazyVGrid`.
    static func columns(forWidth width: CGFloat, spacing: CGFloat) -> [GridItem] {
        let count = columnCount(forWidth: width, spacing: spacing)
        let cell = cellWidth(forWidth: width, columns: count, spacing: spacing)
        // Top-aligned so a two-line title doesn't push its cover up the row.
        return Array(
            repeating: GridItem(.fixed(cell), spacing: spacing, alignment: .top),
            count: count
        )
    }

    /// The most columns that keep every cell at or above `minimumCellWidth`, never less than one.
    private static func largestCount(forWidth width: CGFloat, spacing: CGFloat) -> Int {
        let fitting = (max(0, width) + spacing) / (minimumCellWidth + spacing)
        return max(1, Int(fitting.rounded(.down)))
    }
}
