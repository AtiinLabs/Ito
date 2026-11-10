import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// Read marks and history keyed by a chapter number, as the app wrote them for chapters whose numbers have no
/// exact `Float` form (`1.1`, `10.3`), restored from the golden backup. `readProgressNumber.chapterNumber` is part
/// of a primary key and holds `Double(Float)`, so a reader that matches numbers at another width, or a writer that
/// stores another width, stops finding the rows it wrote.
@MainActor
struct PersistedReadStateTests {
    private nonisolated static let media = MediaIdentity(
        pluginId: PersistedLibraryFixture.pluginId, canonicalMediaId: "manga-abi2", mediaKind: .manga
    )
    private static let decimalKeys = ["ch-004-decimal", "ch-005-decimal"]

    /// The golden backup restored into an empty database, and the chapters of its manga payload.
    private static func restored() async throws -> (database: TestDatabase, chapters: [Chapter]) {
        let database = try TestDatabase()
        let manager = try PersistedBackupRestoreTests.makeManager(target: database)
        _ = try await manager.restoreBackup(
            from: try PersistedBackupRestoreTests.stageBackup(beside: database), mode: .merge
        )
        guard case .manga(let manga) = try await JSONDeferredPluginPayloadDecoder().decode(
            try PersistedLibraryFixture.mangaABI2.libraryItem()
        ) else {
            throw PersistedFixtureError.missing("manga-abi2 payload")
        }
        return (database, manga.chapters ?? [])
    }

    private static func chapter(_ key: String, in chapters: [Chapter]) throws -> Chapter {
        try #require(chapters.first { $0.key == key })
    }

    private static func storedNumbers(_ database: TestDatabase) async throws -> [Double] {
        try await database.dbPool.read { db in
            try Double.fetchAll(db, sql: """
                SELECT chapterNumber FROM readProgressNumber
                WHERE pluginId = ? AND canonicalMediaId = ? AND mediaKind = 'manga' ORDER BY chapterNumber
                """, arguments: [media.pluginId, media.canonicalMediaId])
        }
    }

    // MARK: - Read marks

    @Test func theStoredReadNumbersAreTheLegacyFloatsWidenedToDouble() async throws {
        let (database, _) = try await Self.restored()
        defer { database.cleanup() }

        // Each stored key is the Float the reader marked, widened: 1.1 is stored as 1.100000023841858.
        #expect(try await Self.storedNumbers(database) == [Double(Float(1.1)), Double(Float(10.3))])
    }

    @Test func aStoredReadMarkStillMatchesTheChapterNumberTheModelHolds() async throws {
        let (database, chapters) = try await Self.restored()
        defer { database.cleanup() }
        let progress = ReadProgressManager(dbPool: database.dbPool)
        try await progress.reload()

        for key in Self.decimalKeys {
            let number = try Self.chapter(key, in: chapters).chapter
            #expect(number != nil)
            // Matched by number alone: the chapter key is one this series never stored.
            #expect(progress.isRead(media: Self.media, chapterId: "another-edition-of-\(key)", chapterNum: number), "\(key)")
            // And by the key it was marked with.
            #expect(progress.isRead(media: Self.media, chapterId: key, chapterNum: nil))
        }
        // Numbers that were never marked stay unread.
        #expect(!progress.isRead(media: Self.media, chapterId: "unread", chapterNum: try Self.chapter("ch-002", in: chapters).chapter))
        #expect(!progress.isRead(media: Self.media, chapterId: "unread", chapterNum: 1.2))
        #expect(!progress.isRead(media: Self.media, chapterId: "unread", chapterNum: 10.4))
    }

