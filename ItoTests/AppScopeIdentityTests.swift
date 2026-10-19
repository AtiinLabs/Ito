import Combine
import XCTest
@testable import Ito
import ito_runner

@MainActor
final class AppScopeIdentityTests: XCTestCase {
    func testRepeatedRootAndTabRecomputationReturnsSameLibraryViewModel() {
        let scope = makeScope()

        XCTAssertFalse(scope.rootModels.hasLoadedLibraryViewModel)
        let first = scope.rootModels.libraryViewModel
        _ = scope.viewFactory.makeLibraryView()
        let second = scope.viewFactory.rootModels.libraryViewModel
        _ = scope.viewFactory.makeLibraryView()
        let third = scope.rootModels.libraryViewModel

        XCTAssertTrue(first === second)
        XCTAssertTrue(second === third)
        XCTAssertTrue(scope.rootModels.hasLoadedLibraryViewModel)
    }

    func testNewPreparedRuntimeEpochReceivesNewLibraryViewModel() {
        let firstScope = makeScope()
        let secondScope = makeScope()

        XCTAssertFalse(
            firstScope.rootModels.libraryViewModel
                === secondScope.rootModels.libraryViewModel
        )
    }

    func testCategoryAndHistoryViewModelsAreFreshPerPresentationAndNotRootStored() throws {
        let scope = makeScope()
        let factory = scope.viewFactory.categoryHistoryViewFactory

        let firstAssignment = factory.makeCategoryAssignmentViewModel(itemID: "first")
        let secondAssignment = factory.makeCategoryAssignmentViewModel(itemID: "second")
        let firstSettings = factory.makeCategorySettingsViewModel()
        let secondSettings = factory.makeCategorySettingsViewModel()
        let firstHistory = factory.makeHistoryViewModel()
        let secondHistory = factory.makeHistoryViewModel()
        let source = try sourceFile("Ito/AppScope.swift")
        let rootStart = try XCTUnwrap(source.range(of: "final class RootModelStore"))
        let scopeStart = try XCTUnwrap(source.range(of: "final class AppScope"))
        let rootModelStore = String(source[rootStart.lowerBound..<scopeStart.lowerBound])

        XCTAssertEqual(firstAssignment.itemID, "first")
        XCTAssertEqual(secondAssignment.itemID, "second")
        XCTAssertFalse(firstAssignment === secondAssignment)
        XCTAssertFalse(firstSettings === secondSettings)
        XCTAssertFalse(firstHistory === secondHistory)
        XCTAssertFalse(rootModelStore.contains("CategoryAssignmentViewModel"))
        XCTAssertFalse(rootModelStore.contains("CategorySettingsViewModel"))
        XCTAssertFalse(rootModelStore.contains("HistoryViewModel"))
    }

    func testDeferredPluginViewModelIsScreenOwnedAndNotStoredInRootModelStore() throws {
        let scope = makeScope()
        let item = Ito.LibraryItem(
            id: "item",
            title: "Item",
            coverUrl: nil,
            pluginId: "plugin",
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil
        )

        let first = scope.viewFactory.makeDeferredPluginViewModel(item: item)
        let second = scope.viewFactory.makeDeferredPluginViewModel(item: item)
        let source = try sourceFile("Ito/AppScope.swift")

        XCTAssertFalse(first === second)
        XCTAssertFalse(source.contains("storedDeferredPluginViewModel"))
        XCTAssertFalse(source.contains("hasLoadedDeferredPluginViewModel"))
    }

    func testRepeatedRootAndTabRecomputationReturnsSameSearchViewModel() {
        let scope = makeScope()

        let first = scope.rootModels.searchViewModel
        _ = scope.viewFactory.makeSearchView()
        let second = scope.viewFactory.rootModels.searchViewModel
        _ = scope.viewFactory.makeSearchView()
        let third = scope.rootModels.searchViewModel

        XCTAssertTrue(first === second)
        XCTAssertTrue(second === third)
    }

