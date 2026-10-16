import Foundation

@MainActor
struct PreparedApplicationDependencies {
    let settings: PreparedSettingsDependencies
    let tracking: PreparedTrackingDependencies
    let mediaDetail: PreparedMediaDetailDependencies?
    let mangaReader: PreparedMangaReaderDependencies
    let novelReader: PreparedNovelReaderDependencies
    let videoPlayer: PreparedVideoPlayerDependencies
    let backupSettings: PreparedBackupSettingsDependencies
    let migrationReport: PreparedMigrationReportDependencies
    let library: PreparedLibraryDependencies
    let categoryHistory: PreparedCategoryHistoryDependencies
    let searchExecutor: any SearchPluginExecuting
    let recentSearchStore: any RecentSearchPersisting
    let searchDebounceMilliseconds: Int?
    let presentationLogger: any PresentationEventLogging
    let browseRepositoryManager: any BrowseRepositoryManaging
    let repositoryManagement: PreparedRepositoryManagementDependencies
    let browsePluginManager: any BrowsePluginManaging
    let browseFileOperations: any BrowsePluginFileOperating
    let source: PreparedSourceDependencies
    let discoverDetail: PreparedDiscoverDetailDependencies
    let discoverService: any DiscoverHomeFilterServing
    let discoverCache: any DiscoverCaching
    let discoverClock: any DiscoverClock
    let discoverDebounceMilliseconds: Int?

    init(
        settings: PreparedSettingsDependencies,
        tracking: PreparedTrackingDependencies? = nil,
        mediaDetail: PreparedMediaDetailDependencies? = nil,
        mangaReader: PreparedMangaReaderDependencies? = nil,
        novelReader: PreparedNovelReaderDependencies? = nil,
        videoPlayer: PreparedVideoPlayerDependencies? = nil,
        backupSettings: PreparedBackupSettingsDependencies? = nil,
        migrationReport: PreparedMigrationReportDependencies? = nil,
        library: PreparedLibraryDependencies? = nil,
        categoryHistory: PreparedCategoryHistoryDependencies? = nil,
        searchExecutor: any SearchPluginExecuting,
        recentSearchStore: any RecentSearchPersisting,
        searchDebounceMilliseconds: Int?,
        presentationLogger: any PresentationEventLogging,
        browseRepositoryManager: any BrowseRepositoryManaging,
        repositoryManagement: PreparedRepositoryManagementDependencies,
        browsePluginManager: any BrowsePluginManaging,
        browseFileOperations: any BrowsePluginFileOperating,
        source: PreparedSourceDependencies? = nil,
        discoverDetail: PreparedDiscoverDetailDependencies? = nil,
        discoverService: any DiscoverHomeFilterServing = DiscoverManager.shared,
        discoverCache: any DiscoverCaching = InMemoryDiscoverCache(),
        discoverClock: any DiscoverClock = SystemDiscoverClock(),
        discoverDebounceMilliseconds: Int? = DiscoverViewModel.productionDebounceMilliseconds
    ) {
        self.settings = settings
        self.tracking = tracking ?? .unavailable()
        self.mediaDetail = mediaDetail
        self.mangaReader = mangaReader ?? .unavailable()
        self.novelReader = novelReader ?? .unavailable()
        self.videoPlayer = videoPlayer ?? .unavailable()
        self.backupSettings = backupSettings ?? .unavailable()
        self.migrationReport = migrationReport ?? .unavailable()
        self.library = library ?? .unavailable()
        self.categoryHistory = categoryHistory ?? .unavailable()
        self.searchExecutor = searchExecutor
        self.recentSearchStore = recentSearchStore
        self.searchDebounceMilliseconds = searchDebounceMilliseconds
        self.presentationLogger = presentationLogger
        self.browseRepositoryManager = browseRepositoryManager
        self.repositoryManagement = repositoryManagement
        self.browsePluginManager = browsePluginManager
        self.browseFileOperations = browseFileOperations
        self.source = source ?? .unavailable()
        self.discoverDetail = discoverDetail ?? .unavailable()
        self.discoverService = discoverService
        self.discoverCache = discoverCache
        self.discoverClock = discoverClock
        self.discoverDebounceMilliseconds = discoverDebounceMilliseconds
    }

