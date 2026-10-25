import CryptoKit
import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

@Suite struct AppDatabaseV15MigrationTests {
    private let testEpoch = "0123456789abcdef0123456789abcdef"

    @Test func v14FixtureMangaAnimeNovelStateMigrateCorrectlyWithAllColumns() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v14")

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        try dbQueue.write { db in
            // 1. Authoritative library items for manga, anime, and novel
            try db.execute(
                sql: """
                    INSERT INTO libraryItem (id, title, coverUrl, pluginId, isAnime, pluginType, rawPayload, anilistId)
                    VALUES
                        ('source.manga_m1', 'Manga Title', 'https://example.com/m.jpg', 'source.manga', 0, 'manga', X'00', 101),
                        ('source.anime_a1', 'Anime Title', 'https://example.com/a.jpg', 'source.anime', 1, 'anime', X'00', 102),
                        ('source.novel_n1', 'Novel Title', 'https://example.com/n.jpg', 'source.novel', 0, 'novel', X'00', 103)
                    """
            )

            // 2. Authoritative sourceMapping evidence for an unsaved anime item
            try db.execute(
                sql: """
                    INSERT INTO sourceMapping (
                        canonicalProvider, canonicalMediaId, mediaType, pluginId, pluginMediaKey,
                        decision, matchMethod, confidence, titleSnapshot, createdAt, updatedAt
                    ) VALUES (
                        'anilist', '900', 'anime', 'source.mapping', 'map-anime-1',
                        'autoConfirm', 'exact', 1.0, 'Mapped Anime', ?, ?
                    )
                    """,
                arguments: [fixedDate, fixedDate]
            )

            // 3. Authoritative pluginCompletionOutbox evidence for an unsaved novel item
            try db.execute(
                sql: """
                    INSERT INTO pluginCompletionOutbox (
                        pluginId, canonicalMediaId, mediaKey, unitKey, kind, originatingEpoch,
                        revision, status, createdAt, nextAttemptAt
                    ) VALUES (
                        'source.outbox', 'box-novel-1', 'box-novel-1', 'unit-1', 'novel', ?,
                        1, 'pending', ?, ?
                    )
                    """,
                arguments: [testEpoch, fixedDate, fixedDate]
            )

            // 4. v14 state rows in readProgressKey
            try db.execute(
                sql: """
                    INSERT INTO readProgressKey (pluginId, canonicalMediaId, chapterKey, markedAt, provenance)
                    VALUES
                        ('source.manga', 'm1', 'ch-1', ?, 'runtime'),
                        ('source.anime', 'a1', 'ep-1', ?, 'legacyUnknownTime'),
                        ('source.novel', 'n1', 'vol-1', ?, 'runtime'),
                        ('source.outbox', 'box-novel-1', 'ch-1', ?, 'runtime')
                    """,
                arguments: [fixedDate, fixedDate, fixedDate, fixedDate]
            )

            // 5. v14 state rows in readProgressNumber
            try db.execute(
                sql: """
                    INSERT INTO readProgressNumber (pluginId, canonicalMediaId, chapterNumber, markedAt, provenance)
                    VALUES
                        ('source.manga', 'm1', 1.5, ?, 'runtime'),
                        ('source.anime', 'a1', 12.0, ?, 'legacyUnknownTime'),
                        ('source.novel', 'n1', 3.0, ?, 'runtime')
                    """,
                arguments: [fixedDate, fixedDate, fixedDate]
            )

            // 6. v14 state rows in mediaReadProgress with all columns including v10/v11 additions
            try db.execute(
                sql: """
                    INSERT INTO mediaReadProgress (
                        pluginId, canonicalMediaId, lastReadChapterKey, updatedAt, provenance,
                        lastReadPosition, readerViewer
                    ) VALUES
                        ('source.manga', 'm1', 'ch-1', ?, 'runtime', 15.0, 2),
                        ('source.anime', 'a1', 'ep-1', ?, 'legacyUnknownTime', 1420.5, NULL),
                        ('source.novel', 'n1', 'vol-1', ?, 'runtime', 5420.0, NULL)
                    """,
                arguments: [fixedDate, fixedDate, fixedDate]
            )

            // 7. v14 state rows in trackerLink
            try db.execute(
                sql: """
                    INSERT INTO trackerLink (pluginId, canonicalMediaId, providerId, remoteMediaId, updatedAt, provenance)
                    VALUES
                        ('source.manga', 'm1', 'anilist', '10001', ?, 'runtime'),
                        ('source.anime', 'a1', 'mal', '20002', ?, 'legacyUnknownTime'),
                        ('source.novel', 'n1', 'anilist', '30003', ?, 'runtime'),
                        ('source.mapping', 'map-anime-1', 'anilist', '900', ?, 'runtime')
                    """,
                arguments: [fixedDate, fixedDate, fixedDate, fixedDate]
            )

            // 8. v14 state rows in updateBadge
            try db.execute(
                sql: """
                    INSERT INTO updateBadge (pluginId, canonicalMediaId, count, updatedAt, provenance)
                    VALUES
                        ('source.manga', 'm1', 4, ?, 'runtime'),
                        ('source.anime', 'a1', 1, ?, 'legacyUnknownTime'),
                        ('source.novel', 'n1', 0, ?, 'runtime')
                    """,
                arguments: [fixedDate, fixedDate, fixedDate]
            )

            // 9. v14 state rows in readingHistory
            try db.execute(
                sql: """
                    INSERT INTO readingHistory (
                        id, libraryItemId, mediaKey, title, coverUrl, pluginId,
                        chapterKey, chapterTitle, readAt
                    ) VALUES
                        ('hist-manga', 'source.manga_m1', 'm1', 'Manga Title', 'https://example.com/m.jpg', 'source.manga', 'ch-1', 'Chapter 1', ?),
                        ('hist-anime', 'source.anime_a1', 'a1', 'Anime Title', 'https://example.com/a.jpg', 'source.anime', 'ep-1', 'Episode 1', ?),
                        ('hist-novel', 'source.novel_n1', 'n1', 'Novel Title', 'https://example.com/n.jpg', 'source.novel', 'vol-1', 'Volume 1', ?),
                        ('hist-unsaved-mapping', NULL, 'map-anime-1', 'Mapped Anime', NULL, 'source.mapping', 'ep-2', 'Episode 2', ?)
                    """,
                arguments: [fixedDate, fixedDate, fixedDate, fixedDate]
            )
        }