    func testNewPreparedRuntimeEpochReceivesNewSearchViewModel() {
        let firstScope = makeScope()
        let secondScope = makeScope()

        XCTAssertFalse(firstScope === secondScope)
        XCTAssertFalse(
            firstScope.rootModels.searchViewModel
                === secondScope.rootModels.searchViewModel
        )
    }

    func testRepeatedRootAndTabRecomputationReturnsSameDiscoverViewModel() {
        let scope = makeScope()

        let first = scope.rootModels.discoverViewModel
        _ = scope.viewFactory.makeDiscoverView()
        let second = scope.viewFactory.rootModels.discoverViewModel
        _ = scope.viewFactory.makeDiscoverView()
        let third = scope.rootModels.discoverViewModel

        XCTAssertTrue(first === second)
        XCTAssertTrue(second === third)
    }

    func testNewPreparedRuntimeEpochReceivesNewDiscoverViewModel() {
        let firstScope = makeScope()
        let secondScope = makeScope()

        XCTAssertFalse(firstScope === secondScope)
        XCTAssertFalse(
            firstScope.rootModels.discoverViewModel
                === secondScope.rootModels.discoverViewModel
        )
    }

    func testSearchDependenciesAndModelAreNotDuplicated() {
        let executor = AppScopeSearchExecutor()
        let store = AppScopeRecentStore()
        let dependencies = PreparedApplicationDependencies(
            settings: makeTestPreparedSettingsDependencies(),
            searchExecutor: executor,
            recentSearchStore: store,
            searchDebounceMilliseconds: nil,
            presentationLogger: PresentationEventCaptureSpy(),
            browseRepositoryManager: AppScopeBrowseRepositoryManager(),
            repositoryManagement: makeTestRepositoryManagementDependencies(),
            browsePluginManager: AppScopeBrowsePluginManager(),
            browseFileOperations: AppScopeBrowseFileOperations()
        )
        let scope = AppScope(preparedDependencies: dependencies)

        XCTAssertFalse(scope.rootModels.hasLoadedSearchViewModel)
        let first = scope.rootModels.searchViewModel
        let second = scope.rootModels.searchViewModel

        XCTAssertTrue(first === second)
        XCTAssertTrue(scope.dependencies.searchExecutor === executor)
        XCTAssertEqual(store.loadCallCount, 1)
    }

    func testSearchConstructionIsLazyWithinPreparedScope() {
        let scope = makeScope()

        XCTAssertFalse(scope.rootModels.hasLoadedSearchViewModel)
        _ = scope.viewFactory.makeSearchView()
        XCTAssertTrue(scope.rootModels.hasLoadedSearchViewModel)
    }

    func testDiscoverDependenciesAndModelAreNotDuplicated() {
        let service = AppScopeDiscoverService()
        let cache = InMemoryDiscoverCache()
        let clock = AppScopeDiscoverClock()
        let dependencies = PreparedApplicationDependencies(
            settings: makeTestPreparedSettingsDependencies(),
            searchExecutor: AppScopeSearchExecutor(),
            recentSearchStore: AppScopeRecentStore(),
            searchDebounceMilliseconds: nil,
            presentationLogger: PresentationEventCaptureSpy(),
            browseRepositoryManager: AppScopeBrowseRepositoryManager(),
            repositoryManagement: makeTestRepositoryManagementDependencies(),
            browsePluginManager: AppScopeBrowsePluginManager(),
            browseFileOperations: AppScopeBrowseFileOperations(),
            discoverService: service,
            discoverCache: cache,
            discoverClock: clock,
            discoverDebounceMilliseconds: nil
        )
        let scope = AppScope(preparedDependencies: dependencies)

        XCTAssertFalse(scope.rootModels.hasLoadedDiscoverViewModel)
        let first = scope.rootModels.discoverViewModel
        let second = scope.rootModels.discoverViewModel

        XCTAssertTrue(first === second)
        XCTAssertTrue(scope.dependencies.discoverService === service)
        XCTAssertTrue(scope.dependencies.discoverCache === cache)
        XCTAssertTrue(scope.dependencies.discoverClock === clock)
    }

