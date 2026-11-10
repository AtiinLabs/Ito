import Foundation
import Testing
@testable import Ito

@MainActor
struct StorageDownloadsTests {
    @Test func totalsIncludeDamagedCopiesAndClearDownloadsNeverCallsCacheClear() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let service = TestDownloadsOverview()
        let first = TestDownloadsOverview.media("a")
        let second = TestDownloadsOverview.media("b")
        service.summaries = [
            OfflineInventorySummary(media: first, state: .verified, count: 2, byteCount: 300),
            OfflineInventorySummary(media: first, state: .damaged, count: 1, byteCount: 10),
            OfflineInventorySummary(media: second, state: .verified, count: 1, byteCount: 20)
        ]
        service.failedSeries = [second]
        let cache = TestSettingsStorageAccess()
        let model = StorageSettingsViewModel(settingsStore: AppSettingsStore(dbPool: database.dbPool),
                                             storageAccess: cache, downloads: service)
        #expect(model.hasDownloads)
        await model.refreshDownloadsUsage()
        #expect(model.downloadBytes == 330)

        await model.clearDownloads()

        #expect(Set(service.deletedSeries) == [first, second])
        #expect(service.deletedSeries.count == 2)
        #expect(service.suppressionFlags == [true, true])
        #expect(model.downloadBytes == 20)
        #expect(model.downloadsMessage?.contains("Other deletions were kept") == true)
        #expect(!model.isClearingDownloads)
        #expect(cache.clearCallCount == 0)
        await model.clearCache()
        #expect(cache.clearCallCount == 1)
        #expect(service.deletedSeries.count == 2)
        #expect(model.downloadBytes == 20)
    }

    @Test func absentStoreHidesOfflineStorageAndDoesNotAffectCacheActions() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let cache = TestSettingsStorageAccess()
        let model = StorageSettingsViewModel(settingsStore: AppSettingsStore(dbPool: database.dbPool), storageAccess: cache)
        #expect(!model.hasDownloads)
        await model.refreshDownloadsUsage()
        await model.clearDownloads()
        #expect(model.downloadBytes == nil)
        #expect(model.downloadsMessage == nil)
        await model.clearCache()
        #expect(cache.clearCallCount == 1)
    }

    @Test func deletingEverythingAlsoCancelsSeriesThatOnlyHaveQueuedJobs() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let fixture = try DownloadWorkerFixture()
        _ = try await fixture.offline.publishedEdition(fixture.store, chapterKey: "saved", canonicalMediaId: "saved-series")
        _ = try await fixture.offline.enqueue(fixture.store, chapterKey: "queued", canonicalMediaId: "queued-series")
        _ = try await fixture.offline.enqueue(fixture.store, chapterKey: "queued-too", canonicalMediaId: "saved-series")
        #expect(try await fixture.offline.rowCount("downloadedChapter") == 1)
        #expect(try await fixture.store.jobs().count == 2)
        let model = StorageSettingsViewModel(
            settingsStore: AppSettingsStore(dbPool: database.dbPool), storageAccess: TestSettingsStorageAccess(),
            downloads: LiveDownloadsOverview(center: fixture.center, store: fixture.store)
        )

        await model.clearDownloads()

        #expect(try await fixture.store.jobs().isEmpty)
        #expect(try await fixture.offline.rowCount("downloadedChapter") == 0)
        #expect(model.downloadBytes == 0)
        #expect(model.downloadsMessage == nil)
    }
}
