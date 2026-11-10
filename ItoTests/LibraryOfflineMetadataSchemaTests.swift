import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

/// Schema v20: the saved-details freshness and cover thumbnail tables.
struct LibraryOfflineMetadataSchemaTests {
    @Test func v20AddsTheLibraryMetadataTablesEmptyAndKeepsTheV19Rows() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v19")
        let item = makeLibraryItem(id: "series-1", pluginId: "plugin.test", anilistId: nil)
        let suppressedAt = Date(timeIntervalSince1970: 1_000)
        try dbQueue.write { db in
            try item.insert(db)
            try DownloadSuppressionRecord(
                pluginId: "plugin.test",
                mediaKind: .manga,
                canonicalMediaId: "series-1",
                chapterKey: "chapter-1",
                authorityScope: .publicUnscoped,
                suppressedAt: suppressedAt
            ).insert(db)
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let fetched = try LibraryItem.fetchOne(db, key: "series-1")
            let suppression = try DownloadSuppressionRecord.fetchOne(db)
            let states = try LibrarySnapshotStateRecord.fetchCount(db)
            let thumbnails = try LibraryCoverThumbnailRecord.fetchCount(db)
            let migrated = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM grdb_migrations WHERE identifier = 'v20')"
            )
            #expect(fetched == item)
            #expect(suppression?.suppressedAt == suppressedAt)
            #expect(states == 0)
            #expect(thumbnails == 0)
            #expect(migrated == true)
        }
    }

    @Test func v20StoresAnUnknownCatalogAsUnknownAndRefusesWhatItCannotRepresent() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let digest = String(repeating: "a", count: 64)
        func insertState(
            scope: String = "unknown",
            completeness: String = "unknown",
            rows: Int = 1,
            digest: String = digest,
            media: String = "series-1",
            kind: String = "manga"
        ) throws {
            try database.dbPool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO librarySnapshotState
                          (pluginId, mediaKind, canonicalMediaId, payloadSHA256, refreshedAt, catalogScope,
                           catalogCompleteness, chapterRowCount)
                        VALUES ('plugin.test', ?, ?, ?, 0, ?, ?, ?)
                        """,
                    arguments: [kind, media, digest, scope, completeness, rows]
                )
            }
        }

        // Scope and completeness are separate columns, each with its own unknown.
        try insertState(media: "a")
        try insertState(scope: "visible", completeness: "complete", media: "b")
        try insertState(scope: "allEligible", completeness: "partial", media: "c")
        try insertState(scope: "allEligible", completeness: "complete", media: "d", kind: "anime")

        #expect(throws: DatabaseError.self) { try insertState(rows: 0, media: "e") }
        #expect(throws: DatabaseError.self) { try insertState(scope: "complete", media: "f") }
        #expect(throws: DatabaseError.self) { try insertState(completeness: "visible", media: "g") }
        #expect(throws: DatabaseError.self) { try insertState(digest: "short", media: "h") }
        #expect(throws: DatabaseError.self) { try insertState(media: "i", kind: "video") }
        #expect(throws: DatabaseError.self) { try insertState(media: "a") }
        let kept = try database.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT canonicalMediaId FROM librarySnapshotState ORDER BY 1")
        }
        #expect(kept == ["a", "b", "c", "d"])
    }

    @Test func v20RefusesAThumbnailTheLibraryCannotUse() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try database.dbPool.write { db in
            try makeLibraryItem(id: "series-1", pluginId: "plugin.test", anilistId: nil).insert(db)
        }
        let digest = String(repeating: "b", count: 64)
        func insertThumbnail(
            item: String = "series-1",
            data: Data = Data([1]),
            width: Int = 20,
            height: Int = 30,
            digest: String = digest
        ) throws {
            try database.dbPool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO libraryCoverThumbnail
                          (libraryItemId, coverURLSHA256, imageData, pixelWidth, pixelHeight, storedAt)
                        VALUES (?, ?, ?, ?, ?, 0)
                        """,
                    arguments: [item, digest, data, width, height]
                )
            }
        }

        #expect(throws: DatabaseError.self) { try insertThumbnail(data: Data()) }
        #expect(throws: DatabaseError.self) { try insertThumbnail(data: Data(count: 262_145)) }
        #expect(throws: DatabaseError.self) { try insertThumbnail(width: 0) }
        #expect(throws: DatabaseError.self) { try insertThumbnail(width: 1_025) }
        #expect(throws: DatabaseError.self) { try insertThumbnail(height: 0) }
        #expect(throws: DatabaseError.self) { try insertThumbnail(height: 1_537) }
        #expect(throws: DatabaseError.self) { try insertThumbnail(digest: "short") }
        // A thumbnail needs a Library item.
        #expect(throws: DatabaseError.self) { try insertThumbnail(item: "missing") }

        try insertThumbnail(data: Data(count: 262_144), width: 1_024, height: 1_536)
        let count = try database.dbPool.read { db in try LibraryCoverThumbnailRecord.fetchCount(db) }
        #expect(count == 1)
        // One thumbnail per item.
        #expect(throws: DatabaseError.self) { try insertThumbnail() }
    }

    private func makeLibraryItem(id: String, pluginId: String, anilistId: Int?) -> LibraryItem {
        LibraryItem(
            id: id, title: "Title", coverUrl: nil, pluginId: pluginId, isAnime: false,
            pluginType: nil, rawPayload: Data([1, 2, 3]), anilistId: anilistId
        )
    }
}