    func testDiscoverConstructionIsLazyWithinPreparedScope() {
        let scope = makeScope()

        XCTAssertFalse(scope.rootModels.hasLoadedDiscoverViewModel)
        _ = scope.viewFactory.makeDiscoverView()
        XCTAssertTrue(scope.rootModels.hasLoadedDiscoverViewModel)
    }

    func testDiscoverDetailIsScreenOwnedAndNotStoredInRootModelStore() throws {
        let scope = makeScope()
        let media = DiscoverMedia(
            id: 12,
            title: "Detail",
            titleEnglish: nil,
            titleRomaji: nil,
            titleNative: nil,
            synonyms: [],
            coverImage: nil,
            bannerImage: nil,
            format: nil,
            status: nil,
            description: nil,
            cleanDescription: nil,
            genres: nil,
            averageScore: nil,
            episodes: nil,
            chapters: nil,
            season: nil,
            seasonYear: nil,
            type: "MANGA",
            recommendations: nil
        )

        let first = scope.viewFactory.makeDiscoverDetailViewModel(media: media)
        let second = scope.viewFactory.makeDiscoverDetailViewModel(media: media)
        let source = try sourceFile("Ito/AppScope.swift")

        XCTAssertEqual(first.media.id, media.id)
        XCTAssertEqual(first.media.title, media.title)
        XCTAssertFalse(first === second)
        XCTAssertFalse(first.sourceResolver === second.sourceResolver)
        XCTAssertFalse(source.contains("storedDiscoverDetailViewModel"))
        XCTAssertFalse(source.contains("hasLoadedDiscoverDetailViewModel"))
    }

    func testMigrationReportFactoryCreatesFreshRemediatingModelsOutsideRootStore() {
        let scope = makeScope()
        let report = MigrationReport(unresolvedPlugins: [], totalItemsImported: 0, totalItemsSkipped: 0)

        let first = scope.viewFactory.makeMigrationReportViewModel(report: report)
        let second = scope.viewFactory.makeMigrationReportViewModel(report: report)

        XCTAssertFalse(first === second)
        XCTAssertTrue(first.isRemediationAllowed)
        XCTAssertTrue(second.isRemediationAllowed)
    }

    func testSettingsRootFactoryDoesNotEagerlyLoadAnySettingsViewModel() {
        let scope = makeScope()

        XCTAssertFalse(scope.rootModels.hasLoadedAppearanceSettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedLibrarySettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedPrivacySettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedStorageSettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedDebugLogViewModel)

        _ = scope.viewFactory.makeSettingsView()

        XCTAssertFalse(scope.rootModels.hasLoadedAppearanceSettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedLibrarySettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedPrivacySettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedStorageSettingsViewModel)
        XCTAssertFalse(scope.rootModels.hasLoadedDebugLogViewModel)
    }

