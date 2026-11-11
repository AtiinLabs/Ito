import SwiftUI
import ito_runner

@MainActor
struct MediaDetailReaderViewFactory {
    private let mangaReaderDependencies: PreparedMangaReaderDependencies
    private let novelReaderDependencies: PreparedNovelReaderDependencies
    private let videoPlayerDependencies: PreparedVideoPlayerDependencies
    private let offlineReading: any OfflineChapterReading
    private let downloads: any MediaDetailDownloadServing
    private let connectivity: any ConnectivityServing
    private let networkContexts: PluginNetworkContexts

    init(
        mangaReaderDependencies: PreparedMangaReaderDependencies,
        novelReaderDependencies: PreparedNovelReaderDependencies = .unavailable(),
        videoPlayerDependencies: PreparedVideoPlayerDependencies = .unavailable(),
        offlineReading: any OfflineChapterReading = UnavailableOfflineChapterReading(),
        downloads: any MediaDetailDownloadServing = UnavailableMediaDetailDownloads(),
        connectivity: any ConnectivityServing = UnavailableConnectivity(),
        networkContexts: PluginNetworkContexts
    ) {
        self.mangaReaderDependencies = mangaReaderDependencies
        self.novelReaderDependencies = novelReaderDependencies
        self.videoPlayerDependencies = videoPlayerDependencies
        self.offlineReading = offlineReading
        self.downloads = downloads
        self.connectivity = connectivity
        self.networkContexts = networkContexts
    }

    @ViewBuilder
    func destination(for destination: MediaDetailReaderDestination) -> some View {
        switch destination {
        case .pages(_, let content, let pluginID, let entry, let chapter):
            ReaderView(
                viewModel: makeMangaViewModel(
                    content: content,
                    pluginID: pluginID,
                    entry: entry,
                    chapter: chapter
                )
            )
        case .anime(_, let runner, let pluginID, let media, let episode):
            VideoPlayerView(
                viewModel: makeVideoPlayerViewModel(
                    runner: runner,
                    pluginID: pluginID,
                    anime: media,
                    episode: episode
                )
            )
        case .text(_, let content, let pluginID, let entry, let chapter):
            NovelReaderView(
                viewModel: makeNovelViewModel(
                    content: content,
                    pluginID: pluginID,
                    entry: entry,
                    chapter: chapter
                )
            )
        }
    }

    func makeMangaViewModel(
        content: ReaderContentSource,
        pluginID: String,
        entry: MediaEntry,
        chapter: Chapter
    ) -> MangaReaderViewModel {
        let loader = ResolvingMangaPageLoader(
            pluginID: pluginID,
            local: offlineReading,
            remote: content.remote.map {
                ItoRunnerMangaPageLoader(runner: $0, pluginID: pluginID, contexts: networkContexts) as any MangaPageLoading
            },
            preference: content.preference
        )
        return MangaReaderViewModel(
            pageLoader: loader,
            pluginID: pluginID,
            entry: entry,
            initialChapter: chapter,
            dependencies: mangaReaderDependencies,
            offline: makeOfflineContext(pluginID: pluginID, entry: entry, content: content, loader: loader)
        )
    }

    func makeNovelViewModel(
        content: ReaderContentSource,
        pluginID: String,
        entry: MediaEntry,
        chapter: Chapter
    ) -> NovelReaderViewModel {
        let loader = ResolvingNovelChapterLoader(
            pluginID: pluginID,
            local: offlineReading,
            remote: content.remote.map {
                ItoRunnerNovelChapterLoader(runner: $0, pluginID: pluginID, contexts: networkContexts) as any NovelChapterLoading
            },
            preference: content.preference
        )
        return NovelReaderViewModel(
            chapterLoader: loader,
            pluginID: pluginID,
            entry: entry,
            initialChapter: chapter,
            dependencies: novelReaderDependencies,
            offline: makeOfflineContext(pluginID: pluginID, entry: entry, content: content, loader: loader)
        )
    }

    /// The series' stored copies and the network, as the reader's boundaries need them. Where downloads
    /// are unavailable (release builds until they ship) the reader keeps its earlier behavior.
    private func makeOfflineContext(
        pluginID: String,
        entry: MediaEntry,
        content: ReaderContentSource,
        loader: any DownloadedCopyReopening
    ) -> ReaderOfflineContext {
        guard downloads.isAvailable else { return ReaderOfflineContext() }
        return ReaderOfflineContext(
            availability: ObservedReaderOfflineAvailability(
                media: MediaIdentity(pluginId: pluginID, canonicalMediaId: entry.key, mediaKind: entry.kind),
                downloads: downloads,
                connectivity: connectivity
            ),
            isSavedOnly: content.remote == nil,
            downloadedCopy: loader
        )
    }

