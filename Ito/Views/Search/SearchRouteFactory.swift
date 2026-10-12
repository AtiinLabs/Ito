import SwiftUI
import ito_runner

@MainActor
struct AppViewFactory {
    let rootModels: RootModelStore
    let searchRouteFactory: SearchRouteFactory
    private let repositoryManagement: PreparedRepositoryManagementDependencies
    private let pluginManager: any BrowsePluginManaging
    private let repositoryMessagePresenter: any RepositoryManagementMessagePresenting
    private let sourceDependencies: PreparedSourceDependencies
    private let sourceMessagePresenter: any SourceMessagePresenting
    private let discoverDetailDependencies: PreparedDiscoverDetailDependencies
    private let discoverDetailMessagePresenter: any DiscoverDetailMessagePresenting
    private let backupSettingsDependencies: PreparedBackupSettingsDependencies
    private let libraryDependencies: PreparedLibraryDependencies
    private let presentationLogger: any PresentationEventLogging
    let categoryHistoryViewFactory: CategoryHistoryViewFactory
    let trackingViewFactory: TrackingViewFactory
    let mediaDetailViewFactory: MediaDetailViewFactory?

    init(
        rootModels: RootModelStore,
        repositoryManagement: PreparedRepositoryManagementDependencies,
        pluginManager: any BrowsePluginManaging,
        repositoryMessagePresenter: any RepositoryManagementMessagePresenting,
        sourceDependencies: PreparedSourceDependencies,
        sourceMessagePresenter: any SourceMessagePresenting,
        discoverDetailDependencies: PreparedDiscoverDetailDependencies,
        discoverDetailMessagePresenter: any DiscoverDetailMessagePresenting,
        trackingDependencies: PreparedTrackingDependencies,
        trackingMessagePresenter: any TrackingMessagePresenting,
        mediaDetailDependencies: PreparedMediaDetailDependencies?,
        mangaReaderDependencies: PreparedMangaReaderDependencies,
        novelReaderDependencies: PreparedNovelReaderDependencies = .unavailable(),
        videoPlayerDependencies: PreparedVideoPlayerDependencies = .unavailable(),
        backupSettingsDependencies: PreparedBackupSettingsDependencies,
        mediaDetailMessagePresenter: any MediaDetailMessagePresenting,
        libraryDependencies: PreparedLibraryDependencies,
        categoryHistoryDependencies: PreparedCategoryHistoryDependencies,
        categoryHistoryMessagePresenter: any CategoryHistoryMessagePresenting,
        presentationLogger: any PresentationEventLogging,
        searchRouteFactory: SearchRouteFactory? = nil
    ) {
        self.rootModels = rootModels
        self.repositoryManagement = repositoryManagement
        self.pluginManager = pluginManager
        self.repositoryMessagePresenter = repositoryMessagePresenter
        self.sourceDependencies = sourceDependencies
        self.sourceMessagePresenter = sourceMessagePresenter
        self.discoverDetailDependencies = discoverDetailDependencies
        self.discoverDetailMessagePresenter = discoverDetailMessagePresenter
        self.backupSettingsDependencies = backupSettingsDependencies
        self.libraryDependencies = libraryDependencies
        self.presentationLogger = presentationLogger
        let categoryHistoryViewFactory = CategoryHistoryViewFactory(
            dependencies: categoryHistoryDependencies,
            messagePresenter: categoryHistoryMessagePresenter,
            presentationLogger: presentationLogger
        )
        self.categoryHistoryViewFactory = categoryHistoryViewFactory
        let trackingViewFactory = TrackingViewFactory(
            dependencies: trackingDependencies,
            messagePresenter: trackingMessagePresenter,
            presentationLogger: presentationLogger
        )
        self.trackingViewFactory = trackingViewFactory
        let mediaDetailViewFactory = mediaDetailDependencies.map {
            MediaDetailViewFactory(
                dependencies: $0,
                mangaReaderDependencies: mangaReaderDependencies,
                novelReaderDependencies: novelReaderDependencies,
                videoPlayerDependencies: videoPlayerDependencies,
                messagePresenter: mediaDetailMessagePresenter,
                presentationLogger: presentationLogger,
                trackingViewFactory: trackingViewFactory,
                categoryHistoryViewFactory: categoryHistoryViewFactory
            )
        }
        self.mediaDetailViewFactory = mediaDetailViewFactory
        self.searchRouteFactory = searchRouteFactory ?? SearchRouteFactory(
            mediaDetailViewFactory: mediaDetailViewFactory
        )
    }