    func testAppScopeIsUnavailableBeforeRuntimePreparation() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: {},
            sourceDatabaseURL: database.databaseURL,
            installedPluginsDirectory: database.databaseURL
                .deletingLastPathComponent()
                .appendingPathComponent("Plugins", isDirectory: true)
        )

        XCTAssertNil(bootstrap.appScope)
        let prepared = await bootstrap.prepare()
        XCTAssertTrue(prepared)
        XCTAssertNotNil(bootstrap.appScope)
        XCTAssertFalse(try XCTUnwrap(bootstrap.appScope).rootModels.hasLoadedSearchViewModel)
        XCTAssertFalse(try XCTUnwrap(bootstrap.appScope).rootModels.hasLoadedDiscoverViewModel)
        XCTAssertFalse(try XCTUnwrap(bootstrap.appScope).rootModels.hasLoadedLibraryViewModel)
    }

    func testRootFactoriesAndViewsContainNoLegacyEnvironmentObjectWiring() throws {
        let appSource = try sourceFile("Ito/ItoApp.swift")
        let tabSource = try sourceFile("Ito/Views/MainTabView.swift")
        let viewsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Ito/Views")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: viewsRoot, includingPropertiesForKeys: nil)
        )
        let viewSources = try enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }

        XCTAssertFalse(appSource.contains(".environmentObject("))
        XCTAssertFalse(appSource.contains("@EnvironmentObject"))
        XCTAssertFalse(tabSource.contains("trackingViewFactory"))
        for viewSource in viewSources {
            XCTAssertFalse(viewSource.contains("@EnvironmentObject"))
            XCTAssertFalse(viewSource.contains(".environmentObject("))
            XCTAssertFalse(viewSource.contains("TrackingViewFactoryEnvironmentKey"))
        }
        for tabFactoryCall in [
            "appScope.viewFactory.makeLibraryView()",
            "appScope.viewFactory.makeBrowseView()",
            "appScope.viewFactory.makeDiscoverView()",
            "appScope.viewFactory.makeSearchView()",
            "appScope.viewFactory.makeSettingsView()"
        ] {
            XCTAssertTrue(tabSource.contains(tabFactoryCall))
        }
    }

    func testUITestFixtureStorageAndDefaultsAreIsolatedFromProduction() throws {
        let appSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let productionDatabaseURL = appSupportURL.appendingPathComponent(
            UITestLaunchConfiguration.productionDatabaseDirectoryName,
            isDirectory: true
        )
        let fixtureDatabaseURL = try UITestLaunchConfiguration.fixtureRootURL()
            .appendingPathComponent(
                UITestLaunchConfiguration.fixtureDatabaseDirectoryName,
                isDirectory: true
            )

        XCTAssertNotEqual(
            productionDatabaseURL.standardizedFileURL,
            fixtureDatabaseURL.standardizedFileURL
        )
        XCTAssertNotEqual(
            UITestLaunchConfiguration.fixtureDefaultsSuiteName,
            Bundle.main.bundleIdentifier
        )
        XCTAssertNotEqual(
            UITestLaunchConfiguration.fixtureTrackerKeychainService,
            KeychainTrackerCredentialStore.productionService
        )
        XCTAssertTrue(
            UITestLaunchConfiguration(
                resetsStorage: true,
                repositoryDeepLinkEnabled: false,
                backupWipeEnabled: false
            ).isEnabled
        )
    }

    func testPreparedDependenciesUseInjectedDefaultsAndPluginDirectory() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let suiteName = "AppScopeIdentityTests.\(UUID().uuidString)"
        let fixtureDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { fixtureDefaults.removePersistentDomain(forName: suiteName) }
        let recentSearchSentinel = "fixture-\(UUID().uuidString)"
        fixtureDefaults.set(
            [recentSearchSentinel],
            forKey: UserDefaultsRecentSearchStore.key
        )

        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pluginsDirectory = fixtureRoot.appendingPathComponent(
            "Plugins",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let pluginSettings = PluginSettingsStore(dbPool: database.dbPool)
        let pluginManager = PluginManager(
            pluginSettingsStore: pluginSettings,
            pluginsDirectory: pluginsDirectory
        )
        let repoManager = RepoManager(
            dbPool: database.dbPool,
            pluginManager: pluginManager
        )
        let settingsStore = AppSettingsStore(dbPool: database.dbPool)
        let trackerManager = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: fixtureDefaults
        )
        let readProgressManager = ReadProgressManager(dbPool: database.dbPool)
        let libraryManager = LibraryManager(dbPool: database.dbPool)
        let historyManager = HistoryManager(
            dbPool: database.dbPool,
            libraryManager: libraryManager
        )
        let updateManager = UpdateManager(dbPool: database.dbPool)
        let noOpRefresh: BackupRestoreRefresher.RefreshOperations.Operation = {}
        let backupManager = BackupManager(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            exportReadiness: {},
            restoreRefresher: BackupRestoreRefresher(
                dbPool: database.dbPool,
                operations: .init(
                    appSettings: noOpRefresh,
                    pluginIdentity: noOpRefresh,
                    pluginSettings: noOpRefresh,
                    repositories: noOpRefresh,
                    userImporterAliases: noOpRefresh,
                    library: noOpRefresh,
                    history: noOpRefresh,
                    readProgress: noOpRefresh,
                    trackerLinks: noOpRefresh,
                    updateBadges: noOpRefresh,
                    storage: noOpRefresh,
                    appearance: noOpRefresh
                )
            )
        )
        let librarySourceRemapper = LibrarySourceRemapper(dbPool: database.dbPool)
        let notificationManager = NotificationManager()
        let storageManager = StorageManager(pluginManager: pluginManager)
        let discordRPCManager = DiscordRPCManager(
            libraryManager: libraryManager
        )
        let sourceMappingRepository = GRDBSourceMappingRepository(
            dbWriter: database.dbPool
        )
        let pluginResolver = PluginResolver(
            dbPool: database.dbPool,
            repoManager: repoManager,
            installedPluginIds: { [] }
        )
        let dependencies = PreparedApplicationDependencies.production(
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
            themeManager: ThemeManager.shared,
            notificationManager: notificationManager,
            storageManager: storageManager,
            discordRPCManager: discordRPCManager,
            sourceMappingRepository: sourceMappingRepository,
            discoverDetailService: DiscoverManager.shared,
            discoverDetailThemeService: ThemeManager.shared,
            recentSearchDefaults: fixtureDefaults,
            browsePluginsDirectory: pluginsDirectory
        )

        XCTAssertTrue(dependencies.settings.settingsStore === settingsStore)
        XCTAssertTrue(dependencies.tracking.settingsStore === settingsStore)
        XCTAssertTrue(dependencies.tracking.localProgressReader === readProgressManager)
        XCTAssertTrue(
            dependencies.tracking.settingsService as AnyObject
                === dependencies.tracking.sheetService as AnyObject
        )
        XCTAssertTrue(
            dependencies.tracking.settingsService as AnyObject
                === dependencies.tracking.searchService as AnyObject
        )
        XCTAssertTrue(
            dependencies.tracking.settingsService as AnyObject
                === dependencies.tracking.detailsService as AnyObject
        )
        XCTAssertTrue(
            dependencies.tracking.settingsService as AnyObject
                === dependencies.tracking.linkStore as AnyObject
        )
        XCTAssertTrue(dependencies.settings.notificationAuthorization === notificationManager)
        XCTAssertTrue(dependencies.settings.storageAccess === storageManager)
        XCTAssertTrue(dependencies.settings.discordRPCManager === discordRPCManager)
        XCTAssertTrue(dependencies.repositoryManagement.repositoryListManager === repoManager)
        XCTAssertTrue(dependencies.repositoryManagement.repositoryDetailManager === repoManager)
        XCTAssertTrue(dependencies.source.runnerProvider === pluginManager)
        XCTAssertTrue(dependencies.source.settingsStore === pluginSettings)
        XCTAssertTrue(dependencies.migrationReport.repositories === repoManager)
        XCTAssertTrue(dependencies.migrationReport.plugins === pluginManager)
        XCTAssertTrue(
            (dependencies.migrationReport.remapper as? LibrarySourceRemapperMigrationAdapter)?.remapper
                === librarySourceRemapper
        )
        XCTAssertTrue(dependencies.source.pluginStatePublisher === pluginManager)
        XCTAssertTrue(dependencies.discoverDetail.pluginProvider === pluginManager)
        XCTAssertTrue(dependencies.discoverDetail.detailService === DiscoverManager.shared)
        XCTAssertTrue(dependencies.discoverDetail.themeService === ThemeManager.shared)
        XCTAssertTrue(dependencies.discoverDetail.libraryObserver === libraryManager)
        XCTAssertTrue(dependencies.discoverDetail.trackerLinker === trackerManager)
        XCTAssertTrue(dependencies.library.library === libraryManager)
        XCTAssertTrue(dependencies.library.layout === settingsStore)
        XCTAssertTrue(dependencies.library.updates === updateManager)
        XCTAssertTrue(dependencies.library.export === backupManager)
        XCTAssertTrue(dependencies.backupSettings.service === backupManager)
        XCTAssertTrue(dependencies.library.discord === discordRPCManager)
        XCTAssertTrue(dependencies.library.plugins === pluginManager)
        XCTAssertTrue(dependencies.library.installer === repoManager)
        XCTAssertTrue(dependencies.categoryHistory.organization === libraryManager)
        XCTAssertTrue(dependencies.categoryHistory.history === historyManager)
        XCTAssertTrue(
            dependencies.discoverDetail.sourceMappingRepository
                as? GRDBSourceMappingRepository === sourceMappingRepository
        )
        XCTAssertEqual(dependencies.recentSearchStore.load(), [recentSearchSentinel])
        let fileOperations = try XCTUnwrap(
            dependencies.browseFileOperations as? LocalBrowsePluginFileOperations
        )
        XCTAssertTrue(dependencies.source.fileDeletion === fileOperations)
        XCTAssertEqual(
            fileOperations.configuredPluginsDirectory?.standardizedFileURL,
            pluginsDirectory.standardizedFileURL
        )

        let sourceURL = fixtureRoot.appendingPathComponent("fixture.ito")
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: sourceURL)
        try fileOperations.installPluginFile(from: sourceURL)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: pluginsDirectory.appendingPathComponent("fixture.ito").path
            )
        )
    }

    func testBackupSettingsFactoryCreatesFreshNavigatedViewModels() {
        let scope = makeScope()

        let first = scope.viewFactory.makeBackupSettingsViewModel()
        let second = scope.viewFactory.makeBackupSettingsViewModel()

        XCTAssertFalse(first === second)
    }

    func testDiscoverDetailFactoryUsesCanonicalPreparedGRDBRepository() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginManager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool)
        )
        let repository = GRDBSourceMappingRepository(dbWriter: database.dbPool)
        let dependencies = PreparedApplicationDependencies(
            settings: makeTestPreparedSettingsDependencies(),
            searchExecutor: AppScopeSearchExecutor(),
            recentSearchStore: AppScopeRecentStore(),
            searchDebounceMilliseconds: nil,
            presentationLogger: PresentationEventCaptureSpy(),
            browseRepositoryManager: AppScopeBrowseRepositoryManager(),
            repositoryManagement: makeTestRepositoryManagementDependencies(),
            browsePluginManager: pluginManager,
            browseFileOperations: AppScopeBrowseFileOperations(),
            discoverDetail: PreparedDiscoverDetailDependencies(
                sourceMappingRepository: repository,
                pluginProvider: pluginManager,
                detailService: DiscoverManager.shared,
                themeService: ThemeManager.shared,
                sourceRouteFactory: SourceRouteFactory()
            )
        )
        let scope = AppScope(preparedDependencies: dependencies)
        let media = DiscoverMedia(
            id: 88,
            title: "Boundary",
            titleEnglish: nil,
            titleRomaji: nil,
            titleNative: nil,
            synonyms: [],
            coverImage: nil,
            bannerImage: nil,
            format: nil,
            status: nil,
            description: nil,
            cleanDescription: nil,
            genres: nil,
            averageScore: nil,
            episodes: nil,
            chapters: nil,
            season: nil,
            seasonYear: nil,
            type: "MANGA",
            recommendations: nil
        )
        let resolver = scope.viewFactory.makeDiscoverDetailViewModel(
            media: media
        ).sourceResolver
        let confirmed = MatchedSource(
            pluginID: "plugin.confirmed",
            pluginVersion: "1.0",
            media: .manga(Manga(key: "confirmed", title: "Confirmed")),
            matchMethod: .exactPreferred,
            score: 1,
            decision: .autoConfirm
        )
        let rejected = MatchedSource(
            pluginID: "plugin.rejected",
            pluginVersion: "1.0",
            media: .manga(Manga(key: "rejected", title: "Rejected")),
            matchMethod: .fuzzy,
            score: 0.7,
            decision: .requiresConfirmation
        )

        try await resolver.confirmMatch(confirmed)
        try await resolver.rejectMatch(rejected)

        let records = try await repository.fetchAll(
            canonicalProvider: "anilist",
            canonicalMediaId: "88",
            mediaType: .manga
        )
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(
            records.first(where: { $0.pluginMediaKey == "confirmed" })?.decision,
            .autoConfirm
        )
        XCTAssertEqual(
            records.first(where: { $0.pluginMediaKey == "rejected" })?.decision,
            .discard
        )
        XCTAssertTrue(
            scope.dependencies.discoverDetail.sourceMappingRepository
                as? GRDBSourceMappingRepository === repository
        )
    }

    private func makeScope() -> AppScope {
        AppScope(
            preparedDependencies: PreparedApplicationDependencies(
                settings: makeTestPreparedSettingsDependencies(),
                searchExecutor: AppScopeSearchExecutor(),
                recentSearchStore: AppScopeRecentStore(),
                searchDebounceMilliseconds: nil,
                presentationLogger: PresentationEventCaptureSpy(),
                browseRepositoryManager: AppScopeBrowseRepositoryManager(),
                repositoryManagement: makeTestRepositoryManagementDependencies(),
                browsePluginManager: AppScopeBrowsePluginManager(),
                browseFileOperations: AppScopeBrowseFileOperations()
            )
        )
    }

    private func sourceFile(_ path: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}

