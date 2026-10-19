import XCTest
import ito_runner
@testable import Ito

@MainActor
final class VideoPlayerDependencyBoundaryTests: XCTestCase {
    func testVideoPlayerPresentationHasNoBusinessEnvironmentOrDirectGlobals() throws {
        let view = try source("Ito/Views/Reader/VideoPlayerView.swift")
        let viewModel = try source("Ito/ViewModels/VideoPlayerViewModel.swift")
        let forbidden = [
            "@EnvironmentObject",
            "ReadProgressManager",
            "HistoryManager",
            "TrackerManager",
            "DiscordRPCManager",
            "PluginManager",
            "URLSession",
            "AppLogger",
            "getRunner",
            "AppDatabase.shared",
            "UserDefaults.standard"
        ]

        for text in forbidden {
            XCTAssertFalse(view.contains(text), "VideoPlayerView contains \(text)")
            XCTAssertFalse(viewModel.contains(text), "VideoPlayerViewModel contains \(text)")
        }
        for playerAuthority in [
            "AVPlayer(",
            "AVURLAsset",
            "AVPlayerItem(",
            "addPeriodicTimeObserver",
            "removeTimeObserver",
            "replaceCurrentItem"
        ] {
            XCTAssertFalse(view.contains(playerAuthority))
            XCTAssertFalse(viewModel.contains(playerAuthority))
        }
    }

    func testViewOwnsExactlyOneInjectedScreenStateObjectAndRetainsRendering() throws {
        let view = try source("Ito/Views/Reader/VideoPlayerView.swift")

        XCTAssertEqual(view.components(separatedBy: "@StateObject").count - 1, 1)
        XCTAssertTrue(view.contains("@StateObject private var viewModel: VideoPlayerViewModel"))
        XCTAssertTrue(view.contains("StateObject(wrappedValue: viewModel)"))
        XCTAssertTrue(view.contains("VideoPlayer(player: surface.player)"))
        XCTAssertTrue(view.contains("confirmationDialog(\"Select Quality\""))
        XCTAssertTrue(view.contains("confirmationDialog(\"Select Audio Track\""))
        XCTAssertTrue(view.contains("confirmationDialog(\"Select Subtitles\""))
        XCTAssertTrue(view.contains("@Environment(\\.dismiss)"))
    }

    func testFactoryWrapsExactRouteRunnerOnceAndCreatesFreshScreenModels() {
        let subject = makeVideoPlayerSubject()
        let dependencies = PreparedVideoPlayerDependencies(
            progress: subject.progress,
            history: subject.history,
            tracker: subject.tracker,
            presence: subject.presence,
            pluginMetadata: subject.metadata,
            subtitleLoader: subject.subtitleLoader,
            makePlaybackCoordinator: { VideoPlaybackCoordinatorFake() },
            presentationLogger: subject.logger
        )
        let factory = MediaDetailReaderViewFactory(
            mangaReaderDependencies: .unavailable(),
            novelReaderDependencies: .unavailable(),
            videoPlayerDependencies: dependencies
        )
        let runner = ItoRunner()
        let anime = Anime(key: "anime", title: "Anime")
        let episode = Anime.Episode(key: "episode", episode: 1)

        let first = factory.makeVideoPlayerViewModel(
            runner: runner,
            pluginID: "plugin",
            anime: anime,
            episode: episode
        )
        let second = factory.makeVideoPlayerViewModel(
            runner: runner,
            pluginID: "plugin",
            anime: anime,
            episode: episode
        )

        XCTAssertFalse(first === second)
        XCTAssertEqual(first.pluginID, "plugin")
        XCTAssertEqual(first.anime.key, "anime")
        XCTAssertEqual(first.episode.key, "episode")
        XCTAssertTrue((first.streamLoader as? ItoRunnerVideoStreamLoader)?.runner === runner)
        XCTAssertTrue((second.streamLoader as? ItoRunnerVideoStreamLoader)?.runner === runner)
        XCTAssertFalse(first.playbackCoordinator === second.playbackCoordinator)
    }

    func testReaderFactoryHasNoSecondRunnerLookupAndKeepsAllRoutesTyped() throws {
        let factory = try source("Ito/Views/Browse/MediaDetailViewFactory.swift")

        XCTAssertTrue(factory.contains("ItoRunnerVideoStreamLoader(runner: runner)"))
        XCTAssertTrue(factory.contains("ItoRunnerMangaPageLoader(runner: runner)"))
        XCTAssertTrue(factory.contains("ItoRunnerNovelChapterLoader(runner: runner)"))
        XCTAssertFalse(factory.contains("getRunner"))
        XCTAssertFalse(factory.contains("PluginManager"))
        XCTAssertTrue(factory.contains("ReaderView("))
        XCTAssertTrue(factory.contains("VideoPlayerView("))
        XCTAssertTrue(factory.contains("NovelReaderView("))
    }

