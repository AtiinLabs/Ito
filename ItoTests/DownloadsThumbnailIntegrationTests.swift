import Combine
import Foundation
import GRDB
import Testing
import UIKit
import ito_runner
@testable import Ito

@MainActor
struct DownloadsThumbnailIntegrationTests {
    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func realStoredCoverReachesManagerAndChangingCoverDropsOldThumbnail() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = try await fixture.offline.publishedEdition(fixture.store)
        let item = LibraryItem(id: "series-1", title: "Series", coverUrl: "https://example.test/a.jpg",
                               pluginId: "plugin.test", isAnime: false, pluginType: .manga,
                               rawPayload: Data(), anilistId: nil)
        try await fixture.offline.database.dbPool.write { db in try item.insert(db) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        }
        let encoded = try #require(LibraryCoverThumbnailEncoder.encode(image))
        let store = LibraryCoverThumbnailStore(database: fixture.offline.database.dbPool)
        #expect(try await store.store(encoded, itemID: item.id, coverUrl: try #require(item.coverUrl)) == .stored)
        let covers = LibraryCoverThumbnails(store: store)
        let adapter = LibraryDownloadsThumbnails(covers: covers)
        let library = LibraryManager(dbPool: fixture.offline.database.dbPool,
                                     observationScheduler: ImmediateValueObservationScheduler())
        let model = DownloadsViewModel(service: LiveDownloadsOverview(center: fixture.center, store: fixture.store),
                                       library: library, thumbnails: adapter)
        await model.start()
        defer { model.stop() }
        for await value in model.$snapshot.values {
            if !value.downloaded.isEmpty { break }
        }
        await model.loadThumbnail(for: item.mediaIdentity, owner: UUID())
        let displayed = try #require(model.thumbnails[item.mediaIdentity])
        #expect(displayed.coverURLSHA256 == LibraryCoverThumbnailStore.coverHash(try #require(item.coverUrl)))
        #expect(displayed.image.size.width == 20)
        #expect(displayed.image.size.height == 30)
        #expect(model.libraryItems[item.mediaIdentity]?.id == item.id)
        #expect(model.snapshot.downloaded.first?.id == item.mediaIdentity)
        #expect(model.libraryItems[MediaIdentity(pluginId: "missing", canonicalMediaId: "removed", mediaKind: .manga)] == nil)

        // Library item identity stays the same, but the old cover must no longer be displayed.
        try await fixture.offline.database.dbPool.write { db in
            try db.execute(sql: "UPDATE libraryItem SET coverUrl = ? WHERE id = ?",
                           arguments: ["https://example.test/b.jpg", item.id])
        }
        for await items in model.$libraryItems.values {
            if items[item.mediaIdentity]?.coverUrl == "https://example.test/b.jpg" { break }
        }
        #expect(model.thumbnails[item.mediaIdentity] == nil)
        let changed = try #require(model.libraryItems[item.mediaIdentity])
        #expect(await adapter.thumbnail(for: changed) == nil)
        #expect(await adapter.thumbnail(for: LibraryItem(id: item.id, title: item.title, coverUrl: nil,
                                                        pluginId: item.pluginId, isAnime: false,
                                                        rawPayload: Data(), anilistId: nil)) == nil)
        let revision = model.thumbnailRevision
        await covers.record(itemID: item.id, coverUrl: "https://example.test/b.jpg", image: image)
        #expect(model.thumbnailRevision > revision)
        await model.loadThumbnail(for: item.mediaIdentity, owner: UUID())
        #expect(model.thumbnails[item.mediaIdentity]?.coverURLSHA256
                == LibraryCoverThumbnailStore.coverHash("https://example.test/b.jpg"))
    }
}
