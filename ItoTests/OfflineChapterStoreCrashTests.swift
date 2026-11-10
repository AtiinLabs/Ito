import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// Each test stops the protocol after one step, drops the store without cleanup, and starts a new
/// store instance on the same database and filesystem. A new instance is the only restart:
/// crash recovery runs at most once per instance.
struct OfflineChapterStoreCrashTests {
    private static let pages = [
        OfflineStoreFixture.imagePage(0),
        OfflineStoreFixture.imagePage(1),
        OfflineStoreFixture.imagePage(2)
    ]

    @Test(arguments: OfflinePublishStep.allCases)
    func crashAfterEachPublishStepRecoversToAConsistentState(step: OfflinePublishStep) async throws {
        let fixture = try OfflineStoreFixture()
        let crashed = fixture.makeStore()
        let jobID = try await fixture.enqueue(crashed)

        let halted = try await crashed.perform(
            .publish(jobID: jobID, pages: Self.pages, commitGuard: { _ in true }),
            through: .publish(step)
        )

        let restarted = fixture.makeStore()
        let report = await restarted.reconcile(rollForwardGuard: { _ in true })
        guard case .completed = report else {
            Issue.record("Reconciliation after \(step) did not complete: \(report)")
            return
        }

        switch step {
        case .stagingIntent, .stream, .verify:
            #expect(halted == nil)
            #expect(try await restarted.verifiedEdition(for: OfflineStoreFixture.mangaEdition) == nil)
            #expect(try await restarted.job(id: jobID)?.state == .queued)
        case .rename:
            #expect(halted == nil)
            #expect(try await restarted.verifiedEdition(for: OfflineStoreFixture.mangaEdition) != nil)
            #expect(try await restarted.job(id: jobID) == nil)
        case .commit:
            #expect(halted == .published(versionId: fixture.fileSystem.childNames(of: fixture.versionsURL)[0]))
            #expect(try await restarted.verifiedEdition(for: OfflineStoreFixture.mangaEdition) != nil)
            #expect(try await restarted.job(id: jobID) == nil)
        }
        try await fixture.assertInvariants(restarted)
    }

    @Test func rollForwardWithoutTheCommitGuardRequeuesTheChapter() async throws {
        let fixture = try OfflineStoreFixture()
        let crashed = fixture.makeStore()
        let jobID = try await fixture.enqueue(crashed)
        _ = try await crashed.perform(
            .publish(jobID: jobID, pages: Self.pages, commitGuard: { _ in true }),
            through: .publish(.rename)
        )

        let restarted = fixture.makeStore()
        let report = await restarted.reconcile()

        guard case .completed(let details) = report else {
            Issue.record("Reconciliation did not complete: \(report)")
            return
        }
        #expect(details.requeuedJobs == 1)
        #expect(details.rolledForward == 0)
        #expect(try await restarted.verifiedEdition(for: OfflineStoreFixture.mangaEdition) == nil)
        let job = try #require(try await restarted.job(id: jobID))
        #expect(job.state == .queued)
        #expect(job.stagingVersionId == nil)
        #expect(fixture.fileSystem.childNames(of: fixture.versionsURL).isEmpty)
        try await fixture.assertInvariants(restarted)
    }

    @Test func corruptedPageAfterRenameIsDiscardedAndTheJobRequeued() async throws {
        let fixture = try OfflineStoreFixture()
        let crashed = fixture.makeStore()
        let jobID = try await fixture.enqueue(crashed)
        _ = try await crashed.perform(
            .publish(jobID: jobID, pages: Self.pages, commitGuard: { _ in true }),
            through: .publish(.rename)
        )
        let versionId = try #require(fixture.fileSystem.childNames(of: fixture.versionsURL).first)
        let damagedPage = fixture.versionURL(versionId)
            .appendingPathComponent(OfflinePageFileName.make(index: 1, fileExtension: "jpg"))
        fixture.fileSystem.replaceFile(at: damagedPage, with: Data("not the staged bytes".utf8))

        let restarted = fixture.makeStore()
        _ = await restarted.reconcile(rollForwardGuard: { _ in true })

        #expect(try await restarted.verifiedEdition(for: OfflineStoreFixture.mangaEdition) == nil)
        #expect(try await restarted.job(id: jobID)?.state == .queued)
        try await fixture.assertInvariants(restarted)
    }