    func testNetworkAndPlayerAuthorityAreIsolatedAndDiagnosticFetchWasRemoved() throws {
        let service = try source(
            "Ito/Services/VideoPlayer/VideoPlayerDependencies.swift"
        )
        let view = try source("Ito/Views/Reader/VideoPlayerView.swift")
        let viewModel = try source("Ito/ViewModels/VideoPlayerViewModel.swift")

        XCTAssertTrue(service.contains("final class URLSessionVideoSubtitleLoader"))
        XCTAssertTrue(service.contains("private let session: URLSession"))
        XCTAssertTrue(service.contains("final class AVPlayerVideoPlaybackCoordinator"))
        XCTAssertTrue(service.contains("AVURLAsset(url: url"))
        XCTAssertTrue(service.contains("AVPlayer(playerItem:"))
        XCTAssertTrue(service.contains("addPeriodicTimeObserver"))
        XCTAssertTrue(service.contains("removeTimeObserver"))
        XCTAssertTrue(service.contains("AVURLAssetHTTPHeaderFieldsKey"))
        for removed in [
            "URLSession.shared",
            "diagnoseStreamBlocked",
            "response payload",
            "absoluteString",
            "AppLogger"
        ] {
            XCTAssertFalse(service.contains(removed))
            XCTAssertFalse(view.contains(removed))
            XCTAssertFalse(viewModel.contains(removed))
        }
    }

    func testVideoPlayerIsPreparedButNotStoredInRootModelStore() throws {
        let appScope = try source("Ito/AppScope.swift")
        let rootStart = try XCTUnwrap(appScope.range(of: "final class RootModelStore"))
        let scopeStart = try XCTUnwrap(
            appScope.range(
                of: "final class AppScope",
                range: rootStart.upperBound..<appScope.endIndex
            )
        )
        let rootStore = String(appScope[rootStart.lowerBound..<scopeStart.lowerBound])

        XCTAssertTrue(appScope.contains("let videoPlayer: PreparedVideoPlayerDependencies"))
        XCTAssertTrue(appScope.contains("videoPlayer: .production("))
        XCTAssertTrue(appScope.contains("videoPlayerDependencies: preparedDependencies.videoPlayer"))
        XCTAssertFalse(rootStore.contains("VideoPlayerViewModel"))
        XCTAssertFalse(rootStore.contains("storedVideoPlayer"))
        XCTAssertFalse(rootStore.contains("makeVideoPlayer"))
    }

    func testProductionBundleReusesCanonicalManagerInstances() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let defaultsName = "VideoPlayerDependencyBoundaryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let library = LibraryManager(dbPool: database.dbPool)
        let progress = ReadProgressManager(dbPool: database.dbPool)
        let history = HistoryManager(dbPool: database.dbPool, libraryManager: library)
        let tracker = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: defaults
        )
        let discord = DiscordRPCManager(libraryManager: library)
        let plugin = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool)
        )
        let logger = PresentationEventCaptureSpy()

        let dependencies = PreparedVideoPlayerDependencies.production(
            readProgressManager: progress,
            historyManager: history,
            trackerManager: tracker,
            discordRPCManager: discord,
            pluginManager: plugin,
            presentationLogger: logger
        )

        XCTAssertTrue(dependencies.progress as AnyObject === progress)
        XCTAssertTrue(dependencies.history as AnyObject === history)
        XCTAssertTrue(dependencies.tracker as AnyObject === tracker)
        XCTAssertTrue(dependencies.presence as AnyObject === discord)
        XCTAssertTrue(dependencies.pluginMetadata as AnyObject === plugin)
        XCTAssertTrue(dependencies.subtitleLoader is URLSessionVideoSubtitleLoader)
        XCTAssertTrue(dependencies.makePlaybackCoordinator() is AVPlayerVideoPlaybackCoordinator)
        XCTAssertTrue(dependencies.presentationLogger as AnyObject === logger)
    }

    func testMangaNovelOwnershipRemainsStableAndLegacyReaderIsRemoved() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manga = try source("Ito/ViewModels/MangaReaderViewModel.swift")
        let novel = try source("Ito/ViewModels/NovelReaderViewModel.swift")

        XCTAssertFalse(manga.contains("VideoPlayerViewModel"))
        XCTAssertFalse(novel.contains("VideoPlayerViewModel"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Ito/ViewModels/ReaderViewModel.swift").path
            )
        )
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
