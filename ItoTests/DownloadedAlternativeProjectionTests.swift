import Foundation
import Testing
import ito_runner
@testable import Ito

/// Which stored uploads count as other copies of a chapter's reading position. The projection reads only the
/// rows it is given, so these tests need no store, plugin or file.
struct DownloadedAlternativeProjectionTests {
    private static let series = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)

    private static func edition(
        _ key: String,
        plugin: String = "plugin.test",
        series seriesID: String = "series-1",
        kind: MediaKind = .manga
    ) -> OfflineChapterEdition {
        OfflineChapterEdition(pluginId: plugin, mediaKind: kind, canonicalMediaId: seriesID, chapterKey: key)
    }

    private static func catalogAnchor(_ key: String = "a", unit: String = "unit-1") -> OfflineChapterAlternativeAnchor {
        .catalog(edition: edition(key), logicalUnitID: unit)
    }

    private static func project(
        _ anchor: OfflineChapterAlternativeAnchor,
        _ rows: [DownloadedChapterRecord],
        epoch: String? = nil
    ) throws -> DownloadedChapterAlternatives {
        try OfflineChapterAlternatives.project(anchor: anchor, inventory: rows, sourceEpoch: epoch)
    }

    // MARK: - 1, 2

    @Test func sameLogicalUnitInTheSameOriginMatchesAnUploadTheLiveCatalogNoLongerHas() throws {
        let rows = [
            try DownloadedChapterRecord.alternativeFixture(.upload("a")),
            try DownloadedChapterRecord.alternativeFixture(.upload("b", group: "Group B"))
        ]

        let result = try Self.project(Self.catalogAnchor(), rows, epoch: "epoch-1")

        #expect(result.candidates.map(\.edition.chapterKey) == ["b"])
        #expect(result.logicalUnitID == "unit-1")
        #expect(result.sourceEpoch == "epoch-1")
        #expect(result.metadataOrigin.isByteIdentical(to: Self.series))
    }

    @Test func aMissingDifferentOrEmptyLogicalUnitMatchesNothing() throws {
        let rows = [
            try DownloadedChapterRecord.alternativeFixture(.upload("b", unit: nil)),
            try DownloadedChapterRecord.alternativeFixture(.upload("c", unit: "unit-2")),
            try DownloadedChapterRecord.alternativeFixture(.upload("d", unit: ""))
        ]

        #expect(try Self.project(Self.catalogAnchor(), rows).candidates.isEmpty)
        // An empty identifier identifies nothing, even against rows that also carry an empty one.
        #expect(try Self.project(Self.catalogAnchor(unit: ""), rows).candidates.isEmpty)
        // Same number and title are never enough: the chapter key is not a logical unit either.
        let sameNumber = [try DownloadedChapterRecord.alternativeFixture(.upload("b", unit: nil))]
        #expect(try Self.project(Self.catalogAnchor(unit: ""), sameNumber).candidates.isEmpty)
    }

    // MARK: - 3

    @Test func identitiesThatDifferOnlyByUnicodeEquivalenceAreDifferentIdentities() throws {
        let precomposed = "caf\u{e9}"
        let decomposed = "cafe\u{301}"
        #expect(precomposed == decomposed)
        #expect(!precomposed.utf8.elementsEqual(decomposed.utf8))

        // A logical unit written another way is another unit; the same bytes are the same unit.
        let differentBytes = [try DownloadedChapterRecord.alternativeFixture(.upload("b", unit: decomposed))]
        let sameBytes = [try DownloadedChapterRecord.alternativeFixture(.upload("b", unit: precomposed))]
        #expect(try Self.project(Self.catalogAnchor(unit: precomposed), differentBytes).candidates.isEmpty)
        #expect(try Self.project(Self.catalogAnchor(unit: precomposed), sameBytes).candidates.count == 1)

        // A key that is only canonically equal to the anchor's is another upload, not the anchor itself.
        let anchor = OfflineChapterAlternativeAnchor.catalog(edition: Self.edition(precomposed), logicalUnitID: "unit-1")
        let otherKey = [try DownloadedChapterRecord.alternativeFixture(.upload(decomposed))]
        #expect(try Self.project(anchor, otherKey).candidates.map(\.edition.chapterKey) == [decomposed])
        let sameKey = [try DownloadedChapterRecord.alternativeFixture(.upload(precomposed))]
        #expect(try Self.project(anchor, sameKey).candidates.isEmpty)

        // A series written another way is another series.
        let otherSeries = [
            try DownloadedChapterRecord.alternativeFixture(.upload("b"), canonicalMediaId: "s\u{e9}rie")
        ]
        let seriesAnchor = OfflineChapterAlternativeAnchor.catalog(
            edition: Self.edition("a", series: "se\u{301}rie"),
            logicalUnitID: "unit-1"
        )
        #expect(try Self.project(seriesAnchor, otherSeries).candidates.isEmpty)
    }

    // MARK: - 4

    @Test func otherPluginKindOrSeriesRowsAreNotCandidates() throws {
        let rows = [
            try DownloadedChapterRecord.alternativeFixture(.upload("b"), pluginId: "plugin.other"),
            try DownloadedChapterRecord.alternativeFixture(.upload("c"), mediaKind: .novel),
            try DownloadedChapterRecord.alternativeFixture(.upload("d"), canonicalMediaId: "series-2")
        ]

        #expect(try Self.project(Self.catalogAnchor(), rows).candidates.isEmpty)
    }

    // MARK: - 5, 6

    @Test func aRowMovedToTheCatalogsSeriesKeepsItsOldOriginAndDoesNotMatchTheNewOne() throws {
        let moved = try DownloadedChapterRecord.originData(pluginId: "plugin.old", canonicalMediaId: "series-old")
        let rows = [try DownloadedChapterRecord.alternativeFixture(.upload("b"), origin: moved)]

        #expect(try Self.project(Self.catalogAnchor(), rows).candidates.isEmpty)
    }

    @Test func anOriginThatCannotBeReadEstablishesNothing() throws {
        let rows = [try DownloadedChapterRecord.alternativeFixture(.upload("b"), origin: Data("not json".utf8))]

        #expect(try Self.project(Self.catalogAnchor(), rows).candidates.isEmpty)
    }

    @Test func aSavedAnchorAndARowFromTheSameOriginalSeriesMatchWhenTheirLogicalUnitsAgree() throws {
        let origin = try DownloadedChapterRecord.originData(pluginId: "plugin.old", canonicalMediaId: "series-old")
        let rows = [
            try DownloadedChapterRecord.alternativeFixture(.upload("a"), origin: origin),
            try DownloadedChapterRecord.alternativeFixture(.upload("b"), origin: origin),
            try DownloadedChapterRecord.alternativeFixture(.upload("c", unit: "unit-2"), origin: origin)
        ]

        let result = try Self.project(.saved(edition: Self.edition("a")), rows)

        #expect(result.candidates.map(\.edition.chapterKey) == ["b"])
        #expect(result.candidates.first?.metadataOrigin.pluginId == "plugin.old")
        #expect(result.metadataOrigin.canonicalMediaId == "series-old")
        #expect(result.logicalUnitID == "unit-1")
    }

    @Test func aSavedAnchorFromAnotherOriginalSeriesDoesNotMatchARowOfOneOrNoOrigin() throws {
        let other = try DownloadedChapterRecord.originData(pluginId: "plugin.old", canonicalMediaId: "series-old")
        let rows = [
            try DownloadedChapterRecord.alternativeFixture(.upload("a"), origin: other),
            try DownloadedChapterRecord.alternativeFixture(.upload("b"))
        ]

        #expect(try Self.project(.saved(edition: Self.edition("a")), rows).candidates.isEmpty)
    }

    // MARK: - 7

    @Test func damagedAndUnreadableRowsAreNotCandidates() throws {
        let rows = [
            try DownloadedChapterRecord.alternativeFixture(.upload("b"), state: .damaged),
            try DownloadedChapterRecord.alternativeFixture(.upload("c"), snapshot: Data("not a chapter".utf8)),
            // The snapshot names another key than the row does.
            try DownloadedChapterRecord.alternativeFixture(.upload("other"), chapterKey: "d"),
            try DownloadedChapterRecord.alternativeFixture(.upload("e"))
        ]

        #expect(try Self.project(Self.catalogAnchor(), rows).candidates.map(\.edition.chapterKey) == ["e"])
    }

    @Test func aSavedAnchorWithoutUsableMetadataFailsInsteadOfGuessingACatalogOrigin() throws {
        let unusable: [[DownloadedChapterRecord]] = [
            [],
            [try DownloadedChapterRecord.alternativeFixture(.upload("a"), state: .damaged)],
            [try DownloadedChapterRecord.alternativeFixture(.upload("a"), snapshot: Data("not a chapter".utf8))],
            [try DownloadedChapterRecord.alternativeFixture(.upload("other"), chapterKey: "a")],
            [try DownloadedChapterRecord.alternativeFixture(.upload("a"), origin: Data("not json".utf8))]
        ]
        for rows in unusable {
            #expect(throws: DownloadedAlternativeError.selectionChanged) {
                try Self.project(.saved(edition: Self.edition("a")), rows)
            }
        }
    }

    @Test func aValidSavedAnchorWithoutALogicalUnitHasNoCandidates() throws {
        let rows = [
            try DownloadedChapterRecord.alternativeFixture(.upload("a", unit: nil)),
            try DownloadedChapterRecord.alternativeFixture(.upload("b", unit: nil))
        ]

        #expect(try Self.project(.saved(edition: Self.edition("a")), rows).candidates.isEmpty)
    }

    // MARK: - 8, 9

    @Test func everyQualifyingCopyIsKeptWithItsExactGroupInStableOrderAndNothingIsPreferred() throws {
        let rows = [
            try DownloadedChapterRecord.alternativeFixture(.upload("z", group: "Same", groupID: "id-2"), contentKind: .text),
            try DownloadedChapterRecord.alternativeFixture(.upload("b", group: "Same", groupID: "id-1")),
            try DownloadedChapterRecord.alternativeFixture(.upload("c", group: "Same")),
            try DownloadedChapterRecord.alternativeFixture(.upload("d", group: nil, groupID: nil), contentKind: .mixed),
            try DownloadedChapterRecord.alternativeFixture(.upload("a"))
        ]

        let reversed = try Self.project(Self.catalogAnchor(), rows.reversed())
        let forward = try Self.project(Self.catalogAnchor(), rows)

        #expect(forward.candidates.map(\.edition.chapterKey) == ["b", "c", "d", "z"])
        #expect(reversed.candidates.map(\.edition.chapterKey) == ["b", "c", "d", "z"])
        #expect(forward.candidates.map(\.chapter.scanlatorID) == ["id-1", nil, nil, "id-2"])
        #expect(forward.candidates.map(\.chapter.scanlator) == ["Same", "Same", nil, "Same"])
        #expect(forward.candidates.map(\.contentKind) == [.images, .images, .mixed, .text])
    }

    @Test func aCandidateCarriesTheSavedValuesAndDigestsExactly() throws {
        var saved = Chapter.upload("b", group: "Group B", groupID: "g-b", kind: .text, revision: "rev-7")
        saved.volume = 2
        let row = try DownloadedChapterRecord.alternativeFixture(saved, versionId: "version-b", contentKind: .text)

        let candidate = try #require(try Self.project(Self.catalogAnchor(), [row]).candidates.first)

        #expect(candidate.id == "version-b")
        #expect(candidate.versionID == "version-b")
        #expect(candidate.manifestSHA256 == row.manifestSHA256)
        #expect(candidate.chapterSnapshotSHA256 == OfflineDigest.sha256Hex(row.chapterSnapshot))
        #expect(candidate.contentKind == .text)
        #expect(candidate.chapter.revision == "rev-7")
        #expect(candidate.chapter.kind == .text)
        #expect(candidate.chapter.volume == 2)
        #expect(candidate.chapter.title == "Title b")
        #expect(candidate.edition.isByteIdentical(to: Self.edition("b")))
    }
}
