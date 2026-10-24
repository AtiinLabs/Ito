import Combine
import XCTest
@testable import Ito

@MainActor
final class NetworkSettingsViewModelTests: XCTestCase {
    func testInitialStateMirrorsSettingsStore() async throws {
        let (store, persistence, siteDataClearer) = try await makeNetworkSettingsDependencies(wifiOnly: false)
        let viewModel = NetworkSettingsViewModel(
            settingsStore: store,
            siteDataClearer: siteDataClearer
        )

        XCTAssertFalse(viewModel.wifiOnlyUpdates)
        XCTAssertFalse(viewModel.isClearingSiteData)
        XCTAssertNil(viewModel.alert)
        _ = persistence
    }

    func testSetWifiOnlyUpdatesPersistsValueAndClearsAlert() async throws {
        let (store, persistence, siteDataClearer) = try await makeNetworkSettingsDependencies(wifiOnly: false)
        let viewModel = NetworkSettingsViewModel(
            settingsStore: store,
            siteDataClearer: siteDataClearer
        )

        await viewModel.setWifiOnlyUpdates(true)

        XCTAssertTrue(store.wifiOnlyUpdates)
        XCTAssertTrue(viewModel.wifiOnlyUpdates)
        XCTAssertNil(viewModel.alert)

        let history = await persistence.writeHistory
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.first?.key, AppPreferenceKeys.wifiOnlyUpdates)
    }

    func testSetWifiOnlyUpdatesFailureRetainsCommittedValueAndPresentsSaveFailed() async throws {
        let (store, persistence, siteDataClearer) = try await makeNetworkSettingsDependencies(wifiOnly: false)
        let viewModel = NetworkSettingsViewModel(
            settingsStore: store,
            siteDataClearer: siteDataClearer
        )

        await persistence.failNextWriteAttempt()
        await viewModel.setWifiOnlyUpdates(true)

        XCTAssertFalse(store.wifiOnlyUpdates)
        XCTAssertFalse(viewModel.wifiOnlyUpdates)
        XCTAssertEqual(viewModel.alert, .saveFailed)

        // Retry succeeds and clears alert
        await viewModel.setWifiOnlyUpdates(true)
        XCTAssertTrue(store.wifiOnlyUpdates)
        XCTAssertTrue(viewModel.wifiOnlyUpdates)
        XCTAssertNil(viewModel.alert)
    }

    func testClearSiteDataSuccessPresentsSiteDataClearedAlert() async throws {
        let (store, _, siteDataClearer) = try await makeNetworkSettingsDependencies(wifiOnly: false)
        let viewModel = NetworkSettingsViewModel(
            settingsStore: store,
            siteDataClearer: siteDataClearer
        )

        await viewModel.clearSiteData()

        XCTAssertEqual(siteDataClearer.clearCallCount, 1)
        XCTAssertFalse(viewModel.isClearingSiteData)
        XCTAssertEqual(viewModel.alert, .siteDataCleared)

        viewModel.dismissAlert()
        XCTAssertNil(viewModel.alert)
    }

    func testClearSiteDataFailurePresentsSiteDataClearFailedAlert() async throws {
        let (store, _, siteDataClearer) = try await makeNetworkSettingsDependencies(wifiOnly: false)
        let viewModel = NetworkSettingsViewModel(
            settingsStore: store,
            siteDataClearer: siteDataClearer
        )

        siteDataClearer.shouldThrow = true
        await viewModel.clearSiteData()

        XCTAssertEqual(siteDataClearer.clearCallCount, 1)
        XCTAssertFalse(viewModel.isClearingSiteData)
        XCTAssertEqual(viewModel.alert, .siteDataClearFailed)
    }

    func testClearSiteDataSuppressesOverlappingRuns() async throws {
        let (store, _, siteDataClearer) = try await makeNetworkSettingsDependencies(wifiOnly: false)
        let blockingClearer = BlockingSiteDataClearer()
        let viewModel = NetworkSettingsViewModel(
            settingsStore: store,
            siteDataClearer: blockingClearer
        )
        _ = siteDataClearer

        let task1 = Task { await viewModel.clearSiteData() }
        // Yield to allow task1 to enter clearSiteData
        await Task.yield()

        let task2 = Task { await viewModel.clearSiteData() }

        blockingClearer.resume()
        await task1.value
        await task2.value

        XCTAssertEqual(blockingClearer.callCount, 1)
        XCTAssertEqual(viewModel.alert, .siteDataCleared)
    }

    func testNetworkModelIdentityIsStableWithinScopeAndNewAcrossScopes() {
        let firstScope = makeScope()
        let secondScope = makeScope()

        XCTAssertFalse(firstScope.rootModels.hasLoadedNetworkSettingsViewModel)
        _ = firstScope.viewFactory.makeNetworkSettingsView()
        let first = firstScope.rootModels.networkSettingsViewModel
        let repeated = firstScope.rootModels.networkSettingsViewModel
        let second = secondScope.rootModels.networkSettingsViewModel

        XCTAssertTrue(firstScope.rootModels.hasLoadedNetworkSettingsViewModel)
        XCTAssertTrue(first === repeated)
        XCTAssertFalse(first === second)
    }

    func testNetworkViewAndModelStayWithinAllowedBoundaries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try [
            "Ito/ViewModels/Settings/NetworkSettingsViewModel.swift",
            "Ito/Views/Settings/NetworkSettingsView.swift"
        ].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")

        for forbidden in [
            "UserDefaults.standard",
            "UIApplication.shared",
            "UNUserNotificationCenter.current()",
            "FileManager.default",
            "SnackBarManager.shared",
            "AppLogger",
            "URLSession.shared",
            "@Environment",
            "configure(",
            "HTTPCookieStorage",
            "WKWebsiteDataStore",
            "CloudflareManager",
            "AppMessageCenter"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Forbidden Network access: \(forbidden)")
        }
        XCTAssertTrue(source.contains("@StateObject private var viewModel"))
        XCTAssertTrue(source.contains("Clear Cookies and Site Data"))
        XCTAssertTrue(source.contains(".confirmationDialog("))
    }

    private func makeNetworkSettingsDependencies(
        wifiOnly: Bool
    ) async throws -> (
        AppSettingsStore,
        TestAppSettingsPersistence,
        TestSiteDataClearer
    ) {
        let preferences = [
            try AppPreference(key: AppPreferenceCatalog.wifiOnlyUpdates, value: wifiOnly)
        ]
        let persistence = TestAppSettingsPersistence(preferences: preferences)
        let store = AppSettingsStore(persistence: persistence)
        try await store.reload()
        await persistence.resetWriteTracking()
        return (store, persistence, TestSiteDataClearer())
    }

    private func makeScope(
        settings: PreparedSettingsDependencies = makeTestPreparedSettingsDependencies(),
        messageCenter: AppMessageCenter = AppMessageCenter()
    ) -> AppScope {
        AppScope(
            preparedDependencies: PreparedApplicationDependencies(
                settings: settings,
                searchExecutor: NetworkTestSearchExecutor(),
                recentSearchStore: NetworkTestRecentStore(),
                searchDebounceMilliseconds: nil,
                presentationLogger: PresentationEventCaptureSpy(),
                browseRepositoryManager: NetworkTestRepositoryManager(),
                repositoryManagement: makeTestRepositoryManagementDependencies(),
                browsePluginManager: NetworkTestPluginManager(),
                browseFileOperations: NetworkTestFileOperations()
            ),
            messageCenter: messageCenter
        )
    }
}

@MainActor
private final class BlockingSiteDataClearer: SiteDataClearing {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func clearSiteData() async throws {
        callCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class NetworkTestSearchExecutor: SearchPluginExecuting {
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
private final class NetworkTestRecentStore: RecentSearchPersisting {
    func load() -> [String] { [] }
    func save(_ searches: [String]) { _ = searches }
    func clear() {}
}

@MainActor
private final class NetworkTestRepositoryManager: BrowseRepositoryManaging {
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
private final class NetworkTestPluginManager: BrowsePluginManaging {
    let installedPlugins: [String: InstalledPlugin] = [:]
    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        Just(installedPlugins).eraseToAnyPublisher()
    }

    func reloadInstalledPlugins() async {}
    func holdCompletionDelivery(for pluginID: String) async throws {}
    func purgeCompletionDelivery(for pluginID: String) async {}
    func removeSecrets(for pluginID: String) {}
}

@MainActor
private final class NetworkTestFileOperations: BrowsePluginFileOperating {
    func supportsPluginFile(at url: URL) -> Bool { _ = url; return false }
    func installPluginFile(from url: URL) throws { _ = url }
    func deletePluginFile(at url: URL) throws { _ = url }
}
