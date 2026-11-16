import Foundation
import Testing
import ito_runner
@testable import Ito

/// What one chapter of a reader opening is made of, decided from the copy or the source that actually serves it.
@MainActor
struct ReaderChapterPreparerTests {
    private static let pluginID = "plugin.test"
    private static let mangaEntry = MediaEntry.manga(Manga(key: "series-1", title: "Series One"))
    private static let novelEntry = MediaEntry.novel(Novel(key: "series-1", title: "Series One"))
    private static let chapter = Chapter(key: "chapter-1", title: "One")

    private final class RemoteCounter: MangaPageLoading, NovelChapterLoading {
        private(set) var mangaKeys: [String] = []
        private(set) var novelKeys: [String] = []
        private(set) var operations: [PluginNetworkOperation] = []

        func pages(for entry: MediaEntry, chapter: Chapter, operation: PluginNetworkOperation) async throws -> [Page] {
            mangaKeys.append(chapter.key)
            operations.append(operation)
            return [Page(index: 2, content: .url("https://remote.example.test/b")), Page(index: 1, content: .url("https://remote.example.test/a"))]
        }

        func content(for entry: MediaEntry, chapter: Chapter, operation: PluginNetworkOperation) async throws -> [Page] {
            novelKeys.append(chapter.key)
            operations.append(operation)
            return [Page(index: 0, content: .text("Remote words."))]
        }
    }

    private func makePreparer(
        store: any OfflineChapterReading = UnavailableOfflineChapterReading(),
        content: ReaderContentSource,
        remote: RemoteCounter?
    ) -> MediaDetailReaderChapterPreparer {
        MediaDetailReaderChapterPreparer(
            pluginID: Self.pluginID, content: content, local: store, remoteManga: remote, remoteNovel: remote
        )
    }

    private static func publish(
        _ fixture: OfflineStoreFixture,
        _ store: OfflineChapterStore,
        mediaKind: MediaKind,
        pages: [OfflinePageInput]
    ) async throws {
        let jobID = try await fixture.enqueue(store, chapterKey: "chapter-1", mediaKind: mediaKind)
        let outcome = try await store.perform(.publish(jobID: jobID, pages: pages, commitGuard: { _ in true }), through: .all)
        guard case .published(_)? = outcome else { throw OfflineStoreFixtureError.notPublished }
    }

    // MARK: - The saved form decides

    @Test func aSavedTextCopyOfAMangaChapterOpensAsTextWithoutTheSource() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        try await Self.publish(fixture, store, mediaKind: .manga, pages: [OfflineStoreFixture.textPage(0, "Saved words.")])
        let remote = RemoteCounter()
        let preparer = makePreparer(store: store, content: ReaderContentSource(remote: nil), remote: remote)

        let prepared = try await preparer.prepareChapter(
            entry: Self.mangaEntry, chapter: Self.chapter, operation: makeTestNetworkOperation()
        )

