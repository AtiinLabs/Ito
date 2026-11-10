import Combine
import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// What a relink or a source remap does to a series' downloads: stored copies move with it and stay
/// readable, queued jobs are cancelled, and a name-based scanlator choice never crosses plugins.
@MainActor
struct LibrarySourceRemapperDownloadTests {
    private nonisolated static let pluginId = "plugin.test"
    private nonisolated static let otherPluginId = "plugin.other"

    // MARK: - Fixtures

    private nonisolated static func item(_ id: String, pluginId: String = LibrarySourceRemapperDownloadTests.pluginId) -> LibraryItem {
        LibraryItem(
            id: id,
            title: "Series",
            coverUrl: nil,
            pluginId: pluginId,
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil
        )
    }

    private nonisolated static func media(_ id: String, pluginId: String = LibrarySourceRemapperDownloadTests.pluginId) -> MediaIdentity {
        MediaIdentity(pluginId: pluginId, canonicalMediaId: id, mediaKind: .manga)
    }

    private nonisolated static func edition(
        _ chapterKey: String = "chapter-1",
        series: String,
        pluginId: String = LibrarySourceRemapperDownloadTests.pluginId
    ) -> OfflineChapterEdition {
        OfflineChapterEdition(media: media(series, pluginId: pluginId), chapterKey: chapterKey)
    }

    @discardableResult
    private nonisolated static func relink(
        _ pool: DatabasePool,
        from: String = "series-1",
        to: String = "series-2"
    ) async throws -> LibrarySourceRemapper.Result {
        try await LibrarySourceRemapper(dbPool: pool).relink(
            pluginId: pluginId,
            mediaKind: .manga,
            possibleSourceItemIds: [from],
            destinationItemId: to,
            title: "Relinked",
            coverUrl: nil,
            rawPayload: Data("relinked".utf8)
        )
    }

    private nonisolated static func insertItem(_ pool: DatabasePool, _ id: String = "series-1") async throws {
        try await pool.write { db in try item(id).insert(db) }
    }

    private nonisolated static func rows(_ pool: DatabasePool) async throws -> [DownloadedChapterRecord] {
        try await pool.read { db in try DownloadedChapterRecord.fetchAll(db) }
    }

    /// Every stored copy as `plugin/series/chapter/version/hasOrigin`, for before-and-after comparison.
    private nonisolated static func inventory(_ pool: DatabasePool) async throws -> [String] {
        try await rows(pool).map {
            "\($0.pluginId)/\($0.canonicalMediaId)/\($0.chapterKey)/\($0.versionId)/\($0.originIdentity != nil)"
        }.sorted()
    }

