import Foundation
import GRDB
import XCTest
@testable import Ito

final class SourceMappingV16MigrationTests: XCTestCase {

    func testV16MigrationPreservesExistingMangaAndAnimeRowsAndPermitsNovel() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()

        // 1. Migrate up to v15
        try migrator.migrate(dbQueue, upTo: "v15")

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedDate = Date(timeIntervalSince1970: 1_700_000_100)
        let verifiedDate = Date(timeIntervalSince1970: 1_700_000_200)
        let samplePayload = Data([10, 20, 30, 40])

        let mangaRecord = SourceMappingRecord(
            canonicalProvider: "anilist",
            canonicalMediaId: "manga-1",
            mediaType: .manga,
            pluginId: "plugin.manga",
            pluginMediaKey: "key-m1",
            decision: .autoConfirm,
            matchMethod: .exactPreferred,
            confidence: 0.99,
            titleSnapshot: "Manga Title",
            createdAt: fixedDate,
            updatedAt: updatedDate,
            coverURLSnapshot: "https://example.com/manga.jpg",
            encodedPayload: samplePayload,
            payloadVersion: 1,
            pluginVersion: "1.2.3",
            lastVerifiedAt: verifiedDate
        )

        let animeRecord = SourceMappingRecord(
            canonicalProvider: "anilist",
            canonicalMediaId: "anime-1",
            mediaType: .anime,
            pluginId: "plugin.anime",
            pluginMediaKey: "key-a1",
            decision: .requiresConfirmation,
            matchMethod: .fuzzy,
            confidence: 0.85,
            titleSnapshot: "Anime Title",
            createdAt: fixedDate,
            updatedAt: updatedDate,
            coverURLSnapshot: "https://example.com/anime.jpg",
            encodedPayload: samplePayload,
            payloadVersion: 1,
            pluginVersion: "2.0.0",
            lastVerifiedAt: verifiedDate
        )

        try dbQueue.write { db in
            try mangaRecord.insert(db)
            try animeRecord.insert(db)
        }

        // Verify v15 rejects novel via CHECK constraint
        try dbQueue.write { db in
            XCTAssertThrowsError(
                try db.execute(sql: """
                    INSERT INTO sourceMapping (
                        canonicalProvider, canonicalMediaId, mediaType, pluginId, pluginMediaKey,
                        decision, matchMethod, confidence, titleSnapshot, createdAt, updatedAt
                    ) VALUES (
                        'anilist', 'novel-fail', 'novel', 'plugin.novel', 'key-n0',
                        'autoConfirm', 'exactPreferred', 1.0, 'Fail Novel', '2024-01-01', '2024-01-01'
                    )
                    """)
            )
        }

        // 2. Migrate to v16
        try migrator.migrate(dbQueue, upTo: "v16")

        // 3. Verify existing rows are preserved with identical fields
        try dbQueue.read { db in
            let fetchedManga = try SourceMappingRecord.fetchOne(db, key: [
                "canonicalProvider": "anilist",
                "canonicalMediaId": "manga-1",
                "mediaType": "manga",
                "pluginId": "plugin.manga",
                "pluginMediaKey": "key-m1"
            ])
            XCTAssertEqual(fetchedManga, mangaRecord)

            let fetchedAnime = try SourceMappingRecord.fetchOne(db, key: [
                "canonicalProvider": "anilist",
                "canonicalMediaId": "anime-1",
                "mediaType": "anime",
                "pluginId": "plugin.anime",
                "pluginMediaKey": "key-a1"
            ])
            XCTAssertEqual(fetchedAnime, animeRecord)
        }

        // 4. Verify v16 permits novel rows
        let novelRecord = SourceMappingRecord(
            canonicalProvider: "anilist",
            canonicalMediaId: "novel-1",
            mediaType: .novel,
            pluginId: "plugin.novel",
            pluginMediaKey: "key-n1",
            decision: .autoConfirm,
            matchMethod: .exactPreferred,
            confidence: 0.98,
            titleSnapshot: "Novel Title",
            createdAt: fixedDate,
            updatedAt: updatedDate,
            coverURLSnapshot: "https://example.com/novel.jpg",
            encodedPayload: samplePayload,
            payloadVersion: 1,
            pluginVersion: "1.0.0",
            lastVerifiedAt: verifiedDate
        )

        try dbQueue.write { db in
            try novelRecord.insert(db)
        }

        try dbQueue.read { db in
            let fetchedNovel = try SourceMappingRecord.fetchOne(db, key: [
                "canonicalProvider": "anilist",
                "canonicalMediaId": "novel-1",
                "mediaType": "novel",
                "pluginId": "plugin.novel",
                "pluginMediaKey": "key-n1"
            ])
            XCTAssertEqual(fetchedNovel, novelRecord)
        }

        // 5. Verify invalid mediaType is still rejected
        try dbQueue.write { db in
            XCTAssertThrowsError(
                try db.execute(sql: """
                    INSERT INTO sourceMapping (
                        canonicalProvider, canonicalMediaId, mediaType, pluginId, pluginMediaKey,
                        decision, matchMethod, confidence, titleSnapshot, createdAt, updatedAt
                    ) VALUES (
                        'anilist', 'invalid-1', 'audiobook', 'plugin.audio', 'key-aud1',
                        'autoConfirm', 'exactPreferred', 1.0, 'Invalid', '2024-01-01', '2024-01-01'
                    )
                    """)
            )
        }

        // 6. Verify composite primary key uniqueness
        try dbQueue.write { db in
            XCTAssertThrowsError(
                try novelRecord.insert(db)
            )
        }

        // 7. Verify indexes exist on the new table
        try dbQueue.read { db in
            let indexes = try db.indexes(on: "sourceMapping")
            let indexNames = Set(indexes.map(\.name))
            XCTAssertTrue(indexNames.contains("idx_sourceMapping_canonical"))
            XCTAssertTrue(indexNames.contains("idx_sourceMapping_plugin"))
        }
    }
}
