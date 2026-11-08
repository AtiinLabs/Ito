import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

struct OfflineChapterStoreReconciliationTests {
    private static func inventoryRow(_ fixture: OfflineStoreFixture, chapterKey: String = "chapter-1") throws -> DownloadedChapterRecord? {
        try fixture.database.dbPool.read { db in
            try DownloadedChapterRecord.filter(
                OfflineChapterEdition(
                    pluginId: "plugin.test",
                    mediaKind: .manga,
                    canonicalMediaId: "series-1",
                    chapterKey: chapterKey
                ).predicate
            ).fetchOne(db)
        }
    }

    @Test func protectedDataUnavailableDefersWithoutDeletingOrMarkingAnything() async throws {
        let fixture = try OfflineStoreFixture()
        let crashed = fixture.makeStore()
        let jobID = try await fixture.enqueue(crashed)
        let attempt = try await crashed.beginAttempt(jobID: jobID)
        try await attempt.append(OfflineStoreFixture.imagePage(0))
        // The first instance is dropped here, as after a crash.
        await fixture.protectedData.setAvailable(false)

        let restarted = fixture.makeStore()
        let deferred = await restarted.reconcile()

        #expect(deferred == .deferred)
        #expect(fixture.fileSystem.exists(attempt.directory))
        #expect(try await restarted.job(id: jobID)?.state == .downloading)

        await fixture.protectedData.setAvailable(true)
        let completed = await restarted.reconcile()
        guard case .completed(let details) = completed else {
            Issue.record("Expected reconciliation to complete, got \(completed)")
            return
        }
        #expect(details.requeuedJobs == 1)
        #expect(try await restarted.job(id: jobID)?.state == .queued)
        #expect(!fixture.fileSystem.exists(attempt.directory))
    }

    @Test func lockedFileSystemDefersAndLeavesVerifiedCopiesIntact() async throws {
        let fixture = try OfflineStoreFixture()
        let first = fixture.makeStore()
        let versionId = try await fixture.publishedEdition(first)

        let restarted = fixture.makeStore()
        fixture.fileSystem.setLocked(true)
        let deferred = await restarted.reconcile()
        fixture.fileSystem.setLocked(false)

        #expect(deferred == .deferred)
        #expect(fixture.fileSystem.exists(fixture.versionURL(versionId)))
        #expect(try Self.inventoryRow(fixture)?.state == .verified)

        let completed = await restarted.reconcile()
        #expect(completed == .completed(OfflineReconcileDetails()))
    }

    @Test func missingVersionDirectoryRemovesItsRow() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let versionId = try await fixture.publishedEdition(store)
        try fixture.fileSystem.removeItem(at: fixture.versionURL(versionId))

        let restarted = fixture.makeStore()
        let report = await restarted.reconcile()

