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
    private let migrationReportDependencies: PreparedMigrationReportDependencies
    private let libraryDependencies: PreparedLibraryDependencies
    private let presentationLogger: any PresentationEventLogging
    private let completionRecovery: (any PluginCompletionRecovering)?
    private let settingsDiagnostics: (any PluginSettingsDiagnosing)?
    private let pluginCookies: PluginCookieJar?
    private let pluginTrust: PluginTrustStore?
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
        migrationReportDependencies: PreparedMigrationReportDependencies,
        mediaDetailMessagePresenter: any MediaDetailMessagePresenting,
        libraryDependencies: PreparedLibraryDependencies,
        categoryHistoryDependencies: PreparedCategoryHistoryDependencies,
        categoryHistoryMessagePresenter: any CategoryHistoryMessagePresenting,
        presentationLogger: any PresentationEventLogging,
        searchRouteFactory: SearchRouteFactory? = nil,
        completionRecovery: (any PluginCompletionRecovering)? = nil,
        settingsDiagnostics: (any PluginSettingsDiagnosing)? = nil,
        pluginCookies: PluginCookieJar? = nil,
        pluginTrust: PluginTrustStore? = nil
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
        self.migrationReportDependencies = migrationReportDependencies
        self.libraryDependencies = libraryDependencies
        self.presentationLogger = presentationLogger
        self.completionRecovery = completionRecovery
        self.settingsDiagnostics = settingsDiagnostics
        self.pluginCookies = pluginCookies
        self.pluginTrust = pluginTrust
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
            routeFactory: searchRouteFactory,
            makePluginSettings: { makePluginSettingsSheet(pluginID: $0) },
            signInTarget: { signInTarget(pluginID: $0) },
            makePluginSignIn: { makePluginSignInSheet(target: $0) },
            pendingTrust: { pendingTrust(for: $0) },
            trustAction: { request, retry in trustAction(for: request, retry: retry) }
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
            ) { manga in
                try await pluginCall { try await runner.getMediaUpdate(.manga(manga)).expecting(\.manga) }
            }
        case .anime(let pluginID, let runner, let media):
            makeAnimeDetailView(
                runner: runner,
                media: media,
                pluginID: pluginID
            ) { anime in
                try await pluginCall { try await runner.getMediaUpdate(.anime(anime)).expecting(\.anime) }
            }
        case .novel(let pluginID, let runner, let media):
            makeNovelDetailView(
                runner: runner,
                media: media,
                pluginID: pluginID
            ) { novel in
                try await pluginCall { try await runner.getMediaUpdate(.novel(novel)).expecting(\.novel) }
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
            surface: destination.surface,
            runnerProvider: sourceDependencies.runnerProvider,
            settingsStore: sourceDependencies.settingsStore,
            messagePresenter: sourceMessagePresenter,
            completionRecovery: completionRecovery,
            diagnostics: settingsDiagnostics
        )
    }

    func makePluginSettingsSheet(pluginID: String) -> PluginSettingsRecoverySheet {
        PluginSettingsRecoverySheet(
            viewModel: PluginSettingsLoaderViewModel(
                plugin: pluginManager.installedPlugins[pluginID],
                runnerProvider: sourceDependencies.runnerProvider
            ),
            viewFactory: self
        )
    }

    /// The source's website for signing in, or nil when it has none or sign-in isn't available.
    func signInTarget(pluginID: String) -> PluginSignInTarget? {
        guard pluginCookies != nil, let plugin = pluginManager.installedPlugins[pluginID] else { return nil }
        return PluginSignInTarget(pluginID: plugin.id, pluginName: plugin.info.name, siteURL: plugin.info.url)
    }

    /// The sign-in sheet for `target`; nil when sign-in isn't available in this app scope.
    func makePluginSignInSheet(target: PluginSignInTarget) -> PluginSignInSheet? {
        guard let pluginCookies else { return nil }
        let runnerProvider = sourceDependencies.runnerProvider
        return PluginSignInSheet(viewModel: PluginSignInViewModel(
            target: target,
            cookieJar: pluginCookies,
            evictRunner: { runnerProvider.evictSourceRunner(for: $0) }
        ))
    }

    func pendingTrust(for pluginID: String) -> PendingTrust? {
        pluginTrust?.pending(pluginID: pluginID)
    }

    /// The sheet shows, and Trust approves, the certificate the source is waiting on now: a
    /// later request may have met a rotated certificate since `request` was captured.
    func trustAction(for request: PendingTrust, retry: @escaping () -> Void) -> TrustCertificateAction {
        let current = pluginTrust?.pending(pluginID: request.pluginID) ?? request
        return TrustCertificateAction(
            request: current,
            sourceName: sourceName(pluginID: current.pluginID),
            confirm: { [pluginTrust, pluginManager, sourceDependencies] in
                guard let pluginTrust, pluginManager.installedPlugins[current.pluginID] != nil else {
                    throw PluginTrustConfirmationError.staleRequest
                }
                try pluginTrust.confirm(current)
                sourceDependencies.runnerProvider.evictSourceRunner(for: current.pluginID)
            },
            onSuccess: retry
        )
    }

    func sourceName(pluginID: String) -> String {
        pluginManager.installedPlugins[pluginID]?.info.name ?? pluginID
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
            routeFactory: discoverDetailDependencies.sourceRouteFactory,
            libraryObserver: discoverDetailDependencies.libraryObserver,
            trackerLinker: discoverDetailDependencies.trackerLinker
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
        case .storage:
            makeStorageSettingsView()
        case .network:
            makeNetworkSettingsView()
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

    func makeNetworkSettingsView() -> NetworkSettingsView {
        NetworkSettingsView(viewModel: rootModels.networkSettingsViewModel)
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
        BackupSettingsView(
            viewModel: makeBackupSettingsViewModel(),
            makeMigrationReportViewModel: { makeMigrationReportViewModel(report: $0) }
        )
    }

    func makeMigrationReportViewModel(report: MigrationReport) -> MigrationReportViewModel {
        MigrationReportViewModel(
            report: report,
            dependencies: migrationReportDependencies,
            presentationLogger: presentationLogger
        )
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
