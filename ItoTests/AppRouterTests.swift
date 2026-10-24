import Combine
import XCTest
@testable import Ito

@MainActor
final class AppRouterTests: XCTestCase {
    func testInitialSelectedTabIsLibrary() {
        let router = AppRouter()

        XCTAssertEqual(router.selectedTab, .library)
        XCTAssertNil(router.repositoryIntentDelivery)
    }

    func testValidRepositoryDeepLinkSelectsBrowseAndCreatesPendingIntent() throws {
        let router = AppRouter()
        let repositoryURL = URL(string: "https://example.com/repository")!

        XCTAssertTrue(router.handleRepositoryDeepLink(deepLink(for: repositoryURL)))

        XCTAssertEqual(router.selectedTab, .browse)
        let delivery = try XCTUnwrap(router.repositoryIntentDelivery)
        guard case .pending(let intent) = delivery else {
            return XCTFail("Expected a pending repository intent")
        }
        XCTAssertEqual(intent.repositoryURL, repositoryURL)
    }

    func testEveryAcceptedIntentReceivesAnOpaqueToken() throws {
        let router = AppRouter()
        router.handleRepositoryDeepLink(deepLink(for: URL(string: "https://one.example")!))

        let intent = try XCTUnwrap(router.repositoryIntentDelivery?.intent)

        XCTAssertEqual(intent.id, intent.token)
    }

    func testPendingIntentCanBeClaimedOnlyOnce() throws {
        let router = AppRouter()
        router.handleRepositoryDeepLink(deepLink(for: URL(string: "https://example.com")!))

        let first = try XCTUnwrap(router.claimPendingRepositoryIntent())

        XCTAssertNil(router.claimPendingRepositoryIntent())
        XCTAssertEqual(router.repositoryIntentDelivery, .claimed(first))
    }

    func testExactTokenAcknowledgmentClearsMatchingIntent() throws {
        let router = AppRouter()
        router.handleRepositoryDeepLink(deepLink(for: URL(string: "https://example.com")!))
        let intent = try XCTUnwrap(router.claimPendingRepositoryIntent())

        router.acknowledgeRepositoryIntent(token: intent.token)

        XCTAssertNil(router.repositoryIntentDelivery)
    }

    func testWrongTokenAcknowledgmentDoesNotClearIntent() throws {
        let router = AppRouter()
        router.handleRepositoryDeepLink(deepLink(for: URL(string: "https://example.com")!))
        let intent = try XCTUnwrap(router.claimPendingRepositoryIntent())

        router.acknowledgeRepositoryIntent(token: UUID())

        XCTAssertEqual(router.repositoryIntentDelivery, .claimed(intent))
    }

    func testStaleAcknowledgmentDoesNotClearNewerIntent() throws {
        let router = AppRouter()
        router.handleRepositoryDeepLink(deepLink(for: URL(string: "https://one.example")!))
        let first = try XCTUnwrap(router.claimPendingRepositoryIntent())
        router.handleRepositoryDeepLink(deepLink(for: URL(string: "https://two.example")!))
        router.acknowledgeRepositoryIntent(token: first.token)
        let second = try XCTUnwrap(router.claimPendingRepositoryIntent())

        router.acknowledgeRepositoryIntent(token: first.token)

        XCTAssertEqual(router.repositoryIntentDelivery, .claimed(second))
    }

    func testSecondDistinctDeepLinkGetsDistinctIndependentlyConsumableToken() throws {
        let router = AppRouter()
        router.handleRepositoryDeepLink(deepLink(for: URL(string: "https://one.example")!))
        let first = try XCTUnwrap(router.claimPendingRepositoryIntent())
        router.handleRepositoryDeepLink(deepLink(for: URL(string: "https://two.example")!))
        router.acknowledgeRepositoryIntent(token: first.token)

        let second = try XCTUnwrap(router.claimPendingRepositoryIntent())

        XCTAssertNotEqual(first.token, second.token)
        XCTAssertEqual(second.repositoryURL.host, "two.example")
    }

