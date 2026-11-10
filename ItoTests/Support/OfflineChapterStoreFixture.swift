import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// A migrated database, an in-memory filesystem and fixed inputs for offline store tests.
/// Several stores can be built over the same fixture to simulate restarts: a restart is a new
/// store instance, because crash recovery runs once per instance.
final class OfflineStoreFixture {
    let database: TestDatabase
    let fileSystem = FakeOfflineFileSystem()
    let protectedData = FakeProtectedDataAvailability()
    let root = URL(fileURLWithPath: "/ito-offline-tests/OfflineChapters", isDirectory: true)

    static let fixedDate = Date(timeIntervalSince1970: 1_000)
    static let clock: @Sendable () -> Date = { OfflineStoreFixture.fixedDate }

    /// The epoch of `plugin.test` in `pluginCompletionScope`, and the epoch after a rotation.
    static let epoch = String(repeating: "a", count: 32)
    static let rotatedEpoch = String(repeating: "b", count: 32)

    static let mangaEdition = OfflineChapterEdition(
        pluginId: "plugin.test",
        mediaKind: .manga,
        canonicalMediaId: "series-1",
        chapterKey: "chapter-1"
    )

    init() throws {
        database = try TestDatabase()
        try database.dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO pluginCompletionScope(pluginId, epoch) VALUES (?, ?)",
                arguments: ["plugin.test", Self.epoch]
            )
        }
    }

    deinit {
        database.cleanup()
    }

    func makeStore() -> OfflineChapterStore {
        OfflineChapterStore(
            root: root,
            database: database.dbPool,
            fileSystem: fileSystem,
            protectedData: protectedData,
            clock: Self.clock
        )
    }

    /// Rotates the source epoch in the database, as a plugin setting change does.
    func rotateEpoch(to epoch: String) throws {
        try database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE pluginCompletionScope SET epoch = ? WHERE pluginId = ?",
                arguments: [epoch, "plugin.test"]
            )
        }
    }

    var versionsURL: URL { root.appendingPathComponent("versions", isDirectory: true) }
    var stagingURL: URL { root.appendingPathComponent("staging", isDirectory: true) }
    var trashURL: URL { root.appendingPathComponent("trash", isDirectory: true) }
    var storeIdentifierURL: URL { root.appendingPathComponent("store-id") }

    func versionURL(_ versionId: String) -> URL {
        versionsURL.appendingPathComponent(versionId, isDirectory: true)
    }

    // MARK: - Inputs

    static func request(
        chapterKey: String = "chapter-1",
        mediaKind: MediaKind = .manga,
        paywalled: Bool? = nil,
        sourceEpoch: String? = OfflineStoreFixture.epoch,
        canonicalMediaId: String = "series-1"
    ) -> DownloadEnqueueRequest {
        DownloadEnqueueRequest(
            pluginId: "plugin.test",
            mediaKind: mediaKind,
            canonicalMediaId: canonicalMediaId,
            entry: .manga(Manga(key: canonicalMediaId, title: "Series One")),
            chapter: chapter(chapterKey, paywalled: paywalled),
            seriesTitle: "Series One",
            sourceEpoch: sourceEpoch
        )
    }

    static func chapter(_ key: String, paywalled: Bool? = nil) -> Chapter {
        Chapter(
            key: key,
            title: "Chapter",
            url: "https://source.test/read/\(key)?token=signed-secret",
            paywalled: paywalled
        )
    }

    /// A batch of chapters in the given reading order. `lockedKeys` are marked paywalled.
    static func batchRequest(
        chapterKeys: [String],
        lockedKeys: Set<String> = [],
        mediaKind: MediaKind = .manga,
        canonicalMediaId: String = "series-1",
        preset: DownloadBatchPreset = .next5,
        selection: Data = DownloadBatchRecord.sourceListSelection,
        catalogDigest: String? = String(repeating: "d", count: 64)
    ) -> DownloadBatchRequest {
        DownloadBatchRequest(
            pluginId: "plugin.test",
            mediaKind: mediaKind,
            canonicalMediaId: canonicalMediaId,
            entry: .manga(Manga(key: canonicalMediaId, title: "Series One")),
            seriesTitle: "Series One",
            preset: preset,
            selection: selection,
            catalogDigest: catalogDigest,
            chapters: chapterKeys.map { chapter($0, paywalled: lockedKeys.contains($0) ? true : nil) }
        )
    }

    /// Bytes that start with a JPEG signature and differ per tag, so each page hashes differently.
    static func jpeg(_ tag: String) -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(tag.utf8)
    }

    static func imagePage(_ index: Int32) -> OfflinePageInput {
        OfflinePageInput(content: .image(jpeg("image-\(index)")), sourceIndex: index)
    }

    static func textPage(_ index: Int32, _ text: String) -> OfflinePageInput {
        OfflinePageInput(content: .text(Data(text.utf8)), sourceIndex: index)
    }

    // MARK: - Common flows

    /// Reconciles the store, then queues the chapter and returns its job id.
    func enqueue(
        _ store: OfflineChapterStore,
        chapterKey: String = "chapter-1",
        mediaKind: MediaKind = .manga,
        sourceEpoch: String? = OfflineStoreFixture.epoch,
        canonicalMediaId: String = "series-1"
    ) async throws -> String {
        _ = await store.reconcile()
        let outcome = try await store.enqueue(
            Self.request(
                chapterKey: chapterKey,
                mediaKind: mediaKind,
                sourceEpoch: sourceEpoch,
                canonicalMediaId: canonicalMediaId
            )
        )
        guard outcome == .queued else { throw OfflineStoreFixtureError.notQueued }
        let jobs = try await store.jobs()
        guard let job = jobs.last(where: { $0.chapterKey == chapterKey && $0.canonicalMediaId == canonicalMediaId }) else {
            throw OfflineStoreFixtureError.notQueued
        }
        return job.id
    }

    /// Reconciles, then queues the chapters as one batch and returns their job ids in request order.
    func enqueueBatch(
        _ store: OfflineChapterStore,
        chapterKeys: [String],
        canonicalMediaId: String = "series-1"
    ) async throws -> [String] {
        _ = await store.reconcile()
        let outcome = try await store.enqueueBatch(
            Self.batchRequest(chapterKeys: chapterKeys, canonicalMediaId: canonicalMediaId),
            sourceEpoch: Self.epoch
        )
        guard outcome.queued == chapterKeys.count else { throw OfflineStoreFixtureError.notQueued }
        let jobs = try await store.jobs()
        return try chapterKeys.map { key in
            guard let job = jobs.first(where: { $0.chapterKey == key && $0.canonicalMediaId == canonicalMediaId }) else {
                throw OfflineStoreFixtureError.notQueued
            }
            return job.id
        }
    }

    /// Reconciles, queues the chapter and publishes three pages through the whole protocol.
    func publishedEdition(
        _ store: OfflineChapterStore,
        chapterKey: String = "chapter-1",
        canonicalMediaId: String = "series-1"
    ) async throws -> String {
        let jobID = try await enqueue(store, chapterKey: chapterKey, canonicalMediaId: canonicalMediaId)

        let pages = [Self.imagePage(0), Self.imagePage(1), Self.imagePage(2)]
        let outcome = try await store.perform(
            .publish(jobID: jobID, pages: pages, commitGuard: { _ in true }),
            through: .all
        )
        guard case .published(let versionId)? = outcome else {
            throw OfflineStoreFixtureError.notPublished
        }
        return versionId
    }

    /// The invariants the crash and reconciliation tests check after a restart:
    /// I1 manifests match their rows, I2 no leftover staging, trash or unreferenced versions,
    /// and I3 no job is left downloading and each edition has at most one job.
    func assertInvariants(_ store: OfflineChapterStore) async throws {
        let rows = try await database.dbPool.read { db in
            try DownloadedChapterRecord.fetchAll(db)
        }
        let jobs = try await store.jobs()
        let referencedVersions = Set(rows.map(\.versionId))

        for row in rows where row.state == .verified {
            let manifest = try fileSystem.readData(
                at: versionURL(row.versionId).appendingPathComponent(OfflineChapterManifest.fileName)
            )
            #expect(OfflineDigest.sha256Hex(manifest) == row.manifestSHA256)
        }
        #expect(fileSystem.childNames(of: stagingURL).isEmpty)
        #expect(fileSystem.childNames(of: trashURL).isEmpty)
        #expect(Set(fileSystem.childNames(of: versionsURL)) == referencedVersions)
        #expect(jobs.allSatisfy { $0.state != .downloading })
        #expect(Set(jobs.map(\.edition)).count == jobs.count)
        // I4: every batch has a job, so a frozen snapshot never outlives the work it was frozen for.
        #expect(try await rowCount("downloadBatch") == (Set(jobs.map(\.batchId))).count)
    }

    /// The number of rows in one of the offline tables.
    func rowCount(_ table: String) async throws -> Int {
        try await database.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }
}

enum OfflineStoreFixtureError: Error {
    case notQueued
    case notPublished
}