    static func production(
        pluginManager: PluginManager,
        repoManager: RepoManager,
        pluginResolver: PluginResolver,
        settingsStore: AppSettingsStore,
        trackerManager: TrackerManager,
        readProgressManager: ReadProgressManager,
        libraryManager: LibraryManager,
        historyManager: HistoryManager,
        updateManager: UpdateManager,
        backupManager: BackupManager,
        librarySourceRemapper: LibrarySourceRemapper,
        themeManager: ThemeManager,
        notificationManager: NotificationManager,
        storageManager: StorageManager,
        discordRPCManager: DiscordRPCManager,
        sourceMappingRepository: any SourceMappingRepository,
        discoverDetailService: any DiscoverDetailServing,
        discoverDetailThemeService: any DiscoverDetailThemeServing,
        recentSearchDefaults: UserDefaults = .standard,
        browsePluginsDirectory: URL? = nil
    ) -> Self {
        let fileOperations = LocalBrowsePluginFileOperations(
            pluginsDirectory: browsePluginsDirectory
        )
        let tracking = PreparedTrackingDependencies.production(
            trackerManager: trackerManager,
            settingsStore: settingsStore,
            readProgressManager: readProgressManager
        )
        let presentationLogger = OSLogPresentationEventLogger()
        return Self(
            settings: PreparedSettingsDependencies(
                settingsStore: settingsStore,
                notificationAuthorization: notificationManager,
                applicationSettingsOpener: SystemApplicationSettingsOpener(),
                storageAccess: storageManager,
                discordRPCManager: discordRPCManager,
                logReader: SystemDebugLogReader(),
                clipboardWriter: SystemClipboardWriter()
            ),
            tracking: tracking,
            mediaDetail: .production(
                libraryManager: libraryManager,
                readProgressManager: readProgressManager,
                tracking: tracking,
                themeManager: themeManager,
                librarySourceRemapper: librarySourceRemapper,
                updateManager: updateManager,
                settingsStore: settingsStore,
                pluginManager: pluginManager,
                discordRPCManager: discordRPCManager
            ),
            mangaReader: .production(
                readProgressManager: readProgressManager,
                historyManager: historyManager,
                trackerManager: trackerManager,
                settingsStore: settingsStore,
                discordRPCManager: discordRPCManager,
                pluginManager: pluginManager,
                presentationLogger: presentationLogger
            ),
            novelReader: .production(
                readProgressManager: readProgressManager,
                historyManager: historyManager,
                trackerManager: trackerManager,
                settingsStore: settingsStore,
                discordRPCManager: discordRPCManager,
                pluginManager: pluginManager,
                presentationLogger: presentationLogger
            ),
            videoPlayer: .production(
                readProgressManager: readProgressManager,
                historyManager: historyManager,
                trackerManager: trackerManager,
                discordRPCManager: discordRPCManager,
                pluginManager: pluginManager,
                presentationLogger: presentationLogger
            ),
            backupSettings: .production(backupManager: backupManager),
            migrationReport: .production(
                repoManager: repoManager,
                pluginManager: pluginManager,
                librarySourceRemapper: librarySourceRemapper,
                pluginResolver: pluginResolver
            ),
            library: .production(
                libraryManager: libraryManager,
                settingsStore: settingsStore,
                updateManager: updateManager,
                backupManager: backupManager,
                discordRPCManager: discordRPCManager,
                pluginManager: pluginManager,
                repoManager: repoManager
            ),
            categoryHistory: .production(
                libraryManager: libraryManager,
                historyManager: historyManager
            ),
            searchExecutor: PluginManagerSearchExecutor(pluginManager: pluginManager),
            recentSearchStore: UserDefaultsRecentSearchStore(defaults: recentSearchDefaults),
            searchDebounceMilliseconds: SearchViewModel.automaticSearchDebounceMilliseconds,
            presentationLogger: presentationLogger,
            browseRepositoryManager: repoManager,
            repositoryManagement: PreparedRepositoryManagementDependencies(
                repositoryListManager: repoManager,
                repositoryDetailManager: repoManager
            ),
            browsePluginManager: pluginManager,
            browseFileOperations: fileOperations,
            source: PreparedSourceDependencies(
                runnerProvider: pluginManager,
                settingsStore: pluginManager.pluginSettingsStore,
                pluginStatePublisher: pluginManager,
                fileDeletion: fileOperations
            ),
            discoverDetail: PreparedDiscoverDetailDependencies(
                sourceMappingRepository: sourceMappingRepository,
                pluginProvider: pluginManager,
                detailService: discoverDetailService,
                themeService: discoverDetailThemeService,
                sourceRouteFactory: SourceRouteFactory()
            )
        )
    }
}

