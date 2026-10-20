import Foundation
import GRDB
import Testing
@testable import Ito

@MainActor
struct ReadProgressStoreTests {
    @Test func scopedProgressRoundTripsAndUsesNumberFallback() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = ReadProgressManager(dbPool: database.dbPool)
        let first = MediaIdentity(pluginId: "plugin.one", canonicalMediaId: "same")
        let second = MediaIdentity(pluginId: "plugin.two", canonicalMediaId: "same")

        try await manager.markAsRead(media: first, chapterId: "chapter-a", chapterNum: 1.5)
        #expect(manager.isRead(media: first, chapterId: "other-key", chapterNum: 1.5))
        #expect(!manager.isRead(media: second, chapterId: "chapter-a", chapterNum: 1.5))
        #expect(manager.lastReadChapter(for: first) == "chapter-a")

        let reloaded = ReadProgressManager(dbPool: database.dbPool)
        try await reloaded.reload()
        #expect(reloaded.isRead(media: first, chapterId: "chapter-a", chapterNum: nil))
        #expect(reloaded.readChapterNumbers(for: first) == [1.5])
    }

    @Test func logicalUpsertReplacesMetadataWithoutDuplicatingProgress() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = ReadProgressManager(dbPool: database.dbPool)
        let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media")

        try await manager.markAsRead(media: media, chapterId: "chapter", chapterNum: 2)
        try await manager.markAsRead(media: media, chapterId: "chapter", chapterNum: 2)

        try await database.dbPool.read { db in
            let keyCount = try ReadProgressKeyRecord.fetchCount(db)
            let numberCount = try ReadProgressNumberRecord.fetchCount(db)
            let resumeCount = try MediaReadProgressRecord.fetchCount(db)
            #expect(keyCount == 1)
            #expect(numberCount == 1)
            #expect(resumeCount == 1)
        }
    }

    @Test func markUpToClearsBadgeInSameCommit() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let updates = UpdateManager(dbPool: database.dbPool)
        let manager = ReadProgressManager(dbPool: database.dbPool)
        manager.configure(updateManager: updates)
        let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media")
        let pluginId = media.pluginId
        let canonicalMediaId = media.canonicalMediaId
        try await database.dbPool.write { db in
            try UpdateBadgeRecord(
                pluginId: pluginId,
                canonicalMediaId: canonicalMediaId,
                count: 4,
                updatedAt: Date(),
                provenance: .runtime
            ).insert(db)
        }
        try await updates.reload()

        try await manager.markReadUpTo(media: media, maxChapterNum: 3.5)

        #expect(manager.readChapterNumbers(for: media) == [1, 2, 3, 3.5])
        #expect(updates.badgeCount(for: media) == 0)
        try await database.dbPool.read { db in
            let badgeCount = try UpdateBadgeRecord.fetchCount(db)
            #expect(badgeCount == 0)
        }
    }

    @Test func markUpToZeroIsNoOp() async throws {
        try await expectMarkUpToNoOp(maxChapterNum: 0)
    }

    @Test func markUpToNegativeIsNoOp() async throws {
        try await expectMarkUpToNoOp(maxChapterNum: -2)
    }

    @Test func markUpToFractionalBelowOneIsNoOp() async throws {
        try await expectMarkUpToNoOp(maxChapterNum: 0.5)
    }

    @Test func databaseFailureDoesNotPublishOrLeavePartialRows() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = ReadProgressManager(dbPool: database.dbPool)
        let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media")
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_read_number
                BEFORE INSERT ON readProgressNumber
                BEGIN
                    SELECT RAISE(ABORT, 'injected read failure');
                END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await manager.markAsRead(
                media: media,
                chapterId: "chapter",
                chapterNum: 1
            )
        }

        #expect(!manager.isRead(media: media, chapterId: "chapter", chapterNum: 1))
        #expect(manager.lastReadChapter(for: media) == nil)
        try await database.dbPool.read { db in
            let keyCount = try ReadProgressKeyRecord.fetchCount(db)
            let numberCount = try ReadProgressNumberRecord.fetchCount(db)
            let resumeCount = try MediaReadProgressRecord.fetchCount(db)
            #expect(keyCount == 0)
            #expect(numberCount == 0)
            #expect(resumeCount == 0)
        }
    }

    @Test func positionIsSavedPerLastChapterAndSurvivesReload() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = ReadProgressManager(dbPool: database.dbPool)
        let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media")

        try await manager.savePosition(media: media, chapterKey: "chapter-3", position: 12)

        #expect(manager.savedPosition(media: media, chapterKey: "chapter-3") == 12)
        #expect(manager.savedPosition(media: media, chapterKey: "chapter-4") == nil)
        #expect(manager.lastReadChapter(for: media) == "chapter-3")
        #expect(!manager.isRead(media: media, chapterId: "chapter-3"))

        let reloaded = ReadProgressManager(dbPool: database.dbPool)
        try await reloaded.reload()
        #expect(reloaded.savedPosition(media: media, chapterKey: "chapter-3") == 12)
    }

    @Test func finishingTheSavedChapterKeepsItsPositionButAnotherChapterClearsIt() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = ReadProgressManager(dbPool: database.dbPool)
        let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media")

        try await manager.savePosition(media: media, chapterKey: "chapter-3", position: 19)
        try await manager.markAsRead(media: media, chapterId: "chapter-3", chapterNum: 3)
        #expect(manager.savedPosition(media: media, chapterKey: "chapter-3") == 19)

        try await manager.markAsRead(media: media, chapterId: "chapter-7", chapterNum: 7)
        #expect(manager.savedPosition(media: media, chapterKey: "chapter-7") == nil)
        let reloaded = ReadProgressManager(dbPool: database.dbPool)
        try await reloaded.reload()
        #expect(reloaded.lastReadChapter(for: media) == "chapter-7")
        #expect(reloaded.savedPosition(media: media, chapterKey: "chapter-7") == nil)
    }

    @Test func rowsWithoutThePositionColumnDecodeWithNoPosition() throws {
        // Backups made before v10 have no lastReadPosition column.
        let queue = try DatabaseQueue()
        let record = try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE mediaReadProgress (
                    pluginId TEXT NOT NULL, canonicalMediaId TEXT NOT NULL,
                    lastReadChapterKey TEXT NOT NULL, updatedAt DATETIME, provenance TEXT
                )
                """)
            try db.execute(sql: """
                INSERT INTO mediaReadProgress (pluginId, canonicalMediaId, lastReadChapterKey)
                VALUES ('plugin', 'media', 'chapter')
                """)
            return try MediaReadProgressRecord.fetchOne(db)
        }
        #expect(record?.lastReadChapterKey == "chapter")
        #expect(record?.lastReadPosition == nil)
    }

    private func expectMarkUpToNoOp(maxChapterNum: Float) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = ReadProgressManager(dbPool: database.dbPool)
        let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media")

        try await manager.markReadUpTo(media: media, maxChapterNum: maxChapterNum)

        #expect(manager.readChapterNumbers(for: media).isEmpty)
        let rowCounts = try await database.dbPool.read { db in
            (
                keys: try ReadProgressKeyRecord.fetchCount(db),
                numbers: try ReadProgressNumberRecord.fetchCount(db),
                resume: try MediaReadProgressRecord.fetchCount(db),
                badges: try UpdateBadgeRecord.fetchCount(db)
            )
        }
        #expect(rowCounts.keys == 0)
        #expect(rowCounts.numbers == 0)
        #expect(rowCounts.resume == 0)
        #expect(rowCounts.badges == 0)
    }
}
