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
            #expect(row.knownChapterCountBasis == nil, "Legacy backups must not claim the exact-key basis")
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

    @Test(arguments: [BackupRestoreMode.merge, .wipe])
    func exactCountBasisRoundTripsThroughExportAndRestore(mode: BackupRestoreMode) async throws {
        let source = try TestDatabase()
        defer { source.cleanup() }
        try await source.dbPool.write { db in
            // An installed app has every catalogued preference; export validates the complete catalog.
            for entry in AppPreferenceCatalogEntry.allCases {
                try AppPreference(key: entry.rawValue, value: entry.canonicalDefaultJSON).insert(db)
            }
        }
        let library = LibraryManager(dbPool: source.dbPool)
        let itemID = try await library.saveMangaDurably(
            manga: Manga(key: "editions", title: "Editions", chapters: [
                Chapter(key: "a", chapter: 1), Chapter(key: "b", chapter: 1)
            ]),
            pluginId: "source"
        )
        let url = source.databaseURL.deletingLastPathComponent().appendingPathComponent("basis.itobackup")
        try await BackupExportOperation(
            dbPool: source.dbPool, sourceDatabaseURL: source.databaseURL, readinessGate: {}
        ).export(to: url)
        let target = try TestDatabase()
        defer { target.cleanup() }
        let manager = try Self.makeManager(target: target)
        _ = try await manager.restoreBackup(from: url, mode: mode)
        let restored = try await target.dbPool.read { db in
            try #require(try Ito.LibraryItem.fetchOne(db, key: itemID))
        }
        #expect(restored.knownChapterCount == 2)
        #expect(restored.knownChapterCountBasis == .exactChapterKeys)
    }

    @Test func legacyAndUnknownCountBasisDecodeConservatively() throws {
        let item = Ito.LibraryItem(
            id: "legacy", title: "Legacy", coverUrl: nil, pluginId: "source",
            isAnime: false, pluginType: .manga, rawPayload: Data(), anilistId: nil,
            knownChapterCount: 4, knownChapterCountBasis: .exactChapterKeys
        )
        let encoded = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(Ito.LibraryItem.self, from: encoded).knownChapterCountBasis == .exactChapterKeys)
        var fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        fields.removeValue(forKey: "knownChapterCountBasis")
        let legacy = try JSONDecoder().decode(Ito.LibraryItem.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(legacy.knownChapterCount == 4)
        #expect(legacy.knownChapterCountBasis == nil)
        fields["knownChapterCountBasis"] = "future-identity"
        let unknown = try JSONDecoder().decode(Ito.LibraryItem.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(unknown.knownChapterCountBasis == .unknown)
        #expect(unknown != item)
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