@MainActor
final class RootModelStore {
    private let makeSearchViewModel: () -> SearchViewModel
    private let makeLibraryViewModel: () -> LibraryViewModel
    private let makeBrowseViewModel: () -> BrowseViewModel
    private let makeDiscoverViewModel: () -> DiscoverViewModel
    private let makeAppearanceSettingsViewModel: () -> AppearanceSettingsViewModel
    private let makeLibrarySettingsViewModel: () -> LibrarySettingsViewModel
    private let makePrivacySettingsViewModel: () -> PrivacySettingsViewModel
    private let makeStorageSettingsViewModel: () -> StorageSettingsViewModel
    private let makeDebugLogViewModel: () -> DebugLogViewModel
    private var storedSearchViewModel: SearchViewModel?
    private var storedLibraryViewModel: LibraryViewModel?
    private var storedBrowseViewModel: BrowseViewModel?
    private var storedDiscoverViewModel: DiscoverViewModel?
    private var storedAppearanceSettingsViewModel: AppearanceSettingsViewModel?
    private var storedLibrarySettingsViewModel: LibrarySettingsViewModel?
    private var storedPrivacySettingsViewModel: PrivacySettingsViewModel?
    private var storedStorageSettingsViewModel: StorageSettingsViewModel?
    private var storedDebugLogViewModel: DebugLogViewModel?

    init(
        preparedDependencies: PreparedApplicationDependencies,
        repositoryIntentRouter: any BrowseRepositoryIntentRouting,
        browseMessagePresenter: any BrowseMessagePresenting,
        debugLogMessagePresenter: any DebugLogMessagePresenting,
        libraryMessagePresenter: any LibraryMessagePresenting
    ) {
        makeLibraryViewModel = {
            LibraryViewModel(
                dependencies: preparedDependencies.library,
                messagePresenter: libraryMessagePresenter,
                presentationLogger: preparedDependencies.presentationLogger
            )
        }
        makeSearchViewModel = {
            SearchViewModel(
                searchExecutor: preparedDependencies.searchExecutor,
                recentSearchStore: preparedDependencies.recentSearchStore,
                debounceMilliseconds: preparedDependencies.searchDebounceMilliseconds,
                presentationLogger: preparedDependencies.presentationLogger
            )
        }
        makeBrowseViewModel = {
            BrowseViewModel(
                repositoryManager: preparedDependencies.browseRepositoryManager,
                pluginManager: preparedDependencies.browsePluginManager,
                fileOperations: preparedDependencies.browseFileOperations,
                messagePresenter: browseMessagePresenter,
                repositoryIntentRouter: repositoryIntentRouter
            )
        }
        makeDiscoverViewModel = {
            DiscoverViewModel(
                service: preparedDependencies.discoverService,
                cache: preparedDependencies.discoverCache,
                clock: preparedDependencies.discoverClock,
                debounceMilliseconds: preparedDependencies.discoverDebounceMilliseconds
            )
        }
        makeAppearanceSettingsViewModel = {
            AppearanceSettingsViewModel(
                settingsStore: preparedDependencies.settings.settingsStore
            )
        }
        makeLibrarySettingsViewModel = {
            LibrarySettingsViewModel(
                settingsStore: preparedDependencies.settings.settingsStore,
                notificationAuthorization: preparedDependencies.settings.notificationAuthorization,
                applicationSettingsOpener: preparedDependencies.settings.applicationSettingsOpener
            )
        }
        makePrivacySettingsViewModel = {
            PrivacySettingsViewModel(
                settingsStore: preparedDependencies.settings.settingsStore,
                discordRPCManager: preparedDependencies.settings.discordRPCManager
            )
        }
        makeStorageSettingsViewModel = {
            StorageSettingsViewModel(
                settingsStore: preparedDependencies.settings.settingsStore,
                storageAccess: preparedDependencies.settings.storageAccess
            )
        }
        makeDebugLogViewModel = {
            DebugLogViewModel(
                logReader: preparedDependencies.settings.logReader,
                clipboardWriter: preparedDependencies.settings.clipboardWriter,
                messagePresenter: debugLogMessagePresenter
            )
        }
    }

    var searchViewModel: SearchViewModel {
        if let storedSearchViewModel { return storedSearchViewModel }
        let viewModel = makeSearchViewModel()
        storedSearchViewModel = viewModel
        return viewModel
    }

    var libraryViewModel: LibraryViewModel {
        if let storedLibraryViewModel { return storedLibraryViewModel }
        let viewModel = makeLibraryViewModel()
        storedLibraryViewModel = viewModel
        return viewModel
    }

    var hasLoadedLibraryViewModel: Bool {
        storedLibraryViewModel != nil
    }

