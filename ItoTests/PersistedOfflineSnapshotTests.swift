import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// The offline store's frozen series entries, queued chapter snapshots and inventory copies, as the store
/// wrote them, decode through every path that reads them and keep their values.
struct PersistedOfflineSnapshotTests {
    private static let pluginId = "plugin.test"

    // MARK: - Blobs

    @Test(arguments: PersistedOfflineFixture.allCases)
    func aFrozenEntryDecodesAsItsMediaEntryWithTheListedChapters(fixture: PersistedOfflineFixture) throws {
        let entry = try JSONDecoder().decode(
            MediaEntry.self, from: try PersistedDataFixtures.data(fixture.entryFileName)
        )

        switch entry {
        case .manga(let manga):
            #expect(fixture.kind == .manga)
            #expect(manga.key == fixture.seriesKey)
            #expect(manga.title == fixture.title)
            #expect(manga.authors == ["Writer A", "Writer B"])
            #expect(manga.status == .Ongoing)
            #expect(manga.viewer == (fixture == .mangaABI1 ? .Rtl : .Webtoon))
            ExpectedChapter.check(manga.chapters, fixture.listedChapters)
        case .novel(let novel):
            #expect(fixture.kind == .novel)
            #expect(novel.key == fixture.seriesKey)
            #expect(novel.title == fixture.title)
            #expect(novel.authors == ["Novelist D"])
            #expect(novel.status == .Completed)
            ExpectedChapter.check(novel.chapters, fixture.listedChapters)
        case .anime:
            Issue.record("The frozen entry of \(fixture.rawValue) decoded as an anime")
        }
    }

    @Test(arguments: PersistedOfflineFixture.allCases)
    func aQueuedChapterKeepsEverythingTheSourceReturned(fixture: PersistedOfflineFixture) throws {
        for expected in fixture.queuedChapters {
            let blob = try PersistedDataFixtures.data(fixture.jobFileName(chapterKey: expected.key))

            expected.check(try JSONDecoder().decode(Chapter.self, from: blob))
        }
    }

    @Test(arguments: PersistedOfflineFixture.allCases)
    func anInventoryCopyHasNoPageListingFields(fixture: PersistedOfflineFixture) throws {
        for expected in fixture.queuedChapters {
            let blob = try PersistedDataFixtures.data(fixture.inventoryFileName(chapterKey: expected.key))

            expected.withoutPageListingFields()
                .check(try JSONDecoder().decode(Chapter.self, from: blob))
        }
    }

    // MARK: - Readers of the queue and the inventory

    @Test(arguments: PersistedOfflineFixture.allCases)
    func theDownloadsListReadsTheQueuedAndSavedSnapshots(fixture: PersistedOfflineFixture) async throws {
        let offline = try OfflineStoreFixture()
        try await Self.seedQueue(fixture, into: offline.database.dbPool)
        try await Self.seedInventory(fixture, into: offline.database.dbPool)

        let snapshot = try await offline.database.dbPool.read { db in try DownloadsSnapshot.read(db) }

        let queued = try #require(snapshot.inProgress.first)
        #expect(queued.title == "Series")
        #expect(queued.rows.map(\.edition.chapterKey) == fixture.queuedChapters.map(\.key))
        Self.checkRows(queued.rows, against: fixture.queuedChapters)
        let saved = try #require(snapshot.downloaded.first)
        #expect(Set(saved.rows.map(\.edition.chapterKey)) == Set(fixture.queuedChapters.map(\.key)))
        Self.checkRows(saved.rows, against: fixture.queuedChapters)
    }

    @Test(arguments: PersistedOfflineFixture.allCases)
    func savedDetailsAddTheSavedChaptersTheListDoesNotHave(fixture: PersistedOfflineFixture) async throws {
        let offline = try OfflineStoreFixture()
        try await Self.seedInventory(fixture, into: offline.database.dbPool)
        let inventory = try await offline.database.dbPool.read { db in
            try DownloadedChapterRecord.fetchAll(db)
        }
        let first = fixture.queuedChapters[0]

        let merged = try #require(SavedChapterMerge.merged([], inventory: inventory))
        #expect(Set(merged.map(\.key)) == Set(fixture.queuedChapters.map(\.key)))
        for chapter in merged {
            let expected = try #require(fixture.queuedChapters.first { $0.key == chapter.key })
            expected.withoutPageListingFields().check(chapter)
        }

        // A chapter the list already has is never duplicated by its saved copy.
        let listed = [Chapter(key: first.key, title: "Listed title")]
        let withListed = try #require(SavedChapterMerge.merged(listed, inventory: inventory))
        #expect(withListed.map(\.key).first == first.key)
        #expect(Set(withListed.map(\.key)) == Set(fixture.queuedChapters.map(\.key)))
        #expect(withListed.count == fixture.queuedChapters.count)
    }

    // MARK: - Download attempt

