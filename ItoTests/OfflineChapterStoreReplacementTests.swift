import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

struct OfflineChapterStoreReplacementTests {
    private func request(_ version: String, expectedRevision: String? = nil) -> DownloadReplacementRequest {
        DownloadReplacementRequest(
            download: OfflineStoreFixture.request(), expectedVersionId: version,
            expectedRevision: expectedRevision, authorizationId: UUID().uuidString
        )
    }

    private func staging(_ store: OfflineChapterStore) async throws -> OfflineStagingAttempt {
        let job = try #require(try await store.jobs().first)
        let attempt = try await store.beginAttempt(jobID: job.id)
        try await attempt.append(OfflineStoreFixture.imagePage(7))
        let intent = try #require(try await store.replacementIntent(jobID: job.id))
        try await store.confirmReplacement(intent, staging: attempt)
        return attempt
    }

    @Test func enqueueBindsVersionRevisionEpochAndSuppression() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let old = try await fixture.publishedEdition(store)
        #expect(try await store.enqueueReplacement(request("different")) == .refused(.unavailable))
        #expect(try await store.enqueueReplacement(request(old, expectedRevision: "different")) == .refused(.unavailable))
        try fixture.rotateEpoch(to: OfflineStoreFixture.rotatedEpoch)
        #expect(try await store.enqueueReplacement(request(old)) == .refused(.unavailable))
        try fixture.rotateEpoch(to: OfflineStoreFixture.epoch)
        try await fixture.database.dbPool.write { db in
            try DownloadSuppressionRecord(
                pluginId: "plugin.test", mediaKind: .manga, canonicalMediaId: "series-1",
                chapterKey: "chapter-1", authorityScope: .publicUnscoped, suppressedAt: OfflineStoreFixture.fixedDate
            ).insert(db)
        }
        #expect(try await store.enqueueReplacement(request(old)) == .refused(.unavailable))
        #expect(try await store.jobs().isEmpty)
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition)?.versionId == old)
    }

    @Test func aReplacementBatchFreezesTheSourceListSelection() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let old = try await fixture.publishedEdition(store)
        #expect(try await store.enqueueReplacement(request(old)) == .queued)
        let batch = try await fixture.database.dbPool.read { db in try DownloadBatchRecord.fetchOne(db) }
        #expect(batch?.selection == DownloadBatchRecord.sourceListSelection)
    }

    @Test func replacementSwapsPointerWhileOldLeaseReadsUntilRelease() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let old = try await fixture.publishedEdition(store)
        try await fixture.database.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO readingHistory
                  (id, mediaKey, title, pluginId, mediaKind, chapterKey, readAt)
                VALUES ('visit', 'series-1', 'Series', 'plugin.test', 'manga', 'chapter-1', ?)
                """, arguments: [OfflineStoreFixture.fixedDate])
            try db.execute(sql: """
                INSERT INTO readProgressKey (pluginId, canonicalMediaId, mediaKind, chapterKey)
                VALUES ('plugin.test', 'series-1', 'manga', 'chapter-1')
                """)
        }
        let history = try await fixture.database.dbPool.read { db in try ReadingHistoryRecord.fetchAll(db) }
        var lease: OfflineChapterLease? = try await store.openLease(edition: OfflineStoreFixture.mangaEdition)
        let first = try #require(lease?.manifest.pages.first)
        let page = try #require(lease?.page(fileName: first.file))
        #expect(try await store.enqueueReplacement(request(old)) == .queued)
        #expect(try await store.enqueueReplacement(request(old)) == .alreadyQueued)
        let attempt = try await staging(store)
        #expect(try await store.publish(attempt, commitGuard: { _ in true }) == .published(versionId: attempt.versionId))
        let current = try await store.openLease(edition: OfflineStoreFixture.mangaEdition)
        #expect(current.versionId == attempt.versionId)
        #expect(try store.readVerifiedPage(page) == OfflineStoreFixture.jpeg("image-0"))
        #expect(fixture.fileSystem.exists(fixture.versionURL(old)))
        #expect(try await fixture.rowCount("downloadReplacementIntent") == 0)
        lease = nil
        await store.leases.awaitReclamations()
        #expect(!fixture.fileSystem.exists(fixture.versionURL(old)))
        #expect(try await fixture.database.dbPool.read { db in try ReadingHistoryRecord.fetchAll(db) } == history)
        #expect(try await fixture.rowCount("readProgressKey") == 1)
    }

    @Test(arguments: ["pointer", "revision", "epoch", "relink", "delete"])
    func stagedReplacementCannotPublishAfterAuthorityChanges(_ change: String) async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let old = try await fixture.publishedEdition(store)
        #expect(try await store.enqueueReplacement(request(old)) == .queued)
        let attempt = try await staging(store)
        switch change {
        case "pointer":
            try await fixture.database.dbPool.write { db in
                try db.execute(
                    sql: "UPDATE downloadedChapter SET versionId = ?",
                    arguments: [UUID().uuidString]
                )
            }
        case "revision":
            try await fixture.database.dbPool.write { db in
                let data = try JSONEncoder().encode(Chapter(key: "chapter-1", revision: "changed"))
                try db.execute(sql: "UPDATE downloadedChapter SET chapterSnapshot = ?", arguments: [data])
            }
        case "epoch": try fixture.rotateEpoch(to: OfflineStoreFixture.rotatedEpoch)
        case "relink":
            try await fixture.database.dbPool.write { db in
                try db.execute(sql: "UPDATE downloadedChapter SET canonicalMediaId = 'relinked'")
            }
        default: try await store.delete(OfflineStoreFixture.mangaEdition)
        }
        let outcome = try await store.publish(attempt, commitGuard: { _ in true })
        guard case .refused = outcome else { Issue.record("Stale replacement published"); return }
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition)?.versionId != attempt.versionId)
        if change == "delete" {
            #expect(try await fixture.rowCount("downloadReplacementIntent") == 0)
            #expect(try await fixture.rowCount("downloadSuppression") == 1)
            #expect(try await store.jobs().isEmpty)
        }
    }

    @Test func publishWithoutLiveConfirmationEndsTheReplacementAndKeepsTheOldCopy() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let old = try await fixture.publishedEdition(store)
        #expect(try await store.enqueueReplacement(request(old)) == .queued)
        let job = try #require(try await store.jobs().first)
        let attempt = try await store.beginAttempt(jobID: job.id)
        try await attempt.append(OfflineStoreFixture.imagePage(9))
        #expect(try await store.publish(attempt, commitGuard: { _ in true }) == .refused(.replacementSettled))
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition)?.versionId == old)
        let ended = try #require(try await store.job(id: job.id))
        #expect(ended.state == .failed)
        #expect(ended.failureReason == .replacementContentChanged)
        #expect(try await fixture.rowCount("downloadReplacementIntent") == 0)
    }

    @Test(arguments: [OfflinePublishStep.stagingIntent, .stream, .verify, .rename])
    func restartEndsTheReplacementAsInterruptedAndNeverRollsItForward(_ step: OfflinePublishStep) async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let old = try await fixture.publishedEdition(store)
        #expect(try await store.enqueueReplacement(request(old)) == .queued)
        let job = try #require(try await store.jobs().first)
        _ = try await store.perform(
            .publish(jobID: job.id, pages: [OfflineStoreFixture.imagePage(9)], commitGuard: { _ in true }),
            through: .publish(step)
        )
        let restarted = fixture.makeStore()
        _ = await restarted.reconcile(rollForwardGuard: { _ in true })
        #expect(try await restarted.verifiedEdition(for: OfflineStoreFixture.mangaEdition)?.versionId == old)
        let ended = try #require(try await restarted.job(id: job.id))
        #expect(ended.state == .failed)
        #expect(ended.failureReason == .replacementInterrupted)
        #expect(try await fixture.rowCount("downloadReplacementIntent") == 0)
        #expect(fixture.fileSystem.childNames(of: fixture.versionsURL) == [old])
    }

    @Test func commitGuardRefusalKeepsTheIntentAndRequeuesTheReplacement() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let old = try await fixture.publishedEdition(store)
        #expect(try await store.enqueueReplacement(request(old)) == .queued)
        let refused = try await staging(store)
        #expect(try await store.publish(refused, commitGuard: { _ in false }) == .refused(.staleRuntime))
        let requeued = try #require(try await store.jobs().first)
        #expect(requeued.state == .queued)
        #expect(requeued.stagingVersionId == nil)
        #expect(try await fixture.rowCount("downloadReplacementIntent") == 1)
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition)?.versionId == old)
        #expect(!fixture.fileSystem.childNames(of: fixture.versionsURL).contains(refused.versionId))

        let retried = try await staging(store)
        #expect(try await store.publish(retried, commitGuard: { _ in true }) == .published(versionId: retried.versionId))
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition)?.versionId == retried.versionId)
        #expect(!fixture.fileSystem.exists(fixture.versionURL(old)))
        #expect(try await fixture.rowCount("downloadReplacementIntent") == 0)
    }

    @Test func crashAfterThePublishCommitBeforeTheOldCopyIsReclaimedIsCollectedOnRestart() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let old = try await fixture.publishedEdition(store)
        #expect(try await store.enqueueReplacement(request(old)) == .queued)
        // A reader still holds the old copy, so the commit cannot reclaim it. The process then dies: leases are
        // never persisted, so the restarted store sees nothing holding the old bytes.
        let lease = try await store.openLease(edition: OfflineStoreFixture.mangaEdition)
        let attempt = try await staging(store)
        #expect(try await store.publish(attempt, commitGuard: { _ in true }) == .published(versionId: attempt.versionId))
        #expect(fixture.fileSystem.exists(fixture.versionURL(old)))

        let restarted = fixture.makeStore()
        _ = await restarted.reconcile()
        #expect(!fixture.fileSystem.exists(fixture.versionURL(old)))
        try await fixture.assertInvariants(restarted)
        withExtendedLifetime(lease) {}
    }

    @Test(arguments: ["pointer", "damaged", "epoch", "relink"])
    func aStaleIntentEndsAtTheStartOfItsAttemptWithoutLeavingTheJobQueued(_ change: String) async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let old = try await fixture.publishedEdition(store)
        #expect(try await store.enqueueReplacement(request(old)) == .queued)
        let job = try #require(try await store.jobs().first)
        switch change {
        case "pointer":
            try await fixture.database.dbPool.write { db in
                try db.execute(sql: "UPDATE downloadedChapter SET versionId = ?", arguments: [UUID().uuidString])
            }
        case "damaged":
            try await store.markDamaged(versionId: old, reason: .pageMismatch)
        case "epoch":
            try fixture.rotateEpoch(to: OfflineStoreFixture.rotatedEpoch)
        default:
            try await fixture.database.dbPool.write { db in
                try db.execute(sql: "UPDATE downloadedChapter SET canonicalMediaId = 'relinked'")
            }
        }

        await #expect(throws: OfflineStoreError.replacementSettled(.replacementStale)) {
            try await store.beginAttempt(jobID: job.id)
        }
        let ended = try #require(try await store.job(id: job.id))
        #expect(ended.state == .failed)
        #expect(ended.failureReason == .replacementStale)
        #expect(try await store.nextQueuedJob() == nil)
        #expect(try await fixture.rowCount("downloadReplacementIntent") == 0)
        #expect(fixture.fileSystem.exists(fixture.versionURL(old)))
        #expect(fixture.fileSystem.childNames(of: fixture.stagingURL).isEmpty)
    }

    @Test func retryNeverRestampsAReplacementAndEndsItWhenTheSourceMovedOn() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let old = try await fixture.publishedEdition(store)
        #expect(try await store.enqueueReplacement(request(old)) == .queued)
        let job = try #require(try await store.jobs().first)
        // A restore pauses every job until it is reviewed.
        try await fixture.database.dbPool.write { db in
            try db.execute(sql: "UPDATE downloadJob SET state = 'waiting', waitingReason = 'restoredPendingReview'")
        }
        try fixture.rotateEpoch(to: OfflineStoreFixture.rotatedEpoch)

        try await store.retry(jobID: job.id, currentEpoch: OfflineStoreFixture.rotatedEpoch)

        let ended = try #require(try await store.job(id: job.id))
        #expect(ended.state == .failed)
        #expect(ended.failureReason == .replacementStale)
        #expect(ended.sourceEpoch == OfflineStoreFixture.epoch)
        #expect(try await fixture.rowCount("downloadReplacementIntent") == 0)
        await #expect(throws: OfflineStoreError.jobUnavailable) {
            try await store.retry(jobID: job.id, currentEpoch: OfflineStoreFixture.rotatedEpoch)
        }
        let requeued = try await store.retry(
            jobIDs: [job.id], epochs: ["plugin.test": OfflineStoreFixture.rotatedEpoch]
        )
        #expect(requeued == 0)
        #expect(try await store.job(id: job.id)?.failureReason == .replacementStale)
    }

    @Test func aFreshReplaceSupersedesATerminalRecordWithoutClearingTombstones() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let old = try await fixture.publishedEdition(store)
        #expect(try await store.enqueueReplacement(request(old)) == .queued)
        let first = try #require(try await store.jobs().first)
        try await fixture.database.dbPool.write { db in
            try DownloadSuppressionRecord(
                pluginId: "plugin.test", mediaKind: .manga, canonicalMediaId: "series-1",
                chapterKey: "chapter-9", authorityScope: .publicUnscoped, suppressedAt: OfflineStoreFixture.fixedDate
            ).insert(db)
        }
        #expect(try await store.settleStaleReplacement(jobID: first.id, currentEpoch: "unrelated") == true)

        #expect(try await store.enqueueReplacement(request(old)) == .queued)
        let second = try #require(try await store.jobs().first)
        #expect(second.id != first.id)
        #expect(second.state == .queued)
        #expect(try await fixture.rowCount("downloadReplacementIntent") == 1)
        #expect(try await fixture.rowCount("downloadBatch") == 1)
        #expect(try await fixture.rowCount("downloadSuppression") == 1)
    }

    @Test func aReplacementWithoutRoomForItsOldCopyWaitsAndIsNotReadmittedByTheReserveAlone() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let old = try await fixture.publishedEdition(store)
        let oldBytes = try #require(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition)).byteCount
        #expect(try await store.enqueueReplacement(request(old)) == .queued)
        let job = try #require(try await store.jobs().first)
        fixture.fileSystem.setCapacity(OfflineChapterStore.reserveBytes + oldBytes / 2)
        await #expect(throws: OfflineStoreError.blocked(.insufficientStorage)) {
            try await store.beginAttempt(jobID: job.id)
        }

        // The base reserve is back, but the room for the old copy it replaces is not.
        try await store.readmitWaiting([.insufficientStorage])
        #expect(try await store.job(id: job.id)?.state == .waiting)

        fixture.fileSystem.setCapacity(OfflineChapterStore.reserveBytes + oldBytes)
        try await store.readmitWaiting([.insufficientStorage])
        #expect(try await store.job(id: job.id)?.state == .queued)
    }

    @Test func storageWaitNeverDeletesGoodOldCopy() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let old = try await fixture.publishedEdition(store)
        #expect(try await store.enqueueReplacement(request(old)) == .queued)
        let job = try #require(try await store.jobs().first)
        fixture.fileSystem.setCapacity(OfflineChapterStore.reserveBytes)
        await #expect(throws: OfflineStoreError.blocked(.insufficientStorage)) {
            try await store.beginAttempt(jobID: job.id)
        }
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition)?.versionId == old)
        #expect(fixture.fileSystem.exists(fixture.versionURL(old)))
        #expect(try await store.job(id: job.id)?.waitingReason == .insufficientStorage)
    }
}