    var hasLoadedSearchViewModel: Bool {
        storedSearchViewModel != nil
    }

    var browseViewModel: BrowseViewModel {
        if let storedBrowseViewModel { return storedBrowseViewModel }
        let viewModel = makeBrowseViewModel()
        storedBrowseViewModel = viewModel
        return viewModel
    }

    var hasLoadedBrowseViewModel: Bool {
        storedBrowseViewModel != nil
    }

    var discoverViewModel: DiscoverViewModel {
        if let storedDiscoverViewModel { return storedDiscoverViewModel }
        let viewModel = makeDiscoverViewModel()
        storedDiscoverViewModel = viewModel
        return viewModel
    }

    var hasLoadedDiscoverViewModel: Bool {
        storedDiscoverViewModel != nil
    }

    var appearanceSettingsViewModel: AppearanceSettingsViewModel {
        if let storedAppearanceSettingsViewModel { return storedAppearanceSettingsViewModel }
        let viewModel = makeAppearanceSettingsViewModel()
        storedAppearanceSettingsViewModel = viewModel
        return viewModel
    }

    var hasLoadedAppearanceSettingsViewModel: Bool {
        storedAppearanceSettingsViewModel != nil
    }

    var librarySettingsViewModel: LibrarySettingsViewModel {
        if let storedLibrarySettingsViewModel { return storedLibrarySettingsViewModel }
        let viewModel = makeLibrarySettingsViewModel()
        storedLibrarySettingsViewModel = viewModel
        return viewModel
    }

    var hasLoadedLibrarySettingsViewModel: Bool {
        storedLibrarySettingsViewModel != nil
    }

    var privacySettingsViewModel: PrivacySettingsViewModel {
        if let storedPrivacySettingsViewModel { return storedPrivacySettingsViewModel }
        let viewModel = makePrivacySettingsViewModel()
        storedPrivacySettingsViewModel = viewModel
        return viewModel
    }

    var hasLoadedPrivacySettingsViewModel: Bool {
        storedPrivacySettingsViewModel != nil
    }

    var storageSettingsViewModel: StorageSettingsViewModel {
        if let storedStorageSettingsViewModel { return storedStorageSettingsViewModel }
        let viewModel = makeStorageSettingsViewModel()
        storedStorageSettingsViewModel = viewModel
        return viewModel
    }

    var hasLoadedStorageSettingsViewModel: Bool {
        storedStorageSettingsViewModel != nil
    }

    var debugLogViewModel: DebugLogViewModel {
        if let storedDebugLogViewModel { return storedDebugLogViewModel }
        let viewModel = makeDebugLogViewModel()
        storedDebugLogViewModel = viewModel
        return viewModel
    }

    var hasLoadedDebugLogViewModel: Bool {
        storedDebugLogViewModel != nil
    }
}

@MainActor
final class AppScope {
    let dependencies: PreparedApplicationDependencies
    let rootModels: RootModelStore
    let viewFactory: AppViewFactory
    let router: AppRouter
    let messageCenter: AppMessageCenter
    let debugLogMessagePresenter: any DebugLogMessagePresenting
    let repositoryManagementMessagePresenter: any RepositoryManagementMessagePresenting
    let sourceMessagePresenter: any SourceMessagePresenting
    let discoverDetailMessagePresenter: any DiscoverDetailMessagePresenting
    let trackingMessagePresenter: any TrackingMessagePresenting
    let mediaDetailMessagePresenter: any MediaDetailMessagePresenting
    let libraryMessagePresenter: any LibraryMessagePresenting
    let categoryHistoryMessagePresenter: any CategoryHistoryMessagePresenting