    func testInvalidAndUnsupportedURLsDoNotChangeRoutingState() {
        let router = AppRouter()
        router.selectedTab = .search
        let invalidURLs = [
            URL(string: "ito://repo/remove?url=https://example.com")!,
            URL(string: "ito://other/add?url=https://example.com")!,
            URL(string: "ito://repo/add")!,
            deepLink(for: URL(string: "file:///tmp/private-repo")!)
        ]

        for url in invalidURLs {
            XCTAssertFalse(router.handleRepositoryDeepLink(url))
        }

        XCTAssertEqual(router.selectedTab, .search)
        XCTAssertNil(router.repositoryIntentDelivery)
    }

    func testRepeatedHandlingWhileEventIsPendingDoesNotCreateSecondDelivery() throws {
        let router = AppRouter()
        let link = deepLink(for: URL(string: "https://example.com/repository")!)

        router.handleRepositoryDeepLink(link)
        let originalToken = try XCTUnwrap(router.repositoryIntentDelivery?.intent.token)
        router.handleRepositoryDeepLink(link)
        let claimed = try XCTUnwrap(router.claimPendingRepositoryIntent())

        XCTAssertEqual(claimed.token, originalToken)
        XCTAssertNil(router.claimPendingRepositoryIntent())
    }

    func testRouterIdentityIsStableThroughRootRecomputation() {
        let scope = makeScope()
        let router = scope.router

        _ = scope.viewFactory.makeBrowseView()
        _ = scope.viewFactory.makeSearchView()

        XCTAssertTrue(router === scope.router)
    }

    func testNewAppScopeEpochGetsNewEmptyRouter() {
        let first = makeScope()
        first.router.handleRepositoryDeepLink(
            deepLink(for: URL(string: "https://example.com")!)
        )
        let second = makeScope()

        XCTAssertFalse(first.router === second.router)
        XCTAssertEqual(second.router.selectedTab, .library)
        XCTAssertNil(second.router.repositoryIntentDelivery)
    }

    func testRouterSourceContainsNoFeatureDetailNavigation() throws {
        let source = try sourceFile("Ito/AppRouter.swift")

        for forbidden in [
            "SearchDetailRoute",
            "SourceView",
            "ListingView",
            "DiscoverDetail",
            "LibraryView",
            "ReaderView",
            "SettingsView",
            "sheet",
            "modal"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Unexpected router responsibility: \(forbidden)")
        }
    }

    private func deepLink(for repositoryURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = "ito"
        components.host = "repo"
        components.path = "/add"
        components.queryItems = [URLQueryItem(name: "url", value: repositoryURL.absoluteString)]
        return components.url!
    }

    private func makeScope() -> AppScope {
        AppScope(
            preparedDependencies: PreparedApplicationDependencies(
                settings: makeTestPreparedSettingsDependencies(),
                searchExecutor: RouterSearchExecutor(),
                recentSearchStore: RouterRecentStore(),
                searchDebounceMilliseconds: nil,
                presentationLogger: PresentationEventCaptureSpy(),
                browseRepositoryManager: RouterRepositoryManager(),
                repositoryManagement: makeTestRepositoryManagementDependencies(),
                browsePluginManager: RouterPluginManager(),
                browseFileOperations: RouterFileOperations()
            )
        )
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

@MainActor
private final class RouterSearchExecutor: SearchPluginExecuting {
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

    func evictRunner(for pluginID: String) { _ = pluginID }
}

@MainActor
private final class RouterRecentStore: RecentSearchPersisting {
    func load() -> [String] { [] }
    func save(_ searches: [String]) { _ = searches }
    func clear() {}
}

@MainActor
private final class RouterRepositoryManager: BrowseRepositoryManaging {
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
private final class RouterPluginManager: BrowsePluginManaging {
    let installedPlugins: [String: InstalledPlugin] = [:]
    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        Just(installedPlugins).eraseToAnyPublisher()
    }

    func reloadInstalledPlugins() async {}
    func holdCompletionDelivery(for pluginID: String) async throws {}
    func purgeCompletionDelivery(for pluginID: String) async {}
    func revokeTrust(for pluginID: String) throws {}
    func removeSecrets(for pluginID: String) {}
}

@MainActor
private final class RouterFileOperations: BrowsePluginFileOperating {
    func supportsPluginFile(at url: URL) -> Bool { _ = url; return false }
    func installPluginFile(from url: URL) throws { _ = url }
    func deletePluginFile(at url: URL) throws { _ = url }
}