    @Test func markingReadUpToAStoredDecimalAddsNoSecondRowForIt() async throws {
        let (database, chapters) = try await Self.restored()
        defer { database.cleanup() }
        let progress = ReadProgressManager(dbPool: database.dbPool)
        try await progress.reload()
        let stored = try await Self.storedNumbers(database)
        let one = try #require(try Self.chapter("ch-004-decimal", in: chapters).chapter)
        let ten = try #require(try Self.chapter("ch-005-decimal", in: chapters).chapter)

        try await progress.markReadUpTo(media: Self.media, maxChapterNum: ten, availableChapterNumbers: [one, ten])

        let after = try await Self.storedNumbers(database)
        // The two stored rows are reused; only the whole numbers 1 through 10 are new.
        #expect(after.count == stored.count + 10)
        #expect(Set(stored).isSubset(of: Set(after)))
        #expect(after.filter { abs($0 - 1.1) < 0.01 }.count == 1)
        #expect(after.filter { abs($0 - 10.3) < 0.01 }.count == 1)
        try await progress.reload()
        for number in [one, ten, 1, 5, 10] {
            #expect(progress.isRead(media: Self.media, chapterId: "unlisted", chapterNum: number), "\(number)")
        }
    }

    // MARK: - History

    @Test func storedHistoryRowsKeepTheirChapterNumberAndVolume() async throws {
        let (database, _) = try await Self.restored()
        defer { database.cleanup() }

        let rows = try await database.dbPool.read { db in
            try ReadingHistoryRecord
                .filter(ReadingHistoryRecord.Columns.mediaKey == "manga-abi2")
                .order(ReadingHistoryRecord.Columns.chapterKey).fetchAll(db)
        }

        try #require(rows.count == 2)
        #expect(rows.map(\.chapterKey) == Self.decimalKeys)
        // As written: the model's Float, widened to the stored Double.
        #expect(rows[0].chapterNumber == Double(Float(1.1)))
        #expect(rows[0].volume == Double(Float(0.1)))
        #expect(legacyFloat(rows[0].chapterNumber) == 1.1)
        #expect(legacyFloat(rows[0].volume) == 0.1)
        #expect(rows[0].chapterTitle == "Decimal")
        #expect(rows[0].scanlator == "Group One")
        #expect(rows[0].format == .pages)
        #expect(rows[1].chapterNumber == Double(Float(10.3)))
        #expect(legacyFloat(rows[1].chapterNumber) == 10.3)
        #expect(rows[1].volume == nil)
        #expect(rows[1].chapterTitle == nil)
    }

    @Test func visitingAStoredChapterAgainWritesTheSameNumberAndKeepsOneRow() async throws {
        let (database, chapters) = try await Self.restored()
        defer { database.cleanup() }
        let library = LibraryManager(dbPool: database.dbPool)
        try await library.reload()
        let settings = AppSettingsStore(dbPool: database.dbPool)
        try await settings.reload()
        let history = HistoryManager(dbPool: database.dbPool, libraryManager: library)
        history.configure(settingsStore: settings)
        try await history.reload()
        let before = try #require(history.history.first { $0.record.chapterKey == "ch-004-decimal" }?.record)
        let decimal = try Self.chapter("ch-004-decimal", in: chapters)
        guard case .manga(let manga) = try await JSONDeferredPluginPayloadDecoder().decode(
            try PersistedLibraryFixture.mangaABI2.libraryItem()
        ) else {
            Issue.record("The manga payload decoded as another kind")
            return
        }

        await history.recordManga(
            manga,
            chapter: HistoryChapter(key: decimal.key, title: decimal.title, number: decimal.chapter,
                                    volume: decimal.volume, scanlator: decimal.scanlator, format: .pages),
            pluginId: PersistedLibraryFixture.pluginId
        )?.value

        let rows = try await database.dbPool.read { db in
            try ReadingHistoryRecord.filter(ReadingHistoryRecord.Columns.mediaKey == "manga-abi2").fetchAll(db)
        }
        #expect(rows.count == 2)
        let after = try #require(rows.first { $0.chapterKey == "ch-004-decimal" })
        #expect(after.id == before.id)
        #expect(after.chapterNumber == before.chapterNumber)
        #expect(after.volume == before.volume)
    }
}
