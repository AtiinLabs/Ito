import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

struct OfflineChapterStoreQueueTests {
    @Test func enqueueBeforeReconciliationIsRefusedSoJobsCanOnlyMeanARestore() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()

        await #expect(throws: OfflineStoreError.reconciliationPending) {
            try await store.enqueue(OfflineStoreFixture.request())
        }
        #expect(try await store.jobs().isEmpty)
    }

    @Test func enqueueRefusesPaywalledUnsupportedAndUnboundRequests() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = await store.reconcile()

        let paywalled = try await store.enqueue(OfflineStoreFixture.request(paywalled: true))
        let anime = try await store.enqueue(OfflineStoreFixture.request(mediaKind: .anime))
        let unbound = try await store.enqueue(OfflineStoreFixture.request(sourceEpoch: nil))

        #expect(paywalled == .refused(.paywalled))
        #expect(anime == .refused(.unsupportedKind))
        #expect(unbound == .refused(.unavailable))
        #expect(try await store.jobs().isEmpty)
    }

    @Test func duplicateEnqueueIsAlreadyQueuedAndVerifiedEditionIsAlreadyDownloaded() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)

        let duplicate = try await store.enqueue(OfflineStoreFixture.request())
        #expect(duplicate == .alreadyQueued)

        _ = try await store.perform(
            .publish(jobID: jobID, pages: [OfflineStoreFixture.imagePage(0)], commitGuard: { _ in true }),
            through: .all
        )
        let downloaded = try await store.enqueue(OfflineStoreFixture.request())
        #expect(downloaded == .alreadyDownloaded)
    }

    @Test func successfulPublishCommitsInventoryWithoutURLsAndDeletesTheJob() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let versionId = try await fixture.publishedEdition(store)

        let row = try #require(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition))
        #expect(row.versionId == versionId)
        #expect(row.state == .verified)
        #expect(row.pageCount == 3)
        #expect(row.byteCount == 33)
        #expect(row.contentKind == .images)
        #expect(row.sourceEpoch == OfflineStoreFixture.epoch)
        #expect(row.seriesTitle == "Series One")

        let chapter = try JSONDecoder().decode(Chapter.self, from: row.chapterSnapshot)
        #expect(chapter.key == "chapter-1")
        #expect(chapter.url == nil)
        #expect(chapter.paywalled == nil)

        #expect(try await store.jobs().isEmpty)
        try await fixture.assertInvariants(store)
    }

    @Test func mixedTextAndImagePagesAreStoredAsMixedContent() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store, chapterKey: "novel-1")

        let outcome = try await store.perform(
            .publish(
                jobID: jobID,
                pages: [OfflineStoreFixture.textPage(0, "Chapter text."), OfflineStoreFixture.imagePage(1)],
                commitGuard: { _ in true }
            ),
            through: .all
        )

        guard case .published(let versionId)? = outcome else {
            Issue.record("Expected a published version, got \(String(describing: outcome))")
            return
        }
        let row = try #require(try await store.verifiedEdition(for: OfflineChapterEdition(
            pluginId: "plugin.test",
            mediaKind: .manga,
            canonicalMediaId: "series-1",
            chapterKey: "novel-1"
        )))
        #expect(row.contentKind == .mixed)
        #expect(row.pageCount == 2)
        #expect(fixture.fileSystem.exists(fixture.versionURL(versionId).appendingPathComponent("p0000.txt")))
        try await fixture.assertInvariants(store)
    }

    @Test func beginAttemptBeforeReconciliationIsRefusedForAJobFromAnEarlierInstance() async throws {
        let fixture = try OfflineStoreFixture()
        let earlier = fixture.makeStore()
        let jobID = try await fixture.enqueue(earlier)

        let restarted = fixture.makeStore()
        await #expect(throws: OfflineStoreError.reconciliationPending) {
            try await restarted.beginAttempt(jobID: jobID)
        }
        #expect(try await restarted.job(id: jobID)?.state == .queued)
    }

    @Test func onlyAQueuedJobStartsAnAttempt() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        try await store.setWaiting(jobID: jobID, reason: .noConnection)

        await #expect(throws: OfflineStoreError.jobUnavailable) {
            try await store.beginAttempt(jobID: jobID)
        }
        #expect(try await store.job(id: jobID)?.waitingReason == .noConnection)
    }

    @Test func cancelRemovesTheJobAndItsStagingDirectory() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        let attempt = try await store.beginAttempt(jobID: jobID)
        try await attempt.append(OfflineStoreFixture.imagePage(0))

        try await store.cancel(jobID: jobID)

        #expect(try await store.job(id: jobID) == nil)
        #expect(!fixture.fileSystem.exists(attempt.directory))
        let late = try await store.publish(attempt, commitGuard: { _ in true })
        #expect(late == .refused(.jobGone))
        #expect(fixture.fileSystem.childNames(of: fixture.versionsURL).isEmpty)
    }

    @Test func lateCommitAfterDeleteCannotResurrectTheChapter() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        let attempt = try await store.beginAttempt(jobID: jobID)
        for index in 0..<3 {
            try await attempt.append(OfflineStoreFixture.imagePage(Int32(index)))
        }

        // The gate before the last asset: the user deletes the queued chapter.
        try await store.delete(OfflineStoreFixture.mangaEdition)
        let late = try await store.publish(attempt, commitGuard: { _ in true })

        #expect(late == .refused(.jobGone))
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition) == nil)
        #expect(fixture.fileSystem.childNames(of: fixture.versionsURL).isEmpty)
        #expect(fixture.fileSystem.childNames(of: fixture.stagingURL).isEmpty)
        try await fixture.assertInvariants(store)
    }

    @Test func rotatedSourceEpochInTheDatabaseRefusesTheCommitAndWaitsForRetry() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        let attempt = try await store.beginAttempt(jobID: jobID)
        for index in 0..<3 {
            try await attempt.append(OfflineStoreFixture.imagePage(Int32(index)))
        }
        try fixture.rotateEpoch(to: OfflineStoreFixture.rotatedEpoch)

        let outcome = try await store.publish(attempt, commitGuard: { _ in true })

        #expect(outcome == .refused(.configurationChanged))
        let job = try #require(try await store.job(id: jobID))
        #expect(job.state == .waiting)
        #expect(job.waitingReason == .sourceConfigurationChanged)
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition) == nil)
        #expect(fixture.fileSystem.childNames(of: fixture.versionsURL).isEmpty)
        try await fixture.assertInvariants(store)
    }

    @Test func inMemoryGuardRefusalRequeuesTheChapter() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        let attempt = try await store.beginAttempt(jobID: jobID)
        for index in 0..<3 {
            try await attempt.append(OfflineStoreFixture.imagePage(Int32(index)))
        }

        let outcome = try await store.publish(attempt, commitGuard: { _ in false })

        #expect(outcome == .refused(.staleRuntime))
        let job = try #require(try await store.job(id: jobID))
        #expect(job.state == .queued)
        #expect(job.waitingReason == nil)
        #expect(job.stagingVersionId == nil)
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition) == nil)
        try await fixture.assertInvariants(store)
    }

    @Test func refusedCommitKeepsBytesWhileARowStillReferencesTheVersion() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        let attempt = try await store.beginAttempt(jobID: jobID)
        for index in 0..<3 {
            try await attempt.append(OfflineStoreFixture.imagePage(Int32(index)))
        }
        // A row for another edition references this attempt's version, inserted out of band.
        try await fixture.database.dbPool.write { db in
            try DownloadedChapterRecord(
                pluginId: "plugin.test",
                mediaKind: .manga,
                canonicalMediaId: "series-1",
                chapterKey: "chapter-9",
                authorityScope: .publicUnscoped,
                versionId: attempt.versionId,
                state: .verified,
                damageReason: nil,
                contentKind: .images,
                pageCount: 3,
                byteCount: 33,
                manifestFormatVersion: 1,
                manifestSHA256: String(repeating: "c", count: 64),
                chapterSnapshot: Data("{}".utf8),
                seriesTitle: "Series One",
                sourceEpoch: nil,
                verifiedAt: OfflineStoreFixture.fixedDate
            ).insert(db)
        }

        let outcome = try await store.publish(attempt, commitGuard: { _ in false })

        #expect(outcome == .refused(.staleRuntime))
        #expect(fixture.fileSystem.exists(fixture.versionURL(attempt.versionId)))
        #expect(try await store.job(id: jobID)?.state == .queued)
    }

    @Test func abandonAfterASuccessfulPublishLeavesTheVerifiedCopyIntact() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        let attempt = try await store.beginAttempt(jobID: jobID)
        for index in 0..<3 {
            try await attempt.append(OfflineStoreFixture.imagePage(Int32(index)))
        }
        let outcome = try await store.publish(attempt, commitGuard: { _ in true })
        #expect(outcome == .published(versionId: attempt.versionId))

        try await store.abandonAttempt(jobID: jobID, versionId: attempt.versionId, outcome: .failed(.fileSystem))

        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition) != nil)
        #expect(fixture.fileSystem.exists(fixture.versionURL(attempt.versionId)))
        #expect(try await store.job(id: jobID) == nil)
        try await fixture.assertInvariants(store)
    }

    @Test func abandonAfterTheJobVanishedReleasesTheStagingDirectory() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        let attempt = try await store.beginAttempt(jobID: jobID)
        // The rows go without the store's staging cleanup, as when a Cancel lands before the staging
        // directory exists and so cannot see it. Like every job-removing transaction, the Cancel also
        // removes the batch it empties.
        _ = try await fixture.database.dbPool.write { db in
            let batchId = try DownloadJobRecord.fetchOne(db, key: jobID)?.batchId
            try DownloadJobRecord.deleteOne(db, key: jobID)
            try db.execute(sql: "DELETE FROM downloadBatch WHERE id = ?", arguments: [batchId])
        }

        try await store.abandonAttempt(jobID: jobID, versionId: attempt.versionId, outcome: .queued)

        #expect(!fixture.fileSystem.exists(attempt.directory))
        #expect(try await store.job(id: jobID) == nil)
        try await fixture.assertInvariants(store)
    }

    @Test func abandonOfAnAttemptThisInstanceDoesNotOwnChangesNothing() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        let attempt = try await store.beginAttempt(jobID: jobID)
        try await attempt.append(OfflineStoreFixture.imagePage(0))

        try await store.abandonAttempt(jobID: jobID, versionId: "not-this-attempt", outcome: .queued)

        #expect(fixture.fileSystem.exists(attempt.directory))
        #expect(try await store.job(id: jobID)?.stagingVersionId == attempt.versionId)
        #expect(try await store.job(id: jobID)?.state == .downloading)
    }

    @Test func collectionNeverRemovesALiveAttemptsStaging() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        let attempt = try await store.beginAttempt(jobID: jobID)
        try await attempt.append(OfflineStoreFixture.imagePage(0))

        let report = try await store.collectGarbage()

        #expect(report == OfflineCollectionReport())
        #expect(fixture.fileSystem.exists(attempt.directory))
    }

    @Test func pluginRemovedMidAttemptWaitsForRetryAndRetryRefreezesTheEpoch() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        let attempt = try await store.beginAttempt(jobID: jobID)
        try await attempt.append(OfflineStoreFixture.imagePage(0))

        try await store.abandonAttempt(
            jobID: jobID,
            versionId: attempt.versionId,
            outcome: .waiting(.sourceUnavailable)
        )

        let waiting = try #require(try await store.job(id: jobID))
        #expect(waiting.state == .waiting)
        #expect(waiting.waitingReason == .sourceUnavailable)
        #expect(waiting.stagingVersionId == nil)
        #expect(!fixture.fileSystem.exists(attempt.directory))

        try await store.retry(jobID: jobID, currentEpoch: "epoch-b")
        let retried = try #require(try await store.job(id: jobID))
        #expect(retried.state == .queued)
        #expect(retried.waitingReason == nil)
        #expect(retried.sourceEpoch == "epoch-b")
    }

    @Test func retryRequiredReasonsAreNeverReplacedOrClearedByEvents() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        try await store.setWaiting(jobID: jobID, reason: .sourceUnavailable)

        // Neither a later event nor a different pause reason replaces a retry-required reason.
        try await store.setWaiting(jobID: jobID, reason: .noConnection)
        try await store.readmitWaiting([.sourceUnavailable, .noConnection])

        let job = try #require(try await store.job(id: jobID))
        #expect(job.state == .waiting)
        #expect(job.waitingReason == .sourceUnavailable)
    }

    @Test func readmitClearsOnlyTheListedEventReasons() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let storageJob = try await fixture.enqueue(store, chapterKey: "chapter-1")
        let sourceJob = try await fixture.enqueue(store, chapterKey: "chapter-2")
        try await store.setWaiting(jobID: storageJob, reason: .insufficientStorage)
        try await store.setWaiting(jobID: sourceJob, reason: .sourceUnavailable)

        try await store.readmitWaiting([.insufficientStorage, .sourceUnavailable])

        #expect(try await store.job(id: storageJob)?.state == .queued)
        #expect(try await store.job(id: sourceJob)?.waitingReason == .sourceUnavailable)
    }

    @Test func jobsAreReturnedOldestFirstByCreationTime() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let first = try await fixture.enqueue(store, chapterKey: "chapter-1")
        let second = try await fixture.enqueue(store, chapterKey: "chapter-2")
        // Both jobs share the fixed clock, so move the first one's creation time later.
        try await fixture.database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE downloadJob SET createdAt = ? WHERE id = ?",
                arguments: [Date(timeIntervalSince1970: 5_000), first]
            )
        }

        #expect(try await store.jobs().map(\.id) == [second, first])
    }
}
