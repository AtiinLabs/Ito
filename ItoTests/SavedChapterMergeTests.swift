import Foundation
import ito_runner
import Testing
@testable import Ito

/// Saved editions the source's list no longer has: matched by exact key and nothing else.
struct SavedChapterMergeTests {
    private static func row(_ key: String, snapshot: Chapter? = nil, rawSnapshot: Data? = nil) throws -> DownloadedChapterRecord {
        DownloadedChapterRecord(
            pluginId: "plugin.test",
            mediaKind: .manga,
            canonicalMediaId: "series-1",
            chapterKey: key,
            authorityScope: .publicUnscoped,
            versionId: UUID().uuidString,
            state: .verified,
            damageReason: nil,
            contentKind: .images,
            pageCount: 1,
            byteCount: 1,
            manifestFormatVersion: 1,
            manifestSHA256: String(repeating: "a", count: 64),
            chapterSnapshot: try rawSnapshot ?? JSONEncoder().encode(snapshot ?? Chapter(key: key, chapter: 9)),
            seriesTitle: "Series",
            sourceEpoch: nil,
            verifiedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func onlyKeysTheListLacksAreAdded() throws {
        let listed = [Chapter(key: "c1", chapter: 1), Chapter(key: "c2", chapter: 2)]

        let merged = SavedChapterMerge.merged(listed, inventory: [try Self.row("c2"), try Self.row("gone")])

        #expect(merged?.map(\.key) == ["c1", "c2", "gone"])
    }

    @Test func aSavedEditionIsNeverMatchedByNumberOrScanlator() throws {
        let listed = [Chapter(key: "a16", chapter: 16, scanlator: "A")]
        let saved = Chapter(key: "b16", chapter: 16, scanlator: "A")

        let merged = SavedChapterMerge.merged(listed, inventory: [try Self.row("b16", snapshot: saved)])

        // Same number and same scanlator, different key: a separate edition, so it is added.
        #expect(merged?.map(\.key) == ["a16", "b16"])
    }

    @Test func theSavedChapterIsTheOneTheSourceReturnedWhenItWasDownloaded() throws {
        let saved = Chapter(key: "gone", title: "Old title", chapter: 7, scanlator: "Old group")

        let extra = SavedChapterMerge.savedOnly(listedKeys: [], inventory: [try Self.row("gone", snapshot: saved)])

        #expect(extra.first?.title == "Old title")
        #expect(extra.first?.scanlator == "Old group")
        #expect(extra.first?.chapter == 7)
    }

    @Test func aSnapshotThatCannotBeReadOrNamesAnotherKeyIsLeftOut() throws {
        let inventory = [
            try Self.row("broken", rawSnapshot: Data("not json".utf8)),
            try Self.row("mismatch", snapshot: Chapter(key: "other", chapter: 1)),
            try Self.row("fine")
        ]

        let extra = SavedChapterMerge.savedOnly(listedKeys: [], inventory: inventory)

        #expect(extra.map(\.key) == ["fine"])
    }

    @Test func aListWithNothingToAddIsReturnedAsItIs() throws {
        let listed = [Chapter(key: "c1", chapter: 1)]

        #expect(SavedChapterMerge.merged(listed, inventory: [try Self.row("c1")])?.map(\.key) == ["c1"])
        #expect(SavedChapterMerge.merged(nil, inventory: []) == nil)
        #expect(SavedChapterMerge.merged([], inventory: [])?.isEmpty == true)
    }

    @Test func aMissingListTakesTheSavedEditions() throws {
        let merged = SavedChapterMerge.merged(nil, inventory: [try Self.row("gone")])

        #expect(merged?.map(\.key) == ["gone"])
    }
}
