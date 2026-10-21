import XCTest
import ito_runner
@testable import Ito

@MainActor
final class ReaderChapterOrderingTests: XCTestCase {
    func testChapterTitlePrefersTitleThenNumberWithoutTrailingZero() {
        XCTAssertEqual(ReaderChapterTitle.text(title: "Prologue", number: 3), "Prologue")
        XCTAssertEqual(ReaderChapterTitle.text(title: "", number: 12), "Chapter 12")
        XCTAssertEqual(ReaderChapterTitle.text(title: nil, number: 12.5), "Chapter 12.5")
        XCTAssertEqual(ReaderChapterTitle.text(title: nil, number: nil), "Unknown Chapter")
    }

    func testMangaNextAndPreviousUseClosestNumericChapterIndependentOfInputOrder() {
        let current = mangaChapter("current", number: 2, scanlator: "preferred")
        let one = mangaChapter("one", number: 1)
        let onePointFive = mangaChapter("one-point-five", number: 1.5)
        let three = mangaChapter("three", number: 3)
        let four = mangaChapter("four", number: 4)
        let orders = [
            [one, onePointFive, current, three, four],
            [four, three, current, onePointFive, one],
            [four, one, three, current, onePointFive]
        ]

        for chapters in orders {
            XCTAssertEqual(mangaAfter(current, in: chapters)?.key, "three")
            XCTAssertEqual(mangaBefore(current, in: chapters)?.key, "one-point-five")
        }
    }

    func testMangaFractionalChaptersAndStrictEpsilonBoundaryArePreserved() {
        let currentNumber: Float32 = 1.5
        let current = mangaChapter("current", number: currentNumber)
        let atNextBoundary = currentNumber + 0.0001
        let atPreviousBoundary = currentNumber - 0.0001
        let chapters = [
            current,
            mangaChapter("next-boundary", number: atNextBoundary),
            mangaChapter("next-outside", number: currentNumber + 0.0002),
            mangaChapter("previous-boundary", number: atPreviousBoundary),
            mangaChapter("previous-outside", number: currentNumber - 0.0002)
        ]
        XCTAssertEqual(mangaAfter(current, in: chapters)?.key, "next-outside")
        XCTAssertEqual(mangaBefore(current, in: chapters)?.key, "previous-outside")
    }

    func testMangaDuplicateNumberPrefersCurrentScanlatorThenFallsBackToFirstSource() {
        let current = mangaChapter("current", number: 1, scanlator: "preferred")
        let chapters = [
            current,
            mangaChapter("fallback", number: 2, scanlator: "other"),
            mangaChapter("preferred", number: 2, scanlator: "preferred")
        ]
        XCTAssertEqual(mangaAfter(current, in: chapters)?.key, "preferred")

        let unavailableCurrent = mangaChapter("current", number: 1, scanlator: "missing")
        XCTAssertEqual(mangaAfter(unavailableCurrent, in: chapters)?.key, "fallback")
    }

    func testMangaSourcePreferenceUsesReaderCurrentChapterForSegmentNavigation() {
        let readerCurrent = mangaChapter("reader-current", number: 1, scanlator: "reader-source")
        let segmentChapter = mangaChapter("segment", number: 2, scanlator: "segment-source")
        let chapters = [
            readerCurrent,
            segmentChapter,
            mangaChapter("reader-choice", number: 3, scanlator: "reader-source"),
            mangaChapter("segment-choice", number: 3, scanlator: "segment-source")
        ]
        XCTAssertEqual(
            mangaAfter(
                segmentChapter,
                in: chapters,
                preferredScanlator: readerCurrent.scanlator
            )?.key,
            "reader-choice"
        )
    }

    func testMangaFallbackRepresentationDependsOnSourceArrayOrder() {
        let current = mangaChapter("current", number: 1, scanlator: "missing")
        let first = mangaChapter("first", number: 2, scanlator: "one")
        let second = mangaChapter("second", number: 2, scanlator: "two")

        XCTAssertEqual(mangaAfter(current, in: [current, first, second])?.key, "first")
        XCTAssertEqual(mangaAfter(current, in: [current, second, first])?.key, "second")
    }

