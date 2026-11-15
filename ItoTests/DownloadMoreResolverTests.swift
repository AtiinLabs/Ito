import Foundation
import Testing
@testable import Ito

@MainActor
struct DownloadMoreResolverTests {
    private func row(
        _ number: Int,
        stored: StoredEditionState = .none,
        read: Bool = false
    ) -> DownloadPlanRow {
        DownloadPlanRow(
            facts: ChapterFacts(DownloadTestChapter(key: "c\(number)", number: Float(number))),
            isRead: read,
            stored: stored
        )
    }

    private func count(_ value: Int) throws -> DownloadPositionCount {
        try #require(DownloadPositionCount(value))
    }

    private func keys(_ plan: DownloadPlan<Int>, _ rows: [DownloadPlanRow]) -> [String] {
        plan.toQueue.map { rows[$0].facts.key }
    }

    /// The contract's contrast fixture: ch2 is the last read chapter; ch3 is verified, ch4 queued, ch5 none,
    /// ch6 holds a failed job (queued state), ch7 to ch9 none.
    private var contrastRows: [DownloadPlanRow] {
        [
            row(2, read: true),
            row(3, stored: .verified),
            row(4, stored: .queued),
            row(5),
            row(6, stored: .queued),
            row(7),
            row(8),
            row(9)
        ]
    }

    @Test func moreCountsOnlyNewlyQueuedPositionsWhileNextCountsCoveredOnes() throws {
        let rows = contrastRows
        let more = DownloadPresetResolver.plan(
            rows: rows,
            window: .more(try count(3)),
            selection: .sourceList,
            anchorKey: "c2"
        )
        #expect(keys(more, rows) == ["c5", "c7", "c8"])
        #expect(Set(more.satisfied.map { rows[$0].facts.key }).isSuperset(of: ["c3", "c4", "c6"]))

        let next = DownloadPresetResolver.plan(
            rows: rows,
            window: .next(try count(3)),
            selection: .sourceList,
            anchorKey: "c2"
        )
        #expect(keys(next, rows) == ["c5"])
    }

    @Test func aDamagedPositionIsReportedNotCountedAndPreviews() throws {
        let rows = [row(1, read: true), row(2, stored: .damaged), row(3)]
        let plan = DownloadPresetResolver.plan(
            rows: rows,
            window: .more(try count(1)),
            selection: .sourceList,
            anchorKey: "c1"
        )
        #expect(keys(plan, rows) == ["c3"])
        #expect(plan.damaged.map { rows[$0].facts.key } == ["c2"])
        #expect(plan.issues.contains(.damagedCopies))
        #expect(plan.requiresPreview)
    }

    @Test func moreWithoutAReadChapterStartsAtTheFirstAndPreviewsWithAnIssue() throws {
        let rows = (1...4).map { row($0) }
        let plan = DownloadPresetResolver.plan(
            rows: rows,
            window: .more(try count(2)),
            selection: .sourceList,
            anchorKey: nil
        )
        #expect(keys(plan, rows) == ["c1", "c2"])
        #expect(plan.issues.contains(.noReadingAnchor))
        #expect(plan.requiresPreview)
    }

    @Test func readChaptersAfterTheAnchorAreSkippedAndCounted() throws {
        let rows = [row(1, read: true), row(2, read: true), row(3), row(4)]
        let plan = DownloadPresetResolver.plan(
            rows: rows,
            window: .more(try count(2)),
            selection: .sourceList,
            anchorKey: "c1"
        )
        #expect(keys(plan, rows) == ["c3", "c4"])
        #expect(plan.skippedReadCount == 1)
    }

    @Test func builtInNextPresetsMatchTheCustomNextWithTheSameCount() throws {
        let rows = (1...30).map { row($0) }
        let pairs: [(DownloadPreset, Int)] = [(.next, 1), (.next5, 5), (.next10, 10)]
        for (preset, value) in pairs {
            let builtIn = DownloadPresetResolver.plan(rows: rows, window: preset.window, selection: .sourceList, anchorKey: nil)
            let custom = DownloadPresetResolver.plan(
                rows: rows, window: .next(try count(value)), selection: .sourceList, anchorKey: nil
            )
            #expect(builtIn.toQueue == custom.toQueue)
            #expect(builtIn.satisfied == custom.satisfied)
            #expect(builtIn.issues == custom.issues)
            #expect(builtIn.requiresPreview == custom.requiresPreview)
        }
    }

