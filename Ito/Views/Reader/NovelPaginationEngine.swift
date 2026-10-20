import UIKit
import ito_runner

struct NovelPaginationChapter {
    let id: UUID
    let chapter: Novel.Chapter
    let pages: [Page]
}

struct NovelPaginationConfiguration {
    let containerSize: CGSize
    let fontSize: Double
    let fontFamily: NovelFont
    let lineSpacing: Double
    let textColor: UIColor
}

struct NovelPaginationPage {
    let chapterID: UUID
    let chapter: Novel.Chapter
    let string: NSAttributedString
    /// Offset of the page's first body character; see `NovelTextOffsets`.
    let startOffset: Int
    let isLastInChapter: Bool
}

@MainActor
enum NovelPaginationEngine {
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

        return chapters.flatMap { chapter in
            paginate(
                chapter: chapter,
                usableSize: usableSize,
                titleAttributes: titleAttributes,
                bodyAttributes: bodyAttributes
            )
        }
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

    private static func paginate(
        chapter: NovelPaginationChapter,
        usableSize: CGSize,
        titleAttributes: [NSAttributedString.Key: Any],
        bodyAttributes: [NSAttributedString.Key: Any]
    ) -> [NovelPaginationPage] {
        let fullString = NSMutableAttributedString()
        let title = formattedTitle(for: chapter.chapter) + "\n\n"
        fullString.append(NSAttributedString(string: title, attributes: titleAttributes))
        let titleLength = (title as NSString).length
        for page in chapter.pages {
            if case .text(let text) = page.content {
                fullString.append(
                    NSAttributedString(
                        string: text + NovelTextOffsets.blockSeparator,
                        attributes: bodyAttributes
                    )
                )
            }
        }

        let storage = NSTextStorage(attributedString: fullString)
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
            if containers.count > 1000 || glyphRange.length == 0 {
                break
            }
        } while NSMaxRange(glyphRange) < manager.numberOfGlyphs

        let ranges = containers.compactMap { container -> NSRange? in
            let characterRange = manager.characterRange(
                forGlyphRange: manager.glyphRange(for: container),
                actualGlyphRange: nil
            )
            return characterRange.length > 0 ? characterRange : nil
        }
        return ranges.enumerated().map { index, characterRange in
            NovelPaginationPage(
                chapterID: chapter.id,
                chapter: chapter.chapter,
                string: storage.attributedSubstring(from: characterRange),
                startOffset: max(0, characterRange.location - titleLength),
                isLastInChapter: index == ranges.count - 1
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
