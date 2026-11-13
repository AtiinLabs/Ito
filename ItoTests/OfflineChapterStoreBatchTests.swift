import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// Batches freeze one series snapshot for many jobs, and the bulk operations keep the single-chapter
/// protocols' guarantees: one transaction, no resurrection by a late commit, no orphan snapshot.
struct OfflineChapterStoreBatchTests {
    private static func edition(_ key: String, series: String = "series-1") -> OfflineChapterEdition {
        OfflineChapterEdition(pluginId: "plugin.test", mediaKind: .manga, canonicalMediaId: series, chapterKey: key)
    }

    private static let series1 = MediaIdentity(
        pluginId: "plugin.test",
        canonicalMediaId: "series-1",
        mediaKind: .manga
    )

    // MARK: - enqueueBatch

    @Test func aBatchFreezesOneSnapshotAndQueuesEveryChapterInRequestOrder() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = await store.reconcile()
        let digest = String(repeating: "f", count: 64)
        let selection = Data(#"{"formatVersion":1,"kind":"scanlators","scanlators":[{"name":"Group A"}]}"#.utf8)

        let outcome = try await store.enqueueBatch(
            OfflineStoreFixture.batchRequest(
                chapterKeys: ["c3", "c1", "c2"],
                preset: .next5,
                selection: selection,
                catalogDigest: digest
            ),
            sourceEpoch: OfflineStoreFixture.epoch
        )

        #expect(outcome.queued == 3)
        let batchId = try #require(outcome.batchId)
        let jobs = try await store.jobs()
        #expect(jobs.map(\.chapterKey) == ["c3", "c1", "c2"])
        #expect(jobs.map(\.sequence) == [0, 1, 2])
        #expect(jobs.allSatisfy { $0.batchId == batchId && $0.state == .queued })
        #expect(jobs.allSatisfy { $0.sourceEpoch == OfflineStoreFixture.epoch })
        let batch = try #require(try await fixture.database.dbPool.read { db in
            try DownloadBatchRecord.fetchOne(db, key: batchId)
        })
        #expect(try await fixture.rowCount("downloadBatch") == 1)
        #expect(batch.preset == .next5)
        #expect(batch.selection == selection)
        #expect(batch.catalogDigest == digest)
        #expect(batch.createdAt == OfflineStoreFixture.fixedDate)
        #expect(batch.canonicalMediaId == "series-1")
        guard case .manga(let manga) = try JSONDecoder().decode(MediaEntry.self, from: batch.entrySnapshot) else {
            Issue.record("The frozen entry is not the series' manga entry")
            return
        }
        #expect(manga.key == "series-1")
        // The job keeps the chapter exactly as the source returned it, including the page-listing URL.
        let chapter = try JSONDecoder().decode(Chapter.self, from: jobs[0].chapterSnapshot)
        #expect(chapter.url?.contains("c3") == true)
    }

    @Test func eachRequestedChapterIsSettledOnceAndSequenceIsItsRequestPosition() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "saved")
        _ = try await fixture.publishedEdition(store, chapterKey: "damaged")
        let damagedVersion = try #require(try await store.verifiedEdition(for: Self.edition("damaged"))?.versionId)
        try await store.markDamaged(versionId: damagedVersion, reason: .pageMismatch)
        _ = try await fixture.enqueue(store, chapterKey: "already-queued")

        let outcome = try await store.enqueueBatch(
            OfflineStoreFixture.batchRequest(
                chapterKeys: ["saved", "damaged", "already-queued", "locked", "fresh", "fresh"],
                lockedKeys: ["locked"]
            ),
            sourceEpoch: OfflineStoreFixture.epoch
        )

        #expect(outcome.queued == 1)
        #expect(outcome.alreadySaved == 1)
        #expect(outcome.blockedDamaged == 1)
        // The existing job and the repeat of "fresh" inside the request.
        #expect(outcome.alreadyQueued == 2)
        #expect(outcome.refusedLocked == 1)
        #expect(outcome.refusal == nil)
        let jobs = try await store.jobs()
        #expect(Set(jobs.map(\.chapterKey)) == ["already-queued", "fresh"])
        let fresh = try #require(jobs.first { $0.chapterKey == "fresh" })
        #expect(fresh.sequence == 4)
        // The damaged copy is untouched, and nothing was queued for the locked chapter.
        #expect(try await store.verifiedEdition(for: Self.edition("damaged")) == nil)
        try await fixture.assertInvariants(store)
    }

    @Test func aBatchWithNothingToQueueLeavesNoBatchRow() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "saved")

        let outcome = try await store.enqueueBatch(
            OfflineStoreFixture.batchRequest(chapterKeys: ["saved", "locked"], lockedKeys: ["locked"]),
            sourceEpoch: OfflineStoreFixture.epoch
        )

        #expect(outcome.queued == 0)
        #expect(outcome.batchId == nil)
        #expect(try await fixture.rowCount("downloadBatch") == 0)
        #expect(try await fixture.rowCount("downloadJob") == 0)
    }

    @Test func aFailureInTheMiddleOfTheBatchInsertsNoJobAndNoBatch() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = await store.reconcile()
        try await fixture.database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER failOnBoom BEFORE INSERT ON downloadJob WHEN NEW.chapterKey = 'boom'
                BEGIN SELECT RAISE(ABORT, 'injected failure'); END
                """)
        }

        await #expect(throws: DatabaseError.self) {
            try await store.enqueueBatch(
                OfflineStoreFixture.batchRequest(chapterKeys: ["a", "b", "boom", "c"]),
                sourceEpoch: OfflineStoreFixture.epoch
            )
        }

        #expect(try await store.jobs().isEmpty)
        #expect(try await fixture.rowCount("downloadBatch") == 0)
    }

    @Test func requestsTheStoreCannotFreezeAreRefusedWithoutAnyRow() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()

        await #expect(throws: OfflineStoreError.reconciliationPending) {
            try await store.enqueueBatch(
                OfflineStoreFixture.batchRequest(chapterKeys: ["a"]),
                sourceEpoch: OfflineStoreFixture.epoch
            )
        }
        _ = await store.reconcile()

        let anime = try await store.enqueueBatch(
            OfflineStoreFixture.batchRequest(chapterKeys: ["a"], mediaKind: .anime),
            sourceEpoch: OfflineStoreFixture.epoch
        )
        let unbound = try await store.enqueueBatch(OfflineStoreFixture.batchRequest(chapterKeys: ["a"]), sourceEpoch: nil)
        let arraySelection = try await store.enqueueBatch(
            OfflineStoreFixture.batchRequest(chapterKeys: ["a"], selection: Data("[]".utf8)),
            sourceEpoch: OfflineStoreFixture.epoch
        )
        let garbageSelection = try await store.enqueueBatch(
            OfflineStoreFixture.batchRequest(chapterKeys: ["a"], selection: Data("nope".utf8)),
            sourceEpoch: OfflineStoreFixture.epoch
        )
        let shortDigest = try await store.enqueueBatch(
            OfflineStoreFixture.batchRequest(chapterKeys: ["a"], catalogDigest: "abc"),
            sourceEpoch: OfflineStoreFixture.epoch
        )

        #expect(anime.refusal == .unsupportedKind)
        #expect(unbound.refusal == .unavailable)
        #expect(arraySelection.refusal == .unavailable)
        #expect(garbageSelection.refusal == .unavailable)
        #expect(shortDigest.refusal == .unavailable)
        #expect(try await fixture.rowCount("downloadJob") == 0)
        #expect(try await fixture.rowCount("downloadBatch") == 0)
    }

    @Test func aSingleEnqueueDuringABatchLeavesExactlyOneJobForTheChapter() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = await store.reconcile()

        async let single = store.enqueue(OfflineStoreFixture.request(chapterKey: "shared"))
        async let batch = store.enqueueBatch(
            OfflineStoreFixture.batchRequest(chapterKeys: ["shared", "other"]),
            sourceEpoch: OfflineStoreFixture.epoch
        )
        let (singleOutcome, batchOutcome) = try await (single, batch)

        let jobs = try await store.jobs()
        #expect(jobs.filter { $0.chapterKey == "shared" }.count == 1)
        #expect(jobs.filter { $0.chapterKey == "other" }.count == 1)
        if singleOutcome == .queued {
            #expect(batchOutcome.queued == 1)
            #expect(batchOutcome.alreadyQueued == 1)
        } else {
            #expect(singleOutcome == .alreadyQueued)
            #expect(batchOutcome.queued == 2)
        }
        try await fixture.assertInvariants(store)
    }

    @Test func anExplicitDownloadClearsTheDeleteSuppressionForThatChapter() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "gone")
        _ = try await fixture.publishedEdition(store, chapterKey: "other")
        try await store.delete([Self.edition("gone"), Self.edition("other")], suppress: true)
        #expect(try await fixture.rowCount("downloadSuppression") == 2)

        let outcome = try await store.enqueueBatch(
            OfflineStoreFixture.batchRequest(chapterKeys: ["gone"]),
            sourceEpoch: OfflineStoreFixture.epoch
        )

        #expect(outcome.queued == 1)
        let remaining = try await fixture.database.dbPool.read { db in
            try DownloadSuppressionRecord.fetchAll(db).map(\.chapterKey)
        }
        #expect(remaining == ["other"])
    }

    @Test func aSingleEnqueueIsAOneChapterSingleBatchThatFollowsTheSourceList() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)

        let job = try #require(try await store.job(id: jobID))
        let batch = try #require(try await fixture.database.dbPool.read { db in
            try DownloadBatchRecord.fetchOne(db, key: job.batchId)
        })
        #expect(job.sequence == 0)
        #expect(batch.preset == .single)
        #expect(batch.selection == DownloadBatchRecord.sourceListSelection)
        #expect(batch.catalogDigest == nil)
        #expect(try await fixture.rowCount("downloadBatch") == 1)
    }

    // MARK: - Queue reads

    @Test func theNextQueuedJobIsTheOldestBatchThenTheBatchOrderAndCarriesTheFrozenEntry() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let ids = try await fixture.enqueueBatch(store, chapterKeys: ["c3", "c1", "c2"])

        let first = try #require(try await store.nextQueuedJob())
        #expect(first.job.id == ids[0])
        guard case .manga(let manga) = try JSONDecoder().decode(MediaEntry.self, from: first.entrySnapshot) else {
            Issue.record("The work's entry is not the batch's manga entry")
            return
        }
        #expect(manga.key == "series-1")

        // A waiting job and a downloading job are skipped.
        try await store.setWaiting(jobID: ids[0], reason: .noConnection)
        _ = try await store.beginAttempt(jobID: ids[1])
        #expect(try await store.nextQueuedJob()?.job.id == ids[2])

        // A batch created earlier runs before this one's remaining jobs.
        let older = try await fixture.enqueueBatch(store, chapterKeys: ["o1"], canonicalMediaId: "series-2")
        try await fixture.database.dbPool.write { db in
            let early = Date(timeIntervalSince1970: 10)
            try db.execute(sql: "UPDATE downloadBatch SET createdAt = ? WHERE canonicalMediaId = 'series-2'", arguments: [early])
            try db.execute(sql: "UPDATE downloadJob SET createdAt = ? WHERE canonicalMediaId = 'series-2'", arguments: [early])
        }
        #expect(try await store.nextQueuedJob()?.job.id == older[0])

        try await store.setWaiting(jobID: older[0], reason: .noConnection)
        try await store.setWaiting(jobID: ids[2], reason: .noConnection)
        #expect(try await store.nextQueuedJob() == nil)
    }

    @Test func jobForAnEditionFindsOnlyThatEditionsJob() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let ids = try await fixture.enqueueBatch(store, chapterKeys: ["a", "b"])

        #expect(try await store.job(for: Self.edition("b"))?.id == ids[1])
        #expect(try await store.job(for: Self.edition("c")) == nil)
        #expect(try await store.job(for: Self.edition("a", series: "series-2")) == nil)
    }

    @Test func twoBatchesCreatedAtTheSameInstantNeverInterleaveTheirJobs() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.enqueueBatch(store, chapterKeys: ["a1", "a2", "a3"])
        _ = try await fixture.enqueueBatch(store, chapterKeys: ["b1", "b2", "b3"], canonicalMediaId: "series-2")

        let jobs = try await store.jobs()

        // The fixture's clock is fixed, so both batches carry the same creation time.
        #expect(Set(jobs.map(\.createdAt)).count == 1)
        let batchIds = jobs.map(\.batchId)
        let switches = zip(batchIds, batchIds.dropFirst()).filter { $0 != $1 }.count
        #expect(Set(batchIds).count == 2)
        #expect(switches == 1)
        for batchId in Set(batchIds) {
            #expect(jobs.filter { $0.batchId == batchId }.map(\.sequence) == [0, 1, 2])
        }

        // The worker's query serves the same order.
        var served: [String] = []
        while let work = try await store.nextQueuedJob() {
            served.append(work.job.id)
            try await store.setWaiting(jobID: work.job.id, reason: .noConnection)
        }
        #expect(served == jobs.map(\.id))
    }

    @Test func aLoneLockedChapterIsRefusedAsPaywalledEvenWithoutASourceEpoch() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = await store.reconcile()

        let locked = try await store.enqueue(OfflineStoreFixture.request(paywalled: true, sourceEpoch: nil))
        let unlocked = try await store.enqueue(OfflineStoreFixture.request(sourceEpoch: nil))

        #expect(locked == .refused(.paywalled))
        #expect(unlocked == .refused(.unavailable))
        #expect(try await fixture.rowCount("downloadBatch") == 0)
    }

    // MARK: - Bulk cancel and retry

    @Test func bulkCancelRemovesTheJobsTogetherAndTheBatchWithItsLastJob() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let ids = try await fixture.enqueueBatch(store, chapterKeys: ["a", "b", "c"])
        let attempt = try await store.beginAttempt(jobID: ids[0])
        try await attempt.append(OfflineStoreFixture.imagePage(0))

        let removed = try await store.cancel(jobIDs: [ids[0], ids[1], "no-such-job"])

        #expect(removed == [ids[0], ids[1]])
        #expect(try await store.jobs().map(\.id) == [ids[2]])
        #expect(try await fixture.rowCount("downloadBatch") == 1)
        #expect(!fixture.fileSystem.exists(attempt.directory))
        #expect(try await store.publish(attempt, commitGuard: { _ in true }) == .refused(.jobGone))

        try await store.cancel(jobIDs: [ids[2], ids[2]])

        #expect(try await store.jobs().isEmpty)
        #expect(try await fixture.rowCount("downloadBatch") == 0)
        try await fixture.assertInvariants(store)
    }

    @Test func bulkRetryRequeuesFailedAndWaitingJobsWithTheirPluginsFreshEpoch() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let ids = try await fixture.enqueueBatch(store, chapterKeys: ["failed", "waiting", "queued", "running"])
        let failedAttempt = try await store.beginAttempt(jobID: ids[0])
        try await store.abandonAttempt(
            jobID: ids[0],
            versionId: failedAttempt.versionId,
            outcome: .failed(.network)
        )
        try await store.setWaiting(jobID: ids[1], reason: .sourceUnavailable)
        _ = try await store.beginAttempt(jobID: ids[3])

        let requeued = try await store.retry(jobIDs: ids + ["no-such-job"], epochs: ["plugin.test": "epoch-new"])

        #expect(requeued == 2)
        let jobs = try await store.jobs()
        func job(_ index: Int) throws -> DownloadJobRecord {
            try #require(jobs.first { $0.id == ids[index] })
        }
        for index in [0, 1] {
            let retried = try job(index)
            #expect(retried.state == .queued)
            #expect(retried.waitingReason == nil)
            #expect(retried.failureReason == nil)
            #expect(retried.sourceEpoch == "epoch-new")
        }
        #expect(try job(2).sourceEpoch == OfflineStoreFixture.epoch)
        #expect(try job(3).state == .downloading)
    }

    @Test func bulkRetryWithoutOnePluginsEpochChangesNothing() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let known = try await fixture.enqueueBatch(store, chapterKeys: ["known"])
        try await store.setWaiting(jobID: known[0], reason: .sourceUnavailable)
        let foreign = DownloadBatchRequest(
            pluginId: "plugin.other",
            mediaKind: .manga,
            canonicalMediaId: "series-9",
            entry: .manga(Manga(key: "series-9", title: "Other")),
            seriesTitle: "Other",
            preset: .single,
            selection: DownloadBatchRecord.sourceListSelection,
            catalogDigest: nil,
            chapters: [OfflineStoreFixture.chapter("foreign")]
        )
        _ = try await store.enqueueBatch(foreign, sourceEpoch: "epoch-other")
        let foreignJob = try #require(try await store.jobs().first { $0.pluginId == "plugin.other" })
        try await store.setWaiting(jobID: foreignJob.id, reason: .sourceUnavailable)

        await #expect(throws: OfflineStoreError.jobUnavailable) {
            try await store.retry(jobIDs: [known[0], foreignJob.id], epochs: ["plugin.test": "epoch-new"])
        }

        let jobs = try await store.jobs()
        #expect(jobs.allSatisfy { $0.state == .waiting && $0.waitingReason == .sourceUnavailable })
        #expect(jobs.first { $0.id == known[0] }?.sourceEpoch == OfflineStoreFixture.epoch)
    }

    // MARK: - Bulk delete

    @Test func bulkDeleteRemovesCopiesAndJobsTogetherAndSuppressesAllDeletedEditions() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "a")
        let keptVersion = try await fixture.publishedEdition(store, chapterKey: "b")
        let queued = try await fixture.enqueueBatch(store, chapterKeys: ["q1", "q2"])
        let attempt = try await store.beginAttempt(jobID: queued[0])
        try await attempt.append(OfflineStoreFixture.imagePage(0))

        let summary = try await store.delete(
            [Self.edition("a"), Self.edition("q1"), Self.edition("q2"), Self.edition("never-stored")],
            suppress: true
        )

        #expect(summary == DownloadDeleteSummary(removedCopies: 1, removedJobs: 2))
        #expect(try await store.verifiedEdition(for: Self.edition("a")) == nil)
        #expect(try await store.verifiedEdition(for: Self.edition("b"))?.versionId == keptVersion)
        #expect(try await store.jobs().isEmpty)
        #expect(try await fixture.rowCount("downloadBatch") == 0)
        let suppressed = try await fixture.database.dbPool.read { db in
            try DownloadSuppressionRecord.fetchAll(db).map(\.chapterKey).sorted()
        }
        #expect(suppressed == ["a", "q1", "q2"])
        #expect(!fixture.fileSystem.exists(attempt.directory))
        #expect(try await store.publish(attempt, commitGuard: { _ in true }) == .refused(.jobGone))
        try await fixture.assertInvariants(store)
    }

    @Test func bulkDeleteWithoutSuppressRecordsNothing() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "a")

        try await store.delete([Self.edition("a")], suppress: false)

        #expect(try await fixture.rowCount("downloadSuppression") == 0)
        #expect(try await store.verifiedEdition(for: Self.edition("a")) == nil)
        try await fixture.assertInvariants(store)
    }

    @Test func deletingASeriesLeavesAnotherSeriesCopiesJobsAndBatchesAlone() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "a")
        _ = try await fixture.publishedEdition(store, chapterKey: "b")
        let other = try await fixture.publishedEdition(store, chapterKey: "c", canonicalMediaId: "series-2")
        _ = try await fixture.enqueueBatch(store, chapterKeys: ["q"])
        let otherQueued = try await fixture.enqueueBatch(store, chapterKeys: ["r"], canonicalMediaId: "series-2")

        let summary = try await store.deleteMedia(Self.series1, suppress: true)

        #expect(summary == DownloadDeleteSummary(removedCopies: 2, removedJobs: 1))
        #expect(try await store.verifiedEdition(for: Self.edition("c", series: "series-2"))?.versionId == other)
        #expect(try await store.jobs().map(\.id) == otherQueued)
        #expect(try await fixture.rowCount("downloadBatch") == 1)
        let suppressed = try await fixture.database.dbPool.read { db in
            try DownloadSuppressionRecord.fetchAll(db).map(\.chapterKey).sorted()
        }
        #expect(suppressed == ["a", "b", "q"])
        try await fixture.assertInvariants(store)
    }

    @Test func aLeasedCopyDeletedInBulkKeepsItsBytesUntilTheLeaseIsReleased() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let leasedVersion = try await fixture.publishedEdition(store, chapterKey: "leased")
        let freeVersion = try await fixture.publishedEdition(store, chapterKey: "free")
        var lease: OfflineChapterLease? = try await store.openLease(edition: Self.edition("leased"))

        try await store.delete([Self.edition("leased"), Self.edition("free")], suppress: false)

        #expect(fixture.fileSystem.exists(fixture.versionURL(leasedVersion)))
        #expect(!fixture.fileSystem.exists(fixture.versionURL(freeVersion)))
        #expect(lease != nil)
        lease = nil
        await store.leases.awaitReclamations()
        #expect(!fixture.fileSystem.exists(fixture.versionURL(leasedVersion)))
        try await fixture.assertInvariants(store)
    }

    @Test func aLateCommitAfterABulkDeleteOfItsBatchCannotResurrectAnything() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let ids = try await fixture.enqueueBatch(store, chapterKeys: ["a", "b"])
        let attempt = try await store.beginAttempt(jobID: ids[0])
        for index in 0..<3 {
            try await attempt.append(OfflineStoreFixture.imagePage(Int32(index)))
        }

        try await store.deleteMedia(Self.series1, suppress: false)
        let late = try await store.publish(attempt, commitGuard: { _ in true })

        #expect(late == .refused(.jobGone))
        #expect(try await store.verifiedEdition(for: Self.edition("a")) == nil)
        #expect(try await fixture.rowCount("downloadBatch") == 0)
        #expect(fixture.fileSystem.childNames(of: fixture.versionsURL).isEmpty)
        try await fixture.assertInvariants(store)
    }

    @Test func committingTheLastJobOfABatchDeletesItsBatch() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let ids = try await fixture.enqueueBatch(store, chapterKeys: ["a", "b"])

        for (position, jobID) in ids.enumerated() {
            let outcome = try await store.perform(
                .publish(jobID: jobID, pages: [OfflineStoreFixture.imagePage(0)], commitGuard: { _ in true }),
                through: .all
            )
            guard case .published? = outcome else {
                Issue.record("Job \(position) did not publish: \(String(describing: outcome))")
                return
            }
            #expect(try await fixture.rowCount("downloadBatch") == (position == ids.count - 1 ? 0 : 1))
        }
        try await fixture.assertInvariants(store)
    }

    // MARK: - Orphan batch sweep

    @Test func reconciliationSweepsBatchesNoJobReferences() async throws {
        let fixture = try OfflineStoreFixture()
        let writer = fixture.makeStore()
        let ids = try await fixture.enqueueBatch(writer, chapterKeys: ["a"])
        try await fixture.database.dbPool.write { db in
            for index in 0..<2 {
                try DownloadBatchRecord(
                    id: UUID().uuidString,
                    pluginId: "plugin.test",
                    mediaKind: .manga,
                    canonicalMediaId: "series-\(index)",
                    preset: .all,
                    selection: DownloadBatchRecord.sourceListSelection,
                    catalogDigest: nil,
                    entrySnapshot: Data("{}".utf8),
                    createdAt: OfflineStoreFixture.fixedDate
                ).insert(db)
            }
        }

        let restarted = fixture.makeStore()
        guard case .completed(let details) = await restarted.reconcile() else {
            Issue.record("Reconciliation did not complete")
            return
        }

        #expect(details.removedOrphanBatches == 2)
        #expect(try await restarted.jobs().map(\.id) == ids)
        #expect(try await fixture.rowCount("downloadBatch") == 1)
        try await fixture.assertInvariants(restarted)
    }

    // MARK: - Manifest identity

    @Test func aMovedCopyValidatesThroughItsOriginIdentityAndStaysReadable() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)
        try await Self.moveRow(in: fixture, to: "series-2", origin: Self.origin("series-1"))

        let restarted = fixture.makeStore()
        guard case .completed(let details) = await restarted.reconcile() else {
            Issue.record("Reconciliation did not complete")
            return
        }

        #expect(details.damagedRows == 0)
        let moved = Self.edition("chapter-1", series: "series-2")
        let lease = try await restarted.openLease(edition: moved)
        #expect(lease.edition == moved)
        #expect(try await restarted.verifiedEdition(for: moved) != nil)
    }

    @Test func aMovedCopyWithoutAnOriginIsMarkedDamaged() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)
        try await Self.moveRow(in: fixture, to: "series-2", origin: nil)

        let restarted = fixture.makeStore()
        guard case .completed(let details) = await restarted.reconcile() else {
            Issue.record("Reconciliation did not complete")
            return
        }

        #expect(details.damagedRows == 1)
        await #expect(throws: OfflineStoreError.damaged(.manifestUnreadable)) {
            try await restarted.openLease(edition: Self.edition("chapter-1", series: "series-2"))
        }
    }

    @Test func anOriginThatNamesAnotherSeriesDoesNotValidateTheManifest() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)
        try await Self.moveRow(in: fixture, to: "series-2", origin: Self.origin("series-3"))

        let restarted = fixture.makeStore()
        guard case .completed(let details) = await restarted.reconcile() else {
            Issue.record("Reconciliation did not complete")
            return
        }

        #expect(details.damagedRows == 1)
    }

    @Test func anOriginThatCannotBeReadIsIgnoredSoAnUnmovedCopyStillValidates() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)
        try await Self.moveRow(in: fixture, to: "series-1", origin: Data("not json".utf8))

        let restarted = fixture.makeStore()
        guard case .completed(let details) = await restarted.reconcile() else {
            Issue.record("Reconciliation did not complete")
            return
        }

        #expect(details.damagedRows == 0)
        _ = try await restarted.openLease(edition: OfflineStoreFixture.mangaEdition)
    }

    @Test func manifestIdentityAppliesTheOriginToTheSeriesOnlyAndKeepsKindChapterAndScope() throws {
        let origin = try JSONEncoder().encode(OfflineOriginIdentity(pluginId: "plugin.old", canonicalMediaId: "series-old"))
        var record = DownloadedChapterRecord(
            pluginId: "plugin.new",
            mediaKind: .novel,
            canonicalMediaId: "series-new",
            chapterKey: "chapter-7",
            authorityScope: .publicUnscoped,
            versionId: UUID().uuidString,
            state: .verified,
            damageReason: nil,
            contentKind: .text,
            pageCount: 1,
            byteCount: 1,
            manifestFormatVersion: 1,
            manifestSHA256: String(repeating: "a", count: 64),
            chapterSnapshot: Data("{}".utf8),
            seriesTitle: "Series",
            sourceEpoch: nil,
            verifiedAt: OfflineStoreFixture.fixedDate
        )
        #expect(record.manifestIdentity == record.edition)

        record.originIdentity = origin

        #expect(record.edition.pluginId == "plugin.new")
        #expect(record.manifestIdentity == OfflineChapterEdition(
            pluginId: "plugin.old",
            mediaKind: .novel,
            canonicalMediaId: "series-old",
            chapterKey: "chapter-7"
        ))
    }

    // MARK: - Helpers

    private static func origin(_ canonicalMediaId: String) throws -> Data {
        try JSONEncoder().encode(OfflineOriginIdentity(pluginId: "plugin.test", canonicalMediaId: canonicalMediaId))
    }

    /// Rewrites the stored copy's series identity, as a relink does, leaving its manifest untouched.
    private static func moveRow(in fixture: OfflineStoreFixture, to canonicalMediaId: String, origin: Data?) async throws {
        try await fixture.database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE downloadedChapter SET canonicalMediaId = ?, originIdentity = ? WHERE chapterKey = 'chapter-1'",
                arguments: [canonicalMediaId, origin]
            )
        }
    }
}
