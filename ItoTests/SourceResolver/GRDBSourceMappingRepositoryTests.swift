import XCTest
import GRDB
@testable import Ito

@MainActor
final class GRDBSourceMappingRepositoryTests: XCTestCase {
    private var testDatabase: TestDatabase!
    private var repository: GRDBSourceMappingRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDatabase = try TestDatabase()
        repository = GRDBSourceMappingRepository(dbWriter: testDatabase.dbPool)
    }

    override func tearDownWithError() throws {
        testDatabase = nil
        repository = nil
        try super.tearDownWithError()
    }

    func testMigrationV5() async throws {
        // AppDatabase already ran migration on init of TestDatabase.
        // We can just verify that inserting a record works without schema errors.
        let record = makeRecord()
        try await repository.upsert(record)

        let fetched = try await repository.fetchConfirmed(
            canonicalProvider: record.canonicalProvider,
            canonicalMediaId: record.canonicalMediaId,
            mediaType: record.mediaType
        )

        XCTAssertEqual(fetched.count, 1)
    }

    func testCompositePrimaryKey() async throws {
        let record1 = makeRecord()
        let record2 = makeRecord(confidence: 0.5) // Same keys

        try await repository.upsert(record1)
        try await repository.upsert(record2)

        // Ensure there's only 1 record because they have the same PK
        let fetched = try await repository.fetchAll(
            canonicalProvider: record1.canonicalProvider,
            canonicalMediaId: record1.canonicalMediaId,
            mediaType: record1.mediaType
        )

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.confidence, 0.5)
    }
    func testCanonicalConfirmedLookup() async throws {
        let confirmed = makeRecord(pluginMediaKey: "key1", decision: .autoConfirm)
        let discard = makeRecord(pluginMediaKey: "key2", decision: .discard)

        try await repository.upsert(confirmed)
        try await repository.upsert(discard)

        let fetched = try await repository.fetchConfirmed(
            canonicalProvider: confirmed.canonicalProvider,
            canonicalMediaId: confirmed.canonicalMediaId,
            mediaType: confirmed.mediaType
        )

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.pluginMediaKey, "key1")
    }

    func testFetchAll() async throws {
        let confirmed = makeRecord(pluginMediaKey: "key1", decision: .autoConfirm)
        let discard = makeRecord(pluginMediaKey: "key2", decision: .discard)

        try await repository.upsert(confirmed)
        try await repository.upsert(discard)

        let fetched = try await repository.fetchAll(
            canonicalProvider: confirmed.canonicalProvider,
            canonicalMediaId: confirmed.canonicalMediaId,
            mediaType: confirmed.mediaType
        )

        XCTAssertEqual(fetched.count, 2)
    }

    func testFindPlugin() async throws {
        let record1 = makeRecord(pluginId: "pluginA", pluginMediaKey: "keyA")
        let record2 = makeRecord(pluginId: "pluginA", pluginMediaKey: "keyB")

        try await repository.upsert(record1)
        try await repository.upsert(record2)

        let fetched = try await repository.find(pluginId: "pluginA", pluginMediaKey: "keyA")
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.pluginMediaKey, "keyA")
    }

    func testUpsert() async throws {
        let oldDate = Date(timeIntervalSince1970: 0)
        let record = makeRecord(createdAt: oldDate, updatedAt: oldDate)

        try await repository.upsert(record)

        let fetched1 = try await repository.fetchConfirmed(
            canonicalProvider: record.canonicalProvider,
            canonicalMediaId: record.canonicalMediaId,
            mediaType: record.mediaType
        ).first!

        XCTAssertEqual(fetched1.createdAt, oldDate)
        XCTAssertNotEqual(fetched1.updatedAt, oldDate) // Should be 'now'

        // Update it
        // We delay for a fraction of a second to ensure Date() has ticked forward enough for updated updatedAt
        try await Task.sleep(nanoseconds: 10_000_000)

        let updatedRecord = makeRecord(titleSnapshot: "New Title", createdAt: Date(), updatedAt: Date()) // Try to mess up dates
        try await repository.upsert(updatedRecord)

        let fetched2 = try await repository.fetchConfirmed(
            canonicalProvider: record.canonicalProvider,
            canonicalMediaId: record.canonicalMediaId,
            mediaType: record.mediaType
        ).first!

        XCTAssertEqual(fetched2.titleSnapshot, "New Title")
        XCTAssertEqual(fetched2.createdAt, oldDate) // Preserved
        XCTAssertGreaterThan(fetched2.updatedAt, fetched1.updatedAt) // Updated again
    }

    func testPersistRejection() async throws {
        try await repository.persistRejection(
            canonicalProvider: "anilist",
            canonicalMediaId: "123",
            mediaType: .manga,
            pluginId: "pluginA",
            pluginMediaKey: "keyA"
        )

        let fetched = try await repository.fetchAll(
            canonicalProvider: "anilist",
            canonicalMediaId: "123",
            mediaType: .manga
        )

        XCTAssertEqual(fetched.count, 1)
        let record = fetched.first!
        XCTAssertEqual(record.decision, .discard)
        XCTAssertEqual(record.matchMethod, .none)
        XCTAssertNil(record.encodedPayload)
    }

    func testUnlink() async throws {
        let record = makeRecord()
        try await repository.upsert(record)

        try await repository.unlink(
            canonicalProvider: record.canonicalProvider,
            canonicalMediaId: record.canonicalMediaId,
            mediaType: record.mediaType,
            pluginId: record.pluginId,
            pluginMediaKey: record.pluginMediaKey
        )

        let fetched = try await repository.fetchAll(
            canonicalProvider: record.canonicalProvider,
            canonicalMediaId: record.canonicalMediaId,
            mediaType: record.mediaType
        )

        XCTAssertTrue(fetched.isEmpty)
    }

    func testNovelPersistenceAndRetrieval() async throws {
        let record = makeRecord(canonicalMediaId: "novel-42", mediaType: .novel, pluginMediaKey: "nkey-1")
        try await repository.upsert(record)

        let fetched = try await repository.fetchConfirmed(
            canonicalProvider: "anilist",
            canonicalMediaId: "novel-42",
            mediaType: .novel
        )
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.mediaType, .novel)
        XCTAssertEqual(fetched.first?.pluginMediaKey, "nkey-1")

        try await repository.persistRejection(
            canonicalProvider: "anilist",
            canonicalMediaId: "novel-42",
            mediaType: .novel,
            pluginId: "pluginA",
            pluginMediaKey: "nkey-1"
        )

        let afterRejection = try await repository.fetchConfirmed(
            canonicalProvider: "anilist",
            canonicalMediaId: "novel-42",
            mediaType: .novel
        )
        XCTAssertTrue(afterRejection.isEmpty)

        let allAfterRejection = try await repository.fetchAll(
            canonicalProvider: "anilist",
            canonicalMediaId: "novel-42",
            mediaType: .novel
        )
        XCTAssertEqual(allAfterRejection.count, 1)
        XCTAssertEqual(allAfterRejection.first?.decision, .discard)
    }

    // MARK: - Helpers

    private func makeRecord(
        canonicalProvider: String = "anilist",
        canonicalMediaId: String = "123",
        mediaType: PluginMediaType = .manga,
        pluginId: String = "pluginA",
        pluginMediaKey: String = "key1",
        decision: MatchDecision = .autoConfirm,
        matchMethod: MatchMethod = .exactPreferred,
        confidence: Double = 1.0,
        titleSnapshot: String = "Test Title",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        encodedPayload: Data? = Data([1, 2, 3])
    ) -> SourceMappingRecord {
        SourceMappingRecord(
            canonicalProvider: canonicalProvider,
            canonicalMediaId: canonicalMediaId,
            mediaType: mediaType,
            pluginId: pluginId,
            pluginMediaKey: pluginMediaKey,
            decision: decision,
            matchMethod: matchMethod,
            confidence: confidence,
            titleSnapshot: titleSnapshot,
            createdAt: createdAt,
            updatedAt: updatedAt,
            coverURLSnapshot: nil,
            encodedPayload: encodedPayload,
            payloadVersion: 1,
            pluginVersion: "1.0",
            lastVerifiedAt: Date()
        )
    }
}
