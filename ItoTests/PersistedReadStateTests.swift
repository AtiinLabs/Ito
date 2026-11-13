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

    /// The manga payload with each `Float` number widened to a `Double` literal, as an older Foundation wrote it.
    /// Decoded as `PersistedLibraryPayloadTests` decodes it: the model keeps the stored widened value.
    private static func widenedChapters() async throws -> [Chapter] {
        let item = Ito.LibraryItem(
            id: "manga-abi2", title: "Tower of Dusk", coverUrl: nil, pluginId: PersistedLibraryFixture.pluginId,
            isAnime: false, pluginType: .manga,
            rawPayload: try PersistedDataFixtures.data("persisted-library-manga-widened-literals.json"),
            anilistId: nil
        )
        guard case .manga(let manga) = try await JSONDeferredPluginPayloadDecoder().decode(item) else {
            throw PersistedFixtureError.missing("widened manga payload")
        }
        return manga.chapters ?? []
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
            let number = try Self.chapter(key, in: chapters).chapterNumber
            #expect(number != nil)
            // Matched by number alone: the chapter key is one this series never stored.
            #expect(progress.isRead(media: Self.media, chapterId: "another-edition-of-\(key)", chapterNum: number), "\(key)")
            // And by the key it was marked with.
            #expect(progress.isRead(media: Self.media, chapterId: key, chapterNum: nil))
        }
        // Numbers that were never marked stay unread.
        #expect(!progress.isRead(media: Self.media, chapterId: "unread", chapterNum: try Self.chapter("ch-002", in: chapters).chapterNumber))
        #expect(!progress.isRead(media: Self.media, chapterId: "unread", chapterNum: 1.2))
        #expect(!progress.isRead(media: Self.media, chapterId: "unread", chapterNum: 10.4))
    }

    @Test func markingReadUpToAStoredDecimalAddsNoSecondRowForIt() async throws {
        let (database, chapters) = try await Self.restored()
        defer { database.cleanup() }
        let progress = ReadProgressManager(dbPool: database.dbPool)
        try await progress.reload()
        let stored = try await Self.storedNumbers(database)
        let one = try #require(try Self.chapter("ch-004-decimal", in: chapters).chapterNumber)
        let ten = try #require(try Self.chapter("ch-005-decimal", in: chapters).chapterNumber)

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

    @Test func aNewModelChapterWithTheSameDecimalReusesTheStoredMarkAndAddsNoSecondRow() async throws {
        let (database, _) = try await Self.restored()
        defer { database.cleanup() }
        let stored = try Self.chapter("ch-004-decimal", in: try await Self.widenedChapters())
        // The exact Double a current model holds, where the stored chapter holds the widened Float.
        let fresh = Chapter(key: "ch-004-decimal", chapter: 1.1)
        #expect(stored.chapter == Double(Float(1.1)), "The widened legacy chapter must hold the widened Float")
        #expect(stored.chapter != fresh.chapter, "The two Doubles must differ, or the test proves nothing")
        let number = try #require(fresh.chapterNumber)
        #expect(number == stored.chapterNumber)
        let progress = ReadProgressManager(dbPool: database.dbPool)
        try await progress.reload()
        let before = try await Self.storedNumbers(database)

        // markAsRead needs a PluginCompletionContext, which this suite does not build, so the write goes through
        // markReadUpTo: the same path the existing parity test uses.
        try await progress.markReadUpTo(media: Self.media, maxChapterNum: number, availableChapterNumbers: [number])

        let after = try await Self.storedNumbers(database)
        #expect(Set(before).isSubset(of: Set(after)))
        #expect(after.filter { abs($0 - 1.1) < 0.01 } == [Double(Float(1.1))], "Both Doubles must share one stored row")
        try await progress.reload()
        #expect(progress.isRead(media: Self.media, chapterId: "unlisted", chapterNum: fresh.chapterNumber))
    }

    @Test func theExactAndWidenedDecimalsCountAsOneChapterAsUnderTheFloatModel() async throws {
        let stored = try Self.chapter("ch-004-decimal", in: try await Self.widenedChapters())
        let fresh = Chapter(key: "exact", chapter: 1.1)
        #expect(stored.chapter != fresh.chapter, "The two Doubles must differ, or the test proves nothing")

        #expect([fresh, stored].distinctChapterCount == 1)
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
        let settings = AppSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter())
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
            chapter: HistoryChapter(decimal, format: .pages),
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
