import Foundation
import Nuke
import Testing
import UIKit
import ito_runner
@testable import Ito

/// The read side of offline chapters: resolution with zero installed-source calls, locator-only image
/// bytes, verification on every page read, and the offline image pipeline.
@MainActor
struct OfflineReadPathTests {
    private static let entry = MediaEntry.manga(Manga(key: "series-1", title: "Series One"))
    private static let chapter = Chapter(key: "chapter-1", title: "Chapter")

    @Test func verifiedCopyIsReadWithoutTheInstalledSource() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)
        let remote = RecordingMangaPageLoader()
        let loader = ResolvingMangaPageLoader(pluginID: "plugin.test", local: store, remote: remote)

        let pages = try await loader.pages(for: Self.entry, chapter: Self.chapter)

        #expect(remote.callCount == 0)
        #expect(pages.map(\.index) == [0, 1, 2])
        for page in pages {
            guard case .url(let locator) = page.content else {
                Issue.record("An image page is addressed by its offline locator")
                continue
            }
            #expect(locator.hasPrefix("ito-offline://"))
            #expect(page.headers == nil)
        }
    }

    @Test func chapterWithoutCopyOrSourceIsNotDownloaded() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let loader = ResolvingMangaPageLoader(pluginID: "plugin.test", local: store, remote: nil)

        await #expect(throws: OfflineReadError.notDownloaded) {
            try await loader.pages(for: Self.entry, chapter: Self.chapter)
        }
    }

    @Test func chapterPinnedToTheInstalledSourceStaysRemoteAfterACopyFinishes() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let remote = RecordingMangaPageLoader()
        let loader = ResolvingMangaPageLoader(pluginID: "plugin.test", local: store, remote: remote)

        _ = try await loader.pages(for: Self.entry, chapter: Self.chapter)
        _ = try await fixture.publishedEdition(store)
        _ = try await loader.pages(for: Self.entry, chapter: Self.chapter)

        #expect(remote.callCount == 2)
    }

    @Test func openChapterKeepsItsCopyAfterTheCopyIsDeleted() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)
        let loader = ResolvingMangaPageLoader(pluginID: "plugin.test", local: store, remote: nil)
        _ = try await loader.pages(for: Self.entry, chapter: Self.chapter)

        try await store.delete(OfflineStoreFixture.mangaEdition)
        let pages = try await loader.pages(for: Self.entry, chapter: Self.chapter)

        #expect(pages.count == 3)
        #expect(try await store.verifiedEdition(for: OfflineStoreFixture.mangaEdition) == nil)
    }

    @Test func inventoryListsOnlyVerifiedCopiesOfTheSeries() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)

        let chapters = await store.inventoryChapters(
            pluginId: "plugin.test",
            mediaKind: .manga,
            canonicalMediaId: "series-1"
        )
        let other = await store.inventoryChapters(
            pluginId: "plugin.test",
            mediaKind: .manga,
            canonicalMediaId: "series-2"
        )

        #expect(chapters.map(\.chapterKey) == ["chapter-1"])
        #expect(other.isEmpty)
    }

    @Test func offlineLoaderServesVerifiedBytesOnlyThroughALeasedLocator() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)
        let lease = try await store.openLease(edition: OfflineStoreFixture.mangaEdition)
        let url = try #require(URL(string: OfflineAssetLocator.makeURLString(
            token: lease.token,
            fileName: OfflinePageFileName.make(index: 0, fileExtension: "jpg")
        )))

        let data = try await OfflineReadingTestSupport.load(OfflineAssetDataLoader(reader: store), URLRequest(url: url))

        #expect(data == OfflineStoreFixture.jpeg("image-0"))
    }

    @Test func releasedLeaseNoLongerServesItsPages() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)
        var lease: OfflineChapterLease? = try await store.openLease(edition: OfflineStoreFixture.mangaEdition)
        let token = try #require(lease?.token)
        let url = try #require(URL(string: OfflineAssetLocator.makeURLString(
            token: token,
            fileName: OfflinePageFileName.make(index: 0, fileExtension: "jpg")
        )))
        lease = nil
        await store.leases.awaitReclamations()
        let loader = OfflineAssetDataLoader(reader: store)

        await #expect(throws: OfflineAssetError.leaseReleased) {
            try await OfflineReadingTestSupport.load(loader, URLRequest(url: url))
        }
    }

    @Test func offlineLoaderRefusesEverythingThatIsNotALeasedLocator() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let loader = OfflineAssetDataLoader(reader: store)
        let remote = try #require(URL(string: "https://images.example.test/p0000.jpg"))
        let unknown = try #require(URL(string: "ito-offline://\(UUID().uuidString)/p0000.jpg"))

        await #expect(throws: OfflineAssetError.invalidLocator) {
            try await OfflineReadingTestSupport.load(loader, URLRequest(url: remote))
        }
        await #expect(throws: OfflineAssetError.leaseReleased) {
            try await OfflineReadingTestSupport.load(loader, URLRequest(url: unknown))
        }
    }

    @Test func tamperedPageIsRefusedAsDamagedAndNeverServed() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)
        let lease = try await store.openLease(edition: OfflineStoreFixture.mangaEdition)
        let fileName = OfflinePageFileName.make(index: 0, fileExtension: "jpg")
        let page = try #require(lease.page(fileName: fileName))
        fixture.fileSystem.replaceFile(at: page.fileURL, with: Data("tampered".utf8))
        let url = try #require(URL(string: OfflineAssetLocator.makeURLString(token: lease.token, fileName: fileName)))
        let loader = OfflineAssetDataLoader(reader: store)

        await #expect(throws: OfflineStoreError.damaged(.pageMismatch)) {
            try await OfflineReadingTestSupport.load(loader, URLRequest(url: url))
        }
    }

    @Test func textChapterPagesComeFromTheVerifiedCopy() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        try await Self.publish(
            fixture,
            store,
            chapterKey: "chapter-1",
            pages: [OfflineStoreFixture.textPage(0, "First page.")]
        )
        let loader = ResolvingNovelChapterLoader(pluginID: "plugin.test", local: store, remote: nil)

        let pages = try await loader.content(for: Self.entry, chapter: Self.chapter)

        guard case .text(let text)? = pages.first?.content else {
            Issue.record("A text page is returned as text")
            return
        }
        #expect(text == "First page.")
    }

    @Test func offlinePageDecodesThroughTheOfflinePipelineWithoutRemoteRequests() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let pngChapter = Chapter(key: "png-chapter", title: "Pictures")
        try await Self.publish(
            fixture,
            store,
            chapterKey: pngChapter.key,
            pages: [OfflinePageInput(content: .image(Self.pngData()), sourceIndex: 0)]
        )
        let loader = ResolvingMangaPageLoader(pluginID: "plugin.test", local: store, remote: nil)
        let pages = try await loader.pages(for: Self.entry, chapter: pngChapter)
        guard case .url(let locator)? = pages.first?.content else {
            Issue.record("An image page is addressed by its offline locator")
            return
        }

        let remoteLoader = CountingDataLoader()
        let remotePipeline = ImagePipeline {
            $0.dataLoader = remoteLoader
            $0.dataCache = nil
            $0.imageCache = nil
        }
        let session = ReaderPageImageSession(
            pipeline: remotePipeline,
            offlinePipeline: OfflineImagePipeline.make(reader: store)
        )
        let descriptor = ReaderPageImageDescriptor(
            pageID: "0",
            request: URLRequest(url: try #require(URL(string: locator)))
        )

        let decoded = await OfflineReadingTestSupport.awaitSettled(session, descriptor)

        #expect(decoded)
        #expect(remoteLoader.count == 0)
    }

    @Test func offlineRequestWithoutAnOfflinePipelineFailsAndNeverReachesTheRemotePipeline() async throws {
        let remoteLoader = CountingDataLoader()
        let remotePipeline = ImagePipeline {
            $0.dataLoader = remoteLoader
            $0.dataCache = nil
            $0.imageCache = nil
        }
        let session = ReaderPageImageSession(pipeline: remotePipeline)
        let locator = OfflineAssetLocator.makeURLString(token: UUID(), fileName: "p0000.png")
        let descriptor = ReaderPageImageDescriptor(
            pageID: "0",
            request: URLRequest(url: try #require(URL(string: locator)))
        )

        let decoded = await OfflineReadingTestSupport.awaitSettled(session, descriptor)

        #expect(!decoded)
        #expect(remoteLoader.count == 0)
    }

    @Test func damagedCopyFallsBackToTheInstalledSourceAndStopsPinning() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        try await Self.publish(
            fixture,
            store,
            chapterKey: "chapter-1",
            pages: [OfflineStoreFixture.textPage(0, "First page.")]
        )
        let probe = try await store.openLease(edition: OfflineStoreFixture.mangaEdition)
        let page = try #require(probe.page(fileName: OfflinePageFileName.make(index: 0, fileExtension: "txt")))
        fixture.fileSystem.replaceFile(at: page.fileURL, with: Data("tampered".utf8))
        let remote = RecordingNovelChapterLoader()
        let loader = ResolvingNovelChapterLoader(pluginID: "plugin.test", local: store, remote: remote)

        _ = try await loader.content(for: Self.entry, chapter: Self.chapter)
        _ = try await loader.content(for: Self.entry, chapter: Self.chapter)

        #expect(remote.callCount == 2)
    }

    @Test func damagedCopyWithoutAnInstalledSourceStillReportsDamage() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        try await Self.publish(
            fixture,
            store,
            chapterKey: "chapter-1",
            pages: [OfflineStoreFixture.textPage(0, "First page.")]
        )
        let probe = try await store.openLease(edition: OfflineStoreFixture.mangaEdition)
        let page = try #require(probe.page(fileName: OfflinePageFileName.make(index: 0, fileExtension: "txt")))
        fixture.fileSystem.replaceFile(at: page.fileURL, with: Data("tampered".utf8))
        let loader = ResolvingNovelChapterLoader(pluginID: "plugin.test", local: store, remote: nil)

        await #expect(throws: OfflineStoreError.damaged(.pageMismatch)) {
            try await loader.content(for: Self.entry, chapter: Self.chapter)
        }
    }

    // MARK: - Helpers

    private static func publish(
        _ fixture: OfflineStoreFixture,
        _ store: OfflineChapterStore,
        chapterKey: String,
        pages: [OfflinePageInput]
    ) async throws {
        let jobID = try await fixture.enqueue(store, chapterKey: chapterKey)
        let outcome = try await store.perform(
            .publish(jobID: jobID, pages: pages, commitGuard: { _ in true }),
            through: .all
        )
        guard case .published(_)? = outcome else { throw OfflineStoreFixtureError.notPublished }
    }

    private static func pngData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}

@MainActor
private final class RecordingMangaPageLoader: MangaPageLoading {
    private(set) var callCount = 0

    func pages(for entry: MediaEntry, chapter: Chapter) async throws -> [Page] {
        _ = (entry, chapter)
        callCount += 1
        return [Page(index: 0, content: .url("https://remote.example.test/p0000.jpg"))]
    }
}

@MainActor
private final class RecordingNovelChapterLoader: NovelChapterLoading {
    private(set) var callCount = 0

    func content(for entry: MediaEntry, chapter: Chapter) async throws -> [Page] {
        _ = (entry, chapter)
        callCount += 1
        return [Page(index: 0, content: .text("Remote page."))]
    }
}