        #expect(prepared.format == .text)
        #expect(prepared.entry.chapters?.first?.kind == .text, "The opening's copy of the entry lists the actual form")
        #expect(prepared.entry.kind == .manga)
        #expect(remote.mangaKeys.isEmpty && remote.novelKeys.isEmpty)
        guard case .text(let text)? = prepared.pages.first?.content else {
            Issue.record("The copy is read as text")
            return
        }
        #expect(text == "Saved words.")
        #expect(!prepared.resolver.readsFromSource(chapterKey: "chapter-1"))
    }

    @Test func aSavedImageCopyOfANovelChapterOpensAsPages() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        try await Self.publish(
            fixture, store, mediaKind: .novel,
            pages: [OfflineStoreFixture.imagePage(1), OfflineStoreFixture.imagePage(0)]
        )
        let preparer = makePreparer(store: store, content: ReaderContentSource(remote: nil), remote: nil)

        let prepared = try await preparer.prepareChapter(
            entry: Self.novelEntry, chapter: Self.chapter, operation: makeTestNetworkOperation()
        )

        #expect(prepared.format == .pages)
        #expect(prepared.entry.kind == .novel)
        #expect(prepared.pages.map(\.index) == [0, 1], "Sorted once, in page order")
    }

    @Test func aMixedCopyFollowsTheChaptersDeclaredKindAndKeepsEveryPage() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let mixed = [OfflineStoreFixture.textPage(0, "Words."), OfflineStoreFixture.imagePage(1), OfflineStoreFixture.textPage(2, "More.")]
        try await Self.publish(fixture, store, mediaKind: .manga, pages: mixed)
        let preparer = makePreparer(store: store, content: ReaderContentSource(remote: nil), remote: nil)

        var asText = Self.chapter
        asText.kind = .text
        var asPages = Self.chapter
        asPages.kind = .images
        let text = try await preparer.prepareChapter(entry: Self.mangaEntry, chapter: asText, operation: makeTestNetworkOperation())
        let pages = try await preparer.prepareChapter(entry: Self.mangaEntry, chapter: asPages, operation: makeTestNetworkOperation())

        #expect(text.format == .text)
        #expect(pages.format == .pages)
        #expect(text.pages.count == 3 && pages.pages.count == 3)
        #expect(text.pages.map(\.index) == [0, 1, 2])
    }

    // MARK: - Source stages

    @Test func withoutACopyTheDeclaredKindPicksTheOneExportOnce() async throws {
        let remote = RemoteCounter()
        let preparer = makePreparer(content: ReaderContentSource(remote: ItoRunner()), remote: remote)
        var text = Self.chapter
        text.kind = .text

        let novel = try await preparer.prepareChapter(entry: Self.mangaEntry, chapter: text, operation: makeTestNetworkOperation())
        let pages = try await preparer.prepareChapter(entry: Self.mangaEntry, chapter: Self.chapter, operation: makeTestNetworkOperation())

        #expect(novel.format == .text)
        #expect(pages.format == .pages)
        #expect(remote.novelKeys == ["chapter-1"])
        #expect(remote.mangaKeys == ["chapter-1"])
        #expect(pages.pages.map(\.index) == [1, 2])
    }

    @Test func theOperationReachesTheSourceUnchanged() async throws {
        let remote = RemoteCounter()
        let preparer = makePreparer(content: ReaderContentSource(remote: ItoRunner()), remote: remote)
        let operation = makeTestNetworkOperation()

        _ = try await preparer.prepareChapter(entry: Self.mangaEntry, chapter: Self.chapter, operation: operation)

        #expect(remote.operations == [operation])
    }

    @Test func aChapterWithNeitherACopyNorASourceIsNotDownloaded() async throws {
        let preparer = makePreparer(content: ReaderContentSource(remote: nil), remote: nil)

        await #expect(throws: OfflineReadError.notDownloaded) {
            try await preparer.prepareChapter(entry: Self.mangaEntry, chapter: Self.chapter, operation: makeTestNetworkOperation())
        }
    }

    @Test func readOnlineThisTimeStaysOnTheSourceUntilTheCopyIsAskedFor() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1")
        let remote = RemoteCounter()
        let preparer = makePreparer(
            store: store,
            content: ReaderContentSource(remote: ItoRunner(), preference: .remoteThisTime(chapterKey: "chapter-1")),
            remote: remote
        )

        let online = try await preparer.prepareChapter(entry: Self.mangaEntry, chapter: Self.chapter, operation: makeTestNetworkOperation())
        #expect(preparer.isReadingRemoteThisTime(chapterKey: "chapter-1"))
        #expect(online.resolver.readsFromSource(chapterKey: "chapter-1"))

        preparer.readLocalFirst(chapterKey: "chapter-1")
        let local = try await preparer.prepareChapter(entry: Self.mangaEntry, chapter: Self.chapter, operation: makeTestNetworkOperation())

        #expect(!preparer.isReadingRemoteThisTime(chapterKey: "chapter-1"))
        #expect(remote.mangaKeys == ["chapter-1"], "The copy was read the second time")
        #expect(local.pages.count == 3)
    }

    @Test func aNeighborIsLocalFirstEvenWhenTheOpeningChapterReadsOnline() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-2")
        let remote = RemoteCounter()
        let preparer = makePreparer(
            store: store,
            content: ReaderContentSource(remote: ItoRunner(), preference: .remoteThisTime(chapterKey: "chapter-1")),
            remote: remote
        )

        let neighbor = try await preparer.prepareChapter(
            entry: Self.mangaEntry, chapter: Chapter(key: "chapter-2"), operation: makeTestNetworkOperation()
        )

        #expect(remote.mangaKeys.isEmpty)
        #expect(neighbor.pages.count == 3)
    }

    // MARK: - The selected saved copy

    @Test func aSelectedCopyOverridesTheLiveFormReadsItsOwnLeaseAndNeverAsksASource() async throws {
        let real = try await RealAlternativeFixture.make(
            upload: .upload("b", group: "Other", groupID: "g-b"),
            pages: [OfflineStoreFixture.textPage(0, "Selected words.")]
        )
        let lease = try await real.openLease()
        let destination = try MediaDetailReaderDestination.downloadedAlternative(
            real.candidate, lease: lease,
            of: .manga(Manga(key: "series-1", title: "Series One", chapters: [.upload("a"), .upload("b")])),
            remote: nil, pluginID: Self.pluginID
        )
        guard case .text(_, let content, _, let entry, let chapter) = destination else {
            Issue.record("A copy saved as text opens in the text reader")
            return
        }
        let remote = RemoteCounter()
        let preparer = makePreparer(store: real.store, content: content, remote: remote)

        let prepared = try await preparer.prepareChapter(entry: entry, chapter: chapter, operation: makeTestNetworkOperation())
        // The catalog says images for the neighbors, the copy says text: the copy decides for itself.
        let neighbor = Chapter.upload("a")

        #expect(prepared.format == .text)
        #expect(prepared.chapter.key == "b")
        #expect(entry.kind == .manga)
        #expect(remote.mangaKeys.isEmpty && remote.novelKeys.isEmpty)
        _ = neighbor
    }

    @Test func aSelectedCopyThatNoLongerMatchesFailsLocallyAndNeverFallsBackToTheSource() async throws {
        let real = try await RealAlternativeFixture.make(pages: [OfflineStoreFixture.textPage(0, "Selected words.")])
        let lease = try await real.openLease()
        let destination = try MediaDetailReaderDestination.downloadedAlternative(
            real.candidate, lease: lease,
            of: .manga(Manga(key: "series-1", title: "Series One", chapters: [.upload("a"), .upload("b")])),
            remote: ItoRunner(), pluginID: Self.pluginID
        )
        guard case .text(_, let content, _, _, let chapter) = destination else {
            Issue.record("A copy saved as text opens in the text reader")
            return
        }
        let remote = RemoteCounter()
        let preparer = makePreparer(store: real.store, content: content, remote: remote)
        // Another series with the same chapter key is not the selected copy.
        let otherSeries = MediaEntry.manga(Manga(key: "series-2", title: "Other"))

        await #expect(throws: OfflineReadError.localCopyUnavailable) {
            try await preparer.prepareChapter(entry: otherSeries, chapter: chapter, operation: makeTestNetworkOperation())
        }
        #expect(remote.mangaKeys.isEmpty && remote.novelKeys.isEmpty)
    }
}
