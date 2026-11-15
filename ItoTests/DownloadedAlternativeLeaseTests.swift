import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

/// Listing and leasing saved alternatives over a real store: the listing is one consistent read, and a lease is
/// accepted only for exactly the copy that was listed.
struct DownloadedAlternativeLeaseTests {
    private struct Reviewed {
        let fixture: OfflineStoreFixture
        let store: OfflineChapterStore
        let candidate: DownloadedChapterAlternative
        let epoch: String?
        let versionB: String
    }

    private static let anchor = OfflineChapterAlternativeAnchor.catalog(
        edition: OfflineChapterEdition(
            pluginId: "plugin.test",
            mediaKind: .manga,
            canonicalMediaId: "series-1",
            chapterKey: "a"
        ),
        logicalUnitID: "unit-1"
    )

    /// Publishes upload `a` and upload `b` of one logical unit, and lists the alternatives of `a`.
    private static func reviewed(
        pages: [OfflinePageInput] = [OfflineStoreFixture.imagePage(0), OfflineStoreFixture.imagePage(1)]
    ) async throws -> Reviewed {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        try await fixture.publishUpload(store, .upload("a"))
        let versionB = try await fixture.publishUpload(store, .upload("b", group: "Other", groupID: "g-b"), pages: pages)
        let listed = try await store.downloadedAlternatives(for: anchor)
        guard let candidate = listed.candidates.first else { throw OfflineStoreFixtureError.notPublished }
        return Reviewed(fixture: fixture, store: store, candidate: candidate, epoch: listed.sourceEpoch, versionB: versionB)
    }

    // MARK: - 11, 12

    @MainActor
    @Test func publicationListingAndTheCentersLeaseAgreeAndCauseNoQueuePluginOrPreferenceEffects() async throws {
        let fixture = try DownloadWorkerFixture()
        try await fixture.offline.publishUpload(fixture.store, .upload("a"))
        let versionB = try await fixture.offline.publishUpload(fixture.store, .upload("b", group: "Other", groupID: "g-b"))
        let jobsBefore = try await fixture.store.jobs().count

        let listed = try await fixture.center.downloadedAlternatives(for: Self.anchor)
        let candidate = try #require(listed.candidates.first)
        let lease = try await fixture.center.openDownloadedAlternative(candidate, sourceEpoch: listed.sourceEpoch)

        #expect(listed.candidates.map(\.edition.chapterKey) == ["b"])
        #expect(listed.sourceEpoch == OfflineStoreFixture.epoch)
        #expect(lease.versionId == versionB)
        #expect(lease.versionId == candidate.versionID)
        #expect(lease.edition.isByteIdentical(to: fixture.edition(chapterKey: "b")))
        #expect(lease.manifest.contentKind == candidate.contentKind)
        #expect(fixture.store.leases.isLeased(versionId: versionB))
        // Nothing was fetched, asked of a plugin, queued or remembered.
        #expect(fixture.source.listings.count == 0)
        #expect(fixture.inner.calls.count == 0)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
        #expect(fixture.fetcher.pluginRequests.count == 0)
        #expect(fixture.runtimes.runtimeRequests == 0)
        #expect(try await fixture.store.jobs().count == jobsBefore)
        #expect(try await fixture.offline.rowCount("seriesEditionPreference") == 0)
        #expect(try await fixture.offline.rowCount("downloadBatch") == 0)
    }

    @Test func anInventoryThatCannotBeReadIsAnErrorNotAnEmptyResult() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        try await fixture.publishUpload(store, .upload("a"))
        try fixture.database.dbPool.close()