        // Run migration v15
        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            // Verify readProgressKey
            let keyRecords = try ReadProgressKeyRecord.fetchAll(db).sorted { $0.pluginId < $1.pluginId }
            #expect(keyRecords.count == 4)

            let mangaKey = try #require(keyRecords.first { $0.pluginId == "source.manga" })
            #expect(mangaKey.canonicalMediaId == "m1")
            #expect(mangaKey.mediaKind == .manga)
            #expect(mangaKey.chapterKey == "ch-1")
            #expect(mangaKey.provenance == .runtime)

            let animeKey = try #require(keyRecords.first { $0.pluginId == "source.anime" })
            #expect(animeKey.canonicalMediaId == "a1")
            #expect(animeKey.mediaKind == .anime)
            #expect(animeKey.chapterKey == "ep-1")
            #expect(animeKey.provenance == .legacyUnknownTime)

            let novelKey = try #require(keyRecords.first { $0.pluginId == "source.novel" })
            #expect(novelKey.canonicalMediaId == "n1")
            #expect(novelKey.mediaKind == .novel)
            #expect(novelKey.chapterKey == "vol-1")
            #expect(novelKey.provenance == .runtime)

            let outboxNovelKey = try #require(keyRecords.first { $0.pluginId == "source.outbox" })
            #expect(outboxNovelKey.canonicalMediaId == "box-novel-1")
            #expect(outboxNovelKey.mediaKind == .novel)
            #expect(outboxNovelKey.chapterKey == "ch-1")
            #expect(outboxNovelKey.provenance == .runtime)

