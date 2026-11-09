import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// Downloads belong to this installation: restoring a manual backup must neither bring rows in
/// nor remove the ones already here.
struct OfflineChapterBackupTests {
    @Test func restoringAManualBackupLeavesLocalDownloadsUntouched() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let versionId = try await fixture.publishedEdition(store)
        _ = try await fixture.enqueueBatch(store, chapterKeys: ["chapter-2", "chapter-3"])
        _ = try await fixture.enqueue(store, chapterKey: "chapter-4")
        try await fixture.database.dbPool.write { db in
            try DownloadSuppressionRecord(
                pluginId: "plugin.test",
                mediaKind: .manga,
                canonicalMediaId: "series-1",
                chapterKey: "chapter-9",
                authorityScope: .publicUnscoped,
                suppressedAt: OfflineStoreFixture.fixedDate
            ).insert(db)
        }
        try await fixture.database.dbPool.write { db in
            for entry in AppPreferenceCatalogEntry.allCases {
                try AppPreference(key: entry.rawValue, value: entry.canonicalDefaultJSON).insert(db)
            }
        }
        let before = try await Self.downloadState(fixture.database.dbPool)

        let backupURL = fixture.database.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("offline-downloads.itobackup")
        try await BackupExportOperation(
            dbPool: fixture.database.dbPool,
            sourceDatabaseURL: fixture.database.databaseURL,
            readinessGate: {}
        ).export(to: backupURL)
        let backup = try await ItoNativeImporter().parse(url: backupURL)
        _ = try await ComponentAwareBackupRestoreOperation(
            dbPool: fixture.database.dbPool,
            operationIdProvider: { "offline-restore" },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ).restore(backup, mode: .merge, operationId: "offline-restore")

        #expect(try await Self.downloadState(fixture.database.dbPool) == before)
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition)?.versionId == versionId)
    }

    private static func downloadState(_ dbPool: DatabasePool) async throws -> [String] {
        try await dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT 'row:' || chapterKey || ':' || versionId || ':' || state FROM downloadedChapter
                UNION ALL SELECT 'job:' || chapterKey || ':' || id || ':' || state || ':' || batchId || ':' || sequence FROM downloadJob
                UNION ALL SELECT 'batch:' || id || ':' || preset || ':' || length(selection) || ':' || length(entrySnapshot) FROM downloadBatch
                UNION ALL SELECT 'suppression:' || chapterKey FROM downloadSuppression
                UNION ALL SELECT 'store:' || storeId FROM downloadStore
                ORDER BY 1
                """)
        }
    }
}
