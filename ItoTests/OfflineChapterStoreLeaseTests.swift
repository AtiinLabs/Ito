import Foundation
import GRDB
import Testing
@testable import Ito

struct OfflineChapterStoreLeaseTests {
    @Test func deleteWhileLeasedKeepsBytesAndReleaseByDeinitReclaimsThem() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let versionId = try await fixture.publishedEdition(store)
        var lease: OfflineChapterLease? = try await store.openLease(edition: OfflineStoreFixture.mangaEdition)

        try await store.delete(OfflineStoreFixture.mangaEdition)

        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition) == nil)
        #expect(fixture.fileSystem.exists(fixture.versionURL(versionId)))
        let page = try #require(lease?.page(fileName: OfflinePageFileName.make(index: 0, fileExtension: "jpg")))
        let bytes = try fixture.fileSystem.readData(at: page.fileURL)
        #expect(OfflineDigest.sha256Hex(bytes) == page.page.sha256)

        // Releasing by deinit schedules the reclamation; awaiting it is the observable end of the release.
        lease = nil
        await store.leases.awaitReclamations()

        #expect(!fixture.fileSystem.exists(fixture.versionURL(versionId)))
        #expect(store.leases.leasedVersionIDs().isEmpty)
    }

    @Test func collectionNeverRemovesALeasedVersionAndReleaseMakesItCollectable() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let versionId = try await fixture.publishedEdition(store)
        var lease: OfflineChapterLease? = try await store.openLease(edition: OfflineStoreFixture.mangaEdition)

        // The row disappears without the store's delete path, so the version is unreferenced.
        try await fixture.database.dbPool.write { db in
            _ = try DownloadedChapterRecord.deleteAll(db)
        }
        _ = try await store.collectGarbage()
        #expect(fixture.fileSystem.exists(fixture.versionURL(versionId)))

        lease = nil
        await store.leases.awaitReclamations()
        _ = try await store.collectGarbage()
        #expect(!fixture.fileSystem.exists(fixture.versionURL(versionId)))
    }

    @Test func releasedTokenResolvesNoPages() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)
        var lease: OfflineChapterLease? = try await store.openLease(edition: OfflineStoreFixture.mangaEdition)
        let token = try #require(lease?.token)
        let fileName = OfflinePageFileName.make(index: 0, fileExtension: "jpg")
        #expect(store.leases.resolvePage(token: token, fileName: fileName) != nil)

        lease = nil

        #expect(store.leases.resolvePage(token: token, fileName: fileName) == nil)
        await store.leases.awaitReclamations()
    }

    @Test func leaseResolvesOnlyPagesOfItsManifest() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)
        let lease = try await store.openLease(edition: OfflineStoreFixture.mangaEdition)

        #expect(lease.manifest.pages.count == 3)
        #expect(lease.page(fileName: "p0009.jpg") == nil)
        #expect(lease.page(fileName: "../manifest.json") == nil)
    }

    @Test func openingAnUnverifiedEditionFailsWithoutLeasing() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = await store.reconcile()

        await #expect(throws: OfflineStoreError.notVerified) {
            try await store.openLease(edition: OfflineStoreFixture.mangaEdition)
        }
        #expect(store.leases.leasedVersionIDs().isEmpty)
    }
}
