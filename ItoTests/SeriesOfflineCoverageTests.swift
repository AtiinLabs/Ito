import Foundation
import Testing
@testable import Ito

struct SeriesOfflineCoverageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let digest = "payload-digest"

    private func snapshot(
        scope: SeriesCatalogScope = .complete,
        digest: String = "payload-digest",
        age: TimeInterval = 60
    ) -> SeriesOfflineSnapshot {
        SeriesOfflineSnapshot(catalogScope: scope, payloadSHA256: digest, refreshedAt: now.addingTimeInterval(-age))
    }

    private func row(_ key: String, scanlator: String? = nil, locked: Bool = false, storable: Bool = true) -> ChapterFacts {
        ChapterFacts(key: key, scanlator: scanlator, isLocked: locked, isStorable: storable)
    }

    private func evaluate(
        snapshot: SeriesOfflineSnapshot?,
        selection: EditionSelection = .sourceList,
        catalog: [ChapterFacts],
        states: [String: ChapterDownloadState]
    ) -> SeriesOfflineCoverage.Result {
        SeriesOfflineCoverage.evaluate(
            snapshot: snapshot,
            currentPayloadSHA256: digest,
            selection: selection,
            catalog: catalog,
            states: states,
            now: now
        )
    }

    private let catalog = [ChapterFacts(key: "a"), ChapterFacts(key: "b"), ChapterFacts(key: "c")]

    private var allDownloaded: [String: ChapterDownloadState] {
        ["a": .downloaded, "b": .downloaded, "c": .downloaded]
    }

    @Test func aFreshCompleteSnapshotWithEveryRowSavedIsTheEntireSeries() {
        #expect(evaluate(snapshot: snapshot(), catalog: catalog, states: allDownloaded) == .entireSeries)
    }

    @Test func onlyACompleteCatalogScopeBacksTheClaim() {
        for scope in [SeriesCatalogScope.unknown, .visible, .partial] {
            let result = evaluate(snapshot: snapshot(scope: scope), catalog: catalog, states: allDownloaded)
            #expect(result == .saved(3))
        }
    }

    @Test func aSeriesWithoutASnapshotOnlyHasACount() {
        #expect(evaluate(snapshot: nil, catalog: catalog, states: allDownloaded) == .saved(3))
    }

    @Test func aSnapshotOfADifferentPayloadProvesNothing() {
        let result = evaluate(snapshot: snapshot(digest: "older-payload"), catalog: catalog, states: allDownloaded)
        #expect(result == .saved(3))

        let unknownCurrent = SeriesOfflineCoverage.evaluate(
            snapshot: snapshot(),
            currentPayloadSHA256: nil,
            selection: .sourceList,
            catalog: catalog,
            states: allDownloaded,
            now: now
        )
        #expect(unknownCurrent == .saved(3))
    }

    @Test func aSnapshotMustBeNoOlderThanSevenDays() {
        let week = SeriesOfflineCoverage.freshnessWindow
        #expect(week == 7 * 24 * 60 * 60)

        let atTheLimit = evaluate(snapshot: snapshot(age: week), catalog: catalog, states: allDownloaded)
        #expect(atTheLimit == .entireSeries)

        let justOver = evaluate(snapshot: snapshot(age: week + 1), catalog: catalog, states: allDownloaded)
        #expect(justOver == .saved(3))
    }

    @Test func aSnapshotDatedInTheFutureIsNotRejectedForAge() {
        let future = snapshot(age: -3600)
        #expect(evaluate(snapshot: future, catalog: catalog, states: allDownloaded) == .entireSeries)
    }

    @Test func everyEligibleRowMustBeDownloaded() {
        let states: [[String: ChapterDownloadState]] = [
            ["a": .downloaded, "b": .downloaded],
            ["a": .downloaded, "b": .downloaded, "c": .queued],
            ["a": .downloaded, "b": .downloaded, "c": .damaged],
            ["a": .downloaded, "b": .downloaded, "c": .downloading(completed: 1, total: 2)]
        ]
        for state in states {
            let result = evaluate(snapshot: snapshot(), catalog: catalog, states: state)
            #expect(result == .saved(2))
        }
    }

    @Test func lockedAndNonStorableRowsDoNotHoldTheClaimBack() {
        let rows = [row("a"), row("locked", locked: true), row("episode", storable: false)]
        let result = evaluate(snapshot: snapshot(), catalog: rows, states: ["a": .downloaded])
        #expect(result == .entireSeries)
    }

    @Test func onlyRowsTheSelectionAdmitsMustBeDownloaded() {
        let rows = [row("a1", scanlator: "A"), row("a2", scanlator: "A"), row("b1", scanlator: "B")]
        let states: [String: ChapterDownloadState] = ["a1": .downloaded, "a2": .downloaded]

        let followingA = evaluate(
            snapshot: snapshot(),
            selection: .scanlators([ScanlatorRef(name: "A")]),
            catalog: rows,
            states: states
        )
        #expect(followingA == .entireSeries)

        #expect(evaluate(snapshot: snapshot(), selection: .sourceList, catalog: rows, states: states) == .saved(2))
        #expect(evaluate(snapshot: snapshot(), selection: .allUploads, catalog: rows, states: states) == .saved(2))
    }

    @Test func aCatalogWithNothingEligibleIsNeverTheEntireSeries() {
        #expect(evaluate(snapshot: snapshot(), catalog: [], states: [:]) == .saved(0))
        #expect(evaluate(snapshot: snapshot(), catalog: [row("x", locked: true)], states: [:]) == .saved(0))

        let strict = evaluate(
            snapshot: snapshot(),
            selection: .scanlators([ScanlatorRef(name: "Nobody")]),
            catalog: catalog,
            states: allDownloaded
        )
        #expect(strict == .saved(3))
    }

    @Test func theSavedCountIsExactCopiesAndIncludesKeysTheCatalogNoLongerLists() {
        let states: [String: ChapterDownloadState] = [
            "a": .downloaded,
            "gone": .downloaded,
            "b": .queued,
            "c": .failed(.network)
        ]
        #expect(evaluate(snapshot: nil, catalog: catalog, states: states) == .saved(2))
    }

    // MARK: Positions

    private let strictA = EditionSelection.scanlators([ScanlatorRef(name: "A", binding: .exactIDless)])

    private func unit(_ key: String, _ scanlator: String, _ unit: String?) -> ChapterFacts {
        ChapterFacts(key: key, scanlator: scanlator, logicalUnitID: unit)
    }

    @Test func oneVerifiedPermittedCopySavesAPositionTheSourceDeclaredOnce() {
        let rows = [unit("a1", "A", "u1"), unit("b1", "B", "u1")]

        #expect(evaluate(snapshot: snapshot(), catalog: rows, states: ["a1": .downloaded]) == .entireSeries)
        #expect(evaluate(snapshot: snapshot(), catalog: rows, states: ["b1": .downloaded]) == .entireSeries)

        // Without a shared unit ID they are two positions, and one saved copy covers one.
        let unrelated = [unit("a1", "A", nil), unit("b1", "B", nil)]
        #expect(evaluate(snapshot: snapshot(), catalog: unrelated, states: ["b1": .downloaded]) == .saved(1))
    }

    @Test func aCopyOutsideThePermittedGroupsNeverSavesThePosition() {
        let rows = [unit("a1", "A", "u1"), unit("b1", "B", "u1")]

        #expect(evaluate(snapshot: snapshot(), selection: strictA, catalog: rows, states: ["b1": .downloaded]) == .saved(1))
        #expect(evaluate(snapshot: snapshot(), selection: strictA, catalog: rows, states: ["a1": .downloaded]) == .entireSeries)
    }

    @Test func aQueuedOrDamagedCopyLeavesThePositionUnsaved() {
        let rows = [unit("a1", "A", "u1"), unit("b1", "B", "u1")]

        for state in [ChapterDownloadState.queued, .damaged, .failed(.network), .downloading(completed: 1, total: 2)] {
            #expect(evaluate(snapshot: snapshot(), catalog: rows, states: ["a1": state]) == .saved(0))
        }
        // A verified copy beside a damaged one still saves it.
        #expect(evaluate(snapshot: snapshot(), catalog: rows, states: ["a1": .damaged, "b1": .downloaded]) == .entireSeries)
    }

    @Test func coverageFollowsTheSelectionAndEveryDeclaredPosition() {
        // u1 is offered by A and B, u2 by A only, u3 by B only.
        let rows = [unit("a1", "A", "u1"), unit("b1", "B", "u1"), unit("a2", "A", "u2"), unit("b3", "B", "u3")]
        struct Case {
            let selection: EditionSelection
            let states: [String: ChapterDownloadState]
            let expected: SeriesOfflineCoverage.Result
        }
        let cases: [Case] = [
            Case(selection: .sourceList, states: ["a1": .downloaded, "a2": .downloaded, "b3": .downloaded], expected: .entireSeries),
            Case(selection: .sourceList, states: ["b1": .downloaded, "a2": .downloaded, "b3": .downloaded], expected: .entireSeries),
            Case(selection: .sourceList, states: ["a1": .downloaded, "a2": .downloaded], expected: .saved(2)),
            Case(selection: .sourceList, states: ["a1": .downloaded, "a2": .queued, "b3": .downloaded], expected: .saved(2)),
            Case(
                selection: .sourceList,
                states: ["a1": .damaged, "b1": .damaged, "a2": .downloaded, "b3": .downloaded],
                expected: .saved(2)
            ),
            Case(
                selection: .sourceList,
                states: ["a1": .downloaded, "b1": .downloaded, "a2": .downloaded, "b3": .downloaded],
                expected: .entireSeries
            ),
            // Strict A cannot supply u3, which the source declared: never the entire series.
            Case(selection: strictA, states: ["a1": .downloaded, "a2": .downloaded, "b3": .downloaded], expected: .saved(3)),
            Case(selection: strictA, states: ["a1": .downloaded, "a2": .downloaded], expected: .saved(2)),
            Case(
                selection: .allUploads,
                states: ["a1": .downloaded, "b1": .downloaded, "a2": .downloaded, "b3": .downloaded],
                expected: .entireSeries
            ),
            Case(selection: .allUploads, states: ["a1": .downloaded, "a2": .downloaded, "b3": .downloaded], expected: .saved(3))
        ]
        for entry in cases {
            #expect(evaluate(snapshot: snapshot(), selection: entry.selection, catalog: rows, states: entry.states) == entry.expected)
        }
    }

    @Test func aStrictGroupOnlyIgnoresRowsTheSourceNeverDeclaredAsPositions() {
        let declared = [unit("a1", "A", "u1"), unit("b1", "B", "u1"), unit("b3", "B", "u3")]
        #expect(evaluate(snapshot: snapshot(), selection: strictA, catalog: declared, states: ["a1": .downloaded]) == .saved(1))

        let undeclared = [unit("a1", "A", "u1"), unit("b1", "B", "u1"), unit("b3", "B", nil)]
        #expect(evaluate(snapshot: snapshot(), selection: strictA, catalog: undeclared, states: ["a1": .downloaded]) == .entireSeries)
    }

    @Test func aLockedRowWithASavedCopyStillSavesItsPosition() {
        let rows = [
            ChapterFacts(key: "a1", scanlator: "A", isLocked: true, logicalUnitID: "u1"),
            ChapterFacts(key: "b1", scanlator: "B", logicalUnitID: "u1")
        ]
        let states: [String: ChapterDownloadState] = ["a1": .downloaded]
        #expect(evaluate(snapshot: snapshot(), catalog: rows, states: states) == .entireSeries)
        #expect(evaluate(snapshot: snapshot(), selection: strictA, catalog: rows, states: states) == .entireSeries)
        // Without the copy the free upload is still missing.
        #expect(evaluate(snapshot: snapshot(), catalog: rows, states: [:]) == .saved(0))
    }
}