        guard case .completed(let details) = report else {
            Issue.record("Expected completion, got \(report)")
            return
        }
        #expect(details.removedRows == 1)
        #expect(try Self.inventoryRow(fixture) == nil)
    }

    @Test func tamperedManifestMarksTheCopyDamagedAndOpeningRefuses() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let versionId = try await fixture.publishedEdition(store)
        fixture.fileSystem.replaceFile(
            at: fixture.versionURL(versionId).appendingPathComponent(OfflineChapterManifest.fileName),
            with: Data("tampered".utf8)
        )

        let restarted = fixture.makeStore()
        let report = await restarted.reconcile()

        guard case .completed(let details) = report else {
            Issue.record("Expected completion, got \(report)")
            return
        }
        #expect(details.damagedRows == 1)
        let row = try #require(try Self.inventoryRow(fixture))
        #expect(row.state == .damaged)
        #expect(row.damageReason == .manifestMismatch)
        #expect(try await restarted.verifiedEdition(for: OfflineStoreFixture.mangaEdition) == nil)

        await #expect(throws: OfflineStoreError.damaged(.manifestMismatch)) {
            try await restarted.openLease(edition: OfflineStoreFixture.mangaEdition)
        }
    }

    @Test func markDamagedOnlyAffectsTheVersionTheRowStillReferences() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let versionId = try await fixture.publishedEdition(store)

        try await store.markDamaged(versionId: "some-other-version", reason: .pageMismatch)
        #expect(try Self.inventoryRow(fixture)?.state == .verified)

        try await store.markDamaged(versionId: versionId, reason: .pageMismatch)
        let row = try #require(try Self.inventoryRow(fixture))
        #expect(row.state == .damaged)
        #expect(row.damageReason == .pageMismatch)
    }

    @Test func orphanedStagingTrashAndUnreferencedVersionsAreCollected() async throws {
        let fixture = try OfflineStoreFixture()
        let first = fixture.makeStore()
        _ = await first.reconcile()
        try fixture.fileSystem.createDirectory(fixture.stagingURL.appendingPathComponent("orphan-staging"))
        try fixture.fileSystem.writeFile(
            Data("partial".utf8),
            to: fixture.stagingURL.appendingPathComponent("orphan-staging/p0000.jpg")
        )
        try fixture.fileSystem.createDirectory(fixture.trashURL.appendingPathComponent("orphan-trash"))
        try fixture.fileSystem.createDirectory(fixture.versionURL("ghost-version"))
        try fixture.fileSystem.writeFile(
            Data("{}".utf8),
            to: fixture.versionURL("ghost-version").appendingPathComponent(OfflineChapterManifest.fileName)
        )

        let restarted = fixture.makeStore()
        let report = await restarted.reconcile()

        guard case .completed(let details) = report else {
            Issue.record("Expected completion, got \(report)")
            return
        }
        #expect(details.removedStagingDirectories == 1)
        #expect(details.removedTrashItems == 1)
        #expect(details.reclaimedVersions == 1)
        try await fixture.assertInvariants(restarted)
    }

    @Test func restoredDatabaseWithAForeignMarkerPausesJobsAndKeepsValidCopies() async throws {
        let fixture = try OfflineStoreFixture()
        let original = fixture.makeStore()
        _ = try await fixture.publishedEdition(original, chapterKey: "chapter-1")
        let queuedJobID = try await fixture.enqueue(original, chapterKey: "chapter-2")
        _ = try await original.beginAttempt(jobID: queuedJobID)
        try fixture.fileSystem.writeFile(Data("another-installation".utf8), to: fixture.storeIdentifierURL)

        let restored = fixture.makeStore()
        let report = await restored.reconcile()

        guard case .completed(let details) = report else {
            Issue.record("Expected completion, got \(report)")
            return
        }
        #expect(details.restoredJobs == 1)
        let job = try #require(try await restored.job(id: queuedJobID))
        #expect(job.state == .waiting)
        #expect(job.waitingReason == .restoredPendingReview)
        #expect(try await restored.verifiedEdition(for: OfflineStoreFixture.mangaEdition) != nil)

        let storedID = try await fixture.database.dbPool.read { db in
            try DownloadStoreRecord.fetchOne(db)?.storeId
        }
        let markerID = try #require(fixture.fileSystem.fileData(at: fixture.storeIdentifierURL))
        #expect(String(bytes: markerID, encoding: .utf8) == storedID)
        try await fixture.assertInvariants(restored)
    }

    @Test func restoredDatabaseWithAMissingMarkerPausesJobs() async throws {
        let fixture = try OfflineStoreFixture()
        let original = fixture.makeStore()
        let jobID = try await fixture.enqueue(original)
        try fixture.fileSystem.removeItem(at: fixture.storeIdentifierURL)

        let restored = fixture.makeStore()
        _ = await restored.reconcile()

        let job = try #require(try await restored.job(id: jobID))
        #expect(job.state == .waiting)
        #expect(job.waitingReason == .restoredPendingReview)
    }

    @Test func reconciliationRunsOncePerInstanceAndReturnsTheCachedReport() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let first = await store.reconcile()
        #expect(first == .completed(OfflineReconcileDetails()))

        // An orphan appears after the run. The same instance must not recover again.
        try fixture.fileSystem.createDirectory(fixture.trashURL.appendingPathComponent("late-trash"))
        let second = await store.reconcile()

        #expect(second == first)
        #expect(fixture.fileSystem.childNames(of: fixture.trashURL) == ["late-trash"])
    }

    @Test func reconciliationIsIdempotentAcrossInstancesAndBindsTheInstallationOnce() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)

        let restarted = fixture.makeStore()
        let report = await restarted.reconcile()

        #expect(report == .completed(OfflineReconcileDetails()))
        let storeRows = try await fixture.database.dbPool.read { db in
            try DownloadStoreRecord.fetchCount(db)
        }
        #expect(storeRows == 1)
        #expect(fixture.fileSystem.fileData(at: fixture.storeIdentifierURL) != nil)
    }
}
