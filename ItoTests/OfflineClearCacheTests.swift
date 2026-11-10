import Foundation
import GRDB
import Nuke
import Testing
@testable import Ito

@MainActor
struct OfflineClearCacheTests {
    @Test func clearingRealImageCacheKeepsEveryOfflineByteAndReadableInventory() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("OfflineChapters", isDirectory: true)
        let store = OfflineChapterStore(
            root: root, database: database.dbPool, fileSystem: LocalOfflineFileSystem(),
            protectedData: FakeProtectedDataAvailability()
        )
        try await database.dbPool.write { db in
            try db.execute(sql: "INSERT INTO pluginCompletionScope(pluginId, epoch) VALUES (?, ?)",
                           arguments: ["plugin.test", OfflineStoreFixture.epoch])
        }
        _ = await store.reconcile()
        let queued = try await store.enqueue(OfflineStoreFixture.request())
        #expect(queued == .queued)
        let job = try #require(try await store.jobs().first)
        let published = try await store.perform(
            .publish(jobID: job.id, pages: [OfflineStoreFixture.textPage(0, "Offline chapter text")], commitGuard: { _ in true }),
            through: .all
        )
        guard case .published? = published else {
            Issue.record("The real offline chapter must be published before clearing cache")
            return
        }
        let before = try contents(root)
        #expect(!before.isEmpty)
        let cache = try DataCache(path: directory.appendingPathComponent("ImageCache", isDirectory: true))
        cache.storeData(Data("cached image".utf8), for: "image")
        cache.flush()
        #expect(cache.cachedData(for: "image") != nil)
        let storage = StorageManager(dataCache: cache)

        await storage.clearCache()

        #expect(cache.cachedData(for: "image") == nil)
        #expect(storage.currentCacheSizeBytes == 0)
        #expect(try contents(root) == before)
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition) != nil)
        let lease = try await store.openLease(edition: OfflineStoreFixture.mangaEdition)
        #expect(lease.manifest.pages.count == 1)
        let first = try #require(lease.manifest.pages.first)
        let page = try #require(lease.page(fileName: first.file))
        #expect(try store.readVerifiedPage(page) == Data("Offline chapter text".utf8))
    }

    private func contents(_ root: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var files: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            files[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
        }
        return files
    }
}
