import Foundation
import Testing
import ito_runner
@testable import Ito

/// Reading a downloaded chapter from its source for one opening, and keeping what an open chapter reads.
@MainActor
struct ReaderReadOnlineThisTimeTests {
    private static let entry = MediaEntry.manga(Manga(key: "series-1", title: "Series One"))
    private static let first = Chapter(key: "chapter-1", title: "One")
    private static let second = Chapter(key: "chapter-2", title: "Two")

    private enum RemoteFailure: Error { case offline }

    @Test func remoteThisTimePinsOnlyThatChapterAndLeavesItsNeighborLocalFirst() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1")
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-2")
        let remote = ScriptedRemotePages()
        let loader = ResolvingMangaPageLoader(
            pluginID: "plugin.test",
            local: store,
            remote: remote,
            preference: .remoteThisTime(chapterKey: "chapter-1")
        )

        let online = try await loader.pages(for: Self.entry, chapter: Self.first)
        let neighbor = try await loader.pages(for: Self.entry, chapter: Self.second)
        let onlineAgain = try await loader.pages(for: Self.entry, chapter: Self.first)

        #expect(remote.requestedKeys == ["chapter-1", "chapter-1"])
        #expect(Self.isRemote(online))
        #expect(Self.isRemote(onlineAgain))
        #expect(!Self.isRemote(neighbor))
        #expect(neighbor.count == 3)
    }

    @Test func aLocalFirstOpeningReadsTheCopyAndNeverTheSource() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1")
        let remote = ScriptedRemotePages()
        let loader = ResolvingMangaPageLoader(pluginID: "plugin.test", local: store, remote: remote)

        let pages = try await loader.pages(for: Self.entry, chapter: Self.first)

        #expect(remote.requestedKeys.isEmpty)
        #expect(!Self.isRemote(pages))
    }

    @Test func theChoiceCannotOverrideAMissingSource() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1")
        let loader = ResolvingMangaPageLoader(
            pluginID: "plugin.test",
            local: store,
            remote: nil,
            preference: .remoteThisTime(chapterKey: "chapter-1")
        )

        let pages = try await loader.pages(for: Self.entry, chapter: Self.first)

        #expect(!Self.isRemote(pages))
        #expect(!loader.isReadingRemoteThisTime(chapterKey: "chapter-1"))
        #expect(!loader.readsFromSource(chapterKey: "chapter-1"))
    }

    @Test func readDownloadedCopyReopensLocalFirstAfterTheSourceFails() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1")
        let remote = ScriptedRemotePages(failure: RemoteFailure.offline)
        let loader = ResolvingMangaPageLoader(
            pluginID: "plugin.test",
            local: store,
            remote: remote,
            preference: .remoteThisTime(chapterKey: "chapter-1")
        )

        await #expect(throws: RemoteFailure.offline) {
            try await loader.pages(for: Self.entry, chapter: Self.first)
        }
        #expect(loader.isReadingRemoteThisTime(chapterKey: "chapter-1"))
        #expect(loader.readsFromSource(chapterKey: "chapter-1"))

        loader.readDownloadedCopy(chapterKey: "chapter-1")
        let pages = try await loader.pages(for: Self.entry, chapter: Self.first)

        #expect(!loader.isReadingRemoteThisTime(chapterKey: "chapter-1"))
        #expect(!loader.readsFromSource(chapterKey: "chapter-1"))
        #expect(!Self.isRemote(pages))
        #expect(remote.requestedKeys == ["chapter-1"])
    }

    @Test func dropTheOnlineChoiceNeverReleasesACopyThatIsAlreadyOpen() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1")
        // Without a source the choice cannot apply: the chapter opens from its copy and keeps it.
        let loader = ResolvingMangaPageLoader(
            pluginID: "plugin.test",
            local: store,
            remote: nil,
            preference: .remoteThisTime(chapterKey: "chapter-1")
        )
        _ = try await loader.pages(for: Self.entry, chapter: Self.first)
        try await store.delete(OfflineStoreFixture.mangaEdition)

        loader.readDownloadedCopy(chapterKey: "chapter-1")
        let pages = try await loader.pages(for: Self.entry, chapter: Self.first)

        #expect(pages.count == 3)
    }

    // MARK: - The reader's "Read Downloaded Copy"

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func thePageReaderOffersTheDownloadedCopyOnlyWithAVerifiedCopyAndThenShowsIt() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "chapter-1")
        let subject = makeMangaReaderSubject(manga: Manga(key: "series-1", title: "Series One"), initialChapter: Self.first)
        let availability = ReaderAvailabilityFake()
        let online = ResolvingMangaPageLoader(
            pluginID: "plugin.test",
            local: store,
            remote: ScriptedRemotePages(failure: RemoteFailure.offline),
            preference: .remoteThisTime(chapterKey: "chapter-1")
        )
        let viewModel = MangaReaderViewModel(
            pageLoader: online,
            pluginID: "plugin.test",
            entry: Self.entry,
            initialChapter: Self.first,
            dependencies: subject.dependencies,
            offline: ReaderOfflineContext(availability: availability, downloadedCopy: online)
        )
        #expect(!viewModel.canReadDownloadedCopy)
        viewModel.start()
        await viewModel.waitForTestingOperations()
        guard case .failure = viewModel.loadPhase else {
            Issue.record("The source failed, so the chapter does not load")
            return
        }

        // No verified copy is known: nothing is offered and nothing changes.
        #expect(!viewModel.canReadDownloadedCopy)
        viewModel.readDownloadedCopy()
        #expect(online.isReadingRemoteThisTime(chapterKey: "chapter-1"))

        availability.verified = ["chapter-1"]
        #expect(viewModel.canReadDownloadedCopy)
        viewModel.disappear()
        viewModel.readDownloadedCopy()
        #expect(online.isReadingRemoteThisTime(chapterKey: "chapter-1"))

        viewModel.appear()
        viewModel.readDownloadedCopy()
        await viewModel.waitForTestingOperations()

        #expect(viewModel.loadPhase == .content)
        #expect(viewModel.pagedPages.count == 3)
        #expect(!viewModel.canReadDownloadedCopy)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func theTextReaderOffersTheDownloadedCopyOnlyWithAVerifiedCopyAndThenShowsIt() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let jobID = try await fixture.enqueue(store, chapterKey: "chapter-1")
        _ = try await store.perform(
            .publish(jobID: jobID, pages: [OfflineStoreFixture.textPage(0, "Stored text.")], commitGuard: { _ in true }),
            through: .all
        )
        let subject = makeNovelReaderSubject(novel: Novel(key: "series-1", title: "Series One"), initialChapter: Self.first)
        let availability = ReaderAvailabilityFake()
        let online = ResolvingNovelChapterLoader(
            pluginID: "plugin.test",
            local: store,
            remote: ScriptedRemoteText(failure: RemoteFailure.offline),
            preference: .remoteThisTime(chapterKey: "chapter-1")
        )
        let viewModel = NovelReaderViewModel(
            chapterLoader: online,
            pluginID: "plugin.test",
            entry: Self.entry,
            initialChapter: Self.first,
            dependencies: subject.dependencies,
            offline: ReaderOfflineContext(availability: availability, downloadedCopy: online)
        )
        viewModel.start()
        await viewModel.waitForCurrentMainLoadForTesting()
        guard case .failure = viewModel.loadPhase else {
            Issue.record("The source failed, so the chapter does not load")
            return
        }

        #expect(!viewModel.canReadDownloadedCopy)
        viewModel.readDownloadedCopy()
        #expect(online.isReadingRemoteThisTime(chapterKey: "chapter-1"))

        availability.verified = ["chapter-1"]
        #expect(viewModel.canReadDownloadedCopy)
        viewModel.disappear()
        viewModel.readDownloadedCopy()
        #expect(online.isReadingRemoteThisTime(chapterKey: "chapter-1"))

        viewModel.appear()
        viewModel.readDownloadedCopy()
        await viewModel.waitForCurrentMainLoadForTesting()

        #expect(viewModel.loadPhase == .content)
        #expect(viewModel.loadedChapters.first.flatMap { Self.text($0.pages) } == "Stored text.")
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aLocalFirstReaderThatFailsOffersNoDownloadedCopy() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        let subject = makeMangaReaderSubject(manga: Manga(key: "series-1", title: "Series One"), initialChapter: Self.first)
        let loader = ResolvingMangaPageLoader(pluginID: "plugin.test", local: store, remote: nil)
        let viewModel = MangaReaderViewModel(
            pageLoader: loader,
            pluginID: "plugin.test",
            entry: Self.entry,
            initialChapter: Self.first,
            dependencies: subject.dependencies,
            offline: ReaderOfflineContext(availability: ReaderAvailabilityFake(verified: ["chapter-1"]), downloadedCopy: loader)
        )

        viewModel.start()
        await viewModel.waitForTestingOperations()

        guard case .failure = viewModel.loadPhase else {
            Issue.record("A chapter without a copy or a source does not load")
            return
        }
        #expect(!viewModel.canReadDownloadedCopy)
    }

    // MARK: - Revision pinning

    @Test func anOpenChapterKeepsItsVersionAfterADeleteAndRedownloadAndTheNextOpeningReadsTheNewOne() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        try await Self.publish(fixture, store, text: "Version one.")
        var open: ResolvingNovelChapterLoader? = ResolvingNovelChapterLoader(
            pluginID: "plugin.test",
            local: store,
            remote: nil
        )
        weak var released = open
        let before = try await #require(open).content(for: Self.entry, chapter: Self.first)
        #expect(Self.text(before) == "Version one.")

        try await store.delete(OfflineStoreFixture.mangaEdition)
        try await Self.publish(fixture, store, text: "Version two.")

        // The reader that is still open keeps reading the version it opened, and its files stay on disk.
        let whileOpen = try await #require(open).content(for: Self.entry, chapter: Self.first)
        #expect(Self.text(whileOpen) == "Version one.")
        #expect(fixture.fileSystem.childNames(of: fixture.versionsURL).count == 2)

        // Closing it releases the lease: the old version is reclaimed and nothing holds the loader.
        open = nil
        await store.leases.awaitReclamations()
        #expect(released == nil)
        #expect(fixture.fileSystem.childNames(of: fixture.versionsURL).count == 1)

        // The next opening reads what is stored now.
        let reopened = ResolvingNovelChapterLoader(pluginID: "plugin.test", local: store, remote: nil)
        let after = try await reopened.content(for: Self.entry, chapter: Self.first)
        #expect(Self.text(after) == "Version two.")
    }

    // MARK: - Helpers

    private static func publish(_ fixture: OfflineStoreFixture, _ store: OfflineChapterStore, text: String) async throws {
        let jobID = try await fixture.enqueue(store, chapterKey: "chapter-1")
        let outcome = try await store.perform(
            .publish(jobID: jobID, pages: [OfflineStoreFixture.textPage(0, text)], commitGuard: { _ in true }),
            through: .all
        )
        guard case .published(_)? = outcome else { throw OfflineStoreFixtureError.notPublished }
    }

    private static func text(_ pages: [Page]) -> String? {
        guard case .text(let text)? = pages.first?.content else { return nil }
        return text
    }

    /// A page the source returned, as opposed to one addressed through the offline locator.
    private static func isRemote(_ pages: [Page]) -> Bool {
        pages.contains { page in
            guard case .url(let url) = page.content else { return false }
            return url.hasPrefix("https://remote.example.test/")
        }
    }
}

@MainActor
private final class ScriptedRemotePages: MangaPageLoading {
    private let failure: (any Error)?
    private(set) var requestedKeys: [String] = []

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func pages(for entry: MediaEntry, chapter: Chapter) async throws -> [Page] {
        _ = entry
        requestedKeys.append(chapter.key)
        if let failure { throw failure }
        return [Page(index: 0, content: .url("https://remote.example.test/\(chapter.key)/p0000.jpg"))]
    }
}

@MainActor
private final class ScriptedRemoteText: NovelChapterLoading {
    private let failure: any Error

    init(failure: any Error) {
        self.failure = failure
    }

    func content(for entry: MediaEntry, chapter: Chapter) async throws -> [Page] {
        _ = (entry, chapter)
        throw failure
    }
}
