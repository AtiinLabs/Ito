import Foundation
import GRDB
import Testing
@testable import Ito

struct DownloadPresetsMigrationTests {
    private static let batchID = "11111111-1111-1111-1111-111111111111"
    private static let jobID = "22222222-2222-2222-2222-222222222222"

    /// A database at schema v25 holding one `next5` batch, one job in it, and a v25 capability row.
    private func databaseAtV25() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(queue, upTo: "v25")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO downloadBatch
                  (id, pluginId, mediaKind, canonicalMediaId, preset, selection, catalogDigest, entrySnapshot, createdAt)
                VALUES (?, 'plugin.test', 'manga', 'series-1', 'next5', ?, NULL, ?, 0)
                """, arguments: [Self.batchID, Data("{}".utf8), Data("{}".utf8)])
            try db.execute(sql: """
                INSERT INTO downloadJob
                  (id, batchId, sequence, pluginId, mediaKind, canonicalMediaId, chapterKey, authorityScope,
                   chapterSnapshot, seriesTitle, sourceEpoch, state, waitingReason, failureReason, stagingVersionId,
                   attemptCount, createdAt, updatedAt)
                VALUES (?, ?, 0, 'plugin.test', 'manga', 'series-1', 'c1', 'publicUnscoped',
                        ?, 'Series', NULL, 'queued', NULL, NULL, NULL, 0, 0, 0)
                """, arguments: [Self.jobID, Self.batchID, Data("{}".utf8)])
            try db.execute(sql: "INSERT INTO backupCapability (component, representation) VALUES ('savedLibraryThumbnails', 'representedEmpty')")
            // Synthetic v24-style child table: this base has no replacement migration, but the relation must
            // survive the parent-table rebuild exactly as the real replacement intent does.
            try db.execute(sql: """
                CREATE TABLE downloadReplacementIntent (
                  id TEXT PRIMARY KEY NOT NULL,
                  jobId TEXT NOT NULL REFERENCES downloadJob(id) ON DELETE CASCADE
                )
                """)
            try db.execute(
                sql: "INSERT INTO downloadReplacementIntent (id, jobId) VALUES ('intent', ?)",
                arguments: [Self.jobID]
            )
        }
        return queue
    }

    private func insertBatch(
        _ db: Database,
        preset: String,
        windowKind: String?,
        positionCount: DatabaseValueConvertible?,
        customPresetId: String?
    ) throws {
        let values: [DatabaseValueConvertible?] = [
            UUID().uuidString, preset, windowKind, positionCount, customPresetId, Data("{}".utf8), Data("{}".utf8)
        ]
        try db.execute(sql: """
            INSERT INTO downloadBatch
              (id, pluginId, mediaKind, canonicalMediaId, preset, windowKind, positionCount, customPresetId,
               selection, catalogDigest, entrySnapshot, createdAt)
            VALUES (?, 'plugin.test', 'manga', 'series-1', ?, ?, ?, ?, ?, NULL, ?, 0)
            """, arguments: StatementArguments(values))
    }

    private func insertDefinition(
        _ queue: DatabaseQueue,
        name: DatabaseValueConvertible? = nil,
        windowKind: String = "next",
        positionCount: DatabaseValueConvertible = 3,
        sortIndex: DatabaseValueConvertible = 0
    ) throws {
        let values: [DatabaseValueConvertible?] = [UUID().uuidString, name, windowKind, positionCount, sortIndex]
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO downloadPresetDefinition (id, name, windowKind, positionCount, sortIndex)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: StatementArguments(values))
        }
    }

    @Test func v26KeepsBatchRowsJobsAndTheirForeignKeyAndIndexes() throws {
        let queue = try databaseAtV25()
        try AppDatabase.makeMigrator().migrate(queue)

        try queue.read { db in
            let batch = try #require(try Row.fetchOne(db, sql: "SELECT * FROM downloadBatch WHERE id = ?", arguments: [Self.batchID]))
            let preset: String = batch["preset"]
            let selection: Data = batch["selection"]
            let windowKind: String? = batch["windowKind"]
            let positionCount: Int? = batch["positionCount"]
            let customPresetId: String? = batch["customPresetId"]
            #expect(preset == "next5")
            #expect(selection == Data("{}".utf8))
            #expect(windowKind == nil)
            #expect(positionCount == nil)
            #expect(customPresetId == nil)

            let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(downloadJob)")
            #expect(foreignKeys.contains { (row: Row) in (row["table"] as String?) == "downloadBatch" })
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)

            let indexes = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'downloadJob'"
            )
            #expect(indexes.contains("idx_downloadJob_queue"))
            #expect(indexes.contains("idx_downloadJob_batch"))

            let joined = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM downloadJob JOIN downloadBatch ON downloadBatch.id = downloadJob.batchId
                """)
            #expect(joined == 1)

            let capability = try String.fetchOne(
                db,
                sql: "SELECT representation FROM backupCapability WHERE component = 'savedLibraryThumbnails'"
            )
            #expect(capability == "representedEmpty")
        }
        try queue.write { db in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloadReplacementIntent") == 1)
            try db.execute(sql: "DELETE FROM downloadJob WHERE id = ?", arguments: [Self.jobID])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloadReplacementIntent") == 0)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test func batchCheckRejectsUnknownAndInconsistentProvenance() throws {
        let queue = try databaseAtV25()
        try AppDatabase.makeMigrator().migrate(queue)
        let id = UUID().uuidString

        try queue.write { db in
            // Valid shapes are accepted.
            try insertBatch(db, preset: "custom", windowKind: "next", positionCount: 5, customPresetId: id)
            try insertBatch(db, preset: "more", windowKind: "more", positionCount: 5, customPresetId: nil)
        }

        #expect(throws: DatabaseError.self) {
            try queue.write { db in try insertBatch(db, preset: "bogus", windowKind: nil, positionCount: nil, customPresetId: nil) }
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in try insertBatch(db, preset: "custom", windowKind: "next", positionCount: 5, customPresetId: nil) }
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in try insertBatch(db, preset: "more", windowKind: "next", positionCount: 5, customPresetId: nil) }
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in try insertBatch(db, preset: "next", windowKind: "next", positionCount: 5, customPresetId: nil) }
        }
        for badCount: DatabaseValueConvertible in [0, 1001, 1.5, "not-a-count"] {
            #expect(throws: DatabaseError.self) {
                try queue.write { db in try insertBatch(db, preset: "more", windowKind: "more", positionCount: badCount, customPresetId: nil) }
            }
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in try insertBatch(db, preset: "custom", windowKind: nil, positionCount: nil, customPresetId: id) }
        }
    }

    @Test func backupCapabilityAcceptsDownloadPresetsAndRejectsUnknownAndNullComponents() throws {
        let queue = try databaseAtV25()
        try AppDatabase.makeMigrator().migrate(queue)

        try queue.write { db in
            try db.execute(sql: "INSERT INTO backupCapability (component, representation) VALUES ('downloadPresets', 'representedEmpty')")
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO backupCapability (component, representation) VALUES ('futureComponent', 'representedEmpty')")
            }
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO backupCapability (component, representation) VALUES (NULL, 'representedEmpty')")
            }
        }
    }

    @Test func definitionTableRejectsEveryOutOfContractRow() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(queue)

        try insertDefinition(queue, name: "Valid", windowKind: "more", positionCount: 1000, sortIndex: 19)
        #expect(throws: DatabaseError.self) { try insertDefinition(queue, name: "") }
        #expect(throws: DatabaseError.self) { try insertDefinition(queue, name: String(repeating: "a", count: 257)) }
        #expect(throws: DatabaseError.self) { try insertDefinition(queue, name: Data([0x41])) }
        #expect(throws: DatabaseError.self) { try insertDefinition(queue, windowKind: "unread") }
        #expect(throws: DatabaseError.self) { try insertDefinition(queue, positionCount: 0) }
        #expect(throws: DatabaseError.self) { try insertDefinition(queue, positionCount: 1001) }
        #expect(throws: DatabaseError.self) { try insertDefinition(queue, sortIndex: 20) }
        #expect(throws: DatabaseError.self) { try insertDefinition(queue, sortIndex: 19) }
    }
}
