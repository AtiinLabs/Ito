import SwiftUI
import ito_runner

@MainActor
struct MediaDetailReaderViewFactory {
    private let mangaReaderDependencies: PreparedMangaReaderDependencies
    private let novelReaderDependencies: PreparedNovelReaderDependencies
    private let videoPlayerDependencies: PreparedVideoPlayerDependencies

    init(
        mangaReaderDependencies: PreparedMangaReaderDependencies,
        novelReaderDependencies: PreparedNovelReaderDependencies = .unavailable(),
        videoPlayerDependencies: PreparedVideoPlayerDependencies = .unavailable()
    ) {
        self.mangaReaderDependencies = mangaReaderDependencies
        self.novelReaderDependencies = novelReaderDependencies
        self.videoPlayerDependencies = videoPlayerDependencies
    }

    @ViewBuilder
    func destination(for destination: MediaDetailReaderDestination) -> some View {
        switch destination {
        case .manga(_, let runner, let pluginID, let media, let chapter):
            ReaderView(
                viewModel: makeMangaViewModel(
                    runner: runner,
                    pluginID: pluginID,
                    manga: media,
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
        case .novel(_, let runner, let pluginID, let media, let chapter):
            NovelReaderView(
                viewModel: makeNovelViewModel(
                    runner: runner,
                    pluginID: pluginID,
                    novel: media,
                    chapter: chapter
                )
            )
        }
    }

    func makeMangaViewModel(
        runner: ItoRunner,
        pluginID: String,
        manga: Manga,
        chapter: Manga.Chapter
    ) -> MangaReaderViewModel {
        MangaReaderViewModel(
            pageLoader: ItoRunnerMangaPageLoader(runner: runner),
            pluginID: pluginID,
            manga: manga,
            initialChapter: chapter,
            dependencies: mangaReaderDependencies
        )
    }

    func makeNovelViewModel(
        runner: ItoRunner,
        pluginID: String,
        novel: Novel,
        chapter: Novel.Chapter
    ) -> NovelReaderViewModel {
        NovelReaderViewModel(
            chapterLoader: ItoRunnerNovelChapterLoader(runner: runner),
            pluginID: pluginID,
            novel: novel,
            initialChapter: chapter,
            dependencies: novelReaderDependencies
        )
    }

    func makeVideoPlayerViewModel(
        runner: ItoRunner,
        pluginID: String,
        anime: Anime,
        episode: Anime.Episode
    ) -> VideoPlayerViewModel {
        VideoPlayerViewModel(
            streamLoader: ItoRunnerVideoStreamLoader(runner: runner),
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
    let trackingViewFactory: TrackingViewFactory
    let readerViewFactory: MediaDetailReaderViewFactory

    init(
        dependencies: PreparedMediaDetailDependencies,
        mangaReaderDependencies: PreparedMangaReaderDependencies,
        novelReaderDependencies: PreparedNovelReaderDependencies = .unavailable(),
        videoPlayerDependencies: PreparedVideoPlayerDependencies = .unavailable(),
        messagePresenter: any MediaDetailMessagePresenting,
        presentationLogger: any PresentationEventLogging,
        trackingViewFactory: TrackingViewFactory,
        categoryHistoryViewFactory: CategoryHistoryViewFactory
    ) {
        self.dependencies = dependencies
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger
        self.trackingViewFactory = trackingViewFactory
        self.categoryHistoryViewFactory = categoryHistoryViewFactory
        readerViewFactory = MediaDetailReaderViewFactory(
            mangaReaderDependencies: mangaReaderDependencies,
            novelReaderDependencies: novelReaderDependencies,
            videoPlayerDependencies: videoPlayerDependencies
        )
    }

    func makeMangaView(
        runner: ItoRunner,
        media: Manga,
        pluginID: String,
        loader: @escaping (Manga) async throws -> Manga
    ) -> MediaDetailView<Manga> {
        let context = MediaDetailRouteContext<Manga>(
            loadDetails: loader,
            searchForRelink: { query in
                try await pluginCall {
                    try await runner.getSearchMangaList(query: query, page: 1, filters: nil).entries
                }
            },
            makeReaderDestination: { media, chapter in
                .manga(
                    id: UUID(),
                    runner: runner,
                    pluginID: pluginID,
                    media: media,
                    chapter: chapter
                )
            }
        )
        return makeView(media: media, pluginID: pluginID, context: context)
    }

    func makeAnimeView(
        runner: ItoRunner,
        media: Anime,
        pluginID: String,
        loader: @escaping (Anime) async throws -> Anime
    ) -> MediaDetailView<Anime> {
        let context = MediaDetailRouteContext<Anime>(
            loadDetails: loader,
            searchForRelink: { query in
                try await pluginCall {
                    try await runner.getSearchAnimeList(query: query, page: 1, filters: nil).entries
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
        return makeView(media: media, pluginID: pluginID, context: context)
    }

    func makeNovelView(
        runner: ItoRunner,
        media: Novel,
        pluginID: String,
        loader: @escaping (Novel) async throws -> Novel
    ) -> MediaDetailView<Novel> {
        let context = MediaDetailRouteContext<Novel>(
            loadDetails: loader,
            searchForRelink: { query in
                try await pluginCall {
                    try await runner.getSearchNovelList(query: query, page: 1, filters: nil).entries
                }
            },
            makeReaderDestination: { media, chapter in
                .novel(
                    id: UUID(),
                    runner: runner,
                    pluginID: pluginID,
                    media: media,
                    chapter: chapter
                )
            }
        )
        return makeView(media: media, pluginID: pluginID, context: context)
    }

    private func makeView<M: MediaDisplayable>(
        media: M,
        pluginID: String,
        context: MediaDetailRouteContext<M>
    ) -> MediaDetailView<M> {
        MediaDetailView(
            viewModel: MediaDetailViewModel(
                media: media,
                pluginID: pluginID,
                routeContext: context,
                dependencies: dependencies,
                messagePresenter: messagePresenter,
                presentationLogger: presentationLogger
            ),
            trackingViewFactory: trackingViewFactory,
            readerViewFactory: readerViewFactory,
            categoryHistoryViewFactory: categoryHistoryViewFactory
        )
    }
}
