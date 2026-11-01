import Foundation
import GRDB
import XCTest
@testable import Ito

final class HistoryChapterNumberMigrationTests: XCTestCase {
    func testRowsWithoutTheColumnStillDecodeAndKeepTheirFieldsAfterV17() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v16")
        let readAt = Date(timeIntervalSince1970: 1_700_000_000)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO readingHistory
                        (id, libraryItemId, mediaKey, title, coverUrl, pluginId, mediaKind, chapterKey, chapterTitle, readAt)
                    VALUES ('row', NULL, 'media', 'Title', NULL, 'plugin', 'manga', 'chapter-7', 'chapter-7', ?)
                    """,
                arguments: [readAt]
            )
        }

        // A database or backup written before v17 has no chapterNumber column.
        let beforeV17 = try dbQueue.read(ReadingHistoryRecord.fetchAll)
        XCTAssertEqual(beforeV17.map(\.id), ["row"])
        XCTAssertNil(beforeV17[0].chapterNumber)

        try migrator.migrate(dbQueue)

        let migrated = try XCTUnwrap(try dbQueue.read { try ReadingHistoryRecord.fetchOne($0, key: "row") })
        XCTAssertEqual(migrated.chapterKey, "chapter-7")
        XCTAssertEqual(migrated.chapterTitle, "chapter-7")
        XCTAssertNil(migrated.chapterNumber)
        XCTAssertEqual(migrated.readAt, readAt)

        var numbered = migrated
        numbered.chapterNumber = 7.5
        try dbQueue.write { try numbered.update($0) }
        let reread = try dbQueue.read { try ReadingHistoryRecord.fetchOne($0, key: "row") }
        XCTAssertEqual(reread?.chapterNumber, 7.5)
    }

    func testV17FoldsEarlierVisitsToTheSameChapterIntoTheNewest() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v16")
        try dbQueue.write { db in
            for (id, media, chapter, readAt) in [
                ("old-visit", "media", "chapter-1", 1.0),
                ("new-visit", "media", "chapter-1", 3.0),
                ("other-chapter", "media", "chapter-2", 2.0),
                ("other-series", "media-2", "chapter-1", 0.5)
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO readingHistory
                            (id, libraryItemId, mediaKey, title, coverUrl, pluginId, mediaKind, chapterKey, chapterTitle, readAt)
                        VALUES (?, NULL, ?, 'Title', NULL, 'plugin', 'manga', ?, NULL, ?)
                        """,
                    arguments: [id, media, chapter, Date(timeIntervalSince1970: readAt)]
                )
            }
        }

        try migrator.migrate(dbQueue)

        let ids = try dbQueue.read { try String.fetchSet($0, sql: "SELECT id FROM readingHistory") }
        XCTAssertEqual(ids, ["new-visit", "other-chapter", "other-series"])
    }
}