    private nonisolated static func origin(of record: DownloadedChapterRecord) throws -> OfflineOriginIdentity {
        try JSONDecoder().decode(OfflineOriginIdentity.self, from: #require(record.originIdentity))
    }

    private nonisolated static func count(_ pool: DatabasePool, _ table: String) async throws -> Int {
        try await pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    private nonisolated static func preference(_ series: String, _ pluginId: String = pluginId, bytes: String) -> SeriesEditionPreferenceRecord {
        SeriesEditionPreferenceRecord(
            pluginId: pluginId,
            mediaKind: .manga,
            canonicalMediaId: series,
            selection: Data(bytes.utf8),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private nonisolated static func suppression(_ series: String, _ key: String, _ at: Date) -> DownloadSuppressionRecord {
        DownloadSuppressionRecord(
            pluginId: pluginId, mediaKind: .manga, canonicalMediaId: series, chapterKey: key,
            authorityScope: .publicUnscoped, suppressedAt: at
        )
    }

    private nonisolated static func snapshotState(_ series: String) -> LibrarySnapshotStateRecord {
        LibrarySnapshotStateRecord(
            pluginId: pluginId,
            mediaKind: .manga,
            canonicalMediaId: series,
            payloadSHA256: String(repeating: "a", count: 64),
            refreshedAt: Date(timeIntervalSince1970: 1),
            catalogScope: .allEligible,
            catalogCompleteness: .complete,
            chapterRowCount: 3
        )
    }

    private nonisolated static func firstPageBytes(
        _ store: OfflineChapterStore,
        _ edition: OfflineChapterEdition
    ) async throws -> Data {
        let lease = try await store.openLease(edition: edition)
        let page = try #require(lease.page(fileName: OfflinePageFileName.make(index: 0, fileExtension: "jpg")))
        return try store.readVerifiedPage(page)
    }

    // MARK: - Stored copies

    @Test func aRelinkMovesVerifiedCopiesAndTheirManifestsStillValidate() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let versionId = try await fixture.publishedEdition(store)
        try await Self.insertItem(fixture.database.dbPool)

        let result = try await Self.relink(fixture.database.dbPool)

        #expect(result.cancelledDownloadJobCount == 0)
        let moved = Self.edition(series: "series-2")
        let row = try #require(try await store.verifiedEdition(for: moved))
        #expect(row.versionId == versionId)
        #expect(try Self.origin(of: row) == OfflineOriginIdentity(pluginId: Self.pluginId, canonicalMediaId: "series-1"))
        #expect(row.manifestIdentity.canonicalMediaId == "series-1")
        #expect(try await store.verifiedEdition(for: Self.edition(series: "series-1")) == nil)
        // The lease opens only if the manifest, written under series-1, validates through the origin.
        #expect(try await Self.firstPageBytes(store, moved) == OfflineStoreFixture.jpeg("image-0"))
        #expect(try await store.verifiedChapters(pluginId: Self.pluginId, mediaKind: .manga, canonicalMediaId: "series-2").count == 1)
        #expect(try await store.verifiedChapters(pluginId: Self.pluginId, mediaKind: .manga, canonicalMediaId: "series-1").isEmpty)
        try await fixture.assertInvariants(store)
    }

    @Test func aSecondRelinkKeepsTheFirstOriginAndGoingBackNeedsNone() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        _ = try await fixture.publishedEdition(store)
        try await Self.insertItem(pool)

        try await Self.relink(pool, from: "series-1", to: "series-2")
        try await Self.relink(pool, from: "series-2", to: "series-3")

        let moved = Self.edition(series: "series-3")
        let twice = try #require(try await store.verifiedEdition(for: moved))
        #expect(try Self.origin(of: twice) == OfflineOriginIdentity(pluginId: Self.pluginId, canonicalMediaId: "series-1"))
        #expect(try await Self.firstPageBytes(store, moved) == OfflineStoreFixture.jpeg("image-0"))

        try await Self.relink(pool, from: "series-3", to: "series-1")

        let home = Self.edition(series: "series-1")
        let back = try #require(try await store.verifiedEdition(for: home))
        #expect(back.originIdentity == nil, "A copy back under the identity of its manifest needs no origin")
        #expect(try await Self.firstPageBytes(store, home) == OfflineStoreFixture.jpeg("image-0"))
        try await fixture.assertInvariants(store)
    }

    @Test func aCollisionThrowsAndLeavesBothSidesUnchanged() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1", canonicalMediaId: "series-1")
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1", canonicalMediaId: "series-2")
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-2", canonicalMediaId: "series-1")
        let queued = try await fixture.enqueue(store, chapterKey: "chapter-3", canonicalMediaId: "series-1")
        try await pool.write { db in
            try Self.preference("series-1", bytes: "source").insert(db)
            try DownloadSuppressionRecord(
                pluginId: Self.pluginId,
                mediaKind: .manga,
                canonicalMediaId: "series-1",
                chapterKey: "chapter-9",
                authorityScope: .publicUnscoped,
                suppressedAt: Date(timeIntervalSince1970: 1)
            ).insert(db)
        }
        try await Self.insertItem(pool)
        let before = try await Self.inventory(pool)

        await #expect(
            throws: LibrarySourceRemapper.RemapError.mediaStateDestinationCollision(
                table: "downloadedChapter",
                canonicalMediaId: "series-2"
            )
        ) {
            try await Self.relink(pool)
        }

        #expect(try await Self.inventory(pool) == before)
        #expect(try await store.job(id: queued) != nil)
        #expect(try await Self.count(pool, "downloadSuppression") == 1)
        #expect(try await Self.count(pool, "seriesEditionPreference") == 1)
        let items = try await pool.read { db in try LibraryItem.fetchAll(db).map(\.id) }
        #expect(items == ["series-1"])
    }

    @Test func differentChaptersOfTheTwoSeriesMergeUnderTheDestination() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1", canonicalMediaId: "series-1")
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-2", canonicalMediaId: "series-2")
        try await Self.insertItem(pool)

        try await Self.relink(pool)