@MainActor
private final class AppScopeSearchExecutor: SearchPluginExecuting {
    let plugins: [SearchPluginDescriptor] = []

    func search(
        plugin: SearchPluginDescriptor,
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult] {
        _ = plugin
        _ = query
        _ = limit
        return []
    }

    func evictRunner(for pluginID: String) {
        _ = pluginID
    }
}

@MainActor
private final class AppScopeRecentStore: RecentSearchPersisting {
    private(set) var loadCallCount = 0

    func load() -> [String] {
        loadCallCount += 1
        return []
    }

    func save(_ searches: [String]) {
        _ = searches
    }

    func clear() {}
}

@MainActor
private final class AppScopeBrowsePluginManager: BrowsePluginManaging {
    let installedPlugins: [String: InstalledPlugin] = [:]

    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        Just(installedPlugins).eraseToAnyPublisher()
    }

    func reloadInstalledPlugins() async {}
}

@MainActor
private final class AppScopeBrowseRepositoryManager: BrowseRepositoryManaging {
    let repositories: [Repository] = []

    var repositoriesPublisher: AnyPublisher<[Repository], Never> {
        Just(repositories).eraseToAnyPublisher()
    }

    func addRepository(url: String) async throws -> RepositoryAdditionResult {
        _ = url
        return .added
    }

    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws {
        _ = package
        _ = repositoryURL
    }

    func refreshAll() async {}
}

@MainActor
private final class AppScopeBrowseFileOperations: BrowsePluginFileOperating {
    func supportsPluginFile(at url: URL) -> Bool {
        url.pathExtension == "ito"
    }

    func installPluginFile(from url: URL) throws {
        _ = url
    }

    func deletePluginFile(at url: URL) throws {
        _ = url
    }
}

@MainActor
private final class AppScopeDiscoverService: DiscoverHomeFilterServing {
    func loadHomeSection(
        _ request: DiscoverHomeSectionRequest
    ) async throws -> [DiscoverMedia] {
        _ = request
        return []
    }

    func search(_ request: DiscoverSearchRequest) async throws -> DiscoverPageResult {
        _ = request
        return DiscoverPageResult(media: [], hasNextPage: false)
    }

    func loadGenres() async throws -> [String] { [] }
    func loadTags() async throws -> [DiscoverTag] { [] }
}

@MainActor
private final class AppScopeDiscoverClock: DiscoverClock {
    let now = Date(timeIntervalSince1970: 0)

    func sleep(milliseconds: Int) async throws {
        _ = milliseconds
    }
}