        await #expect(throws: DownloadedAlternativeError.inventoryUnavailable) {
            try await store.downloadedAlternatives(for: Self.anchor)
        }
    }

    @MainActor
    @Test func anEpochThatCannotBeReadIsNotAnAbsentEpochAndAnAbsentOneIsNeverCreated() async throws {
        let fixture = try DownloadWorkerFixture()
        let epochsBefore = try await fixture.offline.rowCount("pluginCompletionScope")

        #expect(try fixture.center.downloadedAlternativeEpoch(for: "plugin.test") == OfflineStoreFixture.epoch)
        #expect(try fixture.center.downloadedAlternativeEpoch(for: "plugin.never-installed") == nil)
        #expect(try await fixture.offline.rowCount("pluginCompletionScope") == epochsBefore)

        try fixture.offline.database.dbPool.close()
        #expect(throws: DownloadedAlternativeError.inventoryUnavailable) {
            try fixture.center.downloadedAlternativeEpoch(for: "plugin.test")
        }
    }

    @MainActor
    @Test func theUnavailableImplementationRefusesEveryOperationExplicitly() async throws {
        let unavailable = UnavailableMediaDetailDownloads()
        let reviewed = try await Self.reviewed()

        #expect(!unavailable.isAvailable)
        await #expect(throws: DownloadedAlternativeError.unavailable) {
            try await unavailable.downloadedAlternatives(for: Self.anchor)
        }
        #expect(throws: DownloadedAlternativeError.unavailable) {
            try unavailable.downloadedAlternativeEpoch(for: "plugin.test")
        }
        await #expect(throws: DownloadedAlternativeError.unavailable) {
            try await unavailable.openDownloadedAlternative(reviewed.candidate, sourceEpoch: reviewed.epoch)
        }
    }

    // MARK: - 13, 14

    @Test func aCopyDeletedBetweenListingAndConfirmationIsUnavailableAndNothingElseIsOpened() async throws {
        let reviewed = try await Self.reviewed()
        try await reviewed.store.delete(reviewed.fixture.edition("b"))

        await #expect(throws: OfflineReadError.localCopyUnavailable) {
            try await reviewed.store.openDownloadedAlternative(reviewed.candidate, sourceEpoch: reviewed.epoch)
        }
        #expect(reviewed.store.leases.leasedVersionIDs().isEmpty)
    }

    enum Change: String, CaseIterable, Sendable {
        case snapshot, origin, savedForm, manifestDigest, versionPointer
    }

    @Test(arguments: Change.allCases)
    func aCopyThatChangedAfterListingIsNotLeasedInPlaceOfTheListedOne(_ change: Change) async throws {
        let reviewed = try await Self.reviewed()
        let pool = reviewed.fixture.database.dbPool
        switch change {
        case .snapshot:
            let renamed = try JSONEncoder().encode(Chapter.upload("b", group: "Renamed", groupID: "g-b"))
            try await pool.write { db in
                try db.execute(sql: "UPDATE downloadedChapter SET chapterSnapshot = ? WHERE chapterKey = 'b'", arguments: [renamed])
            }
        case .origin:
            let origin = try DownloadedChapterRecord.originData(pluginId: "plugin.test", canonicalMediaId: "series-2")
            try await pool.write { db in
                try db.execute(sql: "UPDATE downloadedChapter SET originIdentity = ? WHERE chapterKey = 'b'", arguments: [origin])
            }
        case .savedForm:
            try await pool.write { db in
                try db.execute(sql: "UPDATE downloadedChapter SET contentKind = 'text' WHERE chapterKey = 'b'")
            }
        case .manifestDigest:
            let digest = String(repeating: "c", count: 64)
            try await pool.write { db in
                try db.execute(sql: "UPDATE downloadedChapter SET manifestSHA256 = ? WHERE chapterKey = 'b'", arguments: [digest])
            }
        case .versionPointer:
            try await reviewed.store.delete(reviewed.fixture.edition("b"))
            let replacement = try await reviewed.fixture.publishUpload(reviewed.store, .upload("b", group: "Other", groupID: "g-b"))
            #expect(replacement != reviewed.versionB)
        }

        await #expect(throws: DownloadedAlternativeError.selectionChanged) {
            try await reviewed.store.openDownloadedAlternative(reviewed.candidate, sourceEpoch: reviewed.epoch)
        }
        #expect(reviewed.store.leases.leasedVersionIDs().isEmpty)
    }

    // MARK: - 15

    @Test func aTamperedManifestIsDamagedAndNeverLeased() async throws {
        let reviewed = try await Self.reviewed()
        let manifest = reviewed.fixture.versionURL(reviewed.versionB).appendingPathComponent(OfflineChapterManifest.fileName)
        reviewed.fixture.fileSystem.replaceFile(at: manifest, with: Data("tampered".utf8))

        await #expect(throws: OfflineReadError.localCopyDamaged) {
            try await reviewed.store.openDownloadedAlternative(reviewed.candidate, sourceEpoch: reviewed.epoch)
        }
        #expect(reviewed.store.leases.leasedVersionIDs().isEmpty)
    }

    @Test func aLockedDeviceIsProtectedDataUnavailableAndDoesNotMarkTheCopyDamaged() async throws {
        let reviewed = try await Self.reviewed()
        await reviewed.fixture.protectedData.setAvailable(false)

        await #expect(throws: OfflineReadError.protectedDataUnavailable) {
            try await reviewed.store.openDownloadedAlternative(reviewed.candidate, sourceEpoch: reviewed.epoch)
        }

        await reviewed.fixture.protectedData.setAvailable(true)
        let row = try await reviewed.store.verifiedEdition(for: reviewed.fixture.edition("b"))
        #expect(row?.versionId == reviewed.versionB)
        let lease = try await reviewed.store.openDownloadedAlternative(reviewed.candidate, sourceEpoch: reviewed.epoch)
        #expect(lease.versionId == reviewed.versionB)
    }

    @Test func aMissingVersionDirectoryIsLocalUnavailable() async throws {
        let reviewed = try await Self.reviewed()
        try reviewed.fixture.fileSystem.removeItem(at: reviewed.fixture.versionURL(reviewed.versionB))

        await #expect(throws: OfflineReadError.localCopyUnavailable) {
            try await reviewed.store.openDownloadedAlternative(reviewed.candidate, sourceEpoch: reviewed.epoch)
        }
    }

    // MARK: - 16

    @Test func aRotatedSourceEpochIsSourceChangedAndOpensNothing() async throws {
        let reviewed = try await Self.reviewed()
        try reviewed.fixture.rotateEpoch(to: OfflineStoreFixture.rotatedEpoch)

        await #expect(throws: DownloadedAlternativeError.sourceChanged) {
            try await reviewed.store.openDownloadedAlternative(reviewed.candidate, sourceEpoch: reviewed.epoch)
        }
        #expect(reviewed.store.leases.leasedVersionIDs().isEmpty)
    }

    @Test func theRowsHistoricEpochAloneDoesNotForbidAnOtherwiseValidCopy() async throws {
        let reviewed = try await Self.reviewed()
        try reviewed.fixture.rotateEpoch(to: OfflineStoreFixture.rotatedEpoch)
        let relisted = try await reviewed.store.downloadedAlternatives(for: Self.anchor)
        let candidate = try #require(relisted.candidates.first)

        let lease = try await reviewed.store.openDownloadedAlternative(candidate, sourceEpoch: relisted.sourceEpoch)

        #expect(relisted.sourceEpoch == OfflineStoreFixture.rotatedEpoch)
        #expect(lease.versionId == reviewed.versionB)
    }

    @Test func anAbsentEpochOnBothSidesIsAcceptedWithoutCreatingOne() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        try await fixture.publishUpload(store, .upload("a"))
        let versionB = try await fixture.publishUpload(store, .upload("b"))
        try await fixture.database.dbPool.write { db in try db.execute(sql: "DELETE FROM pluginCompletionScope") }

        let listed = try await store.downloadedAlternatives(for: Self.anchor)
        let candidate = try #require(listed.candidates.first)
        let lease = try await store.openDownloadedAlternative(candidate, sourceEpoch: nil)

        #expect(listed.sourceEpoch == nil)
        #expect(lease.versionId == versionB)
        #expect(try await fixture.rowCount("pluginCompletionScope") == 0)
    }

    // MARK: - 17, 18

    @Test func aCancelledConfirmationEitherFailsWithCancellationOrHandsBackALeaseThatDiesWithItsOwner() async throws {
        let reviewed = try await Self.reviewed()
        let (store, candidate, epoch) = (reviewed.store, reviewed.candidate, reviewed.epoch)
        let task = Task {
            try await store.openDownloadedAlternative(candidate, sourceEpoch: epoch)
        }
        task.cancel()

        do {
            let lease = try await task.value
            #expect(lease.versionId == reviewed.versionB)
        } catch {
            #expect(error is CancellationError)
        }

        // The lease, if one was made, was the only owner: with it gone nothing stays pinned.
        await reviewed.store.leases.awaitReclamations()
        #expect(reviewed.store.leases.leasedVersionIDs().isEmpty)
    }

    @Test func anAcceptedLeaseKeepsItsBytesThroughADeleteAndAReplacementAndReclaimsOnRelease() async throws {
        let reviewed = try await Self.reviewed(pages: [OfflineStoreFixture.textPage(0, "Original text.")])
        var lease: OfflineChapterLease? = try await reviewed.store.openDownloadedAlternative(
            reviewed.candidate,
            sourceEpoch: reviewed.epoch
        )
        try await reviewed.store.delete(reviewed.fixture.edition("b"))
        let replacement = try await reviewed.fixture.publishUpload(
            reviewed.store,
            .upload("b", group: "Other", groupID: "g-b"),
            pages: [OfflineStoreFixture.textPage(0, "Replacement text.")]
        )

        // Reads go through the one lease reference so releasing it below really releases the lease.
        let page = try #require(lease?.page(fileName: OfflinePageFileName.make(index: 0, fileExtension: "txt")))
        let bytes = try reviewed.store.readVerifiedPage(page)

        #expect(String(decoding: bytes, as: UTF8.self) == "Original text.")
        #expect(lease?.versionId == reviewed.versionB)
        #expect(replacement != reviewed.versionB)
        #expect(reviewed.fixture.fileSystem.exists(reviewed.fixture.versionURL(reviewed.versionB)))

        lease = nil
        await reviewed.store.leases.awaitReclamations()

        #expect(!reviewed.fixture.fileSystem.exists(reviewed.fixture.versionURL(reviewed.versionB)))
        #expect(reviewed.fixture.fileSystem.exists(reviewed.fixture.versionURL(replacement)))
    }
}
