import CoreGraphics

/// How the series page arranges its header and chapter list for the space it is given.
enum MediaDetailLayout: Equatable {
    /// One scrolling column with the header, controls, and chapters stacked, as on phones and narrow windows.
    case singleColumn
    /// The header and controls stay in a leading column while the chapter list scrolls beside it.
    case twoColumns(leadingWidth: CGFloat)

    /// Two columns need the wide width class, the same rule the home uses for its side-by-side layout, so a folded or
    /// narrow window keeps the single column it always had.
    static func make(widthClass: WidthClass, width: CGFloat) -> MediaDetailLayout {
        guard widthClass == .wide else { return .singleColumn }
        // The leading column grows with the window but stays wide enough for the cover beside the metadata.
        return .twoColumns(leadingWidth: min(max(width * 0.38, 340), 380))
    }
}
