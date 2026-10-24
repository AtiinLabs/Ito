import XCTest
import ito_runner
@testable import Ito

@MainActor
final class MediaDetailContentKindTests: XCTestCase {
    private static let pluginID = "plugin.test"

    func testAMangaChapterMarkedAsTextOpensInTheTextReader() {
        let runner = ItoRunner()
        let chapters = [
            Chapter(key: "v1", chapter: 1, kind: .images),
            Chapter(key: "v2", chapter: 2, kind: .text),
            Chapter(key: "v3", chapter: 3)
        ]
        let series = Manga(key: "m1", title: "Manga", chapters: chapters)

        guard case .pages(_, _, _, _, let pages) = MediaDetailReaderDestination.reading(
            chapters[0], of: .manga(series), runner: runner, pluginID: Self.pluginID
        ) else { return XCTFail("A page chapter opens the page reader") }
        XCTAssertEqual(pages.key, "v1")

        guard case .text(_, _, _, let entry, let text) = MediaDetailReaderDestination.reading(
            chapters[1], of: .manga(series), runner: runner, pluginID: Self.pluginID
        ) else { return XCTFail("A text chapter opens the text reader") }
        XCTAssertEqual(entry.kind, .manga)
        XCTAssertEqual(entry.key, "m1")
        XCTAssertEqual(text.key, "v2")

        // A chapter from a plugin that predates per-chapter kinds reads as its series does.
        guard case .pages = MediaDetailReaderDestination.reading(
            chapters[2], of: .manga(series), runner: runner, pluginID: Self.pluginID
        ) else { return XCTFail("An unmarked manga chapter opens the page reader") }
    }

    func testANovelsImageChapterOpensThePageReaderWithNovelIdentity() {
        let runner = ItoRunner()
        let text = Chapter(key: "text")
        let images = Chapter(key: "images", kind: .images)
        let novel = Novel(key: "novel", title: "Novel", chapters: [images, text])
        guard case .pages(_, let pageRunner, let pluginID, let entry, let selected) = MediaDetailReaderDestination.reading(
            images, of: .novel(novel), runner: runner, pluginID: Self.pluginID
        ) else { return XCTFail("An image chapter opens the page reader") }
        XCTAssertTrue(pageRunner === runner)
        XCTAssertEqual(pluginID, Self.pluginID)
        XCTAssertEqual(entry.kind, .novel)
        XCTAssertEqual(entry.key, "novel")
        XCTAssertEqual(selected.key, "images")

        guard case .text(_, _, _, let textEntry, let selectedText) = MediaDetailReaderDestination.reading(
            text, of: .novel(novel), runner: runner, pluginID: Self.pluginID
        ) else { return XCTFail("An unmarked novel chapter opens the text reader") }
        XCTAssertEqual(textEntry.kind, .novel)
        XCTAssertEqual(selectedText.key, "text")
    }

    func testTextChaptersAreMarkedOnlyInSeriesThatAlsoHavePages() {
        let mixed = [
            Chapter(key: "v1", kind: .images),
            Chapter(key: "v2", kind: .text),
            Chapter(key: "v3")
        ]
        XCTAssertEqual(mixed.textChapterKeysInMixedSeries(defaultKind: .images), ["v2"])
        // A novel's chapters are all text; marking every one would say nothing.
        let novel = [Chapter(key: "c1", kind: .text), Chapter(key: "c2", kind: .text)]
        XCTAssertEqual(novel.textChapterKeysInMixedSeries(defaultKind: .text), [])
        XCTAssertEqual([Chapter(key: "c1"), Chapter(key: "c2")].textChapterKeysInMixedSeries(defaultKind: .images), [])
        // Unmarked novel chapters resolve to text, not pages.
        let mixedNovel = [Chapter(key: "c1"), Chapter(key: "c2", kind: .images)]
        XCTAssertEqual(mixedNovel.textChapterKeysInMixedSeries(defaultKind: .text), ["c1"])
    }
}