    func makeSearchView() -> SearchView {
        SearchView(
            viewModel: rootModels.searchViewModel,
            routeFactory: searchRouteFactory
        )
    }

    func makeLibraryView() -> LibraryView {
        LibraryView(
            viewModel: rootModels.libraryViewModel,
            viewFactory: self
        )
    }

    func makeCategoryAssignmentSheet(itemID: String) -> CategoryAssignmentSheet {
        categoryHistoryViewFactory.makeCategoryAssignmentSheet(itemID: itemID)
    }

    func makeCategorySettingsView() -> CategorySettingsView {
        categoryHistoryViewFactory.makeCategorySettingsView()
    }

    func makeHistoryView() -> HistoryView {
        categoryHistoryViewFactory.makeHistoryView()
    }

    func makeDeferredPluginViewModel(item: LibraryItem) -> DeferredPluginViewModel {
        DeferredPluginViewModel(
            item: item,
            plugins: libraryDependencies.plugins,
            installer: libraryDependencies.installer,
            payloadDecoder: libraryDependencies.payloadDecoder,
            presentationLogger: presentationLogger
        )
    }

    func makeDeferredPluginView(item: LibraryItem) -> DeferredPluginView {
        DeferredPluginView(
            item: item,
            viewFactory: self
        )
    }

    @ViewBuilder
    func makeDeferredPluginDestination(_ destination: DeferredPluginDestination) -> some View {
        switch destination {
        case .manga(let pluginID, let runner, let media):
            makeMangaDetailView(
                runner: runner,
                media: media,
                pluginID: pluginID
            ) {
                try await runner.getMangaUpdate(manga: $0)
            }
        case .anime(let pluginID, let runner, let media):
            makeAnimeDetailView(
                runner: runner,
                media: media,
                pluginID: pluginID
            ) {
                try await runner.getAnimeUpdate(
                    anime: $0,
                    needsDetails: true,
                    needsEpisodes: true
                )
            }
        case .novel(let pluginID, let runner, let media):
            makeNovelDetailView(
                runner: runner,
                media: media,
                pluginID: pluginID
            ) {
                try await runner.getNovelUpdate(novel: $0)
            }
        }
    }

    func makeBrowseView() -> BrowseView {
        BrowseView(
            viewModel: rootModels.browseViewModel,
            makeRepositoriesView: makeRepositoriesView,
            makeSourceView: makeSourceView
        )
    }

    func makeSourceView(plugin: InstalledPlugin) -> SourceView {
        SourceView(
            viewModel: makeSourceViewModel(plugin: plugin),
            viewFactory: self
        )
    }

    func makeSourceViewModel(plugin: InstalledPlugin) -> SourceViewModel {
        SourceViewModel(
            plugin: plugin,
            runnerProvider: sourceDependencies.runnerProvider,
            pluginStatePublisher: sourceDependencies.pluginStatePublisher,
            fileDeletion: sourceDependencies.fileDeletion,
            messagePresenter: sourceMessagePresenter
        )
    }

    func makeListingView(destination: SourceListingDestination) -> ListingView {
        ListingView(
            viewModel: makeListingViewModel(destination: destination),
            routeFactory: searchRouteFactory
        )
    }

    func makeListingViewModel(destination: SourceListingDestination) -> ListingViewModel {
        ListingViewModel(destination: destination)
    }

    func makePluginSettingsView(destination: SourceSettingsDestination) -> PluginSettingsView {
        PluginSettingsView(
            viewModel: makePluginSettingsViewModel(destination: destination)
        )
    }

    func makePluginSettingsViewModel(
        destination: SourceSettingsDestination
    ) -> PluginSettingsViewModel {
        PluginSettingsViewModel(
            plugin: destination.plugin,
            schema: destination.schema,
            settingsStore: sourceDependencies.settingsStore,
            messagePresenter: sourceMessagePresenter
        )
    }

