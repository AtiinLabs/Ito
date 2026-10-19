import Combine
import XCTest
@testable import Ito

@MainActor
final class MediaDetailDependencyBoundaryTests: XCTestCase {
    func testMediaDetailPresentationFilesContainNoDirectGlobalOrServiceLocatorAccess() throws {
        let view = try source("Ito/Views/Browse/MediaDetailView.swift")
        let viewModel = try source("Ito/ViewModels/MediaDetailViewModel.swift")
        let forbidden = [
            "ThemeManager.shared",
            "SnackBarManager.shared",
            "AppDatabase.shared",
            "UIApplication.shared",
            "UserDefaults.standard",
            "URLSession.shared",
            "FileManager.default",
            "AppLogger",
            "LibraryManager(",
            "TrackerManager(",
            "ReadProgressManager(",
            "UpdateManager(",
            "PluginManager(",
            "DiscordRPCManager(",
            "LibrarySourceRemapper(",
            "AnyView",
            ".configure("
        ]

        for text in forbidden {
            XCTAssertFalse(view.contains(text), "View contains forbidden access: \(text)")
            XCTAssertFalse(viewModel.contains(text), "ViewModel contains forbidden access: \(text)")
        }
    }

    func testViewModelLivesInOwnFileAndViewOwnsExactlyOneStateObject() throws {
        let view = try source("Ito/Views/Browse/MediaDetailView.swift")
        let viewModel = try source("Ito/ViewModels/MediaDetailViewModel.swift")

        XCTAssertFalse(view.contains("final class MediaDetailViewModel"))
        XCTAssertTrue(viewModel.contains("final class MediaDetailViewModel"))
        XCTAssertEqual(view.components(separatedBy: "@StateObject").count - 1, 1)
        XCTAssertTrue(view.contains("@StateObject private var viewModel: MediaDetailViewModel<M>"))
        XCTAssertTrue(view.contains("StateObject(wrappedValue: viewModel)"))
        XCTAssertFalse(view.contains("@EnvironmentObject"))
    }

    func testFactoryOwnsTypedMediaAndReaderCompositionWithoutSecondPluginLookup() throws {
        let mediaFactory = try source("Ito/Views/Browse/MediaDetailViewFactory.swift")
        let searchFactory = try source("Ito/Views/Search/SearchRouteFactory.swift")

        for expected in [
            "MediaDetailViewModel(",
            "getSearchMangaList(",
            "getSearchAnimeList(",
            "getSearchNovelList(",
            "ReaderView(",
            "VideoPlayerView(",
            "NovelReaderView("
        ] {
            XCTAssertTrue(mediaFactory.contains(expected), "Missing factory composition: \(expected)")
        }
        XCTAssertFalse(mediaFactory.contains("PluginManager"))
        XCTAssertFalse(mediaFactory.contains("getRunner"))
        XCTAssertFalse(mediaFactory.contains("AnyView"))
        XCTAssertTrue(searchFactory.contains("mediaDetailViewFactory.makeMangaView("))
        XCTAssertTrue(searchFactory.contains("mediaDetailViewFactory.makeAnimeView("))
        XCTAssertTrue(searchFactory.contains("mediaDetailViewFactory.makeNovelView("))
    }

    func testSourceDiscoverAndLibraryPathsUseCanonicalAppViewFactoryComposition() throws {
        let discover = try source("Ito/Views/Discover/DiscoverDetailView.swift")
        let library = try source("Ito/Views/Library/LibraryView.swift")
        let appFactory = try source("Ito/Views/Search/SearchRouteFactory.swift")
        let tabs = try source("Ito/Views/MainTabView.swift")

        XCTAssertTrue(discover.contains("viewFactory.makeMangaDetailView("))
        XCTAssertTrue(discover.contains("viewFactory.makeAnimeDetailView("))
        XCTAssertFalse(discover.contains("MediaDetailView("))
        XCTAssertTrue(library.contains("viewFactory.makeDeferredPluginView(item: item)"))
        XCTAssertTrue(library.contains("viewFactory.makeDeferredPluginDestination(route.destination)"))
        XCTAssertTrue(appFactory.contains("func makeDeferredPluginDestination"))
        XCTAssertTrue(appFactory.contains("makeMangaDetailView("))
        XCTAssertTrue(appFactory.contains("makeAnimeDetailView("))
        XCTAssertTrue(appFactory.contains("makeNovelDetailView("))
        XCTAssertTrue(tabs.contains("appScope.viewFactory.makeLibraryView()"))
    }