    func makeVideoPlayerViewModel(
        runner: ItoRunner,
        pluginID: String,
        anime: Anime,
        episode: Anime.Episode
    ) -> VideoPlayerViewModel {
        VideoPlayerViewModel(
            streamLoader: ItoRunnerVideoStreamLoader(runner: runner, pluginID: pluginID, contexts: networkContexts),
            pluginID: pluginID,
            anime: anime,
            episode: episode,
            dependencies: videoPlayerDependencies
        )
    }
}

@MainActor
struct MediaDetailViewFactory {
    private let dependencies: PreparedMediaDetailDependencies
    private let messagePresenter: any MediaDetailMessagePresenting
    private let presentationLogger: any PresentationEventLogging
    private let categoryHistoryViewFactory: CategoryHistoryViewFactory
    private let offlineReading: any OfflineChapterReading
    let trackingViewFactory: TrackingViewFactory
    let readerViewFactory: MediaDetailReaderViewFactory
    private let networkContexts: PluginNetworkContexts

    init(
        dependencies: PreparedMediaDetailDependencies,
        mangaReaderDependencies: PreparedMangaReaderDependencies,
        novelReaderDependencies: PreparedNovelReaderDependencies = .unavailable(),
        videoPlayerDependencies: PreparedVideoPlayerDependencies = .unavailable(),
        offlineReading: any OfflineChapterReading = UnavailableOfflineChapterReading(),
        messagePresenter: any MediaDetailMessagePresenting,
        presentationLogger: any PresentationEventLogging,
        trackingViewFactory: TrackingViewFactory,
        categoryHistoryViewFactory: CategoryHistoryViewFactory,
        networkContexts: PluginNetworkContexts
    ) {
        self.dependencies = dependencies
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger
        self.trackingViewFactory = trackingViewFactory
        self.categoryHistoryViewFactory = categoryHistoryViewFactory
        self.offlineReading = offlineReading
        self.networkContexts = networkContexts
        readerViewFactory = MediaDetailReaderViewFactory(
            mangaReaderDependencies: mangaReaderDependencies,
            novelReaderDependencies: novelReaderDependencies,
            videoPlayerDependencies: videoPlayerDependencies,
            offlineReading: offlineReading,
            downloads: dependencies.downloads,
            connectivity: dependencies.connectivity,
            networkContexts: networkContexts
        )
    }

    /// A nil runner and loader make a saved-only route: the saved series, with downloaded chapters only.
    func makeMangaView(
        runner: ItoRunner?,
        media: Manga,
        pluginID: String,
        loader: ((Manga, PluginNetworkOperation) async throws -> Manga)?,
        openIntent: MediaDetailOpenIntent? = nil
    ) -> MediaDetailView<Manga> {
        let context = MediaDetailRouteContext<Manga>(
            loadDetails: loader,
            searchForRelink: runner.map { mangaRelinkSearch($0, pluginID: pluginID) },
            makeReaderDestination: { media, chapter in
                .reading(
                    chapter,
                    of: .manga(media),
                    content: ReaderContentSource(remote: runner),
                    pluginID: pluginID
                )
            },
            isChapterAvailableOffline: offlineChapterAvailability(
                pluginID: pluginID,
                mediaKind: .manga,
                canonicalMediaId: media.key
            ),
            inventoryChapters: offlineInventory()
        )
        return makeView(media: media, pluginID: pluginID, context: context, openIntent: openIntent)
    }

    func makeAnimeView(
        runner: ItoRunner,
        media: Anime,
        pluginID: String,
        loader: @escaping (Anime, PluginNetworkOperation) async throws -> Anime,
        openIntent: MediaDetailOpenIntent? = nil
    ) -> MediaDetailView<Anime> {
        let contexts = networkContexts
        let context = MediaDetailRouteContext<Anime>(
            loadDetails: loader,
            searchForRelink: { query, operationID in
                let searchContext = contexts.context(
                    pluginID: pluginID,
                    PluginNetworkOperation(purpose: .interactiveSearch, operationID: operationID)
                )
                return try await pluginCall {
                    try await runner.search(query: query, page: 1, kind: .anime, context: searchContext)
                        .entries.compactMap(\.anime)
                }
            },
            makeReaderDestination: { media, episode in
                .anime(
                    id: UUID(),
                    runner: runner,
                    pluginID: pluginID,
                    media: media,
                    episode: episode
                )
            }
        )
        return makeView(media: media, pluginID: pluginID, context: context, openIntent: openIntent)
    }

