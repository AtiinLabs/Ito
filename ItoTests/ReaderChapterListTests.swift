import Foundation
import Testing
import ito_runner
@testable import Ito

@MainActor
struct ReaderChapterListTests {
    private static func chapter(
        _ key: String,
        _ number: Float?,
        scanlator: String? = nil,
        title: String? = nil
    ) -> Chapter {
        var chapter = Chapter(key: key, chapter: number.map(Double.init), scanlator: scanlator, scanlatorID: scanlator)
        chapter.title = title
        return chapter
    }

    @Test func rowsListHighestNumberFirstThenUnnumberedInSourceOrder() {
        let chapters = [
            Self.chapter("c1", 1, scanlator: "A"),
            Self.chapter("u2a", 2, scanlator: "A"),
            Self.chapter("unnumbered-first", nil, scanlator: "A"),
            Self.chapter("u2b", 2, scanlator: "B"),
            Self.chapter("u3", 3, scanlator: "A"),
            Self.chapter("unnumbered-second", nil, scanlator: "B")
        ]
        let rows = ReaderChapterList.rows(
            chapters: chapters,
            current: chapters[0],
            isRead: { _ in false },
            boundary: { .chapter($0) }
        )

        #expect(rows.map(\.chapter.key) == ["u3", "u2a", "u2b", "c1", "unnumbered-first", "unnumbered-second"])
    }

    @Test func availabilityMapsEveryBoundaryAndOnlyOpenableRowsAreSelectable() {
        let chapter = Self.chapter("k", 1)

        #expect(ReaderChapterList.availability(of: .chapter(chapter)) == .opensHere)
        #expect(ReaderChapterList.availability(of: .handoff(chapter, requiresGroupConsent: false)) == .opensInOtherReader)
        #expect(ReaderChapterList.availability(of: .locked(chapter)) == .locked)
        #expect(ReaderChapterList.availability(of: .end) == .locked)
        #expect(ReaderChapterList.availability(of: .groupConsent(chapter)) == .locked)
        #expect(ReaderChapterList.availability(of: .notAvailableOffline(chapter)) == .notDownloaded)

        func row(_ availability: ReaderChapterListRow.Availability) -> ReaderChapterListRow {
            ReaderChapterListRow(id: 0, chapter: chapter, isRead: false, availability: availability)
        }
        #expect(row(.current).isSelectable)
        #expect(row(.opensHere).isSelectable)
        #expect(row(.opensInOtherReader).isSelectable)
        #expect(!row(.locked).isSelectable)
        #expect(!row(.notDownloaded).isSelectable)
    }

    @Test func currentIsMatchedByExactBytesNotCanonicalEquivalence() {
        let precomposed = Self.chapter("caf\u{00E9}", 1)
        let decomposed = Self.chapter("cafe\u{0301}", 2)
        let rows = ReaderChapterList.rows(
            chapters: [precomposed, decomposed],
            current: precomposed,
            isRead: { _ in false },
            boundary: { .chapter($0) }
        )

        let precomposedRow = rows.first { $0.chapter.key.utf8.elementsEqual("caf\u{00E9}".utf8) }
        let decomposedRow = rows.first { $0.chapter.key.utf8.elementsEqual("cafe\u{0301}".utf8) }
        #expect(precomposedRow?.availability == .current)
        #expect(decomposedRow?.availability == .opensHere)
    }

    @Test func readFlagComesFromTheReadQuery() {
        let read = Self.chapter("read", 1)
        let unread = Self.chapter("unread", 2)
        let rows = ReaderChapterList.rows(
            chapters: [read, unread],
            current: unread,
            isRead: { $0.key == "read" },
            boundary: { .chapter($0) }
        )

        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.chapter.key, $0.isRead) })
        #expect(byKey["read"] == true)
        #expect(byKey["unread"] == false)
    }

    @Test func directionUsesNumbersThenListOrder() {
        let two = Self.chapter("two", 2)
        let three = Self.chapter("three", 3)
        let unnumbered = Self.chapter("unnumbered", nil)
        let list = [unnumbered, two, three]

        #expect(ReaderChapterOrdering.direction(from: two, to: three, in: nil) == .next)
        #expect(ReaderChapterOrdering.direction(from: three, to: two, in: nil) == .previous)
        // Equal numbers fall back to list positions: a later place is the previous chapter.
        let twoAgain = Self.chapter("two-again", 2)
        #expect(ReaderChapterOrdering.direction(from: two, to: twoAgain, in: [two, twoAgain]) == .previous)
        #expect(ReaderChapterOrdering.direction(from: twoAgain, to: two, in: [two, twoAgain]) == .next)
        // With no number on either side, list positions decide.
        #expect(ReaderChapterOrdering.direction(from: unnumbered, to: two, in: list) == .previous)
        #expect(ReaderChapterOrdering.direction(from: two, to: unnumbered, in: list) == .next)
        // Anything unknown reads as forward.
        #expect(ReaderChapterOrdering.direction(from: unnumbered, to: three, in: nil) == .next)
    }

    @Test func jumpStatusTextHasOneSentencePerCase() {
        let titled = Self.chapter("titled", 12, title: "The Return")
        let numbered = Self.chapter("numbered", 12)
        let bare = Self.chapter("bare", nil)

        #expect(ReaderJumpStatusText.opening(titled).contains("The Return"))
        #expect(ReaderJumpStatusText.failed(titled).contains("The Return"))
        #expect(!ReaderJumpStatusText.opening(numbered).isEmpty)
        #expect(!ReaderJumpStatusText.failed(numbered).isEmpty)
        #expect(!ReaderJumpStatusText.opening(bare).isEmpty)
        #expect(!ReaderJumpStatusText.failed(bare).isEmpty)
    }
}
