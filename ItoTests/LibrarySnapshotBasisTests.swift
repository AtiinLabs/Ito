import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

/// What a series' saved details say about their own catalog: the rows come from the saved payload, found
/// through the same candidate item ids as the other snapshot reads, and a state written for another payload
/// is reported as it is so the caller can refuse it.
@MainActor
struct LibrarySnapshotBasisTests {
    private nonisolated static let media = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)
    private nonisolated static let refreshedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private static func payload(_ keys: [String]) throws -> Data {
        try JSONEncoder().encode(Manga(
            key: "series-1",
            title: "Series",
            chapters: keys.enumerated().map { index, key in
                Chapter(key: key, volume: nil, chapter: Float(index + 1), scanlator: "A", paywalled: index == 2 ? true : nil)
            }
        ))
    }

    private func makeManager(itemID: String, payload: Data, kind: MediaKind = .manga) async throws -> (TestDatabase, LibraryManager) {
        let database = try TestDatabase()
        let manager = LibraryManager(dbPool: database.dbPool)
        try await database.dbPool.write { db in
            try LibraryItem(
                id: itemID, title: "Series", coverUrl: nil, pluginId: "plugin.test", isAnime: kind == .anime,
                pluginType: kind, rawPayload: payload, anilistId: nil
            ).insert(db)
        }
        try await manager.reload()
        return (database, manager)
    }

    private func recordState(_ database: TestDatabase, payloadDigest: String, scope: LibraryCatalogScope = .allEligible) async throws {
        try await database.dbPool.write { db in
            try LibrarySnapshotStateRecord(
                pluginId: "plugin.test", mediaKind: .manga, canonicalMediaId: "series-1",
                payloadSHA256: payloadDigest, refreshedAt: Self.refreshedAt,
                catalogScope: scope, catalogCompleteness: .complete, chapterRowCount: 3
            ).save(db)
        }
    }

    @Test func theCatalogIsTheSavedPayloadsOwnRowsAsFacts() async throws {
        let payload = try Self.payload(["c1", "c2", "c3"])
        let (database, manager) = try await makeManager(itemID: "series-1", payload: payload)
        defer { database.cleanup() }
        try await recordState(database, payloadDigest: OfflineDigest.sha256Hex(payload))

        let basis = try #require(try await manager.snapshotBasis(for: Self.media))

        #expect(basis.catalog.map(\.key) == ["c1", "c2", "c3"])
        #expect(basis.catalog.map(\.number) == [1, 2, 3])
        #expect(basis.catalog.map(\.scanlator) == ["A", "A", "A"])
        #expect(basis.catalog.map(\.isLocked) == [false, false, true])
        #expect(basis.currentPayloadSHA256 == OfflineDigest.sha256Hex(payload))
        #expect(basis.snapshot.payloadSHA256 == basis.currentPayloadSHA256)
        #expect(basis.snapshot.catalogScope == .complete)
    }

    @Test func aLegacyCandidateItemIdIsFoundLikeAnyOtherSnapshotRead() async throws {
        let payload = try Self.payload(["c1", "c2"])
        let candidates = ImportedMediaIdentity.localItemIDs(
            pluginId: Self.media.pluginId, canonicalMediaId: Self.media.canonicalMediaId, mediaKind: Self.media.mediaKind
        )
        let legacyID = try #require(candidates.first { $0 != Self.media.canonicalMediaId })
        let (database, manager) = try await makeManager(itemID: legacyID, payload: payload)
        defer { database.cleanup() }
        try await recordState(database, payloadDigest: OfflineDigest.sha256Hex(payload))

        let basis = try #require(try await manager.snapshotBasis(for: Self.media))

        #expect(basis.catalog.map(\.key) == ["c1", "c2"])
    }

    @Test func aStateWrittenForAnotherPayloadDoesNotMatchTheSavedOne() async throws {
        let payload = try Self.payload(["c1", "c2", "c3"])
        let (database, manager) = try await makeManager(itemID: "series-1", payload: payload)
        defer { database.cleanup() }
        // A restore put an older payload back: the state describes a payload that is no longer saved.
        try await recordState(database, payloadDigest: OfflineDigest.sha256Hex(Data("older".utf8)))

        let basis = try #require(try await manager.snapshotBasis(for: Self.media))

        #expect(basis.snapshot.payloadSHA256 != basis.currentPayloadSHA256)
        let result = SeriesOfflineCoverage.evaluate(
            snapshot: basis.snapshot,
            currentPayloadSHA256: basis.currentPayloadSHA256,
            selection: .sourceList,
            catalog: basis.catalog,
            states: ["c1": .downloaded, "c2": .downloaded],
            now: Self.refreshedAt
        )
        #expect(result == .saved(2), "The claim is refused for a payload the state was not written for")
    }

    @Test func noStateMeansNoBasisAndAnUnreadablePayloadMeansNoRows() async throws {
        let payload = try Self.payload(["c1"])
        let (database, manager) = try await makeManager(itemID: "series-1", payload: payload)
        defer { database.cleanup() }
        #expect(try await manager.snapshotBasis(for: Self.media) == nil)

        let garbage = Data("not a series".utf8)
        try await database.dbPool.write { db in
            try db.execute(sql: "UPDATE libraryItem SET rawPayload = ? WHERE id = 'series-1'", arguments: [garbage])
        }
        try await manager.reload()
        try await recordState(database, payloadDigest: OfflineDigest.sha256Hex(garbage))

        let basis = try #require(try await manager.snapshotBasis(for: Self.media))
        #expect(basis.catalog.isEmpty)
    }

    @Test func theRowsAreOnlyReadWhenTheyCouldBackTheClaim() async throws {
        let payload = try Self.payload(["c1", "c2", "c3"])
        let (database, manager) = try await makeManager(itemID: "series-1", payload: payload)
        defer { database.cleanup() }

        // A catalog that is not known to cover everything backs no claim, so its rows are not read.
        try await recordState(database, payloadDigest: OfflineDigest.sha256Hex(payload), scope: .visible)
        let visible = try #require(try await manager.snapshotBasis(for: Self.media))
        #expect(visible.catalog.isEmpty)
        #expect(visible.snapshot.catalogScope == .visible || visible.snapshot.catalogScope == .partial)

        // The same for a complete catalog written for another payload.
        try await recordState(database, payloadDigest: OfflineDigest.sha256Hex(Data("older".utf8)))
        let mismatched = try #require(try await manager.snapshotBasis(for: Self.media))
        #expect(mismatched.catalog.isEmpty)

        // And they are read once the state does back it.
        try await recordState(database, payloadDigest: OfflineDigest.sha256Hex(payload))
        let backing = try #require(try await manager.snapshotBasis(for: Self.media))
        #expect(backing.catalog.map(\.key) == ["c1", "c2", "c3"])
    }

    @Test func anotherSeriesOfTheSameSourceIsNotRead() async throws {
        let payload = try Self.payload(["c1"])
        let (database, manager) = try await makeManager(itemID: "series-1", payload: payload)
        defer { database.cleanup() }
        try await recordState(database, payloadDigest: OfflineDigest.sha256Hex(payload))
        let other = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-2", mediaKind: .manga)

        #expect(try await manager.snapshotBasis(for: other) == nil)
    }
}