    func testMangaUnnumberedChapterMovesByListPositionNewestFirst() {
        let newer = mangaChapter("newer", number: nil)
        let current = mangaChapter("current", number: nil)
        let older = mangaChapter("older", number: nil)
        let chapters = [newer, current, older]

        XCTAssertEqual(mangaAfter(current, in: chapters)?.key, "newer")
        XCTAssertEqual(mangaBefore(current, in: chapters)?.key, "older")
        XCTAssertNil(mangaAfter(newer, in: chapters))
        XCTAssertNil(mangaBefore(older, in: chapters))
    }

    func testMangaNumberedChapterSkipsUnnumberedExtras() {
        let two = mangaChapter("two", number: 2)
        let extra = mangaChapter("extra", number: nil)
        let one = mangaChapter("one", number: 1)
        let chapters = [two, extra, one]

        XCTAssertNil(mangaBefore(one, in: chapters))
        XCTAssertEqual(mangaAfter(one, in: chapters)?.key, "two")
        XCTAssertNil(mangaAfter(two, in: chapters))
    }

    func testMangaMissingCurrentStillNavigatesNumericallyAndBoundariesReturnNil() {
        let missing = mangaChapter("missing", number: 2)
        let chapters = [mangaChapter("one", number: 1), mangaChapter("three", number: 3)]
        XCTAssertEqual(mangaAfter(missing, in: chapters)?.key, "three")
        XCTAssertEqual(mangaBefore(missing, in: chapters)?.key, "one")
        XCTAssertNil(mangaAfter(mangaChapter("last", number: 3), in: chapters))
        XCTAssertNil(mangaBefore(mangaChapter("first", number: 1), in: chapters))
    }

    func testNovelNumericNavigationUsesClosestNumberForAscendingDescendingAndUnorderedInput() {
        let current = novelChapter("current", number: 2)
        let orders = [
            [novelChapter("one", number: 1), current, novelChapter("three", number: 3)],
            [novelChapter("three", number: 3), current, novelChapter("one", number: 1)],
            [novelChapter("three", number: 3), novelChapter("one", number: 1), current]
        ]

        for chapters in orders {
            XCTAssertEqual(novelAfter(current, in: chapters)?.key, "three")
            XCTAssertEqual(novelBefore(current, in: chapters)?.key, "one")
        }
    }

    func testNovelFractionalChaptersAndStrictEpsilonBoundaryArePreserved() {
        let currentNumber: Float32 = 2.5
        let current = novelChapter("current", number: currentNumber)
        let chapters = [
            current,
            novelChapter("next-boundary", number: currentNumber + 0.0001),
            novelChapter("next-outside", number: currentNumber + 0.0002),
            novelChapter("previous-boundary", number: currentNumber - 0.0001),
            novelChapter("previous-outside", number: currentNumber - 0.0002)
        ]
        XCTAssertEqual(novelAfter(current, in: chapters)?.key, "next-outside")
        XCTAssertEqual(novelBefore(current, in: chapters)?.key, "previous-outside")
    }

    func testNovelNilCurrentNumberUsesListPositionNewestFirst() {
        let newer = novelChapter("newer", number: nil)
        let current = novelChapter("current", number: nil)
        let older = novelChapter("older", number: nil)
        let chapters = [newer, current, older]

        XCTAssertEqual(novelAfter(current, in: chapters)?.key, "newer")
        XCTAssertEqual(novelBefore(current, in: chapters)?.key, "older")
    }

    func testNovelListEndsHaveNoNeighborInsteadOfTheOppositeOne() {
        let first = novelChapter("first", number: nil)
        let second = novelChapter("second", number: nil)
        let chapters = [first, second]

        XCTAssertNil(novelAfter(first, in: chapters))
        XCTAssertNil(novelBefore(second, in: chapters))
    }

    func testNovelLatestAndFirstNumberedChaptersHaveNoNextOrPrevious() {
        // Newest first, as plugins list them: the latest chapter must not lead back to the one
        // before it, which made Seamless Reading alternate between the two.
        let one = novelChapter("one", number: 1)
        let two = novelChapter("two", number: 2)
        let chapters = [two, one]

        XCTAssertNil(novelAfter(two, in: chapters))
        XCTAssertNil(novelBefore(one, in: chapters))
    }