    func makeRepositoriesView() -> RepositoriesView {
        RepositoriesView(
            viewModel: RepositoriesViewModel(
                repositoryManager: repositoryManagement.repositoryListManager,
                messagePresenter: repositoryMessagePresenter
            ),
            makeRepoDetailViewModel: makeRepoDetailViewModel
        )
    }

    func makeRepoDetailViewModel(repositoryURL: String) -> RepoDetailViewModel {
        RepoDetailViewModel(
            repositoryURL: repositoryURL,
            repositoryManager: repositoryManagement.repositoryDetailManager,
            pluginManager: pluginManager,
            messagePresenter: repositoryMessagePresenter
        )
    }

    func makeDiscoverView() -> DiscoverView {
        DiscoverView(
            viewModel: rootModels.discoverViewModel,
            viewFactory: self
        )
    }

    func makeDiscoverDetailView(media: DiscoverMedia) -> DiscoverDetailView {
        DiscoverDetailView(
            viewModel: makeDiscoverDetailViewModel(media: media),
            viewFactory: self
        )
    }

    func makeDiscoverDetailViewModel(media: DiscoverMedia) -> DiscoverDetailViewModel {
        let resolver = SourceResolverViewModel(
            media: media,
            repository: discoverDetailDependencies.sourceMappingRepository,
            pluginProvider: discoverDetailDependencies.pluginProvider,
            routeFactory: discoverDetailDependencies.sourceRouteFactory
        )
        return DiscoverDetailViewModel(
            media: media,
            detailService: discoverDetailDependencies.detailService,
            themeService: discoverDetailDependencies.themeService,
            messagePresenter: discoverDetailMessagePresenter,
            pluginProvider: discoverDetailDependencies.pluginProvider,
            sourceResolver: resolver
        )
    }

    func makeSourceDestinationView(
        resolverViewModel: SourceResolverViewModel
    ) -> SourceDestinationHost {
        SourceDestinationHost(resolverViewModel: resolverViewModel, viewFactory: self)
    }

    @ViewBuilder
    func makeMangaDetailView(
        runner: ItoRunner,
        media: Manga,
        pluginID: String,
        loader: @escaping (Manga) async throws -> Manga
    ) -> some View {
        if let mediaDetailViewFactory {
            mediaDetailViewFactory.makeMangaView(
                runner: runner,
                media: media,
                pluginID: pluginID,
                loader: loader
            )
        } else {
            Text("Media details are unavailable.")
        }
    }

    @ViewBuilder
    func makeAnimeDetailView(
        runner: ItoRunner,
        media: Anime,
        pluginID: String,
        loader: @escaping (Anime) async throws -> Anime
    ) -> some View {
        if let mediaDetailViewFactory {
            mediaDetailViewFactory.makeAnimeView(
                runner: runner,
                media: media,
                pluginID: pluginID,
                loader: loader
            )
        } else {
            Text("Media details are unavailable.")
        }
    }

    @ViewBuilder
    func makeNovelDetailView(
        runner: ItoRunner,
        media: Novel,
        pluginID: String,
        loader: @escaping (Novel) async throws -> Novel
    ) -> some View {
        if let mediaDetailViewFactory {
            mediaDetailViewFactory.makeNovelView(
                runner: runner,
                media: media,
                pluginID: pluginID,
                loader: loader
            )
        } else {
            Text("Media details are unavailable.")
        }
    }

    func makeSettingsView() -> SettingsView {
        SettingsView(viewFactory: self)
    }

    @ViewBuilder
    func makeSettingsDestination(for destination: SettingsDestination) -> some View {
        switch destination {
        case .appearance:
            makeAppearanceSettingsView()
        case .library:
            makeLibrarySettingsView()
        case .privacy:
            makePrivacySettingsView()
        case .trackers:
            makeTrackerSettingsView()
        case .backup:
            makeBackupSettingsView()
        case .readerUnavailable:
            Text("Reader Settings View")
        case .storage:
            makeStorageSettingsView()
        case .networkUnavailable:
            Text("Network Settings View")
        case .extensionsUnavailable:
            Text("Manage Extensions View")
        case .debugLogs:
            makeDebugLogView()
        }
    }

