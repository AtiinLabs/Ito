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
        case .pages(_, let runner, let pluginID, let entry, let chapter):
            ReaderView(
                viewModel: makeMangaViewModel(
                    runner: runner,
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
        case .text(_, let runner, let pluginID, let entry, let chapter):
            NovelReaderView(
                viewModel: makeNovelViewModel(
                    runner: runner,
                    pluginID: pluginID,
                    entry: entry,
                    chapter: chapter
                )
            )
        }
    }

    func makeMangaViewModel(
        runner: ItoRunner,
        pluginID: String,
        entry: MediaEntry,
        chapter: Chapter
    ) -> MangaReaderViewModel {
        MangaReaderViewModel(
            pageLoader: ItoRunnerMangaPageLoader(runner: runner),
            pluginID: pluginID,
            entry: entry,
            initialChapter: chapter,
            dependencies: mangaReaderDependencies
        )
    }

    func makeNovelViewModel(
        runner: ItoRunner,
        pluginID: String,
        entry: MediaEntry,
        chapter: Chapter
    ) -> NovelReaderViewModel {
        NovelReaderViewModel(
            chapterLoader: ItoRunnerNovelChapterLoader(runner: runner),
            pluginID: pluginID,
            entry: entry,
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
                    try await runner.search(query: query, page: 1, kind: .manga).entries.compactMap(\.manga)
                }
            },
            makeReaderDestination: { media, chapter in
                .reading(chapter, of: .manga(media), runner: runner, pluginID: pluginID)
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
                    try await runner.search(query: query, page: 1, kind: .anime).entries.compactMap(\.anime)
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
                    try await runner.search(query: query, page: 1, kind: .novel).entries.compactMap(\.novel)
                }
            },
            makeReaderDestination: { media, chapter in
                .reading(chapter, of: .novel(media), runner: runner, pluginID: pluginID)
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
