import Foundation
import GRDB
import Nuke
import Testing
import UIKit
import ito_runner
@testable import Ito

/// Milestone 0 end to end. The real worker downloads a manga chapter (http pages and a plugin-resolved
/// page) and a novel chapter (text and an inline image) from a scripted source. A new store on a new
/// database connection then opens the same files and reconciles, as after a relaunch. Both chapters read
/// back from their verified copies with no source, and their images decode without a single remote
/// request.
@MainActor
struct OfflineMilestoneZeroAcceptanceTests {
    private static let manga = Manga(key: "series-1", title: "Series One")
    private static let mangaChapter = Chapter(key: "chapter-1", title: "Chapter")
    private static let neverDownloaded = Chapter(key: "chapter-2", title: "Next")
    private static let novel = Novel(key: "novel-1", title: "Novel One")
    private static let novelChapter = Chapter(key: "novel-chapter-1", title: "Opening")
    private static let pluginImage = "ito://plugin.test/https://img.test/plugin-only.jpg"
    private static let novelText = "The first page of the novel, stored as text."

    @Test func downloadedChaptersReadAfterARelaunchWithoutTheirSource() async throws {
        let fixture = try DownloadWorkerFixture(pages: [
            Page(index: 0, content: .url("https://img.test/1.png")),
            Page(index: 1, content: .url("https://img.test/2.png")),
            Page(index: 2, content: .url("https://img.test/3.png")),
            Page(index: 3, content: .url(Self.pluginImage))
        ])
        let mangaImages = [Self.png(.red), Self.png(.green), Self.png(.blue)]
        for (index, image) in mangaImages.enumerated() {
            fixture.fetcher.setResponse(.data(image), for: "https://img.test/\(index + 1).png")
        }
        let novelImage = Self.png(.orange)
        fixture.fetcher.setResponse(.data(novelImage), for: "https://img.test/novel.png")

        // The manga chapter, then the novel chapter, through the real worker.
        #expect(await fixture.enqueue() == .queued)
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()
        fixture.source.setPages([
            Page(index: 0, content: .text(Self.novelText)),
            Page(index: 1, content: .url("https://img.test/novel.png"))
        ])
        let novelOutcome = await fixture.center.enqueue(
            pluginID: DownloadWorkerFixture.plugin,
            mediaKind: .novel,
            canonicalMediaId: Self.novel.key,
            entry: .novel(Self.novel),
            chapter: Self.novelChapter,
            seriesTitle: Self.novel.title
        )
        #expect(novelOutcome == .queued)
        await fixture.coordinator.untilIdle()
        #expect(try await fixture.store.jobs().isEmpty)
        fixture.coordinator.suspend()

        // A relaunch: a new database connection and a new store on the same files, reconciled once.
        let database = try DatabasePool(path: fixture.offline.database.databaseURL.path)
        let relaunched = OfflineChapterStore(
            root: fixture.offline.root,
            database: database,
            fileSystem: fixture.offline.fileSystem,
            protectedData: fixture.offline.protectedData,
            clock: OfflineStoreFixture.clock
        )
        guard case .completed(let details) = await relaunched.reconcile() else {
            Issue.record("Reconciliation after a relaunch completes")
            return
        }
        #expect(details.removedRows == 0)
        #expect(details.damagedRows == 0)
        #expect(details.requeuedJobs == 0)

        let assets = OfflineAssetDataLoader(reader: relaunched)
        let remote = CountingDataLoader()
        let session = ReaderPageImageSession(
            pipeline: ImagePipeline {
                $0.dataLoader = remote
                $0.dataCache = nil
                $0.imageCache = nil
            },
            offlinePipeline: OfflineImagePipeline.make(reader: relaunched)
        )

        // The manga chapter: every page is an offline locator whose bytes verify against the manifest,
        // in the source's order, and every downloaded picture decodes through the offline pipeline.
        let mangaLoader = ResolvingMangaPageLoader(pluginID: DownloadWorkerFixture.plugin, local: relaunched, remote: nil)
        let pluginBytes = OfflineStoreFixture.jpeg(
            "ito-" + (try PluginImageLocator.parse(try #require(URL(string: Self.pluginImage)))).realURLString
        )
        let pages = try await mangaLoader.pages(for: .manga(Self.manga), chapter: Self.mangaChapter, operation: makeTestNetworkOperation())
        #expect(pages.map(\.index) == [0, 1, 2, 3])
        let locators = try pages.map(Self.offlineURL)
        var served: [Data] = []
        for locator in locators {
            served.append(try await OfflineReadingTestSupport.load(assets, URLRequest(url: locator)))
        }
        #expect(served == mangaImages + [pluginBytes])
        for (index, locator) in locators.prefix(3).enumerated() {
            let descriptor = ReaderPageImageDescriptor(pageID: "manga-\(index)", request: URLRequest(url: locator))
            #expect(await OfflineReadingTestSupport.awaitSettled(session, descriptor))
        }

        // The novel chapter: its text and its inline image come from the verified copy.
        let novelLoader = ResolvingNovelChapterLoader(pluginID: DownloadWorkerFixture.plugin, local: relaunched, remote: nil)
        let novelPages = try await novelLoader.content(for: .novel(Self.novel), chapter: Self.novelChapter, operation: makeTestNetworkOperation())
        #expect(novelPages.map(\.index) == [0, 1])
        guard novelPages.count == 2, case .text(let body) = novelPages[0].content else {
            Issue.record("A novel chapter reads its text page first")
            return
        }
        #expect(body == Self.novelText)
        let novelImageURL = try Self.offlineURL(novelPages[1])
        #expect(try await OfflineReadingTestSupport.load(assets, URLRequest(url: novelImageURL)) == novelImage)
        let novelDescriptor = ReaderPageImageDescriptor(pageID: "novel-1", request: URLRequest(url: novelImageURL))
        #expect(await OfflineReadingTestSupport.awaitSettled(session, novelDescriptor))

        // A sibling chapter that was never downloaded does not read without its source.
        await #expect(throws: OfflineReadError.notDownloaded) {
            try await mangaLoader.pages(for: .manga(Self.manga), chapter: Self.neverDownloaded, operation: makeTestNetworkOperation())
        }

        #expect(remote.count == 0)
        try await fixture.offline.assertInvariants(relaunched)
        // The loaders pin their leases; the locators above are valid only while they live.
        withExtendedLifetime((mangaLoader, novelLoader)) {}
    }

    private static func offlineURL(_ page: Page) throws -> URL {
        guard case .url(let locator) = page.content else {
            throw OfflineStoreFixtureError.notPublished
        }
        let url = try #require(URL(string: locator))
        #expect(url.scheme == OfflineAssetLocator.scheme)
        return url
    }

    private static func png(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}
