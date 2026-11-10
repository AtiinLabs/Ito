import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// The scanlator choices a user asked to remember: stored per series on this installation, read back as the
/// same selection, and never carried in a backup.
@MainActor
struct EditionPreferenceTests {
    private nonisolated static let series = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)
    private nonisolated static let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aRememberedChoiceReadsBackAsTheSameSelection() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let selections: [EditionSelection] = [
            .sourceList,
            .allUploads,
            .scanlators([ScanlatorRef(name: "B"), ScanlatorRef(id: "g-1", name: "A"), ScanlatorRef(name: nil)])
        ]

        for selection in selections {
            try await database.dbPool.write {
                try SeriesEditionPreferenceRecord.save(selection, for: Self.series, at: Self.date, in: $0)
            }
            let stored = try await database.dbPool.read {
                try SeriesEditionPreferenceRecord.selection(for: Self.series, in: $0)
            }
            #expect(stored == selection)
        }
        // One row per series: a later choice replaces the earlier one.
        let rows = try await database.dbPool.read { try SeriesEditionPreferenceRecord.fetchCount($0) }
        #expect(rows == 1)
    }

    @Test func theChoiceIsStoredAsTheSelectionsOwnBytes() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let selection = EditionSelection.scanlators([ScanlatorRef(name: "A")])

        try await database.dbPool.write {
            try SeriesEditionPreferenceRecord.save(selection, for: Self.series, at: Self.date, in: $0)
        }

        let bytes = try await database.dbPool.read { try SeriesEditionPreferenceRecord.fetchOne($0)?.selection }
        let expected = try selection.storageData()
        #expect(bytes == expected)
    }

    @Test func eachSeriesAndKindKeepsItsOwnChoice() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let novel = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .novel)
        let other = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-2", mediaKind: .manga)

        try await database.dbPool.write { db in
            try SeriesEditionPreferenceRecord.save(.allUploads, for: Self.series, at: Self.date, in: db)
            try SeriesEditionPreferenceRecord.save(.sourceList, for: novel, at: Self.date, in: db)
        }

        let read = try await database.dbPool.read { db in
            (
                try SeriesEditionPreferenceRecord.selection(for: Self.series, in: db),
                try SeriesEditionPreferenceRecord.selection(for: novel, in: db),
                try SeriesEditionPreferenceRecord.selection(for: other, in: db)
            )
        }
        #expect(read.0 == .allUploads)
        #expect(read.1 == .sourceList)
        #expect(read.2 == nil)
    }

    @Test func aChoiceThisBuildCannotReadIsAnErrorRatherThanNoChoiceOrAnotherOne() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let unreadable = [
            Data("not json".utf8),
            Data(#"{"formatVersion":2,"kind":"allUploads"}"#.utf8),
            Data(#"{"formatVersion":1,"kind":"somethingNew"}"#.utf8)
        ]

        for bytes in unreadable {
            try await database.dbPool.write { db in
                try db.execute(sql: "DELETE FROM seriesEditionPreference")
                try SeriesEditionPreferenceRecord(
                    pluginId: Self.series.pluginId,
                    mediaKind: .manga,
                    canonicalMediaId: Self.series.canonicalMediaId,
                    selection: bytes,
                    updatedAt: Self.date
                ).insert(db)
            }
            do {
                _ = try await database.dbPool.read {
                    try SeriesEditionPreferenceRecord.selection(for: Self.series, in: $0)
                }
                Issue.record("An unreadable stored choice must not read as a choice or as none")
            } catch {
                #expect((error as? SeriesEditionPreferenceError) == .unreadable)
            }
        }
    }

    @Test func removingASeriesFromTheLibraryForgetsItsRememberedChoiceAndNobodyElses() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = LibraryManager(dbPool: database.dbPool)
        let other = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-2", mediaKind: .manga)
        try await database.dbPool.write { db in
            for id in ["series-1", "series-2"] {
                try LibraryItem(
                    id: id, title: id, coverUrl: nil, pluginId: "plugin.test", isAnime: false, pluginType: .manga,
                    rawPayload: Data("x".utf8), anilistId: nil
                ).insert(db)
            }
            try SeriesEditionPreferenceRecord.save(.allUploads, for: Self.series, at: Self.date, in: db)
            try SeriesEditionPreferenceRecord.save(.sourceList, for: other, at: Self.date, in: db)
        }
        try await manager.reload()

        try await manager.removeItemDurably(itemID: "series-1", pluginId: "plugin.test", mediaKind: .manga)

        let remaining = try await database.dbPool.read { try SeriesEditionPreferenceRecord.fetchAll($0).map(\.canonicalMediaId) }
        #expect(remaining == ["series-2"])
    }

    @Test func animeCannotHaveAChoice() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let anime = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .anime)

        await #expect(throws: (any Error).self) {
            try await database.dbPool.write {
                try SeriesEditionPreferenceRecord.save(.sourceList, for: anime, at: Self.date, in: $0)
            }
        }
    }

    @Test func theDownloadCenterRemembersAndRereadsAChoice() async throws {
        let fixture = try DownloadWorkerFixture()
        let selection = EditionSelection.scanlators([ScanlatorRef(name: "A")])
        let series = MediaIdentity(
            pluginId: DownloadWorkerFixture.plugin,
            canonicalMediaId: "series-1",
            mediaKind: .manga
        )
        #expect(try await fixture.center.editionPreference(for: series) == nil)

        try await fixture.center.setEditionPreference(selection, for: series)

        #expect(try await fixture.center.editionPreference(for: series) == selection)
        try await fixture.center.setEditionPreference(.allUploads, for: series)
        #expect(try await fixture.center.editionPreference(for: series) == .allUploads)
    }

    // MARK: - Backup

    @Test func theTableIsInstallationLocalWithAReasonAndNoBackupComponent() {
        let reason = BackupExportOperation.excludedTableReasons[SeriesEditionPreferenceRecord.databaseTableName]
        #expect(reason?.isEmpty == false)
        #expect(
            !BackupExportOperation.durableTablesByComponent.values.flatMap { $0 }
                .contains(SeriesEditionPreferenceRecord.databaseTableName)
        )
    }

    @Test func theV21MigrationAddsTheTableWithoutTouchingEarlierOfflineState() throws {
        let queue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(queue, upTo: "v20")
        let hadTableAtV20 = try queue.read { try $0.tableExists("seriesEditionPreference") }
        #expect(!hadTableAtV20)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO librarySnapshotState
                      (pluginId, mediaKind, canonicalMediaId, payloadSHA256, refreshedAt, catalogScope,
                       catalogCompleteness, chapterRowCount)
                    VALUES ('plugin.test', 'manga', 'series-1', ?, ?, 'unknown', 'unknown', 3)
                    """,
                arguments: [String(repeating: "a", count: 64), Self.date]
            )
        }

        try migrator.migrate(queue)

        let state = try queue.read { db in
            (
                try db.tableExists("seriesEditionPreference"),
                try SeriesEditionPreferenceRecord.fetchCount(db),
                try LibrarySnapshotStateRecord.fetchCount(db)
            )
        }
        #expect(state.0)
        #expect(state.1 == 0)
        #expect(state.2 == 1)
    }

    @Test func anExportCarriesNoRememberedChoicesAndLeavesTheInstallationsOwn() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            for entry in AppPreferenceCatalogEntry.allCases {
                try AppPreference(key: entry.rawValue, value: entry.canonicalDefaultJSON).insert(db)
            }
            try SeriesEditionPreferenceRecord.save(.allUploads, for: Self.series, at: Self.date, in: db)
        }
        let output = database.databaseURL.deletingLastPathComponent().appendingPathComponent("preferences.itobackup")

        try await BackupExportOperation(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            readinessGate: {}
        ).export(to: output)

        let exported = try DatabaseQueue(path: output.path)
        defer { try? exported.close() }
        let exportedRows = try await exported.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM seriesEditionPreference") ?? -1
        }
        #expect(exportedRows == 0)
        let localRows = try await database.dbPool.read { try SeriesEditionPreferenceRecord.fetchCount($0) }
        #expect(localRows == 1)
    }
}