    func testNovelNumberedChapterSkipsUnnumberedExtras() {
        let nilNumber = novelChapter("nil-number", number: nil)
        let current = novelChapter("current", number: 1)
        XCTAssertNil(novelBefore(current, in: [current, nilNumber]))
    }

    func testNovelMissingKeyReturnsNilOnlyWhenNumericSelectionCannotResolve() {
        let missingNumeric = novelChapter("missing", number: 2)
        XCTAssertEqual(
            novelAfter(
                missingNumeric,
                in: [novelChapter("three", number: 3)]
            )?.key,
            "three"
        )

        let missingWithoutNumber = novelChapter("missing-nil", number: nil)
        let chapters = [novelChapter("one", number: nil)]
        XCTAssertNil(novelAfter(missingWithoutNumber, in: chapters))
        XCTAssertNil(novelBefore(missingWithoutNumber, in: chapters))
    }

    func testNovelDuplicateNumericCandidateReturnsFirstRepresentation() {
        let current = novelChapter("current", number: 1)
        let chapters = [
            current,
            novelChapter("first-source", number: 2, scanlator: "one"),
            novelChapter("second-source", number: 2, scanlator: "two")
        ]

        XCTAssertEqual(novelAfter(current, in: chapters)?.key, "first-source")
    }

    func testPageOrderingUsesAscendingIndexAndRetainsDuplicatesGapsAndContent() {
        let pages = [
            Page(index: 9, content: .url("nine")),
            Page(index: 2, content: .text("first-two")),
            Page(index: 2, content: .url("second-two")),
            Page(index: 5, content: .text("five"))
        ]

        let ordered = ReaderPageOrdering.ascending(pages)

        XCTAssertEqual(ordered.map(\.index), [2, 2, 5, 9])
        XCTAssertEqual(pageContents(ordered), ["text:first-two", "url:second-two", "text:five", "url:nine"])
    }

    func testPageOrderingKeepsAlreadySortedAndReverseInputsAscending() {
        let sorted = [
            Page(index: 1, content: .text("one")),
            Page(index: 4, content: .url("four")),
            Page(index: 8, content: .text("eight"))
        ]

        XCTAssertEqual(ReaderPageOrdering.ascending(sorted).map(\.index), [1, 4, 8])
        XCTAssertEqual(
            ReaderPageOrdering.ascending(Array(sorted.reversed())).map(\.index),
            [1, 4, 8]
        )
    }

    private func mangaAfter(
        _ chapter: Manga.Chapter,
        in chapters: [Manga.Chapter],
        preferredScanlator: String? = nil
    ) -> Manga.Chapter? {
        ReaderChapterOrdering.mangaChapter(
            after: chapter,
            in: chapters,
            preferredScanlator: preferredScanlator ?? chapter.scanlator
        )
    }

    private func mangaBefore(
        _ chapter: Manga.Chapter,
        in chapters: [Manga.Chapter]
    ) -> Manga.Chapter? {
        ReaderChapterOrdering.mangaChapter(
            before: chapter,
            in: chapters,
            preferredScanlator: chapter.scanlator
        )
    }

    private func novelAfter(
        _ chapter: Novel.Chapter,
        in chapters: [Novel.Chapter]
    ) -> Novel.Chapter? {
        ReaderChapterOrdering.novelChapter(after: chapter, in: chapters)
    }

    private func novelBefore(
        _ chapter: Novel.Chapter,
        in chapters: [Novel.Chapter]
    ) -> Novel.Chapter? {
        ReaderChapterOrdering.novelChapter(before: chapter, in: chapters)
    }

    private func mangaChapter(
        _ key: String,
        number: Float32?,
        scanlator: String? = nil
    ) -> Manga.Chapter {
        Manga.Chapter(key: key, chapter: number, scanlator: scanlator)
    }

    private func novelChapter(
        _ key: String,
        number: Float32?,
        scanlator: String? = nil
    ) -> Novel.Chapter {
        Novel.Chapter(key: key, chapter: number, scanlator: scanlator)
    }

    private func pageContents(_ pages: [Page]) -> [String] {
        pages.map { page in
            switch page.content {
            case .text(let text): return "text:\(text)"
            case .url(let url): return "url:\(url)"
            }
        }
    }
}