    init(
        preparedDependencies: PreparedApplicationDependencies,
        router: AppRouter = AppRouter(),
        messageCenter: AppMessageCenter = AppMessageCenter()
    ) {
        dependencies = preparedDependencies
        self.router = router
        self.messageCenter = messageCenter
        let debugLogMessagePresenter = AppMessageDebugLogMessagePresenter(
            messageCenter: messageCenter
        )
        self.debugLogMessagePresenter = debugLogMessagePresenter
        let repositoryManagementMessagePresenter = AppMessageRepositoryManagementPresenter(
            messageCenter: messageCenter
        )
        self.repositoryManagementMessagePresenter = repositoryManagementMessagePresenter
        let sourceMessagePresenter = AppMessageSourcePresenter(messageCenter: messageCenter)
        self.sourceMessagePresenter = sourceMessagePresenter
        let discoverDetailMessagePresenter = AppMessageDiscoverDetailPresenter(
            messageCenter: messageCenter
        )
        self.discoverDetailMessagePresenter = discoverDetailMessagePresenter
        let trackingMessagePresenter = AppMessageTrackingPresenter(messageCenter: messageCenter)
        self.trackingMessagePresenter = trackingMessagePresenter
        let mediaDetailMessagePresenter = AppMessageMediaDetailPresenter(
            messageCenter: messageCenter
        )
        self.mediaDetailMessagePresenter = mediaDetailMessagePresenter
        let libraryMessagePresenter = AppMessageLibraryPresenter(messageCenter: messageCenter)
        self.libraryMessagePresenter = libraryMessagePresenter
        let categoryHistoryMessagePresenter = AppMessageCategoryHistoryPresenter(
            messageCenter: messageCenter
        )
        self.categoryHistoryMessagePresenter = categoryHistoryMessagePresenter
        let rootModels = RootModelStore(
            preparedDependencies: preparedDependencies,
            repositoryIntentRouter: router,
            browseMessagePresenter: AppMessageBrowseMessagePresenter(messageCenter: messageCenter),
            debugLogMessagePresenter: debugLogMessagePresenter,
            libraryMessagePresenter: libraryMessagePresenter
        )
        self.rootModels = rootModels
        self.viewFactory = AppViewFactory(
            rootModels: rootModels,
            repositoryManagement: preparedDependencies.repositoryManagement,
            pluginManager: preparedDependencies.browsePluginManager,
            repositoryMessagePresenter: repositoryManagementMessagePresenter,
            sourceDependencies: preparedDependencies.source,
            sourceMessagePresenter: sourceMessagePresenter,
            discoverDetailDependencies: preparedDependencies.discoverDetail,
            discoverDetailMessagePresenter: discoverDetailMessagePresenter,
            trackingDependencies: preparedDependencies.tracking,
            trackingMessagePresenter: trackingMessagePresenter,
            mediaDetailDependencies: preparedDependencies.mediaDetail,
            mangaReaderDependencies: preparedDependencies.mangaReader,
            novelReaderDependencies: preparedDependencies.novelReader,
            videoPlayerDependencies: preparedDependencies.videoPlayer,
            backupSettingsDependencies: preparedDependencies.backupSettings,
            migrationReportDependencies: preparedDependencies.migrationReport,
            mediaDetailMessagePresenter: mediaDetailMessagePresenter,
            libraryDependencies: preparedDependencies.library,
            categoryHistoryDependencies: preparedDependencies.categoryHistory,
            categoryHistoryMessagePresenter: categoryHistoryMessagePresenter,
            presentationLogger: preparedDependencies.presentationLogger
        )
    }

    static func prepared(
        pluginManager: PluginManager,
        repoManager: RepoManager,
        pluginResolver: PluginResolver,
        settingsStore: AppSettingsStore,
        trackerManager: TrackerManager,
        readProgressManager: ReadProgressManager,
        libraryManager: LibraryManager,
        historyManager: HistoryManager,
        updateManager: UpdateManager,
        backupManager: BackupManager,
        librarySourceRemapper: LibrarySourceRemapper,
        themeManager: ThemeManager,
        notificationManager: NotificationManager,
        storageManager: StorageManager,
        discordRPCManager: DiscordRPCManager,
        sourceMappingRepository: any SourceMappingRepository,
        discoverDetailService: any DiscoverDetailServing,
        discoverDetailThemeService: any DiscoverDetailThemeServing,
        recentSearchDefaults: UserDefaults = .standard,
        browsePluginsDirectory: URL? = nil
    ) -> AppScope {
        AppScope(
            preparedDependencies: .production(
                pluginManager: pluginManager,
                repoManager: repoManager,
                pluginResolver: pluginResolver,
                settingsStore: settingsStore,
                trackerManager: trackerManager,
                readProgressManager: readProgressManager,
                libraryManager: libraryManager,
                historyManager: historyManager,
                updateManager: updateManager,
                backupManager: backupManager,
                librarySourceRemapper: librarySourceRemapper,
                themeManager: themeManager,
                notificationManager: notificationManager,
                storageManager: storageManager,
                discordRPCManager: discordRPCManager,
                sourceMappingRepository: sourceMappingRepository,
                discoverDetailService: discoverDetailService,
                discoverDetailThemeService: discoverDetailThemeService,
                recentSearchDefaults: recentSearchDefaults,
                browsePluginsDirectory: browsePluginsDirectory
            )
        )
    }
}