    func testMediaDetailIsPreparedInAppScopeButNotStoredInRootModelStore() throws {
        let appScope = try source("Ito/AppScope.swift")
        let bootstrap = try source("Ito/Managers/DurableStateBootstrap.swift")

        XCTAssertTrue(appScope.contains("let mediaDetail: PreparedMediaDetailDependencies?"))
        XCTAssertTrue(appScope.contains("mediaDetail: .production("))
        XCTAssertTrue(appScope.contains("mediaDetailMessagePresenter"))
        XCTAssertTrue(bootstrap.contains("librarySourceRemapper: runtime.librarySourceRemapper"))
        let rootStoreStart = try XCTUnwrap(appScope.range(of: "final class RootModelStore"))
        let appScopeStart = try XCTUnwrap(
            appScope.range(of: "final class AppScope", range: rootStoreStart.upperBound..<appScope.endIndex)
        )
        let rootStoreSource = String(
            appScope[rootStoreStart.lowerBound..<appScopeStart.lowerBound]
        )
        XCTAssertFalse(rootStoreSource.contains("MediaDetailViewModel"))
    }

    func testPR9TrackingAdapterReusesSheetStateBoundary() async throws {
        let identity = MediaIdentity(pluginId: "plugin", itemId: "media")
        let provider = TrackerProviderPresentation(
            identifier: "anilist",
            name: "AniList",
            isAuthenticated: true,
            username: nil
        )
        let sheet = TrackerSheetServiceFake(
            providers: [provider],
            remoteIDs: [identity: ["anilist": "123"]],
            locallyLinkedMedia: [identity]
        )
        let adapter = TrackingMediaDetailAdapter(sheetService: sheet)
        var publications = 0
        let cancellable = adapter.statePublisher.sink { publications += 1 }
        defer { cancellable.cancel() }

        XCTAssertEqual(
            adapter.state(for: identity),
            MediaDetailTrackerState(
                isAvailable: true,
                isTracked: true,
                anilistID: "123"
            )
        )
        sheet.sendStateChange()
        XCTAssertEqual(publications, 1)
        try await adapter.refresh()
        XCTAssertEqual(sheet.refreshCount, 1)
    }

    func testTypedMessagesRedactSourceIdentityWhilePreservingMoveAction() throws {
        let center = AppMessageCenter()
        let presenter = AppMessageMediaDetailPresenter(messageCenter: center)
        let sourceSentinel = "private-source-key-sentinel"

        presenter.presentSaved(itemID: sourceSentinel)

        let message = try XCTUnwrap(center.currentMessage)
        let presentation = message.kind.presentation
        XCTAssertFalse(String(describing: message).contains(sourceSentinel))
        XCTAssertFalse(String(describing: presentation).contains(sourceSentinel))
        XCTAssertEqual(presentation.title, "Saved to Uncategorized")
        XCTAssertEqual(presentation.actionTitle, "Move")
        let actionID = try XCTUnwrap(presentation.actionID)
        XCTAssertNotEqual(actionID, sourceSentinel)
        XCTAssertEqual(center.mediaDetailItemID(forActionID: actionID), sourceSentinel)

        for failure in [
            MediaDetailMessage.detailLoadFailed,
            .saveFailed,
            .unsaveFailed,
            .trackerProgressFailed
        ] {
            XCTAssertFalse(String(describing: failure).contains(sourceSentinel))
        }
    }

    func testPreparedProductionGraphReusesAuthoritativeInstances() async throws {
        let database = try TestDatabase()
        let defaultsName = "MediaDetailDependencyBoundaryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }
        let pluginManager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: pluginsDirectory
        )
        let library = LibraryManager(dbPool: database.dbPool)
        let progress = ReadProgressManager(dbPool: database.dbPool)
        let tracker = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: defaults
        )
        let tracking = PreparedTrackingDependencies.production(
            trackerManager: tracker,
            settingsStore: AppSettingsStore(dbPool: database.dbPool),
            readProgressManager: progress
        )
        let theme = ThemeManager.shared
        let remapper = LibrarySourceRemapper(dbPool: database.dbPool)
        let baseline = UpdateManager(dbPool: database.dbPool)
        let settings = AppSettingsStore(dbPool: database.dbPool)
        let discord = DiscordRPCManager(libraryManager: library)

        let dependencies = PreparedMediaDetailDependencies.production(
            libraryManager: library,
            readProgressManager: progress,
            tracking: tracking,
            themeManager: theme,
            librarySourceRemapper: remapper,
            updateManager: baseline,
            settingsStore: settings,
            pluginManager: pluginManager,
            discordRPCManager: discord
        )

        XCTAssertTrue(dependencies.library as AnyObject === library)
        XCTAssertTrue(dependencies.progress as AnyObject === progress)
        XCTAssertTrue(dependencies.theme as AnyObject === theme)
        XCTAssertTrue(dependencies.relink as AnyObject === remapper)
        XCTAssertTrue(dependencies.baseline as AnyObject === baseline)
        XCTAssertTrue(dependencies.settings as AnyObject === settings)
        XCTAssertTrue(dependencies.pluginMetadata as AnyObject === pluginManager)
        XCTAssertTrue(dependencies.discord as AnyObject === discord)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
