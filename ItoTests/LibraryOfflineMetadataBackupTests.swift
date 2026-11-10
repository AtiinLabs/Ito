import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

/// Snapshot freshness and cover thumbnails belong to this installation: manual backups carry the newest saved
/// details through the Library item itself, and nothing else.
@MainActor
struct LibraryOfflineMetadataBackupTests {
    private nonisolated static let pluginId = "plugin.test"
    private nonisolated static let media = MediaIdentity(pluginId: pluginId, canonicalMediaId: "series-1", mediaKind: .manga)
    private nonisolated static let originalPayload = Data("original".utf8)
    private nonisolated static let refreshedPayload = Data("refreshed".utf8)
    private nonisolated static let refreshedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private nonisolated static let originalCover = "https://example.com/original.jpg"
    private nonisolated static let refreshedCover = "https://example.com/refreshed.jpg"

    private struct Fixture {
        let database: TestDatabase
        let manager: LibraryManager
        let thumbnails: LibraryCoverThumbnailStore
    }

    private func makeFixture() async throws -> Fixture {
        let database = try TestDatabase()
        try await database.dbPool.write { db in
            for entry in AppPreferenceCatalogEntry.allCases {
                try AppPreference(key: entry.rawValue, value: entry.canonicalDefaultJSON).insert(db)
            }
            try LibraryItem(
                id: "series-1",
                title: "Series",
                coverUrl: Self.originalCover,
                pluginId: Self.pluginId,
                isAnime: false,
                pluginType: .manga,
                rawPayload: Self.originalPayload,
                anilistId: nil
            ).insert(db)
        }
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()
        return Fixture(
            database: database,
            manager: manager,
            thumbnails: LibraryCoverThumbnailStore(database: database.dbPool)
        )
    }

    /// Refreshes the series' details and keeps a thumbnail for the refreshed cover.
    private func refresh(_ fixture: Fixture) async throws {
        let token = try #require(try await fixture.manager.snapshotToken(for: Self.media))
        let outcome = try await fixture.manager.replaceSnapshotDurably(
            token,
            payload: Self.refreshedPayload,
            coverUrl: Self.refreshedCover,
            chapterRowCount: 3,
            refreshedAt: Self.refreshedAt
        )
        #expect(outcome == .replaced)
        let stored = try await fixture.thumbnails.store(
            EncodedCoverThumbnail(data: Data([1, 2, 3]), pixelWidth: 20, pixelHeight: 30),
            itemID: "series-1",
            coverUrl: Self.refreshedCover
        )
        #expect(stored == .stored)
    }

    private func export(_ fixture: Fixture, to name: String) async throws -> URL {
        let url = fixture.database.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent(name)
        try await BackupExportOperation(
            dbPool: fixture.database.dbPool,
            sourceDatabaseURL: fixture.database.databaseURL,
            readinessGate: {}
        ).export(to: url)
        return url
    }

    @Test func anExportCarriesTheRefreshedPayloadButNoFreshnessOrThumbnails() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        try await refresh(fixture)

        let url = try await export(fixture, to: "metadata.itobackup")

        let exported = try DatabaseQueue(path: url.path)
        defer { try? exported.close() }
        let counts = try await exported.read { db in
            try ["librarySnapshotState", "libraryCoverThumbnail"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? 0
            }
        }
        #expect(counts == [0, 0])
        // The newest details travel in the Library item, which is already a backup component.
        let exportedPayload = try await exported.read { db in
            try LibraryItem.fetchOne(db, key: "series-1")?.rawPayload
        }
        #expect(exportedPayload == Self.refreshedPayload)
        let localCounts = try await fixture.database.dbPool.read { db in
            try ["librarySnapshotState", "libraryCoverThumbnail"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? 0
            }
        }
        #expect(localCounts == [1, 1])
    }

    @Test func bothTablesAreClassifiedAsInstallationLocalWithAReason() {
        for table in ["librarySnapshotState", "libraryCoverThumbnail"] {
            let reason = BackupExportOperation.excludedTableReasons[table]
            #expect(reason?.isEmpty == false, "\(table) needs a reason")
            #expect(!BackupExportOperation.durableTablesByComponent.values.flatMap { $0 }.contains(table))
        }
    }

    @Test func restoringOlderDetailsLeavesTheLocalStateAloneAndHidesTheAgeOfThePayload() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        // The backup holds the details as they were before the refresh.
        let url = try await export(fixture, to: "before-refresh.itobackup")
        try await refresh(fixture)
        let tokenBeforeRestore = try #require(try await fixture.manager.snapshotToken(for: Self.media))
        #expect(try await fixture.manager.snapshotRefreshDate(for: Self.media) == Self.refreshedAt)
        let backup = try await ItoNativeImporter().parse(url: url)

        _ = try await ComponentAwareBackupRestoreOperation(
            dbPool: fixture.database.dbPool,
            operationIdProvider: { "metadata-restore" },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ).restore(
            backup,
            mode: .merge,
            operationId: "metadata-restore",
            resolvedConflicts: ["series-1": .keepBackup]
        )

        let restored = try await fixture.database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: "series-1")?.rawPayload
        }
        #expect(restored == Self.originalPayload)
        // The restore does not touch the installation's own tables.
        let state = try await fixture.database.dbPool.read { db in try LibrarySnapshotStateRecord.fetchAll(db) }
        #expect(state.count == 1)
        #expect(try await fixture.thumbnails.storedThumbnail(for: "series-1")?.data == Data([1, 2, 3]))
        // The restored payload is not the one the freshness describes: its age is unknown, not stale.
        #expect(try await fixture.manager.snapshotRefreshDate(for: Self.media) == nil)
        // A refresh that began before the restore cannot write over it.
        let outcome = try await fixture.manager.replaceSnapshotDurably(
            tokenBeforeRestore,
            payload: Data("late".utf8),
            coverUrl: nil,
            chapterRowCount: 1,
            refreshedAt: Self.refreshedAt
        )
        #expect(outcome == .stale)
    }
}