    /// A nil runner and loader make a saved-only route: the saved series, with downloaded chapters only.
    func makeNovelView(
        runner: ItoRunner?,
        media: Novel,
        pluginID: String,
        loader: ((Novel, PluginNetworkOperation) async throws -> Novel)?,
        openIntent: MediaDetailOpenIntent? = nil
    ) -> MediaDetailView<Novel> {
        let context = MediaDetailRouteContext<Novel>(
            loadDetails: loader,
            searchForRelink: runner.map { novelRelinkSearch($0, pluginID: pluginID) },
            makeReaderDestination: { media, chapter in
                .reading(
                    chapter,
                    of: .novel(media),
                    content: ReaderContentSource(remote: runner),
                    pluginID: pluginID
                )
            },
            isChapterAvailableOffline: offlineChapterAvailability(
                pluginID: pluginID,
                mediaKind: .novel,
                canonicalMediaId: media.key
            ),
            inventoryChapters: offlineInventory()
        )
        return makeView(media: media, pluginID: pluginID, context: context, openIntent: openIntent)
    }

    private func mangaRelinkSearch(
        _ runner: ItoRunner,
        pluginID: String
    ) -> (String, UUID) async throws -> [Manga] {
        let contexts = networkContexts
        return { query, operationID in
            let context = contexts.context(
                pluginID: pluginID,
                PluginNetworkOperation(purpose: .interactiveSearch, operationID: operationID)
            )
            return try await pluginCall {
                try await runner.search(query: query, page: 1, kind: .manga, context: context).entries.compactMap(\.manga)
            }
        }
    }

    private func novelRelinkSearch(
        _ runner: ItoRunner,
        pluginID: String
    ) -> (String, UUID) async throws -> [Novel] {
        let contexts = networkContexts
        return { query, operationID in
            let context = contexts.context(
                pluginID: pluginID,
                PluginNetworkOperation(purpose: .interactiveSearch, operationID: operationID)
            )
            return try await pluginCall {
                try await runner.search(query: query, page: 1, kind: .novel, context: context).entries.compactMap(\.novel)
            }
        }
    }

    /// Whether a chapter has a verified copy for this series. Checked when the chapter is opened, by exact
    /// chapter key only.
    private func offlineChapterAvailability(
        pluginID: String,
        mediaKind: MediaKind,
        canonicalMediaId: String
    ) -> (Chapter) async -> Bool {
        let reader = offlineReading
        let media = MediaIdentity(pluginId: pluginID, canonicalMediaId: canonicalMediaId, mediaKind: mediaKind)
        return { chapter in
            await reader.verifiedEdition(OfflineChapterEdition(media: media, chapterKey: chapter.key))
        }
    }

    /// The stored copies of the series asked for, read when the saved-only rows of a runner route need them.
    /// Nil where no offline store is composed.
    private func offlineInventory() -> ((MediaIdentity) async -> [DownloadedChapterRecord])? {
        let reader = offlineReading
        guard reader.isAvailable else { return nil }
        return { media in
            await reader.inventoryChapters(
                pluginId: media.pluginId,
                mediaKind: media.mediaKind,
                canonicalMediaId: media.canonicalMediaId
            )
        }
    }

    private func makeView<M: MediaDisplayable>(
        media: M,
        pluginID: String,
        context: MediaDetailRouteContext<M>,
        openIntent: MediaDetailOpenIntent?
    ) -> MediaDetailView<M> {
        MediaDetailView(
            viewModel: MediaDetailViewModel(
                media: media,
                pluginID: pluginID,
                routeContext: context,
                dependencies: dependencies,
                messagePresenter: messagePresenter,
                presentationLogger: presentationLogger,
                openIntent: openIntent
            ),
            trackingViewFactory: trackingViewFactory,
            readerViewFactory: readerViewFactory,
            categoryHistoryViewFactory: categoryHistoryViewFactory
        )
    }
}
