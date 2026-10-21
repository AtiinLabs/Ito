import UIKit
import ito_runner

nonisolated struct NovelPaginationChapter: Sendable {
    let id: UUID
    let chapter: Novel.Chapter
    let pages: [Page]
}

nonisolated struct NovelPaginationConfiguration: Sendable {
    let containerSize: CGSize
    let fontSize: Double
    let fontFamily: NovelFont
    let lineSpacing: Double
    let textColor: UIColor
}

/// An illustration shown as a page of its own.
nonisolated struct NovelPageImage: Sendable, Equatable {
    let url: String
    let headers: [String: String]?
}

/// One laid-out page. Sendable because `string` is built once and never mutated afterwards.
nonisolated struct NovelPaginationPage: @unchecked Sendable {
    let chapterID: UUID
    let chapter: Novel.Chapter
    /// The page's text; empty for an image page.
    let string: NSAttributedString
    /// Offset of the page's first body character; see `NovelTextOffsets`.
    let startOffset: Int
    var isLastInChapter: Bool
    var image: NovelPageImage?

    /// The same page in another text colour; colour does not change where pages break.
    func recolored(_ color: UIColor) -> NovelPaginationPage {
        let copy = NSMutableAttributedString(attributedString: string)
        copy.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: copy.length))
        return NovelPaginationPage(
            chapterID: chapterID,
            chapter: chapter,
            string: copy,
            startOffset: startOffset,
            isLastInChapter: isLastInChapter,
            image: image
        )
    }
}

/// Pure TextKit layout with no shared state, so it can run off the main thread.
nonisolated enum NovelPaginationEngine {
    static func paginate(
        chapters: [NovelPaginationChapter],
        configuration: NovelPaginationConfiguration
    ) -> [NovelPaginationPage]? {
        guard configuration.containerSize.width > 0,
              configuration.containerSize.height > 0 else {
            return nil
        }

        let usableSize = CGSize(
            width: configuration.containerSize.width - 32,
            height: configuration.containerSize.height - 80
        )
        let fonts = fonts(
            family: configuration.fontFamily,
            size: configuration.fontSize
        )
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: fonts.title,
            .foregroundColor: configuration.textColor
        ]
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = configuration.lineSpacing
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: fonts.body,
            .foregroundColor: configuration.textColor,
            .paragraphStyle: paragraphStyle
        ]

        var pages: [NovelPaginationPage] = []
        for chapter in chapters {
            // A newer layout request replaced this one; stop rather than finish unused work.
            if Task.isCancelled { return nil }
            pages += paginate(
                chapter: chapter,
                usableSize: usableSize,
                titleAttributes: titleAttributes,
                bodyAttributes: bodyAttributes
            )
        }
        return pages
    }

    static func formattedTitle(for chapter: Novel.Chapter) -> String {
        if let number = chapter.chapter {
            if let title = chapter.title, !title.isEmpty {
                return "Chapter \(number.formatted()) - \(title)"
            }
            return "Chapter \(number.formatted())"
        }
        return chapter.title ?? "Unknown Chapter"
    }

    /// Lays out one chapter. Text between images flows across pages; each image is a page of
    /// its own at the offset where it appears, so text after it starts on a new page.
    private static func paginate(
        chapter: NovelPaginationChapter,
        usableSize: CGSize,
        titleAttributes: [NSAttributedString.Key: Any],
        bodyAttributes: [NSAttributedString.Key: Any]
    ) -> [NovelPaginationPage] {
        var pages: [NovelPaginationPage] = []
        let title = formattedTitle(for: chapter.chapter) + "\n\n"
        var run = NSMutableAttributedString(string: title, attributes: titleAttributes)
        var runTitleLength = (title as NSString).length
        var runStart = 0
        var offset = 0
        for page in chapter.pages {
            switch page.content {
            case .text(let text):
                let block = text + NovelTextOffsets.blockSeparator
                run.append(NSAttributedString(string: block, attributes: bodyAttributes))
                offset += (block as NSString).length
            case .url(let url):
                pages += layOut(
                    run,
                    titleLength: runTitleLength,
                    bodyStart: runStart,
                    chapter: chapter,
                    usableSize: usableSize
                )
                pages.append(
                    NovelPaginationPage(
                        chapterID: chapter.id,
                        chapter: chapter.chapter,
                        string: NSAttributedString(),
                        startOffset: offset,
                        isLastInChapter: false,
                        image: NovelPageImage(url: url, headers: page.headers)
                    )
                )
                run = NSMutableAttributedString()
                runTitleLength = 0
                // The image takes one offset unit, matching `NovelTextOffsets`.
                offset += 1
                runStart = offset
            }
        }
        pages += layOut(
            run,
            titleLength: runTitleLength,
            bodyStart: runStart,
            chapter: chapter,
            usableSize: usableSize
        )
        if let last = pages.indices.last {
            pages[last].isLastInChapter = true
        }
        return pages
    }

    /// Breaks one run of text into pages. `bodyStart` is the body offset where the run starts;
    /// the first `titleLength` characters are the chapter title, which has no body offset.
    private static func layOut(
        _ run: NSAttributedString,
        titleLength: Int,
        bodyStart: Int,
        chapter: NovelPaginationChapter,
        usableSize: CGSize
    ) -> [NovelPaginationPage] {
        guard run.length > 0 else { return [] }
        let storage = NSTextStorage(attributedString: run)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        var containers: [NSTextContainer] = []
        var glyphRange = NSRange(location: 0, length: 0)

        repeat {
            let container = NSTextContainer(size: usableSize)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            containers.append(container)
            glyphRange = manager.glyphRange(for: container)
            // A page that takes no text means nothing more fits (the size is too small), so
            // stop; otherwise every page takes text and the loop ends with the chapter.
            if glyphRange.length == 0 {
                break
            }
        } while NSMaxRange(glyphRange) < manager.numberOfGlyphs

        return containers.compactMap { container -> NovelPaginationPage? in
            let characterRange = manager.characterRange(
                forGlyphRange: manager.glyphRange(for: container),
                actualGlyphRange: nil
            )
            guard characterRange.length > 0 else { return nil }
            return NovelPaginationPage(
                chapterID: chapter.id,
                chapter: chapter.chapter,
                string: storage.attributedSubstring(from: characterRange),
                startOffset: bodyStart + max(0, characterRange.location - titleLength),
                isLastInChapter: false
            )
        }
    }

    private static func fonts(
        family: NovelFont,
        size: Double
    ) -> (title: UIFont, body: UIFont) {
        (
            family.uiFont(size: CGFloat(size) + 6, isBold: true),
            family.uiFont(size: CGFloat(size))
        )
    }
}
