import SwiftUI

/// The width class of a window, the one rule every width-dependent layout decision reads.
///
/// `regular` requires a regular vertical size class and at least 600 pt of width. `wide` also requires the window to
/// be wider than it is tall and at least 700 pt wide, which is where a list and detail pair fits side by side.
nonisolated enum WidthClass: Equatable, Sendable {
    case compact
    case regular
    case wide

    static let regularMinimumWidth: CGFloat = 600
    static let wideMinimumWidth: CGFloat = 700

    static func make(size: CGSize, verticallyRegular: Bool) -> WidthClass {
        guard verticallyRegular, size.width >= regularMinimumWidth else { return .compact }
        return size.width >= wideMinimumWidth && size.width > size.height ? .wide : .regular
    }

    var spacing: LayoutSpacing {
        switch self {
        case .compact: .compact
        case .regular: .regular
        case .wide: .wide
        }
    }
}

/// The margins and grid gaps for one width class.
nonisolated struct LayoutSpacing: Equatable, Sendable {
    let margin: CGFloat
    let gridSpacing: CGFloat
    let gridRowSpacing: CGFloat

    static let compact = LayoutSpacing(margin: 16, gridSpacing: 12, gridRowSpacing: 14)
    static let regular = LayoutSpacing(margin: 20, gridSpacing: 14, gridRowSpacing: 16)
    static let wide = LayoutSpacing(margin: 24, gridSpacing: 16, gridRowSpacing: 18)

    /// Fixed-width grid columns for a grid inset by `margin` on each side of `width`.
    func gridColumns(forWidth width: CGFloat) -> [GridItem] {
        AdaptiveGridMetrics.columns(forWidth: width - 2 * margin, spacing: gridSpacing)
    }
}

/// Reads the window's width class from the vertical size class and the space it is given, then builds its content.
struct WidthClassReader<Content: View>: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private let content: (WidthClass, CGSize) -> Content

    init(@ViewBuilder content: @escaping (WidthClass, CGSize) -> Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            content(
                WidthClass.make(size: proxy.size, verticallyRegular: verticalSizeClass == .regular),
                proxy.size
            )
        }
    }
}
