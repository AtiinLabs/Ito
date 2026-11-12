import Foundation
import GRDB
import XCTest
@testable import Ito
import ito_runner

final class HistoryScanlatorIdentityMigrationTests: XCTestCase {
    func testV22AddsNullableIdentityWithoutRewritingExistingHistory() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v21")
        let readAt = Date(timeIntervalSince1970: 1_700_000_000)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO readingHistory
                        (id, libraryItemId, mediaKey, title, coverUrl, pluginId, mediaKind, chapterKey, chapterTitle, scanlator, readAt)
                    VALUES ('legacy', NULL, 'media', 'Title', NULL, 'source', 'manga', 'chapter', 'chapter', 'Renamed later', ?)
                    """,
                arguments: [readAt]
            )
        }

        try migrator.migrate(dbQueue)

        let stored = try dbQueue.read { try ReadingHistoryRecord.fetchOne($0, key: "legacy") }
        XCTAssertNil(stored?.scanlatorID)
        XCTAssertEqual(stored?.scanlator, "Renamed later")
        XCTAssertEqual(stored?.readAt, readAt)

        let record = ReadingHistoryRecord(
            id: "new", mediaKey: "media", title: "Title", coverUrl: nil,
            pluginId: "source", mediaKind: .manga, chapterKey: "chapter-2",
            chapterTitle: nil, scanlator: "Group", scanlatorID: "group-id", readAt: readAt
        )
        try dbQueue.write { try record.insert($0) }
        let reread = try dbQueue.read { try ReadingHistoryRecord.fetchOne($0, key: "new") }
        XCTAssertEqual(reread, record)
        XCTAssertEqual(try JSONDecoder().decode(
            ReadingHistoryRecord.self,
            from: JSONEncoder().encode(record)
        ), record)

        let legacyJSON = try JSONSerialization.data(withJSONObject: [
            "id": "legacy-json", "mediaKey": "media", "title": "Title",
            "pluginId": "source", "mediaKind": "manga", "chapterKey": "chapter",
            "readAt": readAt.timeIntervalSinceReferenceDate
        ])
        XCTAssertNil(try JSONDecoder().decode(ReadingHistoryRecord.self, from: legacyJSON).scanlatorID)
    }

    @MainActor
    func testRecordedGroupReturnsExactSeriesAndChapterIdentityOnly() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let settings = AppSettingsStore(dbPool: database.dbPool)
        try await settings.reload()
        let library = LibraryManager(dbPool: database.dbPool)
        let history = HistoryManager(dbPool: database.dbPool, libraryManager: library)
        history.configure(settingsStore: settings)
        let readAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await database.dbPool.write { db in
            try ReadingHistoryRecord(
                id: "renamed", mediaKey: "series", title: "Title", coverUrl: nil,
                pluginId: "source", mediaKind: .manga, chapterKey: "chapter-1",
                chapterTitle: nil, scanlator: "Old name", scanlatorID: "g1", readAt: readAt
            ).insert(db)
            try ReadingHistoryRecord(
                id: "legacy", mediaKey: "series", title: "Title", coverUrl: nil,
                pluginId: "source", mediaKind: .manga, chapterKey: "chapter-2",
                chapterTitle: nil, scanlator: "Legacy name", readAt: readAt
            ).insert(db)
        }
        let series = MediaIdentity(pluginId: "source", canonicalMediaId: "series", mediaKind: .manga)

        // The exact recorded ID survives a later display-name change; the lookup never reads names.
        let renamed = try await history.recordedGroup(media: series, chapterKey: "chapter-1")
        XCTAssertEqual(renamed?.id, "g1")
        XCTAssertEqual(renamed?.name, "Old name")

        // Legacy rows have no identity and must not be matched by name.
        let legacy = try await history.recordedGroup(media: series, chapterKey: "chapter-2")
        XCTAssertNil(legacy?.id)
        XCTAssertEqual(legacy?.name, "Legacy name")

        // Other chapters and other series never match.
        let missingChapter = try await history.recordedGroup(media: series, chapterKey: "chapter-3")
        XCTAssertNil(missingChapter)
        let otherSeries = MediaIdentity(pluginId: "source", canonicalMediaId: "other", mediaKind: .manga)
        let missingSeries = try await history.recordedGroup(media: otherSeries, chapterKey: "chapter-1")
        XCTAssertNil(missingSeries)
    }

    @MainActor
    func testNewVisitsCaptureTheSourceGroupIDAndLookupReturnsIt() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let library = LibraryManager(dbPool: database.dbPool)
        let settings = AppSettingsStore(dbPool: database.dbPool)
        try await settings.reload()
        let history = HistoryManager(dbPool: database.dbPool, libraryManager: library)
        history.configure(settingsStore: settings)

        let task = history.recordManga(
            Manga(key: "series", title: "Series"),
            chapter: HistoryChapter(
                key: "chapter-1", title: "Chapter 1", number: 1, scanlator: "Group A",
                scanlatorID: "source-group-7", format: .pages
            ),
            pluginId: "source"
        )
        await task?.value

        let stored = try await database.dbPool.read { db in
            try ReadingHistoryRecord.filter(ReadingHistoryRecord.Columns.mediaKey == "series").fetchOne(db)
        }
        XCTAssertEqual(stored?.scanlatorID, "source-group-7")
        let media = MediaIdentity(pluginId: "source", canonicalMediaId: "series", mediaKind: .manga)
        let group = try await history.recordedGroup(media: media, chapterKey: "chapter-1")
        XCTAssertEqual(group, ReaderContinuationGroup(id: "source-group-7", name: "Group A"))
    }
}