            // Verify readProgressNumber
            let numberRecords = try ReadProgressNumberRecord.fetchAll(db)
            #expect(numberRecords.count == 3)
            let mangaNum = try #require(numberRecords.first { $0.pluginId == "source.manga" })
            #expect(mangaNum.mediaKind == .manga)
            #expect(mangaNum.chapterNumber == 1.5)
            let animeNum = try #require(numberRecords.first { $0.pluginId == "source.anime" })
            #expect(animeNum.mediaKind == .anime)
            #expect(animeNum.chapterNumber == 12.0)
            let novelNum = try #require(numberRecords.first { $0.pluginId == "source.novel" })
            #expect(novelNum.mediaKind == .novel)
            #expect(novelNum.chapterNumber == 3.0)

            // Verify mediaReadProgress
            let progressRecords = try MediaReadProgressRecord.fetchAll(db)
            #expect(progressRecords.count == 3)
            let mangaProg = try #require(progressRecords.first { $0.pluginId == "source.manga" })
            #expect(mangaProg.mediaKind == .manga)
            #expect(mangaProg.lastReadChapterKey == "ch-1")
            #expect(mangaProg.lastReadPosition == 15.0)
            #expect(mangaProg.readerViewer == 2)

            let animeProg = try #require(progressRecords.first { $0.pluginId == "source.anime" })
            #expect(animeProg.mediaKind == .anime)
            #expect(animeProg.lastReadPosition == 1420.5)
            #expect(animeProg.readerViewer == nil)

            let novelProg = try #require(progressRecords.first { $0.pluginId == "source.novel" })
            #expect(novelProg.mediaKind == .novel)
            #expect(novelProg.lastReadPosition == 5420.0)

            // Verify trackerLink
            let trackerRecords = try TrackerLinkRecord.fetchAll(db)
            #expect(trackerRecords.count == 4)
            let mappingTracker = try #require(trackerRecords.first { $0.pluginId == "source.mapping" })
            #expect(mappingTracker.mediaKind == .anime)
            #expect(mappingTracker.remoteMediaId == "900")

            // Verify updateBadge
            let badgeRecords = try UpdateBadgeRecord.fetchAll(db)
            #expect(badgeRecords.count == 3)
            let novelBadge = try #require(badgeRecords.first { $0.pluginId == "source.novel" })
            #expect(novelBadge.mediaKind == .novel)
            #expect(novelBadge.count == 0)

            // Verify readingHistory
            let historyRecords = try ReadingHistoryRecord.fetchAll(db)
            #expect(historyRecords.count == 4)
            let histManga = try #require(historyRecords.first { $0.id == "hist-manga" })
            #expect(histManga.mediaKind == .manga)
            #expect(histManga.title == "Manga Title")
            #expect(histManga.chapterKey == "ch-1")

            let histAnime = try #require(historyRecords.first { $0.id == "hist-anime" })
            #expect(histAnime.mediaKind == .anime)

            let histNovel = try #require(historyRecords.first { $0.id == "hist-novel" })
            #expect(histNovel.mediaKind == .novel)

            let histUnsaved = try #require(historyRecords.first { $0.id == "hist-unsaved-mapping" })
            #expect(histUnsaved.mediaKind == .anime)
            #expect(histUnsaved.libraryItemId == nil)

