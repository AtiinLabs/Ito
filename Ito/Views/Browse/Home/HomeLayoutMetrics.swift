import CoreGraphics
import Foundation
import SwiftUI

/// Which arrangement a source home uses for the space it has.
nonisolated enum HomeLayoutMode: Equatable {
    /// One column: the hero across the top, the shelves below. Also used for the stacked preference on wide screens.
    case narrow
    /// The hero pinned in a left column while the shelves scroll in the right one.
    case sideBySide

    /// Two columns need a wide, landscape-shaped space with room to stand a cover up. The height that matters is the
    /// window's, not the home's (the navigation and search bars take part of it), so it is judged by the vertical size
    /// class: regular on an unfolded Duo or iPad, compact on a phone held sideways. A portrait Duo (669 pt) and a
    /// folded one (466 pt) are narrow.
    static func make(
        size: CGSize,
        verticallyRegular: Bool,
        preference: SourceHomeWideLayoutPreference
    ) -> HomeLayoutMode {
        guard preference == .sideBySide, verticallyRegular,
              size.width >= 700, size.width > size.height else {
            return .narrow
        }
        return .sideBySide
    }
}

/// Sizes that scale with the space the home gets.
nonisolated enum HomeLayoutMetrics {
    /// Named by the home so the hero can tell whether it is still on screen.
    static let coordinateSpaceName = "source-home"

    /// The poster width for shelves: 110 pt on a phone, growing with the width up to 160 pt.
    static func posterWidth(forWidth width: CGFloat) -> CGFloat {
        min(max(width * 0.22, 110), 160)
    }

    /// The pinned hero column in two-column layouts.
    static func heroColumnWidth(forWidth width: CGFloat) -> CGFloat {
        min(max(width * 0.42, 300), 400)
    }

    /// The narrow hero is tall and full-bleed, but never taller than the space it has.
    static func narrowHeroHeight(forViewportHeight height: CGFloat) -> CGFloat {
        min(height * 0.62, 520)
    }
}

/// Clips a view at its trailing edge only: the right in left-to-right layouts, the left in right-to-left ones. The
/// other edges reach a full view size beyond the frame, so content that scrolls under the navigation bar, the search
/// bar or the home indicator is not cut off.
nonisolated struct TrailingEdgeClip: Shape {
    let layoutDirection: LayoutDirection

    func path(in rect: CGRect) -> Path {
        let x = layoutDirection == .rightToLeft ? rect.minX : rect.minX - rect.width
        return Path(CGRect(x: x, y: rect.minY - rect.height, width: rect.width * 2, height: rect.height * 3))
    }
}