    @Test func undecodableSnapshotDuringRollForwardDiscardsTheVersionAndFailsTheJob() async throws {
        let fixture = try OfflineStoreFixture()
        let crashed = fixture.makeStore()
        let jobID = try await fixture.enqueue(crashed)
        _ = try await crashed.perform(
            .publish(jobID: jobID, pages: Self.pages, commitGuard: { _ in true }),
            through: .publish(.rename)
        )
        try await fixture.database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE downloadJob SET chapterSnapshot = ? WHERE id = ?",
                arguments: [Data([0x00]), jobID]
            )
        }

        let restarted = fixture.makeStore()
        let report = await restarted.reconcile(rollForwardGuard: { _ in true })

        guard case .completed(let details) = report else {
            Issue.record("Reconciliation must not abort on one job, got \(report)")
            return
        }
        #expect(details.discardedVersions == 1)
        let job = try #require(try await restarted.job(id: jobID))
        #expect(job.state == .failed)
        #expect(job.failureReason == .integrityMismatch)
        #expect(try await restarted.verifiedEdition(for: OfflineStoreFixture.mangaEdition) == nil)
        try await fixture.assertInvariants(restarted)
    }

    /// A commit that fails inside its transaction for a reason other than the database records
    /// the outcome at once, instead of leaving the job downloading until the next launch.
    @Test func aLiveCommitThatCannotReadItsSnapshotFailsTheJobAndDiscardsTheVersion() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        try await fixture.database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE downloadJob SET chapterSnapshot = ? WHERE id = ?",
                arguments: [Data([0x00]), jobID]
            )
        }

        let outcome = try await store.perform(
            .publish(jobID: jobID, pages: Self.pages, commitGuard: { _ in true }),
            through: .all
        )

        #expect(outcome == .discarded(.failed(.integrityMismatch)))
        let job = try #require(try await store.job(id: jobID))
        #expect(job.state == .failed)
        #expect(job.failureReason == .integrityMismatch)
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition) == nil)
        try await fixture.assertInvariants(store)
    }

    @Test func renameFailureDiscardsStagingAndFailsTheJob() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        fixture.fileSystem.failNext(.moveItem, pathContaining: "/versions/", with: .other)

        let outcome = try await store.perform(
            .publish(jobID: jobID, pages: Self.pages, commitGuard: { _ in true }),
            through: .all
        )

        #expect(outcome == .discarded(.failed(.fileSystem)))
        let job = try #require(try await store.job(id: jobID))
        #expect(job.state == .failed)
        #expect(job.failureReason == .fileSystem)
        try await fixture.assertInvariants(store)
    }

    @Test func aFailedJobIsRetriedOnlyByAnExplicitRetry() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store)
        fixture.fileSystem.failNext(.moveItem, pathContaining: "/versions/", with: .other)
        _ = try await store.perform(
            .publish(jobID: jobID, pages: Self.pages, commitGuard: { _ in true }),
            through: .all
        )

        try await store.readmitWaiting([.insufficientStorage, .protectedDataUnavailable])
        #expect(try await store.job(id: jobID)?.state == .failed)

        try await store.retry(jobID: jobID, currentEpoch: OfflineStoreFixture.epoch)
        #expect(try await store.job(id: jobID)?.state == .queued)
    }

    @Test(arguments: OfflineDeleteStep.allCases)
    func crashAfterEachDeleteStepLeavesNoRowNoJobAndNoBytes(step: OfflineDeleteStep) async throws {
        let fixture = try OfflineStoreFixture()
        let crashed = fixture.makeStore()
        _ = try await fixture.publishedEdition(crashed)

        _ = try await crashed.perform(.delete(OfflineStoreFixture.mangaEdition), through: .delete(step))

        let restarted = fixture.makeStore()
        let report = await restarted.reconcile()
        guard case .completed = report else {
            Issue.record("Reconciliation after \(step) did not complete: \(report)")
            return
        }

        #expect(try await restarted.verifiedEdition(for: OfflineStoreFixture.mangaEdition) == nil)
        #expect(try await restarted.jobs().isEmpty)
        #expect(fixture.fileSystem.childNames(of: fixture.versionsURL).isEmpty)
        #expect(fixture.fileSystem.childNames(of: fixture.trashURL).isEmpty)
        try await fixture.assertInvariants(restarted)
    }

    /// Two copies and two queued jobs, one of them mid-attempt with a staging directory, all deleted in one
    /// transaction and then the process dies after `step`.
    @Test(arguments: OfflineDeleteStep.allCases)
    func crashAfterEachBulkDeleteStepLeavesNoRowNoJobNoBatchAndNoBytes(step: OfflineDeleteStep) async throws {
        let fixture = try OfflineStoreFixture()
        let crashed = fixture.makeStore()
        _ = try await fixture.publishedEdition(crashed, chapterKey: "a")
        _ = try await fixture.publishedEdition(crashed, chapterKey: "b")
        let queued = try await fixture.enqueueBatch(crashed, chapterKeys: ["q1", "q2"])
        let attempt = try await crashed.beginAttempt(jobID: queued[0])
        try await attempt.append(OfflineStoreFixture.imagePage(0))
        let editions = ["a", "b", "q1", "q2"].map {
            OfflineChapterEdition(pluginId: "plugin.test", mediaKind: .manga, canonicalMediaId: "series-1", chapterKey: $0)
        }

        _ = try await crashed.perform(.deleteScope(.editions(editions), suppress: true), through: .delete(step))

        try await Self.assertBulkDeleteSettled(fixture, step: step)
    }

    @Test(arguments: OfflineDeleteStep.allCases)
    func crashAfterEachSeriesDeleteStepLeavesNoRowNoJobNoBatchAndNoBytes(step: OfflineDeleteStep) async throws {
        let fixture = try OfflineStoreFixture()
        let crashed = fixture.makeStore()
        _ = try await fixture.publishedEdition(crashed, chapterKey: "a")
        _ = try await fixture.publishedEdition(crashed, chapterKey: "b")
        let queued = try await fixture.enqueueBatch(crashed, chapterKeys: ["q1", "q2"])
        let attempt = try await crashed.beginAttempt(jobID: queued[0])
        try await attempt.append(OfflineStoreFixture.imagePage(0))
        let series = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)

        _ = try await crashed.perform(.deleteScope(.media(series), suppress: true), through: .delete(step))

        try await Self.assertBulkDeleteSettled(fixture, step: step)
    }

    /// After the crash, the first transaction's effects are all in or all out: here all in. The next launch
    /// removes every version, staging directory and trash item the dead process left behind.
    private static func assertBulkDeleteSettled(_ fixture: OfflineStoreFixture, step: OfflineDeleteStep) async throws {
        let restarted = fixture.makeStore()
        let report = await restarted.reconcile()
        guard case .completed = report else {
            Issue.record("Reconciliation after \(step) did not complete: \(report)")
            return
        }

        #expect(try await fixture.rowCount("downloadedChapter") == 0)
        #expect(try await restarted.jobs().isEmpty)
        #expect(try await fixture.rowCount("downloadBatch") == 0)
        // The suppression was committed with the rows, so it survives the crash: copies only, never jobs.
        let suppressed = try await fixture.database.dbPool.read { db in
            try DownloadSuppressionRecord.fetchAll(db).map(\.chapterKey).sorted()
        }
        #expect(suppressed == ["a", "b"])
        #expect(fixture.fileSystem.childNames(of: fixture.versionsURL).isEmpty)
        #expect(fixture.fileSystem.childNames(of: fixture.stagingURL).isEmpty)
        #expect(fixture.fileSystem.childNames(of: fixture.trashURL).isEmpty)
        try await fixture.assertInvariants(restarted)
    }
}
