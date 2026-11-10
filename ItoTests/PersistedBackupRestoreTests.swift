import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// A backup file exported by the app, holding Library rows saved before and after chapters carried a content
/// kind, restores through `BackupManager` with every saved field and payload intact. Backups carry no
/// download rows, so the offline snapshots are never part of one.
@MainActor
struct PersistedBackupRestoreTests {
    private static let backupFileName = "persisted-library-backup.itobackup"

    @Test(arguments: [BackupRestoreMode.merge, .wipe])
    func restoringTheBackupBringsBackEveryLibraryRowAndPayload(mode: BackupRestoreMode) async throws {
        let target = try TestDatabase()
        defer { target.cleanup() }
        let manager = try Self.makeManager(target: target)
        let backupURL = try Self.stageBackup(beside: target)

        _ = try await manager.restoreBackup(from: backupURL, mode: mode)

        let rows = try await target.dbPool.read { db in
            Dictionary(uniqueKeysWithValues: try Ito.LibraryItem.fetchAll(db).map { ($0.id, $0) })
        }
        #expect(Set(rows.keys) == Set(PersistedLibraryFixture.allCases.map(\.id)))
        for fixture in PersistedLibraryFixture.allCases {
            let row = try #require(rows[fixture.id], "Missing restored row \(fixture.id)")
            #expect(row.title == fixture.title)
            #expect(row.coverUrl == fixture.coverURL)
            #expect(row.pluginId == PersistedLibraryFixture.pluginId)
            #expect(row.isAnime == (fixture.kind == .anime))
            #expect(row.pluginType == fixture.kind)
            #expect(row.rawPayload == (try fixture.payload()))
            #expect(row.knownChapterCount == (fixture.kind == .manga ? 5 : fixture.kind == .novel ? 4 : 3))
            PersistedExpectations.check(try await JSONDeferredPluginPayloadDecoder().decode(row), fixture)
        }
        #expect(rows["manga-abi1"]?.anilistId == 4242)
        #expect(rows["manga-abi1"]?.status == "Ongoing")
        #expect(rows["manga-abi2"]?.anilistId == nil)
    }

    @Test func restoredRowsKeepTheirCategories() async throws {
        let target = try TestDatabase()
        defer { target.cleanup() }
        let manager = try Self.makeManager(target: target)

        _ = try await manager.restoreBackup(from: try Self.stageBackup(beside: target), mode: .merge)

        let favorites = try await target.dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT itemLink.itemId FROM itemCategoryLink AS itemLink
                JOIN libraryCategory AS category ON category.id = itemLink.categoryId
                WHERE category.name = 'Favorites' ORDER BY itemLink.itemId
                """)
        }
        #expect(favorites == ["manga-abi1", "novel-abi2"])
    }

    @Test func theBackupBringsNoDownloadRowsAndItsAnalysisFindsNoConflict() async throws {
        let target = try TestDatabase()
        defer { target.cleanup() }
        let manager = try Self.makeManager(target: target)
        let backupURL = try Self.stageBackup(beside: target)

        #expect(try await manager.analyzeMerge(from: backupURL).isEmpty)
        _ = try await manager.restoreBackup(from: backupURL, mode: .merge)

        let counts = try await target.dbPool.read { db in
            try ["downloadBatch", "downloadJob", "downloadedChapter"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        #expect(counts == [0, 0, 0])
    }

    // MARK: - Helpers

    /// A copy of the golden backup next to the target database, so the bundle's file is never opened for write.
    static func stageBackup(beside target: TestDatabase) throws -> URL {
        let url = target.databaseURL.deletingLastPathComponent().appendingPathComponent(backupFileName)
        try FileManager.default.copyItem(at: PersistedDataFixtures.url(backupFileName), to: url)
        return url
    }

    static func makeManager(target: TestDatabase) throws -> BackupManager {
        let noOperation: BackupRestoreRefresher.RefreshOperations.Operation = {}
        let refresher = BackupRestoreRefresher(
            dbPool: target.dbPool,
            operations: .init(
                appSettings: noOperation,
                pluginIdentity: noOperation,
                pluginSettings: noOperation,
                repositories: noOperation,
                userImporterAliases: noOperation,
                library: noOperation,
                history: noOperation,
                readProgress: noOperation,
                trackerLinks: noOperation,
                updateBadges: noOperation,
                storage: noOperation,
                appearance: noOperation
            )
        )
        return BackupManager(
            dbPool: target.dbPool,
            sourceDatabaseURL: target.databaseURL,
            exportReadiness: {},
            restoreRefresher: refresher,
            pluginSecrets: PluginSecretStore(keychain: InMemoryPluginSecretKeychain())
        )
    }
}
