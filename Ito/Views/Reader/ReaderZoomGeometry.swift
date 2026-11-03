import CoreGraphics

/// Native zoom targets use content coordinates; touch positions use viewport coordinates.
nonisolated enum ReaderZoomGeometry {
    static let doubleTapScale: CGFloat = 2.5
    static let maximumScale: CGFloat = 4

    static func targetRect(
        contentPoint: CGPoint,
        viewportPoint: CGPoint,
        viewportSize: CGSize,
        scale: CGFloat
    ) -> CGRect {
        CGRect(
            x: contentPoint.x - viewportPoint.x / scale,
            y: contentPoint.y - viewportPoint.y / scale,
            width: viewportSize.width / scale,
            height: viewportSize.height / scale
        )
    }

    static func documentViewport(contentOffset: CGPoint, viewportSize: CGSize, scale: CGFloat) -> CGRect {
        CGRect(
            x: contentOffset.x / scale,
            y: contentOffset.y / scale,
            width: viewportSize.width / scale,
            height: viewportSize.height / scale
        )
    }
}