    func makeAppearanceSettingsView() -> AppearanceSettingsView {
        AppearanceSettingsView(viewModel: rootModels.appearanceSettingsViewModel)
    }

    func makeLibrarySettingsView() -> LibrarySettingsView {
        LibrarySettingsView(viewModel: rootModels.librarySettingsViewModel)
    }

    func makePrivacySettingsView() -> PrivacySettingsView {
        PrivacySettingsView(viewModel: rootModels.privacySettingsViewModel)
    }

    func makeStorageSettingsView() -> StorageSettingsView {
        StorageSettingsView(viewModel: rootModels.storageSettingsViewModel)
    }

    func makeTrackerSettingsView() -> TrackerSettingsView {
        trackingViewFactory.makeTrackerSettingsView()
    }

    func makeBackupSettingsViewModel() -> BackupSettingsViewModel {
        BackupSettingsViewModel(
            dependencies: backupSettingsDependencies,
            presentationLogger: presentationLogger
        )
    }

    func makeBackupSettingsView() -> BackupSettingsView {
        BackupSettingsView(viewModel: makeBackupSettingsViewModel())
    }

    func makeDebugLogView() -> DebugLogView {
        DebugLogView(viewModel: rootModels.debugLogViewModel)
    }
}

struct SearchRouteFactory {
    private let mediaDetailViewFactory: MediaDetailViewFactory?

    init(mediaDetailViewFactory: MediaDetailViewFactory? = nil) {
        self.mediaDetailViewFactory = mediaDetailViewFactory
    }

    func route(for destination: SearchDestination) -> SearchDetailRoute {
        switch destination {
        case .manga(let pluginID, let context, let media):
            return .manga(
                pluginID: pluginID,
                runner: context.runner,
                media: media,
                loader: context.loadManga
            )
        case .anime(let pluginID, let context, let media):
            return .anime(
                pluginID: pluginID,
                runner: context.runner,
                media: media,
                loader: context.loadAnime
            )
        case .novel(let pluginID, let context, let media):
            return .novel(
                pluginID: pluginID,
                runner: context.runner,
                media: media,
                loader: context.loadNovel
            )
        }
    }

    func destination(for destination: SearchDestination) -> some View {
        SearchDestinationHost(
            route: route(for: destination),
            mediaDetailViewFactory: mediaDetailViewFactory
        )
    }
}

enum SearchDetailRoute {
    case manga(
        pluginID: String,
        runner: ItoRunner,
        media: Manga,
        loader: (Manga) async throws -> Manga
    )
    case anime(
        pluginID: String,
        runner: ItoRunner,
        media: Anime,
        loader: (Anime) async throws -> Anime
    )
    case novel(
        pluginID: String,
        runner: ItoRunner,
        media: Novel,
        loader: (Novel) async throws -> Novel
    )
}

private struct SearchDestinationHost: View {
    let route: SearchDetailRoute
    let mediaDetailViewFactory: MediaDetailViewFactory?

    @ViewBuilder
    var body: some View {
        switch route {
        case .manga(let pluginID, let runner, let media, let loader):
            if let mediaDetailViewFactory {
                mediaDetailViewFactory.makeMangaView(
                    runner: runner,
                    media: media,
                    pluginID: pluginID,
                    loader: loader
                )
            } else {
                Text("Media details are unavailable.")
            }
        case .anime(let pluginID, let runner, let media, let loader):
            if let mediaDetailViewFactory {
                mediaDetailViewFactory.makeAnimeView(
                    runner: runner,
                    media: media,
                    pluginID: pluginID,
                    loader: loader
                )
            } else {
                Text("Media details are unavailable.")
            }
        case .novel(let pluginID, let runner, let media, let loader):
            if let mediaDetailViewFactory {
                mediaDetailViewFactory.makeNovelView(
                    runner: runner,
                    media: media,
                    pluginID: pluginID,
                    loader: loader
                )
            } else {
                Text("Media details are unavailable.")
            }
        }
    }
}
