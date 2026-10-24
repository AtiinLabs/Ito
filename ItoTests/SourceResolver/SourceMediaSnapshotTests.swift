import XCTest
import Foundation
@testable import Ito
import ito_runner

@MainActor
final class SourceMediaSnapshotTests: XCTestCase {

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    override func setUp() {
        super.setUp()
        encoder.outputFormatting = .sortedKeys
    }

    func testMangaRoundTrip() throws {
        let manga = Manga(key: "m1", title: "Test Manga", status: .Ongoing)
        let snapshot = SourceMediaSnapshot(version: 1, payload: .manga(manga))

        // Encode
        let data = try encoder.encode(snapshot)

        // Decode
        let decoded = try decoder.decode(SourceMediaSnapshot.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        if case .manga(let decodedManga) = decoded.payload {
            XCTAssertEqual(decodedManga.key, "m1")
            XCTAssertEqual(decodedManga.title, "Test Manga")
            XCTAssertEqual(decodedManga.status, .Ongoing)
        } else {
            XCTFail("Expected .manga payload")
        }
    }

    func testAnimeRoundTrip() throws {
        let anime = Anime(key: "a1", title: "Test Anime", status: .Completed)
        let snapshot = SourceMediaSnapshot(version: 1, payload: .anime(anime))

        // Encode
        let data = try encoder.encode(snapshot)

        // Decode
        let decoded = try decoder.decode(SourceMediaSnapshot.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        if case .anime(let decodedAnime) = decoded.payload {
            XCTAssertEqual(decodedAnime.key, "a1")
            XCTAssertEqual(decodedAnime.title, "Test Anime")
            XCTAssertEqual(decodedAnime.status, .Completed)
        } else {
            XCTFail("Expected .anime payload")
        }
    }
    func testNovelRoundTrip() throws {
        let novel = Novel(key: "n1", title: "Test Novel", status: .Ongoing)
        let snapshot = SourceMediaSnapshot(version: 1, payload: .novel(novel))

        // Encode
        let data = try encoder.encode(snapshot)

        // Decode
        let decoded = try decoder.decode(SourceMediaSnapshot.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        if case .novel(let decodedNovel) = decoded.payload {
            XCTAssertEqual(decodedNovel.key, "n1")
            XCTAssertEqual(decodedNovel.title, "Test Novel")
            XCTAssertEqual(decodedNovel.status, .Ongoing)
        } else {
            XCTFail("Expected .novel payload")
        }
    }

    func testUnsupportedPayloadVersion() throws {
        // If a new version comes out (e.g., version 999), we should still decode it
        // safely as long as the payload structure hasn't broken the codable contract,
        // or we should handle it at the database layer. For this snapshot test,
        // we just ensure decoding doesn't arbitrarily fail because of the version bump.
        let json = """
        {
            "version": 999,
            "payload": {
                "type": "manga",
                "manga": {
                    "key": "m999",
                    "title": "Future Manga",
                    "status": 0,
                    "contentRating": 0,
                    "nsfw": 0,
                    "viewer": 0
                }
            }
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try decoder.decode(SourceMediaSnapshot.self, from: data)
        XCTAssertEqual(decoded.version, 999)

        if case .manga(let manga) = decoded.payload {
            XCTAssertEqual(manga.key, "m999")
            XCTAssertEqual(manga.title, "Future Manga")
        } else {
            XCTFail("Expected manga payload")
        }
    }

    func testCorruptPayload() throws {
        // Missing the "type" key in the payload object
        let missingTypeJSON = """
        {
            "version": 1,
            "payload": {
                "manga": {
                    "key": "m1",
                    "title": "Test"
                }
            }
        }
        """

        let missingTypeData = missingTypeJSON.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(SourceMediaSnapshot.self, from: missingTypeData)) { error in
            if let decodingError = error as? DecodingError {
                // Should fail trying to decode the "type" key
                if case .keyNotFound(let key, _) = decodingError {
                    XCTAssertEqual(key.stringValue, "type")
                } else {
                    XCTFail("Expected keyNotFound error for 'type', got \(decodingError)")
                }
            } else {
                XCTFail("Expected DecodingError, got \(error)")
            }
        }

        // Invalid type string
        let invalidTypeJSON = """
        {
            "version": 1,
            "payload": {
                "type": "audiobook",
                "audiobook": {
                    "key": "ab1",
                    "title": "Test Audiobook"
                }
            }
        }
        """

        let invalidTypeData = invalidTypeJSON.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(SourceMediaSnapshot.self, from: invalidTypeData)) { error in
            if let decodingError = error as? DecodingError {
                if case .dataCorrupted(let context) = decodingError {
                    XCTAssertEqual(context.codingPath.last?.stringValue, "type")
                } else {
                    XCTFail("Expected dataCorrupted error for invalid type, got \(decodingError)")
                }
            } else {
                XCTFail("Expected DecodingError, got \(error)")
            }
        }
    }
}
