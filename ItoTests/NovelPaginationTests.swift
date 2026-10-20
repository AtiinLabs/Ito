import UIKit
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class NovelPaginationTests: XCTestCase {
    func testInvalidContainerSizeReturnsNoPaginationResult() {
        let chapter = loadedChapter(key: "one", number: 1, body: "Body")

        XCTAssertNil(enginePaginate([chapter], size: .zero))
        XCTAssertNil(enginePaginate([chapter], size: CGSize(width: 320, height: 0)))
        XCTAssertNil(enginePaginate([chapter], size: CGSize(width: 0, height: 480)))
    }

    func testSamePlaceIsFoundAfterTheTextIsLaidOutAgainLarger() throws {
        let words = (1...1200).map { "word\($0)" }.joined(separator: " ")
        let chapter = loadedChapter(key: "long", number: 1, body: words)
        let size = CGSize(width: 320, height: 520)
        let small = try XCTUnwrap(enginePaginate([chapter], size: size, fontSize: 14))
        let large = try XCTUnwrap(enginePaginate([chapter], size: size, fontSize: 24))
        XCTAssertGreaterThan(large.count, small.count)

        // Reading the middle of the chapter at the small size, then making the text larger.
        let reading = small[small.count / 2]
        let anchor = NovelReadingAnchor(chapterID: chapter.id, offset: reading.startOffset)
        let index = try XCTUnwrap(NovelPagingReaderView.pageIndex(for: anchor, in: large))

        // The page shown is the one whose text contains that place.
        XCTAssertLessThanOrEqual(large[index].startOffset, reading.startOffset)
        if large.indices.contains(index + 1) {
            XCTAssertGreaterThan(large[index + 1].startOffset, reading.startOffset)
        }
    }

    func testShortChapterKeepsImagesAsPagesAtTheirPlaceInTheText() throws {
        let loaded = NovelLoadedChapter(
            chapter: Novel.Chapter(key: "one", title: "Opening", chapter: 1),
            pages: [
                Page(index: 0, content: .text("First paragraph.")),
                Page(
                    index: 1,
                    content: .url("https://example.com/image"),
                    headers: ["Referer": "https://example.com"]
                ),
                Page(index: 2, content: .text("Second paragraph."))
            ]
        )

        let pages = try XCTUnwrap(
            enginePaginate([loaded], size: CGSize(width: 320, height: 480))
        )

        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages.map(\.string.string), [
            "Chapter 1 - Opening\n\nFirst paragraph.\n\n",
            "",
            "Second paragraph.\n\n"
        ])
        XCTAssertEqual(
            pages[1].image,
            NovelPageImage(url: "https://example.com/image", headers: ["Referer": "https://example.com"])
        )
        // Offsets match the continuous reader's: the image sits where the second block starts.
        let starts = NovelTextOffsets.blockStarts(loaded.pages)
        XCTAssertEqual(pages.map(\.startOffset), [0, starts[2], starts[2]])
        XCTAssertEqual(pages.map(\.isLastInChapter), [false, false, true])
    }

    func testLongChapterSpansPagesWithoutTextLossOrDuplication() throws {
        let chapter = loadedChapter(
            key: "long",
            number: 4.5,
            body: String(repeating: "Alpha beta gamma delta. ", count: 300)
        )

        let pages = try XCTUnwrap(
            enginePaginate([chapter], size: CGSize(width: 280, height: 320))
        )

        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.map(\.string.string).joined(), expectedFormattedText([chapter]))
        XCTAssertTrue(pages.allSatisfy { $0.chapter.key == "long" })
    }

    func testMultipleChaptersRemainGroupedInInputOrderWithExactOwnership() throws {
        let chapters = [
            loadedChapter(
                key: "second",
                number: 2,
                body: String(repeating: "Second body. ", count: 120)
            ),
            loadedChapter(key: "first", number: 1, body: "First body.")
        ]

        let pages = try XCTUnwrap(
            enginePaginate(chapters, size: CGSize(width: 300, height: 340))
        )
        let secondCount = pages.filter { $0.chapter.key == "second" }.count

        XCTAssertEqual(
            Array(pages.map(\.chapter.key).prefix(secondCount)),
            Array(repeating: "second", count: secondCount)
        )
        XCTAssertEqual(
            Array(pages.map(\.chapter.key).dropFirst(secondCount)),
            Array(repeating: "first", count: pages.count - secondCount)
        )
        XCTAssertEqual(pages.map(\.string.string).joined(), expectedFormattedText(chapters))
    }

    func testExtractedEngineMatchesLegacyTextKitPageBreaksExactly() throws {
        let chapters = [
            loadedChapter(
                key: "one",
                number: 1,
                body: String(repeating: "A deterministic sentence. ", count: 180)
            ),
            loadedChapter(key: "two", number: nil, title: nil, body: "Tail.")
        ]
        let configurations: [(CGSize, Double, Double)] = [
            (CGSize(width: 300, height: 360), 17, 5),
            (CGSize(width: 390, height: 640), 14, 0),
            (CGSize(width: 260, height: 300), 22, 9)
        ]

        for (size, fontSize, lineSpacing) in configurations {
            let actual = try XCTUnwrap(
                enginePaginate(
                    chapters,
                    size: size,
                    fontSize: fontSize,
                    lineSpacing: lineSpacing
                )
            )
            let legacy = try XCTUnwrap(
                legacyPaginate(
                    chapters,
                    size: size,
                    fontSize: fontSize,
                    lineSpacing: lineSpacing
                )
            )

            XCTAssertEqual(actual.map(\.chapter.key), legacy.map(\.chapter.key))
            XCTAssertEqual(actual.map(\.string.string), legacy.map(\.string.string))
        }
    }

    func testRepeatedCallsReturnEquivalentPages() throws {
        let chapters = [
            loadedChapter(
                key: "repeatable",
                number: 1,
                body: String(repeating: "Repeat. ", count: 200)
            )
        ]
        let size = CGSize(width: 300, height: 360)

        let first = try XCTUnwrap(enginePaginate(chapters, size: size))
        let second = try XCTUnwrap(enginePaginate(chapters, size: size))

        XCTAssertEqual(first.map(\.chapter.key), second.map(\.chapter.key))
        XCTAssertEqual(first.map(\.string.string), second.map(\.string.string))
    }

    func testLargerFontAndLineSpacingDeterministicallyIncreasePagePressure() throws {
        let chapters = [
            loadedChapter(
                key: "sizing",
                number: 1,
                body: String(repeating: "Sizing words stay in order. ", count: 250)
            )
        ]
        let size = CGSize(width: 280, height: 320)

        let smallFont = try XCTUnwrap(
            enginePaginate(chapters, size: size, fontSize: 12, lineSpacing: 0)
        )
        let largeFont = try XCTUnwrap(
            enginePaginate(chapters, size: size, fontSize: 24, lineSpacing: 0)
        )
        let wideSpacing = try XCTUnwrap(
            enginePaginate(chapters, size: size, fontSize: 12, lineSpacing: 14)
        )

        XCTAssertGreaterThan(largeFont.count, smallFont.count)
        XCTAssertGreaterThan(wideSpacing.count, smallFont.count)
        XCTAssertEqual(smallFont.map(\.string.string).joined(), expectedFormattedText(chapters))
        XCTAssertEqual(largeFont.map(\.string.string).joined(), expectedFormattedText(chapters))
        XCTAssertEqual(wideSpacing.map(\.string.string).joined(), expectedFormattedText(chapters))
    }

    func testTitleAndBodyAttributesMatchSystemFontSpacingAndTextColor() throws {
        let chapter = loadedChapter(key: "attributes", number: 1, body: "Body")
        let color = UIColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)

        let pages = try XCTUnwrap(
            enginePaginate(
                [chapter],
                size: CGSize(width: 320, height: 480),
                fontSize: 16,
                lineSpacing: 7,
                textColor: color
            )
        )
        let string = try XCTUnwrap(pages.first?.string)
        let bodyLocation = (string.string as NSString).range(of: "Body").location
        let titleFont = try XCTUnwrap(
            string.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        )
        let bodyFont = try XCTUnwrap(
            string.attribute(.font, at: bodyLocation, effectiveRange: nil) as? UIFont
        )
        let paragraph = try XCTUnwrap(
            string.attribute(.paragraphStyle, at: bodyLocation, effectiveRange: nil)
                as? NSParagraphStyle
        )
        let titleColor = try XCTUnwrap(
            string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        )

        XCTAssertEqual(titleFont.pointSize, 22)
        XCTAssertEqual(bodyFont.pointSize, 16)
        XCTAssertEqual(paragraph.lineSpacing, 7)
        XCTAssertTrue(titleColor.isEqual(color))
    }

    func testTitleFormattingLocksNumericEmptyAndMissingMetadataCases() {
        XCTAssertEqual(
            NovelPaginationEngine.formattedTitle(
                for: Novel.Chapter(key: "a", title: "Name", chapter: 2.5)
            ),
            "Chapter 2.5 - Name"
        )
        XCTAssertEqual(
            NovelPaginationEngine.formattedTitle(
                for: Novel.Chapter(key: "b", title: "", chapter: 3)
            ),
            "Chapter 3"
        )
        XCTAssertEqual(
            NovelPaginationEngine.formattedTitle(
                for: Novel.Chapter(key: "c", title: "Interlude", chapter: nil)
            ),
            "Interlude"
        )
        XCTAssertEqual(
            NovelPaginationEngine.formattedTitle(
                for: Novel.Chapter(key: "d", title: nil, chapter: nil)
            ),
            "Unknown Chapter"
        )
    }

    func testDegenerateUsableSizeTerminatesWithLegacySingleNonemptyPage() throws {
        let chapter = loadedChapter(key: "tiny", number: 1, body: "Body")

        let pages = try XCTUnwrap(
            enginePaginate([chapter], size: CGSize(width: 32, height: 80))
        )
        let legacy = try XCTUnwrap(
            legacyPaginate(
                [chapter],
                size: CGSize(width: 32, height: 80),
                fontSize: 16,
                lineSpacing: 4
            )
        )

        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.map(\.string.string), legacy.map(\.string.string))
        XCTAssertEqual(pages.map(\.string.string).joined(), expectedFormattedText([chapter]))
    }

    func testPaginationDoesNotMutateSourceChapterOrPageFixtures() throws {
        let chapter = Novel.Chapter(
            key: "immutable",
            title: "Title",
            volume: 2,
            chapter: 7,
            dateUpdated: 1_234_567,
            scanlator: "Source",
            url: "https://example.com/chapter",
            lang: "en",
            paywalled: true
        )
        let pages = [
            Page(
                index: 2,
                content: .text("Second"),
                hasDescription: true,
                description: "Second description",
                headers: ["Z-Header": "z", "A-Header": "a"]
            ),
            Page(
                index: 1,
                content: .url("https://example.com/image"),
                headers: ["Authorization": "token"]
            )
        ]
        let chapterBefore = NovelChapterFixtureSnapshot(chapter)
        let pagesBefore = pages.map(PageFixtureSnapshot.init)
        let loaded = NovelLoadedChapter(chapter: chapter, pages: pages)

        _ = enginePaginate([loaded], size: CGSize(width: 320, height: 480))

        XCTAssertEqual(NovelChapterFixtureSnapshot(chapter), chapterBefore)
        XCTAssertEqual(pages.map(PageFixtureSnapshot.init), pagesBefore)

        var changedChapter = chapter
        changedChapter.title = "Changed"
        XCTAssertNotEqual(NovelChapterFixtureSnapshot(changedChapter), chapterBefore)

        var changedPages = pages
        changedPages[0].content = .text("Changed")
        XCTAssertNotEqual(changedPages.map(PageFixtureSnapshot.init), pagesBefore)
        XCTAssertNotEqual(pages.reversed().map(PageFixtureSnapshot.init), pagesBefore)
    }

    private struct NovelChapterFixtureSnapshot: Equatable {
        let key: String
        let title: String?
        let volume: Float32?
        let chapter: Float32?
        let dateUpdated: Double?
        let scanlator: String?
        let url: String?
        let lang: String?
        let paywalled: Bool?

        init(_ chapter: Novel.Chapter) {
            key = chapter.key
            title = chapter.title
            volume = chapter.volume
            self.chapter = chapter.chapter
            dateUpdated = chapter.dateUpdated
            scanlator = chapter.scanlator
            url = chapter.url
            lang = chapter.lang
            paywalled = chapter.paywalled
        }
    }

    private struct PageFixtureSnapshot: Equatable {
        let index: Int32
        let content: PageContentFixtureSnapshot
        let hasDescription: Bool
        let description: String?
        let headers: [HeaderFixtureSnapshot]?

        init(_ page: Page) {
            index = page.index
            switch page.content {
            case .text(let text):
                content = .text(text)
            case .url(let url):
                content = .url(url)
            }
            hasDescription = page.hasDescription
            description = page.description
            headers = page.headers?.map(HeaderFixtureSnapshot.init).sorted {
                if $0.name == $1.name {
                    return $0.value < $1.value
                }
                return $0.name < $1.name
            }
        }
    }

    private enum PageContentFixtureSnapshot: Equatable {
        case text(String)
        case url(String)
    }

    private struct HeaderFixtureSnapshot: Equatable {
        let name: String
        let value: String

        init(_ entry: Dictionary<String, String>.Element) {
            name = entry.key
            value = entry.value
        }
    }

    private struct LegacyPagedItem {
        let chapter: Novel.Chapter
        let string: NSAttributedString
    }

    private func enginePaginate(
        _ loadedChapters: [NovelLoadedChapter],
        size: CGSize,
        fontSize: Double = 16,
        lineSpacing: Double = 4,
        textColor: UIColor = .black
    ) -> [NovelPaginationPage]? {
        NovelPaginationEngine.paginate(
            chapters: loadedChapters.map {
                NovelPaginationChapter(id: $0.id, chapter: $0.chapter, pages: $0.pages)
            },
            configuration: NovelPaginationConfiguration(
                containerSize: size,
                fontSize: fontSize,
                fontFamily: .system,
                lineSpacing: lineSpacing,
                textColor: textColor
            )
        )
    }

    private func legacyPaginate(
        _ loadedChapters: [NovelLoadedChapter],
        size: CGSize,
        fontSize: Double,
        lineSpacing: Double
    ) -> [LegacyPagedItem]? {
        guard size.width > 0 && size.height > 0 else { return nil }
        let usableSize = CGSize(width: size.width - 32, height: size.height - 80)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: fontSize + 6),
            .foregroundColor: UIColor.black
        ]
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraphStyle
        ]

        return loadedChapters.flatMap { loadedChapter in
            let fullString = NSMutableAttributedString()
            fullString.append(
                NSAttributedString(
                    string: formattedTitle(loadedChapter.chapter) + "\n\n",
                    attributes: titleAttributes
                )
            )
            for page in loadedChapter.pages {
                if case .text(let text) = page.content {
                    fullString.append(
                        NSAttributedString(string: text + "\n\n", attributes: bodyAttributes)
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
                if containers.count > 1000 || glyphRange.length == 0 { break }
            } while NSMaxRange(glyphRange) < manager.numberOfGlyphs

            let extracted: [LegacyPagedItem] = containers.compactMap { container in
                let glyphRange = manager.glyphRange(for: container)
                let characterRange = manager.characterRange(
                    forGlyphRange: glyphRange,
                    actualGlyphRange: nil
                )
                guard characterRange.length > 0 else { return nil }
                return LegacyPagedItem(
                    chapter: loadedChapter.chapter,
                    string: storage.attributedSubstring(from: characterRange)
                )
            }
            return extracted
        }
    }

    private func formattedTitle(_ chapter: Novel.Chapter) -> String {
        if let number = chapter.chapter {
            if let title = chapter.title, !title.isEmpty {
                return "Chapter \(number.formatted()) - \(title)"
            }
            return "Chapter \(number.formatted())"
        }
        return chapter.title ?? "Unknown Chapter"
    }

    private func loadedChapter(
        key: String,
        number: Float32?,
        title: String? = "Title",
        body: String
    ) -> NovelLoadedChapter {
        NovelLoadedChapter(
            chapter: Novel.Chapter(key: key, title: title, chapter: number),
            pages: [Page(index: 0, content: .text(body))]
        )
    }

    private func expectedFormattedText(
        _ chapters: [NovelLoadedChapter]
    ) -> String {
        chapters.map { loadedChapter in
            let body = loadedChapter.pages.compactMap { page -> String? in
                guard case .text(let text) = page.content else { return nil }
                return text + "\n\n"
            }.joined()
            return formattedTitle(loadedChapter.chapter) + "\n\n" + body
        }.joined()
    }
}