    @Test(arguments: PersistedOfflineFixture.allCases)
    @MainActor
    func aDownloadAttemptReadsTheFrozenSnapshotsAndPublishesAnInventoryCopy(fixture: PersistedOfflineFixture) async throws {
        let worker = try DownloadWorkerFixture()
        await worker.coordinator.reconcile()
        try await Self.seedQueue(fixture, into: worker.offline.database.dbPool)

        worker.coordinator.start()
        await worker.coordinator.untilIdle()

        // The source was asked about exactly the frozen entry and each queued chapter, in queue order.
        let requests = worker.source.listedRequestsSnapshot
        #expect(requests.map(\.chapter.key) == fixture.queuedChapters.map(\.key))
        for (request, expected) in zip(requests, fixture.queuedChapters) {
            expected.check(request.chapter)
            #expect(request.entry.key == fixture.seriesKey)
            #expect(request.entry.kind == fixture.kind)
            switch request.entry {
            case .manga(let manga): ExpectedChapter.check(manga.chapters, fixture.listedChapters)
            case .novel(let novel): ExpectedChapter.check(novel.chapters, fixture.listedChapters)
            case .anime: Issue.record("The frozen entry decoded as an anime")
            }
        }

        // Each chapter was published, and its inventory copy lost the page-listing fields.
        #expect(try await worker.store.jobs().isEmpty)
        for expected in fixture.queuedChapters {
            let copy = try #require(try await worker.store.verifiedEdition(for: OfflineChapterEdition(
                pluginId: Self.pluginId, mediaKind: fixture.kind, canonicalMediaId: fixture.seriesKey,
                chapterKey: expected.key
            )))
            #expect(copy.seriesTitle == "Series")
            expected.withoutPageListingFields()
                .check(try JSONDecoder().decode(Chapter.self, from: copy.chapterSnapshot))
        }
    }

    // MARK: - Helpers

    /// Rows are matched to their chapter by key, so the check does not depend on how the list orders them.
    private static func checkRows(_ rows: [DownloadListRow], against expected: [ExpectedChapter]) {
        for row in rows {
            guard let chapter = expected.first(where: { $0.key == row.edition.chapterKey }) else {
                Issue.record("Unexpected row \(row.edition.chapterKey)")
                continue
            }
            #expect(row.title == chapter.title)
            #expect(sameNumber(row.number, chapter.chapter), "number of \(chapter.key): \(String(describing: row.number))")
            #expect(sameNumber(row.volume, chapter.volume), "volume of \(chapter.key): \(String(describing: row.volume))")
            #expect(row.scanlator == chapter.scanlator)
        }
    }

    /// One batch with the frozen entry, and a queued job for each chapter's stored snapshot.
    private static func seedQueue(_ fixture: PersistedOfflineFixture, into dbPool: DatabasePool) async throws {
        let entry = try PersistedDataFixtures.data(fixture.entryFileName)
        let snapshots = try fixture.queuedChapters.map {
            try PersistedDataFixtures.data(fixture.jobFileName(chapterKey: $0.key))
        }
        let batchId = UUID().uuidString
        try await dbPool.write { db in
            try DownloadBatchRecord(
                id: batchId, pluginId: pluginId, mediaKind: fixture.kind, canonicalMediaId: fixture.seriesKey,
                preset: .next5, selection: DownloadBatchRecord.sourceListSelection, catalogDigest: nil,
                entrySnapshot: entry, createdAt: OfflineStoreFixture.fixedDate
            ).insert(db)
            for (index, expected) in fixture.queuedChapters.enumerated() {
                try DownloadJobRecord(
                    id: UUID().uuidString, batchId: batchId, sequence: index, pluginId: pluginId,
                    mediaKind: fixture.kind, canonicalMediaId: fixture.seriesKey, chapterKey: expected.key,
                    authorityScope: .publicUnscoped, chapterSnapshot: snapshots[index], seriesTitle: "Series",
                    sourceEpoch: OfflineStoreFixture.epoch, state: .queued, waitingReason: nil, failureReason: nil,
                    stagingVersionId: nil, attemptCount: 0, createdAt: OfflineStoreFixture.fixedDate,
                    updatedAt: OfflineStoreFixture.fixedDate
                ).insert(db)
            }
        }
    }

    /// Every queued chapter's stored inventory copy, as a verified saved chapter.
    private static func seedInventory(_ fixture: PersistedOfflineFixture, into dbPool: DatabasePool) async throws {
        let snapshots = try fixture.queuedChapters.map {
            try PersistedDataFixtures.data(fixture.inventoryFileName(chapterKey: $0.key))
        }
        try await dbPool.write { db in
            for (expected, snapshot) in zip(fixture.queuedChapters, snapshots) {
                try DownloadedChapterRecord(
                    pluginId: pluginId, mediaKind: fixture.kind, canonicalMediaId: fixture.seriesKey,
                    chapterKey: expected.key, authorityScope: .publicUnscoped,
                    versionId: UUID().uuidString, state: .verified, damageReason: nil,
                    contentKind: fixture.kind == .novel ? .text : .images, pageCount: 1, byteCount: 10,
                    manifestFormatVersion: 1, manifestSHA256: String(repeating: "a", count: 64),
                    chapterSnapshot: snapshot, seriesTitle: "Series", sourceEpoch: nil,
                    verifiedAt: OfflineStoreFixture.fixedDate
                ).insert(db)
            }
        }
    }
}