        let keys = try await store.verifiedChapters(
            pluginId: Self.pluginId, mediaKind: .manga, canonicalMediaId: "series-2"
        ).map(\.chapterKey)
        #expect(keys == ["chapter-1", "chapter-2"])
        #expect(try await Self.firstPageBytes(store, Self.edition("chapter-1", series: "series-2")) == OfflineStoreFixture.jpeg("image-0"))
        #expect(try await Self.firstPageBytes(store, Self.edition("chapter-2", series: "series-2")) == OfflineStoreFixture.jpeg("image-0"))
        try await fixture.assertInvariants(store)
    }

    @Test func movedCopiesTheNewSourceDoesNotListAreSavedOnlyRowsNeverMatchedByNumber() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        _ = try await fixture.publishedEdition(store, chapterKey: "old-key-7")
        try await Self.insertItem(pool)

        try await Self.relink(pool)

        // What the details screen reads on reload: the copies of the series it shows now.
        let inventory = await store.inventoryChapters(
            pluginId: Self.pluginId, mediaKind: .manga, canonicalMediaId: "series-2"
        )
        let listedByTheNewSource: Set<String> = ["new-key-7", "new-key-8"]
        let savedOnly = SavedChapterMerge.savedOnly(listedKeys: listedByTheNewSource, inventory: inventory)
        #expect(savedOnly.map(\.key) == ["old-key-7"], "The copy keeps its own key; no chapter of the new list absorbs it")
    }

    // MARK: - Queued downloads

    @Test func relinkDeletesTheSeriesJobsAndTheirBatchesAndLeavesOtherSeriesAlone() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        let doomed = try await fixture.enqueueBatch(store, chapterKeys: ["a", "b"], canonicalMediaId: "series-1")
        let kept = try await fixture.enqueueBatch(store, chapterKeys: ["c"], canonicalMediaId: "series-3")
        try await Self.insertItem(pool)

        let result = try await Self.relink(pool)

        #expect(result.cancelledDownloadJobCount == 2)
        for id in doomed {
            #expect(try await store.job(id: id) == nil)
        }
        #expect(try await store.job(id: kept[0]) != nil)
        #expect(try await fixture.rowCount("downloadBatch") == 1)
        try await fixture.assertInvariants(store)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func relinkingWhileAnAttemptRunsStopsItBeforeTheNextAssetAndCommitsNothing() async throws {
        let fixture = try DownloadWorkerFixture()
        let pool = fixture.offline.database.dbPool
        try await Self.insertItem(pool)
        await fixture.coordinator.reconcile()
        _ = await fixture.enqueue()
        fixture.center.startObserving(scheduling: ImmediateValueObservationScheduler())
        let gate = fixture.fetcher.gate(for: "https://img.test/2.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()
        let series = Self.media("series-1")
        for await states in fixture.center.$states.values {
            if case .downloading? = states[series]?["chapter-1"] { break }
        }

        let result = try await Self.relink(pool)
        #expect(result.cancelledDownloadJobCount == 1)

        // The gate is never released: only the center, seeing the job gone, can end the attempt. The time
        // limit turns a missing cancel into a failure instead of a hang.
        await gate.awaitCancellation()
        try Task.checkCancellation()
        #expect(await !gate.wasReleased)
        await fixture.coordinator.untilIdle()

        #expect(!fixture.fetcher.requestedURLs.contains("https://img.test/3.jpg"))
        #expect(try await fixture.store.verifiedEdition(for: Self.edition(series: "series-1")) == nil)
        #expect(try await fixture.store.verifiedEdition(for: Self.edition(series: "series-2")) == nil)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aLateCommitAfterTheRelinkIsRefusedAndNoCopyAppearsUnderEitherSeries() async throws {
        let fixture = try DownloadWorkerFixture()
        let pool = fixture.offline.database.dbPool
        try await Self.insertItem(pool)
        await fixture.coordinator.reconcile()
        _ = await fixture.enqueue()
        let gate = fixture.fetcher.gate(for: "https://img.test/3.jpg")
        await fixture.startWorker()
        await gate.awaitArrival()

        try await Self.relink(pool)
        // Nothing observes the tables here, so the attempt runs on to its commit.
        await gate.release()
        await fixture.coordinator.untilIdle()

        #expect(try await fixture.store.verifiedEdition(for: Self.edition(series: "series-1")) == nil)
        #expect(try await fixture.store.verifiedEdition(for: Self.edition(series: "series-2")) == nil)
        #expect(try await fixture.store.jobs().isEmpty)
        #expect(fixture.offline.fileSystem.childNames(of: fixture.offline.versionsURL).isEmpty)
        try await fixture.offline.assertInvariants(fixture.store)
    }

    @Test func anAttemptPublishedAfterTheRelinkIsRefusedAsItsJobIsGone() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        let jobID = try await fixture.enqueue(store)
        let attempt = try await store.beginAttempt(jobID: jobID)
        for index in 0..<3 {
            try await attempt.append(OfflineStoreFixture.imagePage(Int32(index)))
        }
        try await Self.insertItem(pool)

        try await Self.relink(pool)
        let late = try await store.publish(attempt, commitGuard: { _ in true })

        #expect(late == .refused(.jobGone))
        #expect(try await Self.rows(pool).isEmpty)
        try await fixture.assertInvariants(store)
    }

    // MARK: - Reconciliation and crashes

    @Test func reconcileAfterARelinkMarksNothingDamaged() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1")
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-2")
        try await Self.insertItem(pool)
        try await Self.relink(pool)

        let restarted = fixture.makeStore()
        let report = await restarted.reconcile()

        guard case .completed(let details) = report else {
            Issue.record("Reconciliation did not complete: \(report)")
            return
        }
        #expect(details.damagedRows == 0)
        #expect(details.removedRows == 0)
        #expect(details.discardedVersions == 0)
        #expect(try await Self.rows(pool).allSatisfy { $0.state == .verified && $0.canonicalMediaId == "series-2" })
        try await fixture.assertInvariants(restarted)
    }

    @Test func aCrashBetweenTheRemapCommitAndCollectionLeavesNoOrphanVersion() async throws {
        let fixture = try OfflineStoreFixture()
        let crashed = fixture.makeStore()
        let pool = fixture.database.dbPool
        let versionId = try await fixture.publishedEdition(crashed, chapterKey: "chapter-1")
        let inFlight = try await fixture.enqueue(crashed, chapterKey: "chapter-2")
        let attempt = try await crashed.beginAttempt(jobID: inFlight)
        try await attempt.append(OfflineStoreFixture.imagePage(0))
        try await Self.insertItem(pool)
        try await Self.relink(pool)

        // The process dies here: nothing has collected garbage since the remapper committed.
        let restarted = fixture.makeStore()
        let report = await restarted.reconcile()

        guard case .completed(let details) = report else {
            Issue.record("Reconciliation did not complete: \(report)")
            return
        }
        #expect(details.reclaimedVersions == 0, "The moved copy is still referenced by its row")
        #expect(details.damagedRows == 0)
        #expect(fixture.fileSystem.exists(fixture.versionURL(versionId)))
        #expect(try await restarted.collectGarbage().reclaimedVersions == 0)
        // The cancelled job's staging bytes are not a version: reconciliation removed them.
        #expect(try await Self.rows(pool).map(\.versionId) == [versionId])
        try await fixture.assertInvariants(restarted)
    }

    // MARK: - Same identity

    /// Seeds one series with a copy, a queued chapter, a deletion record, a scanlator choice and snapshot state.
    private func seedSeriesOne(_ fixture: OfflineStoreFixture, _ store: OfflineChapterStore) async throws -> (version: String, job: String) {
        let version = try await fixture.publishedEdition(store, chapterKey: "chapter-1")
        let job = try await fixture.enqueue(store, chapterKey: "chapter-2")
        try await fixture.database.dbPool.write { db in
            try Self.suppression("series-1", "chapter-9", Date(timeIntervalSince1970: 1)).insert(db)
            try Self.preference("series-1", bytes: "chosen").insert(db)
            try Self.snapshotState("series-1").insert(db)
        }
        return (version, job)
    }

    private func expectSeriesOneUntouched(
        _ fixture: OfflineStoreFixture,
        _ store: OfflineChapterStore,
        seeded: (version: String, job: String),
        pluginId: String = LibrarySourceRemapperDownloadTests.pluginId
    ) async throws {
        let pool = fixture.database.dbPool
        #expect(try await Self.inventory(pool) == ["\(pluginId)/series-1/chapter-1/\(seeded.version)/false"])
        #expect(try await store.job(id: seeded.job) != nil)
        #expect(try await fixture.rowCount("downloadBatch") == 1)
        #expect(try await Self.count(pool, "downloadSuppression") == 1)
        #expect(try await Self.count(pool, "seriesEditionPreference") == 1)
        #expect(try await Self.count(pool, "librarySnapshotState") == 1)
        let moved = Self.edition(series: "series-1", pluginId: pluginId)
        #expect(try await Self.firstPageBytes(store, moved) == OfflineStoreFixture.jpeg("image-0"))
    }

    @Test func aRelinkOntoTheSameCanonicalIdentityChangesNothingAndCancelsNothing() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        let seeded = try await seedSeriesOne(fixture, store)
        // A `plugin_key` item relinked to the bare `key`: the two share one canonical identity.
        try await pool.write { db in try Self.item("plugin.test_series-1").insert(db) }

        let result = try await Self.relink(pool, from: "plugin.test_series-1", to: "series-1")

        #expect(result.cancelledDownloadJobCount == 0)
        try await expectSeriesOneUntouched(fixture, store, seeded: seeded)
        let items = try await pool.read { db in try LibraryItem.fetchAll(db).map(\.id) }
        #expect(items == ["series-1"])
    }

    @Test func aRemapWithinOnePluginKeepsTheSameCanonicalIdentityAndChangesNothing() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        let seeded = try await seedSeriesOne(fixture, store)
        try await Self.insertItem(pool)

        let result = try await LibrarySourceRemapper(dbPool: pool).remap(
            oldPluginId: Self.pluginId, newPluginId: Self.pluginId, affectedItemIds: ["series-1"]
        )

        #expect(result.cancelledDownloadJobCount == 0)
        try await expectSeriesOneUntouched(fixture, store, seeded: seeded)
    }

    // MARK: - Deletion records after a move

    @Test func aSourceDeletionRecordIsDroppedWhenTheDestinationHasThatChapterStoredOrQueued() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1", canonicalMediaId: "series-2")
        _ = try await fixture.enqueue(store, chapterKey: "chapter-3", canonicalMediaId: "series-2")
        try await Self.insertItem(pool)
        try await pool.write { db in
            for key in ["chapter-1", "chapter-3", "chapter-5"] {
                try Self.suppression("series-1", key, Date(timeIntervalSince1970: 1)).insert(db)
            }
        }

        try await Self.relink(pool)

        let rows = try await pool.read { db in try DownloadSuppressionRecord.fetchAll(db) }
        #expect(rows.map(\.chapterKey) == ["chapter-5"])
        #expect(rows.map(\.canonicalMediaId) == ["series-2"])
        #expect(try await store.verifiedEdition(for: Self.edition("chapter-1", series: "series-2")) != nil)
    }

    @Test func aDestinationDeletionRecordIsDroppedWhenASourceCopyMovesOntoThatChapter() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1", canonicalMediaId: "series-1")
        try await Self.insertItem(pool)
        try await pool.write { db in
            try Self.suppression("series-2", "chapter-1", Date(timeIntervalSince1970: 1)).insert(db)
            try Self.suppression("series-2", "chapter-5", Date(timeIntervalSince1970: 1)).insert(db)
        }

        try await Self.relink(pool)

        let keys = try await pool.read { db in try DownloadSuppressionRecord.fetchAll(db).map(\.chapterKey) }
        #expect(keys == ["chapter-5"])
        #expect(try await store.verifiedEdition(for: Self.edition("chapter-1", series: "series-2")) != nil)
    }

    // MARK: - The relink seam

    @Test func theRemapperServesTheRelinkSeamAndReturnsItsCancelledJobCount() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        _ = try await fixture.enqueue(store)
        try await Self.insertItem(pool)
        let service: any MediaDetailRelinkServing = LibrarySourceRemapper(dbPool: pool)

        let cancelled = try await service.relink(
            pluginID: Self.pluginId,
            mediaKind: .manga,
            possibleSourceItemIDs: ["series-1"],
            destinationItemID: "series-2",
            title: "Relinked",
            coverURL: nil,
            rawPayload: Data("relinked".utf8)
        )

        #expect(cancelled == 1)
        #expect(try await store.jobs().isEmpty)
    }

    // MARK: - Remap across plugins

    @Test func aRemapAcrossPluginsMovesCopiesAndTheirManifestsStillValidate() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        let versionId = try await fixture.publishedEdition(store)
        let queued = try await fixture.enqueue(store, chapterKey: "chapter-2")
        try await Self.insertItem(pool)

        let result = try await LibrarySourceRemapper(dbPool: pool).remap(
            oldPluginId: Self.pluginId,
            newPluginId: Self.otherPluginId,
            affectedItemIds: ["series-1"]
        )

        #expect(result.cancelledDownloadJobCount == 1)
        #expect(try await store.job(id: queued) == nil)
        let moved = Self.edition(series: "series-1", pluginId: Self.otherPluginId)
        let row = try #require(try await store.verifiedEdition(for: moved))
        #expect(row.versionId == versionId)
        #expect(try Self.origin(of: row) == OfflineOriginIdentity(pluginId: Self.pluginId, canonicalMediaId: "series-1"))
        #expect(try await store.verifiedEdition(for: Self.edition(series: "series-1")) == nil)
        #expect(try await Self.firstPageBytes(store, moved) == OfflineStoreFixture.jpeg("image-0"))

        let restarted = fixture.makeStore()
        guard case .completed(let details) = await restarted.reconcile() else {
            Issue.record("Reconciliation did not complete")
            return
        }
        #expect(details.damagedRows == 0)
        try await fixture.assertInvariants(restarted)
    }

    @Test func aRemapThatWouldPutTwoCopiesOfAChapterUnderOneKeyThrowsAndChangesNothing() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        _ = try await fixture.publishedEdition(store)
        try await Self.insertItem(pool)
        // The destination already holds a copy of the same chapter of the same series.
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO downloadedChapter
                      (pluginId, mediaKind, canonicalMediaId, chapterKey, authorityScope, versionId, state, contentKind,
                       pageCount, byteCount, manifestFormatVersion, manifestSHA256, chapterSnapshot, seriesTitle, verifiedAt)
                    SELECT ?, mediaKind, canonicalMediaId, chapterKey, authorityScope, ?, state, contentKind,
                       pageCount, byteCount, manifestFormatVersion, manifestSHA256, chapterSnapshot, seriesTitle, verifiedAt
                    FROM downloadedChapter
                    """,
                arguments: [Self.otherPluginId, UUID().uuidString]
            )
        }
        let before = try await Self.inventory(pool)

        await #expect(
            throws: LibrarySourceRemapper.RemapError.mediaStateDestinationCollision(
                table: "downloadedChapter",
                canonicalMediaId: "series-1"
            )
        ) {
            _ = try await LibrarySourceRemapper(dbPool: pool).remap(
                oldPluginId: Self.pluginId,
                newPluginId: Self.otherPluginId,
                affectedItemIds: ["series-1"]
            )
        }

        #expect(try await Self.inventory(pool) == before)
    }

    @Test func theMigrationReportRemapInheritsTheSameBehaviour() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pool = fixture.database.dbPool
        _ = try await fixture.publishedEdition(store)
        let ids = try await fixture.enqueueBatch(store, chapterKeys: ["queued-1", "queued-2"])
        try await Self.insertItem(pool)
        let adapter = LibrarySourceRemapperMigrationAdapter(
            remapper: LibrarySourceRemapper(dbPool: pool),
            aliasWriter: { _, _ in }
        )

        let outcome = try await adapter.remapSource(MigrationRemapRequest(
            foreignID: "foreign",
            oldPluginID: Self.pluginId,
            newPluginID: Self.otherPluginId,
            affectedItemIDs: ["series-1"]
        ))

        #expect(outcome == .remappedAndAliased)
        let moved = Self.edition(series: "series-1", pluginId: Self.otherPluginId)
        #expect(try await Self.firstPageBytes(store, moved) == OfflineStoreFixture.jpeg("image-0"))
        for id in ids {
            #expect(try await store.job(id: id) == nil)
        }
        #expect(try await fixture.rowCount("downloadBatch") == 0)
        try await fixture.assertInvariants(store)
    }

    // MARK: - Edition preferences

    @Test func aRelinkMovesTheScanlatorChoiceWhenTheDestinationHasNone() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pool = database.dbPool
        try await Self.insertItem(pool)
        try await pool.write { db in try Self.preference("series-1", bytes: "chosen").insert(db) }

        try await Self.relink(pool)

        let rows = try await pool.read { db in try SeriesEditionPreferenceRecord.fetchAll(db) }
        #expect(rows.map(\.canonicalMediaId) == ["series-2"])
        #expect(rows.first?.selection == Data("chosen".utf8))
    }

    @Test func aRelinkKeepsTheDestinationsChoiceAndDropsTheSourcesWithoutAborting() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pool = database.dbPool
        try await Self.insertItem(pool)
        try await pool.write { db in
            try Self.preference("series-1", bytes: "source").insert(db)
            try Self.preference("series-2", bytes: "destination").insert(db)
        }

        try await Self.relink(pool)

        let rows = try await pool.read { db in try SeriesEditionPreferenceRecord.fetchAll(db) }
        #expect(rows.map(\.canonicalMediaId) == ["series-2"])
        #expect(rows.first?.selection == Data("destination".utf8))
        let items = try await pool.read { db in try LibraryItem.fetchAll(db).map(\.id) }
        #expect(items == ["series-2"])
    }

    @Test func aRemapAcrossPluginsDeletesTheScanlatorChoiceAndKeepsTheDestinationsOwn() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pool = database.dbPool
        try await Self.insertItem(pool)
        try await pool.write { db in try Self.preference("series-1", bytes: "by name").insert(db) }

        _ = try await LibrarySourceRemapper(dbPool: pool).remap(
            oldPluginId: Self.pluginId, newPluginId: Self.otherPluginId, affectedItemIds: ["series-1"]
        )
        #expect(try await Self.count(pool, "seriesEditionPreference") == 0, "Names do not bind across sources")

        let again = try TestDatabase()
        defer { again.cleanup() }
        try await Self.insertItem(again.dbPool)
        try await again.dbPool.write { db in
            try Self.preference("series-1", bytes: "by name").insert(db)
            try Self.preference("series-1", Self.otherPluginId, bytes: "own").insert(db)
        }
        _ = try await LibrarySourceRemapper(dbPool: again.dbPool).remap(
            oldPluginId: Self.pluginId, newPluginId: Self.otherPluginId, affectedItemIds: ["series-1"]
        )
        let rows = try await again.dbPool.read { db in try SeriesEditionPreferenceRecord.fetchAll(db) }
        #expect(rows.map(\.pluginId) == [Self.otherPluginId])
        #expect(rows.first?.selection == Data("own".utf8))
    }

    // MARK: - Other series state

    @Test func deletionRecordsMoveAndADestinationRecordForTheSameChapterIsKept() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pool = database.dbPool
        try await Self.insertItem(pool)
        let earlier = Date(timeIntervalSince1970: 1)
        let later = Date(timeIntervalSince1970: 2)
        try await pool.write { db in
            try Self.suppression("series-1", "shared", earlier).insert(db)
            try Self.suppression("series-1", "only-source", earlier).insert(db)
            try Self.suppression("series-2", "shared", later).insert(db)
        }

        try await Self.relink(pool)

        let rows = try await pool.read { db in
            try DownloadSuppressionRecord.order(Column("chapterKey")).fetchAll(db)
        }
        #expect(rows.map(\.chapterKey) == ["only-source", "shared"])
        #expect(rows.allSatisfy { $0.canonicalMediaId == "series-2" })
        #expect(rows.first { $0.chapterKey == "shared" }?.suppressedAt == later)
    }

    @Test func theSnapshotStateOfTheOldSeriesIsDeletedAndOthersAreKept() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pool = database.dbPool
        try await Self.insertItem(pool)
        try await pool.write { db in
            try Self.snapshotState("series-1").insert(db)
            try Self.snapshotState("series-9").insert(db)
        }

        try await Self.relink(pool)

        let remaining = try await pool.read { db in try LibrarySnapshotStateRecord.fetchAll(db).map(\.canonicalMediaId) }
        #expect(remaining == ["series-9"])
    }

    @Test func theThumbnailOfTheOldItemGoesWithItAndNothingIsCarriedToTheNewOne() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pool = database.dbPool
        try await Self.insertItem(pool)
        try await pool.write { db in
            try LibraryCoverThumbnailRecord(
                libraryItemId: "series-1",
                coverURLSHA256: String(repeating: "b", count: 64),
                imageData: Data([1]),
                pixelWidth: 1,
                pixelHeight: 1,
                storedAt: Date(timeIntervalSince1970: 1)
            ).insert(db)
        }

        try await Self.relink(pool)

        #expect(try await Self.count(pool, "libraryCoverThumbnail") == 0)
    }
}
