import Combine
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
    private let signIn: PluginSignInSheets

    init(
        mangaReaderDependencies: PreparedMangaReaderDependencies,
        novelReaderDependencies: PreparedNovelReaderDependencies = .unavailable(),
        videoPlayerDependencies: PreparedVideoPlayerDependencies = .unavailable(),
        offlineReading: any OfflineChapterReading = UnavailableOfflineChapterReading(),
        downloads: any MediaDetailDownloadServing = UnavailableMediaDetailDownloads(),
        connectivity: any ConnectivityServing = UnavailableConnectivity(),
        networkContexts: PluginNetworkContexts,
        signIn: PluginSignInSheets = .unavailable
    ) {
        self.mangaReaderDependencies = mangaReaderDependencies
        self.novelReaderDependencies = novelReaderDependencies
        self.videoPlayerDependencies = videoPlayerDependencies
        self.offlineReading = offlineReading
        self.downloads = downloads
        self.connectivity = connectivity
        self.networkContexts = networkContexts
        self.signIn = signIn
    }

    @ViewBuilder
    func destination(for destination: MediaDetailReaderDestination) -> some View {
        switch destination {
        case .pages(let id, let content, let pluginID, let entry, let chapter):
            ReaderRouteView(
                coordinator: makeRoute(content: content, pluginID: pluginID, entry: entry, chapter: chapter, format: .pages),
                signIn: signIn
            )
            .id(id)
        case .anime(_, let runner, let pluginID, let media, let episode):
            VideoPlayerView(
                viewModel: makeVideoPlayerViewModel(
                    runner: runner,
                    pluginID: pluginID,
                    anime: media,
                    episode: episode
                )
            )
        case .text(let id, let content, let pluginID, let entry, let chapter):
            ReaderRouteView(
                coordinator: makeRoute(content: content, pluginID: pluginID, entry: entry, chapter: chapter, format: .text),
                signIn: signIn
            )
            .id(id)
        }
    }

    /// The one coordinator of a reader opening. It lives as long as the opening's route view and moves the
    /// route between the page reader and the text reader; the detail screen never learns of the swap.
    func makeRoute(
        content: ReaderContentSource,
        pluginID: String,
        entry: MediaEntry,
        chapter: Chapter,
        format: HistoryReaderFormat
    ) -> ReaderRouteCoordinator {
        let session = ReaderRouteSession(
            media: MediaIdentity(pluginId: pluginID, canonicalMediaId: entry.key, mediaKind: entry.kind),
            mediaKey: entry.key,
            scope: mangaReaderDependencies.progress
        )
        return ReaderRouteCoordinator(
            rootID: UUID(),
            pluginID: pluginID,
            entry: entry,
            chapter: chapter,
            format: format,
            session: session,
            preparer: makeChapterPreparer(content: content, pluginID: pluginID),
            presentations: ReaderRouteComposition(factory: self, pluginID: pluginID, content: content),
            settings: mangaReaderDependencies.settings,
            network: PluginContextsReaderRouteNetwork(contexts: networkContexts)
        )
    }

    /// Prepares any chapter of one opening, with the opening's own source choice.
    func makeChapterPreparer(content: ReaderContentSource, pluginID: String) -> any ReaderChapterPreparing {
        MediaDetailReaderChapterPreparer(
            pluginID: pluginID,
            content: content,
            local: offlineReading,
            remoteManga: content.remote.map {
                ItoRunnerMangaPageLoader(runner: $0, pluginID: pluginID, contexts: networkContexts) as any MangaPageLoading
            },
            remoteNovel: content.remote.map {
                ItoRunnerNovelChapterLoader(runner: $0, pluginID: pluginID, contexts: networkContexts) as any NovelChapterLoading
            }
        )
    }

    func makeMangaViewModel(
        content: ReaderContentSource,
        pluginID: String,
        entry: MediaEntry,
        chapter: Chapter,
        session: ReaderRouteSession,
        preparer: any ReaderChapterPreparing,
        visitID: UUID,
        mode: ReaderPresentationMode
    ) -> MangaReaderViewModel {
        MangaReaderViewModel(
            chapterPreparer: preparer,
            routeSession: session,
            routeVisitID: visitID,
            presentationMode: mode,
            pluginID: pluginID,
            entry: entry,
            initialChapter: chapter,
            dependencies: mangaReaderDependencies,
            offline: makeOfflineContext(pluginID: pluginID, entry: entry, content: content)
        )
    }

    func makeNovelViewModel(
        content: ReaderContentSource,
        pluginID: String,
        entry: MediaEntry,
        chapter: Chapter,
        session: ReaderRouteSession,
        preparer: any ReaderChapterPreparing,
        visitID: UUID,
        mode: ReaderPresentationMode
    ) -> NovelReaderViewModel {
        NovelReaderViewModel(
            chapterPreparer: preparer,
            routeSession: session,
            routeVisitID: visitID,
            presentationMode: mode,
            pluginID: pluginID,
            entry: entry,
            initialChapter: chapter,
            dependencies: novelReaderDependencies,
            offline: makeOfflineContext(pluginID: pluginID, entry: entry, content: content)
        )
    }

    /// The series' stored copies and the network, as the reader's boundaries need them. Where downloads
    /// are unavailable (release builds until they ship) the reader keeps its earlier behavior.
    private func makeOfflineContext(
        pluginID: String,
        entry: MediaEntry,
        content: ReaderContentSource
    ) -> ReaderOfflineContext {
        guard downloads.isAvailable else { return ReaderOfflineContext() }
        return ReaderOfflineContext(
            availability: ObservedReaderOfflineAvailability(
                media: MediaIdentity(pluginId: pluginID, canonicalMediaId: entry.key, mediaKind: entry.kind),
                downloads: downloads,
                connectivity: connectivity
            ),
            isSavedOnly: content.remote == nil
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
    private let signIn: PluginSignInSheets

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
        networkContexts: PluginNetworkContexts,
        signIn: PluginSignInSheets
    ) {
        self.dependencies = dependencies
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger
        self.trackingViewFactory = trackingViewFactory
        self.categoryHistoryViewFactory = categoryHistoryViewFactory
        self.offlineReading = offlineReading
        self.networkContexts = networkContexts
        self.signIn = signIn
        readerViewFactory = MediaDetailReaderViewFactory(
            mangaReaderDependencies: mangaReaderDependencies,
            novelReaderDependencies: novelReaderDependencies,
            videoPlayerDependencies: videoPlayerDependencies,
            offlineReading: offlineReading,
            downloads: dependencies.downloads,
            connectivity: dependencies.connectivity,
            networkContexts: networkContexts,
            signIn: signIn
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
            makeDownloadedAlternativeDestination: { media, candidate, lease in
                try .downloadedAlternative(
                    candidate,
                    lease: lease,
                    of: .manga(media),
                    remote: runner,
                    pluginID: pluginID
                )
            },
            isChapterAvailableOffline: offlineChapterAvailability(
                pluginID: pluginID,
                mediaKind: .manga,
                canonicalMediaId: media.key
            ),
            inventoryChapters: offlineInventory(),
            enumerateEditions: editionEnumeration(runner: runner, pluginID: pluginID)
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
            },
            makeDownloadedAlternativeDestination: { _, _, _ in
                // An episode has no chapter reader, and the screen never offers this action.
                throw DownloadedAlternativeError.unsupportedMediaKind
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
            makeDownloadedAlternativeDestination: { media, candidate, lease in
                try .downloadedAlternative(
                    candidate,
                    lease: lease,
                    of: .novel(media),
                    remote: runner,
                    pluginID: pluginID
                )
            },
            isChapterAvailableOffline: offlineChapterAvailability(
                pluginID: pluginID,
                mediaKind: .novel,
                canonicalMediaId: media.key
            ),
            inventoryChapters: offlineInventory(),
            enumerateEditions: editionEnumeration(runner: runner, pluginID: pluginID)
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

    /// The source's optional listing of every exact upload, for the explicit "Find All Uploads" action only.
    /// Nil on a saved-only route, which has no source to ask.
    private func editionEnumeration(runner: ItoRunner?, pluginID: String) -> ChapterEditionEnumeration? {
        guard let runner else { return nil }
        let adapter = ChapterEditionsAdapter(runner: runner, pluginID: pluginID, contexts: networkContexts)
        return { entry, operation, sourceEpoch in
            try await adapter.enumerate(entry, operation: operation, sourceEpoch: sourceEpoch)
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
            categoryHistoryViewFactory: categoryHistoryViewFactory,
            signIn: signIn
        )
    }
}

// MARK: - Chapter preparation

/// Loads one chapter of a reader opening with the form it is actually stored or served in, so a reader is
/// chosen from what the chapter is rather than from what the catalog declared.
@MainActor
protocol ReaderChapterPreparing: AnyObject {
    func prepareChapter(
        entry: MediaEntry,
        chapter: Chapter,
        operation: PluginNetworkOperation
    ) async throws -> ReaderPreparedChapter
    /// Whether the chapter is held on the installed source for this opening only.
    func isReadingRemoteThisTime(chapterKey: String) -> Bool
    /// Ends that choice: the chapter reads local-first from its next preparation on.
    func readLocalFirst(chapterKey: String)
}

/// One opening's chapter preparation. A resolver is made for each new chapter and handed to the payload that
/// is returned, so the pins of a copy live exactly as long as the content that reads it; this object keeps
/// none. The chapter is fetched once: a verified copy is read from its own lease, and otherwise the source's
/// one chapter export is called, as the chapter's declared kind says.
@MainActor
final class MediaDetailReaderChapterPreparer: ReaderChapterPreparing {
    private let pluginID: String
    private let content: ReaderContentSource
    private let local: any OfflineChapterReading
    let remoteManga: (any MangaPageLoading)?
    let remoteNovel: (any NovelChapterLoading)?
    /// Chapters whose "read online this time" choice the user ended.
    private var releasedRemoteKeys: Set<ExactChapterKey> = []

    init(
        pluginID: String,
        content: ReaderContentSource,
        local: any OfflineChapterReading,
        remoteManga: (any MangaPageLoading)?,
        remoteNovel: (any NovelChapterLoading)?
    ) {
        self.pluginID = pluginID
        self.content = content
        self.local = local
        self.remoteManga = remoteManga
        self.remoteNovel = remoteNovel
    }

    private var preference: ReaderContentPreference {
        if case .remoteThisTime(let key) = content.preference, releasedRemoteKeys.contains(ExactChapterKey(key)) {
            return .localFirst
        }
        return content.preference
    }

    func isReadingRemoteThisTime(chapterKey: String) -> Bool {
        guard content.remote != nil, case .remoteThisTime(let key) = preference else { return false }
        return key == chapterKey
    }

    func readLocalFirst(chapterKey: String) {
        releasedRemoteKeys.insert(ExactChapterKey(chapterKey))
    }

    func prepareChapter(
        entry: MediaEntry,
        chapter: Chapter,
        operation: PluginNetworkOperation
    ) async throws -> ReaderPreparedChapter {
        let resolver = OfflineChapterSourceResolver(
            pluginID: pluginID,
            local: local,
            hasRemote: content.remote != nil,
            preference: preference
        )
        var pages: [Page]?
        var savedForm: OfflineContentKind?
        if case .local(let lease) = try await resolver.source(for: entry, chapter: chapter) {
            pages = try await resolver.localPages(lease, chapter: chapter)
            if pages != nil { savedForm = lease.manifest.contentKind }
        }
        let declared = entry.contentKind(of: chapter)
        let kind: ContentKind
        switch savedForm {
        case .text?: kind = .text
        case .images?: kind = .images
        case .mixed?, nil: kind = declared
        }
        if pages == nil {
            // The documented fallback of an unreadable ordinary copy, or no copy at all.
            pages = try await remotePages(kind: kind, entry: entry, chapter: chapter, operation: operation)
        }
        guard let pages else { throw OfflineReadError.notDownloaded }
        var overridden = chapter
        overridden.kind = kind
        return ReaderPreparedChapter(
            entry: kind == declared ? entry : entry.pinning(overridden),
            chapter: chapter,
            pages: ReaderPageOrdering.ascending(pages),
            format: kind == .text ? .text : .pages,
            resolver: resolver,
            content: content
        )
    }

    private func remotePages(
        kind: ContentKind,
        entry: MediaEntry,
        chapter: Chapter,
        operation: PluginNetworkOperation
    ) async throws -> [Page] {
        switch kind {
        case .text:
            guard let remoteNovel else { throw OfflineReadError.notDownloaded }
            return try await remoteNovel.content(for: entry, chapter: chapter, operation: operation)
        case .images:
            guard let remoteManga else { throw OfflineReadError.notDownloaded }
            return try await remoteManga.pages(for: entry, chapter: chapter, operation: operation)
        }
    }
}

// MARK: - Route composition

/// Builds the readers of one route from the factory: the first one, and the destinations a handoff stages.
@MainActor
struct ReaderRouteComposition: ReaderRoutePresentationMaking {
    let factory: MediaDetailReaderViewFactory
    let pluginID: String
    let content: ReaderContentSource

    func makeInitialPresentation(
        format: HistoryReaderFormat,
        entry: MediaEntry,
        chapter: Chapter,
        session: ReaderRouteSession,
        preparer: any ReaderChapterPreparing,
        visitID: UUID
    ) -> ReaderRoutePresentation {
        switch format {
        case .text:
            .text(visitID: visitID, factory.makeNovelViewModel(
                content: content, pluginID: pluginID, entry: entry, chapter: chapter,
                session: session, preparer: preparer, visitID: visitID, mode: .live
            ))
        case .pages, .video:
            .pages(visitID: visitID, factory.makeMangaViewModel(
                content: content, pluginID: pluginID, entry: entry, chapter: chapter,
                session: session, preparer: preparer, visitID: visitID, mode: .live
            ))
        }
    }

    func makePreparedPresentation(
        _ prepared: ReaderPreparedChapter,
        position: ReaderEntryPosition,
        session: ReaderRouteSession,
        preparer: any ReaderChapterPreparing,
        visitID: UUID,
        mode: ReaderPresentationMode
    ) -> ReaderRoutePresentation {
        switch prepared.format {
        case .text:
            let model = factory.makeNovelViewModel(
                content: content, pluginID: pluginID, entry: prepared.entry, chapter: prepared.chapter,
                session: session, preparer: preparer, visitID: visitID, mode: mode
            )
            model.installPreparedChapter(prepared.pages, position: position)
            model.retain(prepared)
            return .text(visitID: visitID, model)
        case .pages, .video:
            let model = factory.makeMangaViewModel(
                content: content, pluginID: pluginID, entry: prepared.entry, chapter: prepared.chapter,
                session: session, preparer: preparer, visitID: visitID, mode: mode
            )
            model.installPreparedChapter(prepared.pages, position: position)
            model.retain(prepared)
            return .pages(visitID: visitID, model)
        }
    }
}

/// The live network facts of the plugin contexts, read by a route and never captured.
@MainActor
final class PluginContextsReaderRouteNetwork: ReaderRouteNetworking {
    private let contexts: PluginNetworkContexts

    init(contexts: PluginNetworkContexts) {
        self.contexts = contexts
    }

    func liveScope(pluginID: String) -> UUID { contexts.liveScope(pluginID: pluginID) }
    var policyRevision: UInt64 { contexts.policy.revision }
    var pathGeneration: UInt64 { contexts.policy.pathGeneration }

    var policyChanges: AnyPublisher<Void, Never> { contexts.policy.changes }
    var scopeChanges: AnyPublisher<Void, Never> { contexts.scopeChanges }
}