    @Test func aCountAboveTenPreviewsWhileTenWithTenIsQuiet() throws {
        let rows = (1...30).map { row($0) }
        let ten = DownloadPresetResolver.plan(
            rows: rows, window: .next(try count(10)), selection: .sourceList, anchorKey: nil
        )
        #expect(ten.toQueue.count == 10)
        #expect(!ten.requiresPreview)

        let twentyFive = DownloadPresetResolver.plan(
            rows: rows, window: .next(try count(25)), selection: .sourceList, anchorKey: nil
        )
        #expect(twentyFive.toQueue.count == 25)
        #expect(twentyFive.requiresPreview)
    }

    @Test func aThousandPositionWindowTakesOneThousandAndPreviews() throws {
        let rows = (1...1200).map { row($0) }
        let plan = DownloadPresetResolver.plan(
            rows: rows, window: .next(try count(1000)), selection: .sourceList, anchorKey: nil
        )
        #expect(plan.toQueue.count == 1000)
        #expect(plan.requiresPreview)
    }
    @Test func lockedRowsAreReportedAndPassedOverToFillTheWindow() throws {
        let rows = [
            row(1, read: true),
            DownloadPlanRow(facts: ChapterFacts(key: "locked", number: 2, isLocked: true)),
            row(3)
        ]
        let plan = DownloadPresetResolver.plan(
            rows: rows, window: .more(try count(1)), selection: .sourceList, anchorKey: "c1"
        )
        #expect(keys(plan, rows) == ["c3"])
        #expect(plan.locked == [1])
        #expect(plan.issues.contains(.lockedGap))
        #expect(plan.requiresPreview)
    }

    @Test func provenPreferredGapIsReportedButDoesNotCount() throws {
        let rows = [
            DownloadPlanRow(facts: ChapterFacts(
                key: "b1", number: 1, scanlatorID: "b", logicalUnitID: "u1"
            )),
            DownloadPlanRow(facts: ChapterFacts(
                key: "a2", number: 2, scanlatorID: "a", logicalUnitID: "u2"
            ))
        ]
        let plan = DownloadPresetResolver.plan(
            rows: rows, window: .more(try count(1)),
            selection: .preferred(primary: ScanlatorRef(id: "a", name: nil), fallback: .strict),
            anchorKey: nil
        )
        #expect(keys(plan, rows) == ["a2"])
        #expect(plan.missingPositionCount == 1)
        #expect(plan.issues.contains(.preferredUnavailable))
        #expect(plan.requiresPreview)
    }

    @Test func anchorOutsideSelectionAndAmbiguousOrderRequireReview() throws {
        let rows = [
            DownloadPlanRow(facts: ChapterFacts(key: "unselected", scanlatorID: "b")),
            DownloadPlanRow(facts: ChapterFacts(key: "selected", scanlatorID: "a"))
        ]
        let plan = DownloadPresetResolver.plan(
            rows: rows, window: .more(try count(1)),
            selection: .scanlators([ScanlatorRef(id: "a", name: nil)]),
            anchorKey: "unselected"
        )
        #expect(keys(plan, rows) == ["selected"])
        #expect(plan.issues.contains(.anchorNotInSelection))
        #expect(plan.requiresPreview)
        let ambiguous = DownloadPresetResolver.plan(
            rows: rows, window: .more(try count(1)), selection: .sourceList, anchorKey: "unselected"
        )
        #expect(ambiguous.issues.contains(.orderingAmbiguous))
        #expect(ambiguous.requiresPreview)
    }

    @Test func allUploadsCountsAPartlyCoveredLogicalPositionOnce() throws {
        let rows = [
            DownloadPlanRow(facts: ChapterFacts(key: "a1", number: 1, logicalUnitID: "u1"), stored: .verified),
            DownloadPlanRow(facts: ChapterFacts(key: "b1", number: 1, logicalUnitID: "u1")),
            row(2)
        ]
        let plan = DownloadPresetResolver.plan(
            rows: rows, window: .more(try count(1)), selection: .allUploads, anchorKey: "a1"
        )
        #expect(keys(plan, rows) == ["b1"])
        #expect(plan.satisfied == [0])
        #expect(!plan.toQueue.contains(2))
    }
}
