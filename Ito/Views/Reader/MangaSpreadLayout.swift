import CoreGraphics
import Foundation

/// Two-page spreads for the paged manga reader: which pages share a spread, and how a spread fits
/// the space it is given. Aspects are width over height.
nonisolated enum MangaSpreadLayout {
    /// The aspect assumed for a page whose image size is not known yet. Manga pages are usually
    /// portrait, so an unknown page is treated as narrow until its size arrives.
    static let fallbackAspect: CGFloat = 0.7

    /// The aspect to lay a page out with: its known aspect, or the fallback.
    static func aspect(_ known: CGFloat?) -> CGFloat {
        known ?? fallbackAspect
    }

    /// Whether a page is wider than tall. An unknown page is not wide, so it may pair provisionally.
    static func isWide(_ aspect: CGFloat?) -> Bool {
        (aspect ?? 0) > 1
    }

    /// The page ranges shown together for one chapter's `count` pages, in reading order. Pages share
    /// a spread only when `paired` is true. The first page of a chapter stands alone, and so does a
    /// page wider than tall, along with any page next to one. Pairing never crosses a chapter, since
    /// `count` covers only that chapter's pages.
    static func spreads(count: Int, paired: Bool, aspect: (Int) -> CGFloat?) -> [Range<Int>] {
        NovelReaderLayout.spreads(count: count, spread: paired) { index in
            index > 0 && !isWide(aspect(index)) && !isWide(aspect(index + 1))
        }
    }

    /// The height and per-page widths for `aspects` laid side by side with no gutter, scaled as
    /// large as possible within `size`. The spread is never taller than the space it is given.
    static func fit(aspects: [CGFloat], in size: CGSize) -> (height: CGFloat, widths: [CGFloat]) {
        let total = aspects.reduce(0, +)
        guard total > 0, size.width > 0, size.height > 0 else {
            return (0, aspects.map { _ in 0 })
        }
        let height = min(size.height, size.width / total)
        return (height, aspects.map { $0 * height })
    }

    /// The order pages sit on screen, left to right, for a spread of `range`. A right-to-left spread
    /// reads from the right, so its later page is on the left and its earlier page on the right.
    static func order(_ range: Range<Int>, isRightToLeft: Bool) -> [Int] {
        isRightToLeft ? Array(range.reversed()) : Array(range)
    }

    /// The frame of each page in `aspects`, given left to right: pages sit side by side with no gutter
    /// at the fitted height, and the block is centered horizontally and vertically within `size`.
    static func frames(aspects: [CGFloat], in size: CGSize) -> [CGRect] {
        let fitted = fit(aspects: aspects, in: size)
        let total = fitted.widths.reduce(0, +)
        var x = (size.width - total) / 2
        let y = (size.height - fitted.height) / 2
        var frames: [CGRect] = []
        for width in fitted.widths {
            frames.append(CGRect(x: x, y: y, width: width, height: fitted.height))
            x += width
        }
        return frames
    }
}