            // Verify no unexpected archives occurred
            let archives = try LegacyStateArchiveRecord.fetchAll(db)
            #expect(archives.isEmpty)
        }
    }

    @Test func unknownAndConflictingOrphanStateLosslesslyArchived() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v14")

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        try dbQueue.write { db in
            // Valid evidence item
            try db.execute(
                sql: """
                    INSERT INTO libraryItem (id, title, coverUrl, pluginId, isAnime, pluginType, rawPayload)
                    VALUES ('valid.plugin_v1', 'Valid Series', NULL, 'valid.plugin', 0, 'manga', X'00')
                    """
            )
            // Valid row that should migrate
            try db.execute(
                sql: """
                    INSERT INTO readProgressKey (pluginId, canonicalMediaId, chapterKey, markedAt, provenance)
                    VALUES ('valid.plugin', 'v1', 'ch-1', ?, 'runtime')
                    """,
                arguments: [fixedDate]
            )

            // 1. Completely unknown orphan rows (no evidence anywhere)
            try db.execute(
                sql: """
                    INSERT INTO readProgressKey (pluginId, canonicalMediaId, chapterKey, markedAt, provenance)
                    VALUES ('unknown.plugin', 'unk-1', 'ch-orphan', ?, 'runtime')
                    """,
                arguments: [fixedDate]
            )
            try db.execute(
                sql: """
                    INSERT INTO mediaReadProgress (pluginId, canonicalMediaId, lastReadChapterKey, updatedAt, provenance, lastReadPosition, readerViewer)
                    VALUES ('unknown.plugin', 'unk-1', 'ch-orphan', ?, 'runtime', 42.0, 1)
                    """,
                arguments: [fixedDate]
            )
            try db.execute(
                sql: """
                    INSERT INTO trackerLink (pluginId, canonicalMediaId, providerId, remoteMediaId, updatedAt, provenance)
                    VALUES ('unknown.plugin', 'unk-1', 'mal', '777', ?, 'runtime')
                    """,
                arguments: [fixedDate]
            )
            try db.execute(
                sql: """
                    INSERT INTO updateBadge (pluginId, canonicalMediaId, count, updatedAt, provenance)
                    VALUES ('unknown.plugin', 'unk-1', 9, ?, 'runtime')
                    """,
                arguments: [fixedDate]
            )
            try db.execute(
                sql: """
                    INSERT INTO readingHistory (id, libraryItemId, mediaKey, title, coverUrl, pluginId, chapterKey, chapterTitle, readAt)
                    VALUES ('hist-orphan', NULL, 'unk-history', 'Orphan History', NULL, 'unknown.plugin', 'ch-orphan', NULL, ?)
                    """,
                arguments: [fixedDate]
            )

            // 2. Conflicting evidence: libraryItem says manga, but outbox says novel
            try db.execute(
                sql: """
                    INSERT INTO libraryItem (id, title, coverUrl, pluginId, isAnime, pluginType, rawPayload)
                    VALUES ('conflict.plugin_c1', 'Conflict Title', NULL, 'conflict.plugin', 0, 'manga', X'00')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO pluginCompletionOutbox (
                        pluginId, canonicalMediaId, mediaKey, unitKey, kind, originatingEpoch,
                        revision, status, createdAt, nextAttemptAt
                    ) VALUES (
                        'conflict.plugin', 'c1', 'c1', 'unit-1', 'novel', ?,
                        1, 'pending', ?, ?
                    )
                    """,
                arguments: [testEpoch, fixedDate, fixedDate]
            )
            // Conflicting row in readProgressNumber
            try db.execute(
                sql: """
                    INSERT INTO readProgressNumber (pluginId, canonicalMediaId, chapterNumber, markedAt, provenance)
                    VALUES ('conflict.plugin', 'c1', 1.0, ?, 'runtime')
                    """,
                arguments: [fixedDate]
            )
        }

        // Migrate to v15
        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            // Valid row survived in readProgressKey
            let validKeys = try ReadProgressKeyRecord.fetchAll(db)
            #expect(validKeys.count == 1)
            #expect(validKeys[0].pluginId == "valid.plugin")
            #expect(validKeys[0].mediaKind == .manga)

            // None of the unknown rows exist in active tables
            #expect(try Row.fetchOne(db, sql: "SELECT * FROM readProgressKey WHERE pluginId = 'unknown.plugin'") == nil)
            #expect(try Row.fetchOne(db, sql: "SELECT * FROM mediaReadProgress WHERE pluginId = 'unknown.plugin'") == nil)
            #expect(try Row.fetchOne(db, sql: "SELECT * FROM trackerLink WHERE pluginId = 'unknown.plugin'") == nil)
            #expect(try Row.fetchOne(db, sql: "SELECT * FROM updateBadge WHERE pluginId = 'unknown.plugin'") == nil)
            #expect(try Row.fetchOne(db, sql: "SELECT * FROM readingHistory WHERE id = 'hist-orphan'") == nil)

            // Conflicting row was not stored with guessed kind
            #expect(try Row.fetchOne(db, sql: "SELECT * FROM readProgressNumber WHERE pluginId = 'conflict.plugin'") == nil)

            // Verify they were losslessly archived in legacyStateArchive
            let archives = try LegacyStateArchiveRecord.fetchAll(db).sorted { $0.sourceDomain < $1.sourceDomain }
            #expect(archives.count == 6)

            for archive in archives {
                #expect(archive.contentClass == .appNonSecret)
                #expect(archive.reason == "kindUnknown")
                #expect(archive.valueType == "databaseRow")
                #expect(!archive.fingerprint.isEmpty)
                #expect(!archive.sourceDomain.isEmpty)
                #expect(!archive.sourceKey.isEmpty)

                // Verify fields are losslessly decodable
                let fields = try LegacyMediaKindResolver.decodeFields(from: archive)
                #expect(!fields.isEmpty)
            }

            // Verify specific archived row fields
            let progressArchive = try #require(archives.first { $0.sourceDomain == "mediaReadProgress" })
            let progressFields = try LegacyMediaKindResolver.decodeFields(from: progressArchive)
            #expect(progressFields["pluginId"] == .text("unknown.plugin"))
            #expect(progressFields["canonicalMediaId"] == .text("unk-1"))
            #expect(progressFields["lastReadPosition"] == .float(42.0))
            #expect(progressFields["readerViewer"] == .integer(1))

            let historyArchive = try #require(archives.first { $0.sourceDomain == "readingHistory" })
            let historyFields = try LegacyMediaKindResolver.decodeFields(from: historyArchive)
            #expect(historyFields["id"] == .text("hist-orphan"))
            #expect(historyFields["title"] == .text("Orphan History"))
            #expect(historyFields["coverUrl"] == .null)

            let conflictArchive = try #require(archives.first { $0.sourceDomain == "readProgressNumber" })
            let conflictFields = try LegacyMediaKindResolver.decodeFields(from: conflictArchive)
            #expect(conflictFields["pluginId"] == .text("conflict.plugin"))
            #expect(conflictFields["canonicalMediaId"] == .text("c1"))
            #expect(conflictFields["chapterNumber"] == .float(1.0))
        }
    }

    @Test func stateWithoutMediaEvidenceTakesTheOneKindItsPluginDeclaresInCachedRepositoryIndexes() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v14")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        func index(_ packages: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["repo_name": "Repo", "packages": packages])
        }
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO repository (url, indexPayload) VALUES (?, ?), (?, ?)",
                arguments: [
                    "https://one.example", try index([
                        ["id": "single.plugin", "type": "novel"],
                        ["id": "multi.plugin", "type": "manga", "kinds": ["manga", "novel"]],
                        ["id": "split.plugin", "type": "manga"],
                        ["id": "future.plugin", "type": "comic"],
                        ["id": "retyped.plugin", "type": "novel"]
                    ]),
                    "https://two.example", try index([
                        ["id": "single.plugin", "type": "novel"],
                        ["id": "split.plugin", "type": "anime"]
                    ])
                ]
            )
            // A saved series contradicts retyped.plugin's current declaration.
            try db.execute(
                sql: """
                    INSERT INTO libraryItem (id, title, pluginId, isAnime, pluginType, rawPayload)
                    VALUES ('retyped.plugin_saved', 'Saved', 'retyped.plugin', 0, 'manga', X'00')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO readProgressKey (pluginId, canonicalMediaId, chapterKey, provenance)
                    VALUES ('single.plugin', 's1', 'ch-1', 'runtime'), ('multi.plugin', 'm1', 'ch-1', 'runtime'),
                           ('split.plugin', 'p1', 'ch-1', 'runtime'), ('future.plugin', 'f1', 'ch-1', 'runtime'),
                           ('retyped.plugin', 'unsaved', 'ch-1', 'runtime'), ('retyped.plugin', 'saved', 'ch-1', 'runtime')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO readingHistory (id, libraryItemId, mediaKey, title, pluginId, chapterKey, readAt)
                    VALUES ('single-history', NULL, 's1', 'Single', 'single.plugin', 'ch-1', ?),
                           ('multi-history', NULL, 'm1', 'Multi', 'multi.plugin', 'ch-1', ?)
                    """,
                arguments: [fixedDate, fixedDate]
            )
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let keys = try ReadProgressKeyRecord.order(Column("pluginId")).fetchAll(db)
            #expect(keys.map { "\($0.pluginId) \($0.canonicalMediaId) \($0.mediaKind.rawValue)" } == [
                "retyped.plugin saved manga",
                "single.plugin s1 novel"
            ])
            let history = try ReadingHistoryRecord.fetchAll(db)
            #expect(history.map(\.id) == ["single-history"])
            #expect(history.map(\.mediaKind) == [.novel])

            let archived = try LegacyStateArchiveRecord.fetchAll(db)
            #expect(Set(archived.map { "\($0.sourceDomain) \($0.sourceKey)" }) == [
                "readProgressKey multi.plugin/m1/ch-1",
                "readProgressKey split.plugin/p1/ch-1",
                "readProgressKey future.plugin/f1/ch-1",
                "readProgressKey retyped.plugin/unsaved/ch-1",
                "readingHistory multi-history"
            ])
            #expect(archived.allSatisfy { $0.reason == "kindUnknown" })
        }
    }

    @Test func sameKeyDifferentKindRowCoexistenceValidAndPKsIsolateKind() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbQueue) // Migrates directly to v15

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        try dbQueue.write { db in
            // Coexistence in mediaReadProgress: manga, novel, and anime with same pluginId and canonicalMediaId
            let mangaProgress = MediaReadProgressRecord(
                pluginId: "shared.source",
                canonicalMediaId: "42",
                mediaKind: .manga,
                lastReadChapterKey: "ch-10",
                updatedAt: fixedDate,
                provenance: .runtime,
                lastReadPosition: 12.0,
                readerViewer: 1
            )
            let novelProgress = MediaReadProgressRecord(
                pluginId: "shared.source",
                canonicalMediaId: "42",
                mediaKind: .novel,
                lastReadChapterKey: "vol-2",
                updatedAt: fixedDate,
                provenance: .runtime,
                lastReadPosition: 8400.0,
                readerViewer: nil
            )
            let animeProgress = MediaReadProgressRecord(
                pluginId: "shared.source",
                canonicalMediaId: "42",
                mediaKind: .anime,
                lastReadChapterKey: "ep-4",
                updatedAt: fixedDate,
                provenance: .runtime,
                lastReadPosition: 1350.0,
                readerViewer: nil
            )

            try mangaProgress.insert(db)
            try novelProgress.insert(db)
            try animeProgress.insert(db)

            // Coexistence in readProgressKey with identical chapterKey across kinds
            try ReadProgressKeyRecord(
                pluginId: "shared.source",
                canonicalMediaId: "42",
                mediaKind: .manga,
                chapterKey: "1",
                markedAt: fixedDate,
                provenance: .runtime
            ).insert(db)

            try ReadProgressKeyRecord(
                pluginId: "shared.source",
                canonicalMediaId: "42",
                mediaKind: .novel,
                chapterKey: "1",
                markedAt: fixedDate,
                provenance: .runtime
            ).insert(db)

            // Coexistence in readProgressNumber with identical chapterNumber
            try ReadProgressNumberRecord(
                pluginId: "shared.source",
                canonicalMediaId: "42",
                mediaKind: .manga,
                chapterNumber: 1.0,
                markedAt: fixedDate,
                provenance: .runtime
            ).insert(db)

            try ReadProgressNumberRecord(
                pluginId: "shared.source",
                canonicalMediaId: "42",
                mediaKind: .novel,
                chapterNumber: 1.0,
                markedAt: fixedDate,
                provenance: .runtime
            ).insert(db)

            // Coexistence in trackerLink
            try TrackerLinkRecord(
                pluginId: "shared.source",
                canonicalMediaId: "42",
                mediaKind: .manga,
                providerId: "anilist",
                remoteMediaId: "100",
                updatedAt: fixedDate,
                provenance: .runtime
            ).insert(db)

            try TrackerLinkRecord(
                pluginId: "shared.source",
                canonicalMediaId: "42",
                mediaKind: .novel,
                providerId: "anilist",
                remoteMediaId: "200",
                updatedAt: fixedDate,
                provenance: .runtime
            ).insert(db)

            // Coexistence in updateBadge
            try UpdateBadgeRecord(
                pluginId: "shared.source",
                canonicalMediaId: "42",
                mediaKind: .manga,
                count: 5,
                updatedAt: fixedDate,
                provenance: .runtime
            ).insert(db)

            try UpdateBadgeRecord(
                pluginId: "shared.source",
                canonicalMediaId: "42",
                mediaKind: .novel,
                count: 12,
                updatedAt: fixedDate,
                provenance: .runtime
            ).insert(db)
        }

        try dbQueue.read { db in
            let progresses = try MediaReadProgressRecord.fetchAll(db)
            #expect(progresses.count == 3)
            #expect(Set(progresses.map(\.mediaKind)) == [.manga, .novel, .anime])

            let keys = try ReadProgressKeyRecord.fetchAll(db)
            #expect(keys.count == 2)
            #expect(Set(keys.map(\.mediaKind)) == [.manga, .novel])

            let numbers = try ReadProgressNumberRecord.fetchAll(db)
            #expect(numbers.count == 2)
            #expect(Set(numbers.map(\.mediaKind)) == [.manga, .novel])

            let trackers = try TrackerLinkRecord.fetchAll(db)
            #expect(trackers.count == 2)
            let mangaTracker = try #require(trackers.first { $0.mediaKind == .manga })
            let novelTracker = try #require(trackers.first { $0.mediaKind == .novel })
            #expect(mangaTracker.remoteMediaId == "100")
            #expect(novelTracker.remoteMediaId == "200")

            let badges = try UpdateBadgeRecord.fetchAll(db)
            #expect(badges.count == 2)
            let mangaBadge = try #require(badges.first { $0.mediaKind == .manga })
            let novelBadge = try #require(badges.first { $0.mediaKind == .novel })
            #expect(mangaBadge.count == 5)
            #expect(novelBadge.count == 12)
        }

        // Test that PKs isolate mutations per kind
        try dbQueue.write { db in
            // Deleting manga progress does not affect novel or anime
            _ = try MediaReadProgressRecord
                .filter(Column("pluginId") == "shared.source")
                .filter(Column("canonicalMediaId") == "42")
                .filter(Column("mediaKind") == MediaKind.manga.rawValue)
                .deleteAll(db)
        }

        try dbQueue.read { db in
            let progresses = try MediaReadProgressRecord.fetchAll(db)
            #expect(progresses.count == 2)
            #expect(Set(progresses.map(\.mediaKind)) == [.novel, .anime])
        }
    }

    @Test func foreignKeysAndTriggersPreservedAfterV15() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            // Verify foreign key integrity
            let fkCheck = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            #expect(fkCheck.isEmpty)

            // Verify prior triggers exist
            let triggers = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'"
            )
            #expect(triggers.contains("legacyDefaultsInbox_immutablePayload"))
            #expect(triggers.contains("legacyStateMigration_monotonicStatus"))
            #expect(triggers.contains("pluginSetting_clearMigrationAuthority"))
            #expect(triggers.contains("pluginSetting_after_insert_rotate_epoch"))
            #expect(triggers.contains("pluginSetting_after_delete_rotate_epoch"))
            #expect(triggers.contains("pluginSetting_after_update_rotate_epoch"))
            #expect(triggers.contains("pluginCompletionScope_after_insert_pause"))
            #expect(triggers.contains("pluginCompletionScope_after_update_pause"))
            #expect(triggers.contains("pluginCompletionScope_after_delete_pause"))
            #expect(triggers.contains("pluginSetting_completion_after_insert"))
            #expect(triggers.contains("pluginSetting_completion_after_delete"))
            #expect(triggers.contains("pluginSetting_completion_after_update"))
        }

        // Verify trigger behavior is intact: updating pluginSetting rotates pluginImageCacheEpoch
        try dbQueue.write { db in
            let initialEpoch = try String.fetchOne(db, sql: "SELECT epoch FROM pluginImageCacheEpoch WHERE id = 1")
            #expect(initialEpoch != nil)

            try db.execute(
                sql: "INSERT INTO pluginSetting (pluginId, key, value, updatedAt) VALUES ('test.plugin', 'k1', X'AA', ?)",
                arguments: [Date()]
            )
            let rotatedEpoch = try String.fetchOne(db, sql: "SELECT epoch FROM pluginImageCacheEpoch WHERE id = 1")
            #expect(rotatedEpoch != nil)
            #expect(rotatedEpoch != initialEpoch)
        }
    }

    @Test func legacyMediaKindResolverDirectEvidenceAndHistoryResolution() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v14")

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO libraryItem (id, title, coverUrl, pluginId, isAnime, pluginType, rawPayload)
                    VALUES
                        ('p.manga_10', 'Manga', NULL, 'p.manga', 0, 'manga', X'00'),
                        ('p.anime_20', 'Anime', NULL, 'p.anime', 1, 'anime', X'00'),
                        ('p.novel_30', 'Novel', NULL, 'p.novel', 0, 'novel', X'00')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO sourceMapping (
                        canonicalProvider, canonicalMediaId, mediaType, pluginId, pluginMediaKey,
                        decision, matchMethod, confidence, titleSnapshot, createdAt, updatedAt
                    ) VALUES ('anilist', '40', 'manga', 'p.mapping', 'map-40', 'autoConfirm', 'exact', 1.0, 'Title', ?, ?)
                    """,
                arguments: [fixedDate, fixedDate]
            )
            try db.execute(
                sql: """
                    INSERT INTO pluginCompletionOutbox (
                        pluginId, canonicalMediaId, mediaKey, unitKey, kind, originatingEpoch,
                        revision, status, createdAt, nextAttemptAt
                    ) VALUES ('p.outbox', 'box-50', 'box-50', 'u1', 'novel', ?, 1, 'pending', ?, ?)
                    """,
                arguments: [testEpoch, fixedDate, fixedDate]
            )
        }

        try dbQueue.read { db in
            let resolver = try LegacyMediaKindResolver(db: db)

            // Direct canonical media resolution
            #expect(resolver.resolve(pluginID: "p.manga", canonicalMediaID: "10") == .manga)
            #expect(resolver.resolve(pluginID: "p.manga", canonicalMediaID: "p.manga_10") == .manga)
            #expect(resolver.resolve(pluginID: "p.anime", canonicalMediaID: "20") == .anime)
            #expect(resolver.resolve(pluginID: "p.novel", canonicalMediaID: "30") == .novel)
            #expect(resolver.resolve(pluginID: "p.mapping", canonicalMediaID: "map-40") == .manga)
            #expect(resolver.resolve(pluginID: "p.outbox", canonicalMediaID: "box-50") == .novel)

            // Unknown returns nil
            #expect(resolver.resolve(pluginID: "p.unknown", canonicalMediaID: "999") == nil)

            // History resolution with direct libraryItemId
            let historyRowWithLibraryItem = try Row.fetchOne(
                db,
                sql: "SELECT 'p.manga' AS pluginId, 'p.manga_10' AS libraryItemId, 'different-media-key' AS mediaKey"
            )!
            #expect(resolver.resolveHistory(historyRowWithLibraryItem) == .manga)

            // History resolution with libraryItemId belonging to different plugin falls back to mediaKey
            let historyRowMismatchedPlugin = try Row.fetchOne(
                db,
                sql: "SELECT 'p.other' AS pluginId, 'p.manga_10' AS libraryItemId, 'nonexistent' AS mediaKey"
            )!
            #expect(resolver.resolveHistory(historyRowMismatchedPlugin) == nil)

            // History resolution with nil libraryItemId resolves via mediaKey
            let historyRowNilLibraryItem = try Row.fetchOne(
                db,
                sql: "SELECT 'p.novel' AS pluginId, NULL AS libraryItemId, '30' AS mediaKey"
            )!
            #expect(resolver.resolveHistory(historyRowNilLibraryItem) == .novel)

            // History row with existing mediaKind column directly decodes
            let historyRowExistingKind = try Row.fetchOne(
                db,
                sql: "SELECT 'p.unknown' AS pluginId, NULL AS libraryItemId, 'unk' AS mediaKey, 'anime' AS mediaKind"
            )!
            #expect(resolver.resolveHistory(historyRowExistingKind) == .anime)
        }
    }
}
