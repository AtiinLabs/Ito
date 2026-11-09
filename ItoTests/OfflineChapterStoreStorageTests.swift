import Foundation
import Testing
import ito_runner
@testable import Ito

struct OfflineChapterStoreStorageTests {
    @Test func capacityBelowReserveBlocksAttemptBeforeAnyStagingWrite() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = await store.reconcile()
        let jobID = try await fixture.enqueue(store)
        fixture.fileSystem.setCapacity(OfflineChapterStore.reserveBytes - 1)

        await #expect(throws: OfflineStoreError.blocked(.insufficientStorage)) {
            try await store.beginAttempt(jobID: jobID)
        }

        #expect(try await store.job(id: jobID)?.state == .waiting)
        #expect(try await store.job(id: jobID)?.waitingReason == .insufficientStorage)
        #expect(fixture.fileSystem.childNames(of: fixture.stagingURL).isEmpty)
    }

    @Test func capacityAtTheReserveAllowsAnAttemptToStart() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = await store.reconcile()
        let jobID = try await fixture.enqueue(store)
        fixture.fileSystem.setCapacity(OfflineChapterStore.reserveBytes)

        let attempt = try await store.beginAttempt(jobID: jobID)

        #expect(try await store.job(id: jobID)?.state == .downloading)
        #expect(fixture.fileSystem.exists(attempt.directory))
    }

    @Test func noSpaceMidAssetDiscardsStagingAndLeavesVerifiedEditionsUntouched() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1")
        let jobID = try await fixture.enqueue(store, chapterKey: "chapter-2")
        let attempt = try await store.beginAttempt(jobID: jobID)
        try await attempt.append(OfflineStoreFixture.imagePage(0))
        fixture.fileSystem.failNext(.writeFile, pathContaining: "/staging/", with: .noSpace)

        await #expect(throws: OfflineFileSystemError.noSpace) {
            try await attempt.append(OfflineStoreFixture.imagePage(1))
        }
        try await store.abandonAttempt(
            jobID: jobID,
            versionId: attempt.versionId,
            outcome: .waiting(.insufficientStorage)
        )

        let job = try #require(try await store.job(id: jobID))
        #expect(job.state == .waiting)
        #expect(job.waitingReason == .insufficientStorage)
        #expect(!fixture.fileSystem.exists(attempt.directory))
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition) != nil)
        try await fixture.assertInvariants(store)
    }

    @Test func aStorageChangeReadmitsTheJobAndTheNextAttemptStarts() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = await store.reconcile()
        let jobID = try await fixture.enqueue(store)
        fixture.fileSystem.setCapacity(0)
        await #expect(throws: OfflineStoreError.blocked(.insufficientStorage)) {
            try await store.beginAttempt(jobID: jobID)
        }

        fixture.fileSystem.setCapacity(OfflineChapterStore.reserveBytes * 4)
        try await store.readmitWaiting([.insufficientStorage])
        _ = try await store.beginAttempt(jobID: jobID)

        #expect(try await store.job(id: jobID)?.state == .downloading)
    }

    @Test func protectedDataUnavailableBlocksTheAttemptAsWaiting() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = await store.reconcile()
        let jobID = try await fixture.enqueue(store)
        await fixture.protectedData.setAvailable(false)

        await #expect(throws: OfflineStoreError.blocked(.protectedDataUnavailable)) {
            try await store.beginAttempt(jobID: jobID)
        }

        #expect(try await store.job(id: jobID)?.waitingReason == .protectedDataUnavailable)
        #expect(fixture.fileSystem.childNames(of: fixture.stagingURL).isEmpty)
    }

    @Test func lockedDeviceDuringRenameWaitsForUnlockAndKeepsVerifiedCopies() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1")
        let jobID = try await fixture.enqueue(store, chapterKey: "chapter-2")
        fixture.fileSystem.failNext(.moveItem, pathContaining: "/versions/", with: .permissionDenied)

        let outcome = try await store.perform(
            .publish(
                jobID: jobID,
                pages: [OfflineStoreFixture.imagePage(0)],
                commitGuard: { _ in true }
            ),
            through: .all
        )

        #expect(outcome == .discarded(.waiting(.protectedDataUnavailable)))
        #expect(try await store.job(id: jobID)?.waitingReason == .protectedDataUnavailable)
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition) != nil)

        try await store.readmitWaiting([.protectedDataUnavailable])
        #expect(try await store.job(id: jobID)?.state == .queued)
        try await fixture.assertInvariants(store)
    }
}
