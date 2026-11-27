import XCTest
import ito_runner
@testable import Ito

/// The series page's reading thread: each row's role, and which thread segments are drawn and filled.
@MainActor
final class ChapterThreadLayoutTests: XCTestCase {
    func testRolesMarkReadAndUnreadRowsWithoutAnUpNextKey() {
        let roles = ChapterThreadLayout.roles(
            for: [(key: "a", isRead: true), (key: "b", isRead: false)],
            upNextKey: nil
        )

        XCTAssertEqual(roles, [.read, .unread])
    }

    func testUpNextOverridesTheReadStateOfItsRow() {
        // A finished series is read again from its first unit, which is already read.
        let roles = ChapterThreadLayout.roles(
            for: [(key: "a", isRead: true), (key: "b", isRead: true), (key: "c", isRead: false)],
            upNextKey: "a"
        )

        XCTAssertEqual(roles, [.upNext, .read, .unread])
    }

    func testUpNextMarksOnlyTheFirstRowWithItsKey() {
        let roles = ChapterThreadLayout.roles(
            for: [(key: "dup", isRead: false), (key: "other", isRead: true), (key: "dup", isRead: false)],
            upNextKey: "dup"
        )

        XCTAssertEqual(roles, [.upNext, .read, .unread])
    }

    func testAnUpNextKeyNoRowHasMarksNothing() {
        let roles = ChapterThreadLayout.roles(
            for: [(key: "a", isRead: true), (key: "b", isRead: false)],
            upNextKey: "gone"
        )

        XCTAssertEqual(roles, [.read, .unread])
    }

    func testSingleRowHasNoThreadSegments() {
        let steps = ChapterThreadLayout.steps(for: [.read])

        XCTAssertEqual(steps, [
            ChapterThreadStep(role: .read, hasLeadingThread: false, leadingFilled: false,
                              hasTrailingThread: false, trailingFilled: true)
        ])
    }

    func testThreadFillsFromAReadRowToTheNextOnly() {
        // read, read, unread, upNext, read: the thread is filled below a read row and above a row whose
        // predecessor is read; an unread or up-next row does not fill the segment below it.
        let steps = ChapterThreadLayout.steps(for: [.read, .read, .unread, .upNext, .read])

        XCTAssertEqual(steps, [
            ChapterThreadStep(role: .read, hasLeadingThread: false, leadingFilled: false,
                              hasTrailingThread: true, trailingFilled: true),
            ChapterThreadStep(role: .read, hasLeadingThread: true, leadingFilled: true,
                              hasTrailingThread: true, trailingFilled: true),
            ChapterThreadStep(role: .unread, hasLeadingThread: true, leadingFilled: true,
                              hasTrailingThread: true, trailingFilled: false),
            ChapterThreadStep(role: .upNext, hasLeadingThread: true, leadingFilled: false,
                              hasTrailingThread: true, trailingFilled: false),
            ChapterThreadStep(role: .read, hasLeadingThread: true, leadingFilled: false,
                              hasTrailingThread: false, trailingFilled: true)
        ])
    }

    func testDescendingScreenOrderFillsFromTheTopReadRows() {
        // The series page sorts newest first: the read units are at the bottom of the screen, the unread above.
        let rows: [(key: String, isRead: Bool)] = [
            (key: "9", isRead: false),
            (key: "8", isRead: false),
            (key: "7", isRead: true),
            (key: "6", isRead: true)
        ]
        let steps = ChapterThreadLayout.steps(for: ChapterThreadLayout.roles(for: rows, upNextKey: "7"))

        XCTAssertEqual(steps.map(\.role), [.unread, .unread, .upNext, .read])
        XCTAssertEqual(steps.map(\.leadingFilled), [false, false, false, false])
        XCTAssertEqual(steps.map(\.trailingFilled), [false, false, false, true])
    }

    func testNumberLabelShowsWholeAndFractionalChapterNumbers() {
        XCTAssertEqual(ChapterThreadLayout.numberLabel(for: Manga.Chapter(key: "a", title: nil, chapter: 12)), "Chapter 12")
        XCTAssertEqual(ChapterThreadLayout.numberLabel(for: Manga.Chapter(key: "b", title: nil, chapter: 12.5)), "Chapter 12.5")
    }

    func testNumberLabelNamesEpisodesAndDashesAMissingNumber() {
        XCTAssertEqual(ChapterThreadLayout.numberLabel(for: Anime.Episode(key: "e", title: nil, episode: 3)), "Episode 3")
        XCTAssertEqual(ChapterThreadLayout.numberLabel(for: Anime.Episode(key: "f", title: nil)), "Episode —")
        XCTAssertEqual(ChapterThreadLayout.numberLabel(for: Manga.Chapter(key: "g", title: nil)), "Chapter —")
    }
}
