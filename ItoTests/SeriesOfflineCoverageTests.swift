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
}
