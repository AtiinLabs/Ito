import Foundation
import Testing
import ito_runner
@testable import Ito

/// The entire-series proof behind the Library's offline filter, judged as pure values. A proof is the same claim
/// the detail screen makes: the same coverage evaluator decides it, and only the inputs are read differently.
@MainActor
struct LibraryOfflineFacetTests {
    private nonisolated static let media = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)
    private nonisolated static let refreshedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private nonisolated static let digest = String(repeating: "a", count: 64)
    private nonisolated static let until = refreshedAt.addingTimeInterval(SeriesOfflineCoverage.freshnessWindow)
    private nonisolated static let twoRows = [ChapterFacts(key: "a"), ChapterFacts(key: "b")]
    private nonisolated static let allSaved: [String: ChapterDownloadState] = ["a": .downloaded, "b": .downloaded]

    private func record(
        scope: LibraryCatalogScope = .allEligible,
        completeness: LibraryCatalogCompleteness = .complete,
        rows: Int = 2,
        refreshedAt: Date = Self.refreshedAt,
        payloadDigest: String = Self.digest
    ) -> LibrarySnapshotStateRecord {
        LibrarySnapshotStateRecord(
            pluginId: Self.media.pluginId,
            mediaKind: .manga,
            canonicalMediaId: Self.media.canonicalMediaId,
            payloadSHA256: payloadDigest,
            refreshedAt: refreshedAt,
            catalogScope: scope,
            catalogCompleteness: completeness,
            chapterRowCount: rows
        )
    }

    private func catalog(
        _ facts: [ChapterFacts]? = Self.twoRows,
        digest: String = Self.digest
    ) -> LibraryPreparedCatalog {
        LibraryPreparedCatalog(payload: Data(), payloadSHA256: digest, facts: facts)
    }

    private func proof(
        record: LibrarySnapshotStateRecord? = nil,
        preference: Data? = nil,
        catalog: LibraryPreparedCatalog? = nil,
        states: [String: ChapterDownloadState] = Self.allSaved,
        kind: MediaKind = .manga,
        now: Date = Self.refreshedAt
    ) -> LibraryEntireSeriesProof {
        LibraryOfflineFacetEvaluator.entireSeriesProof(
            kind: kind,
            proof: record ?? self.record(),
            preference: preference,
            catalog: catalog ?? self.catalog(),
            states: states,
            now: now
        )
    }

    @Test func aCompleteFreshCatalogWithEveryRowSavedIsProvenUntilTheWindowEnds() {
        #expect(proof() == .proven(until: Self.until))
        #expect(proof(now: Self.until) == .proven(until: Self.until))
        #expect(proof(now: Self.until.addingTimeInterval(1)) == .notProven)
    }

    @Test func onlyACompleteCatalogOfEveryEligibleUploadCanBeProven() {
        #expect(proof(record: record(scope: .unknown)) == .notProven)
        #expect(proof(record: record(scope: .visible)) == .notProven)
        #expect(proof(record: record(completeness: .partial)) == .notProven)
        #expect(proof(record: record(completeness: .unknown)) == .notProven)
    }

    @Test func anEmptyCatalogIsNeverProven() {
        #expect(proof(record: record(rows: 0)) == .notProven)
        #expect(proof(catalog: catalog([])) == .notProven)
    }

    @Test func aPayloadWhoseDigestIsNotTheProvenOneIsNeverJudged() {
        #expect(proof(catalog: catalog(digest: String(repeating: "b", count: 64))) == .notProven)
        let unprepared = LibraryOfflineFacetEvaluator.entireSeriesProof(
            kind: .manga, proof: record(), preference: nil, catalog: nil, states: Self.allSaved, now: Self.refreshedAt
        )
        #expect(unprepared == .notProven)
        #expect(proof(catalog: LibraryPreparedCatalog(payload: Data(), payloadSHA256: Self.digest, facts: nil)) == .notProven)
    }

    @Test func noRememberedChoiceFollowsTheSourceListAndUnreadableChoicesProveNothing() {
        #expect(proof(preference: nil) == .proven(until: Self.until))
        #expect(proof(preference: Data("not a selection".utf8)) == .notProven)
        #expect(proof(preference: Data(#"{"formatVersion":99,"kind":"sourceList"}"#.utf8)) == .notProven)
    }

    @Test func everyEditionFormatGivesTheClaimTheCoverageEvaluatorGives() throws {
        let selections: [EditionSelection] = [
            .sourceList,
            .allUploads,
            .scanlators([ScanlatorRef(name: "A")]),
            .preferred(primary: ScanlatorRef(name: "A"), fallback: .strict),
            .preferred(primary: ScanlatorRef(name: "A"), fallback: .approved([ScanlatorRef(name: "B")]))
        ]
        let rows = [ChapterFacts(key: "a", scanlator: "A"), ChapterFacts(key: "b", scanlator: "B")]
        for selection in selections {
            let data = try selection.storageData()
            let direct = SeriesOfflineCoverage.evaluate(
                snapshot: record().offlineSnapshot,
                currentPayloadSHA256: Self.digest,
                selection: selection,
                catalog: rows,
                states: Self.allSaved,
                now: Self.refreshedAt
            )
            let expected: LibraryEntireSeriesProof = direct == .entireSeries ? .proven(until: Self.until) : .notProven
            #expect(proof(preference: data, catalog: catalog(rows)) == expected)
        }
    }

    @Test func aVerifiedCopyOutsideTheChosenScanlatorDoesNotSaveItsPosition() throws {
        let rows = [ChapterFacts(key: "a", scanlator: "A"), ChapterFacts(key: "b", scanlator: "B")]
        let data = try EditionSelection.scanlators([ScanlatorRef(name: "A")]).storageData()

        #expect(proof(preference: data, catalog: catalog(rows), states: ["a": .queued, "b": .downloaded]) == .notProven)
        #expect(proof(preference: data, catalog: catalog(rows), states: ["a": .downloaded, "b": .damaged]) == .proven(until: Self.until))
    }

    @Test func aDamagedQueuedDownloadingWaitingOrFailedChosenRowBlocksTheClaim() {
        let blockers: [ChapterDownloadState] = [
            .damaged,
            .queued,
            .downloading(completed: 0, total: nil),
            .waiting(.networkUnknown),
            .failed(.sourceError)
        ]
        for state in blockers {
            #expect(proof(states: ["a": .downloaded, "b": state]) == .notProven)
        }
    }

    @Test func aSourceLogicalUnitTheChosenEditionCannotSupplyBlocksTheClaim() throws {
        let rows = [
            ChapterFacts(key: "a", scanlator: "A", logicalUnitID: "unit-1"),
            ChapterFacts(key: "b", scanlator: "B", logicalUnitID: "unit-2")
        ]
        let data = try EditionSelection.scanlators([ScanlatorRef(name: "A")]).storageData()

        #expect(proof(preference: data, catalog: catalog(rows), states: ["a": .downloaded]) == .notProven)
    }

    @Test func anAnimeSeriesIsNeverProvenEvenWithEveryEpisodeSaved() {
        #expect(proof(kind: .anime) == .notProven)
    }

    @Test func preparingDecodesOnlyAPayloadWhoseDigestMatchesTheProof() throws {
        let payload = try JSONEncoder().encode(Manga(
            key: "series-1",
            title: "Series",
            chapters: [
                Chapter(key: "a", volume: nil, chapter: 1, scanlator: nil, paywalled: nil),
                Chapter(key: "b", volume: nil, chapter: 2, scanlator: nil, paywalled: nil)
            ]
        ))
        let payloadDigest = OfflineDigest.sha256Hex(payload)

        let matching = LibraryOfflineFacetEvaluator.prepare([
            LibraryCatalogPreparation(media: Self.media, kind: .manga, payload: payload, expectedSHA256: payloadDigest)
        ])[Self.media]
        #expect(matching?.payloadSHA256 == payloadDigest)
        #expect(matching?.facts?.map(\.key) == ["a", "b"])

        let mismatched = LibraryOfflineFacetEvaluator.prepare([
            LibraryCatalogPreparation(
                media: Self.media,
                kind: .manga,
                payload: payload,
                expectedSHA256: String(repeating: "c", count: 64)
            )
        ])[Self.media]
        #expect(mismatched?.payloadSHA256 == payloadDigest)
        #expect(mismatched?.facts == nil)
    }
}
