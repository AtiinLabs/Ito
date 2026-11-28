import XCTest
@testable import Ito

final class LibrarySeriesProgressTests: XCTestCase {
    func testMangaCountsDistinctKeysAndReadKeys() {
        let references = [
            LibraryChapterReference(key: "a", chapterNumber: 1, groupsByNumber: false),
            LibraryChapterReference(key: "b", chapterNumber: 2, groupsByNumber: false),
            LibraryChapterReference(key: "c", chapterNumber: 2, groupsByNumber: false)
        ]
        let progress = LibrarySeriesProgressCalculator.progress(references: references) { $0.key == "b" }

        XCTAssertEqual(progress, LibrarySeriesProgress(readCount: 1, totalCount: 3))
    }

    func testAnimeGroupsDuplicateEpisodeNumbersAsOneUnit() {
        let references = [
            LibraryChapterReference(key: "ep1-source-a", chapterNumber: 1, groupsByNumber: true),
            LibraryChapterReference(key: "ep1-source-b", chapterNumber: 1, groupsByNumber: true),
            LibraryChapterReference(key: "ep2", chapterNumber: 2, groupsByNumber: true)
        ]
        let progress = LibrarySeriesProgressCalculator.progress(references: references) { $0.key == "ep1-source-b" }

        XCTAssertEqual(progress, LibrarySeriesProgress(readCount: 1, totalCount: 2))
    }

    func testAnimeWithoutFiniteNumberGroupsByKey() {
        let references = [
            LibraryChapterReference(key: "special-a", chapterNumber: nil, groupsByNumber: true),
            LibraryChapterReference(key: "special-b", chapterNumber: .nan, groupsByNumber: true)
        ]
        let progress = LibrarySeriesProgressCalculator.progress(references: references) { _ in false }

        XCTAssertEqual(progress, LibrarySeriesProgress(readCount: 0, totalCount: 2))
    }

    func testReadCountNeverExceedsTotalWhenAnyDuplicateIsRead() {
        let references = [
            LibraryChapterReference(key: "x", chapterNumber: 3, groupsByNumber: true),
            LibraryChapterReference(key: "y", chapterNumber: 3, groupsByNumber: true)
        ]
        let progress = LibrarySeriesProgressCalculator.progress(references: references) { _ in true }

        XCTAssertEqual(progress, LibrarySeriesProgress(readCount: 1, totalCount: 1))
        XCTAssertLessThanOrEqual(progress.readCount, progress.totalCount)
    }

    func testVisibilityRequiresReadingAndKnownTotal() {
        XCTAssertFalse(LibrarySeriesProgress(readCount: 0, totalCount: 5).isVisible)
        XCTAssertFalse(LibrarySeriesProgress(readCount: 2, totalCount: 0).isVisible)
        XCTAssertTrue(LibrarySeriesProgress(readCount: 2, totalCount: 5).isVisible)
    }

    func testFractionIsClampedAndZeroWithoutTotal() {
        XCTAssertEqual(LibrarySeriesProgress(readCount: 1, totalCount: 4).fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(LibrarySeriesProgress(readCount: 0, totalCount: 0).fraction, 0)
        XCTAssertEqual(LibrarySeriesProgress(readCount: 3, totalCount: 2).fraction, 1)
    }

    func testContinueCardShowsOnlyInCompactColumnOutsideSplit() {
        XCTAssertTrue(LibraryContinueVisibility.isShown(isCompact: true, arrangement: .stack))
        XCTAssertTrue(LibraryContinueVisibility.isShown(isCompact: true, arrangement: .detailOnly))
        XCTAssertFalse(LibraryContinueVisibility.isShown(isCompact: true, arrangement: .split))
        XCTAssertFalse(LibraryContinueVisibility.isShown(isCompact: false, arrangement: .stack))
        XCTAssertFalse(LibraryContinueVisibility.isShown(isCompact: false, arrangement: .split))
    }
}
