import XCTest
import ito_runner
@testable import Ito

@MainActor
final class MangaReaderDependencyBoundaryTests: XCTestCase {
    func testReaderPresentationHasNoDirectManagerEnvironmentOrGlobalAccess() throws {
        let view = try source("Ito/Views/Reader/ReaderView.swift")
        let viewModel = try source("Ito/ViewModels/MangaReaderViewModel.swift")
        let forbidden = [
            "@EnvironmentObject",
            "ReadProgressManager",
            "TrackerManager",
            "AppSettingsStore",
            "DiscordRPCManager",
            "HistoryManager",
            "PluginManager",
            "ImagePipeline.shared",
            "AppDatabase.shared",
            "UserDefaults.standard",
            "URLSession.shared",
            "UIApplication.shared",
            "FileManager.default",
            "AppLogger",
            "AnyView",
            ".configure("
        ]

        for text in forbidden {
            XCTAssertFalse(view.contains(text), "ReaderView contains \(text)")
            XCTAssertFalse(viewModel.contains(text), "MangaReaderViewModel contains \(text)")
        }
    }

    func testReaderViewOwnsExactlyOneInjectedStateObject() throws {
        let view = try source("Ito/Views/Reader/ReaderView.swift")

        XCTAssertEqual(view.components(separatedBy: "@StateObject").count - 1, 1)
        XCTAssertTrue(
            view.contains("@StateObject private var viewModel: MangaReaderViewModel")
        )
        XCTAssertTrue(view.contains("MangaImage("))
        XCTAssertTrue(view.contains("ReaderHeaderView("))
        XCTAssertTrue(view.contains("ReaderFooterView("))
        XCTAssertTrue(view.contains("ReaderSettingsView("))
    }

    func testFactoryWrapsExactRouteRunnerOnceAndCreatesFreshScreenModels() {
        let chapter = Manga.Chapter(key: "chapter", chapter: 1)
        let manga = Manga(key: "manga", title: "Manga", chapters: [chapter])
        let subject = makeMangaReaderSubject(manga: manga, initialChapter: chapter)
        let dependencies = PreparedMangaReaderDependencies(
            progress: subject.progress,
            history: subject.history,
            tracker: subject.tracker,
            settings: subject.settings,
            presence: subject.presence,
            pluginMetadata: subject.metadata,
            makeImagePrefetcher: { subject.imagePrefetcher },
            presentationLogger: subject.logger
        )
        let factory = MediaDetailReaderViewFactory(
            mangaReaderDependencies: dependencies
        )
        let runner = ItoRunner()

        let first = factory.makeMangaViewModel(
            runner: runner,
            pluginID: "plugin",
            manga: manga,
            chapter: chapter
        )
        let second = factory.makeMangaViewModel(
            runner: runner,
            pluginID: "plugin",
            manga: manga,
            chapter: chapter
        )

        XCTAssertFalse(first === second)
        XCTAssertEqual(first.pluginID, "plugin")
        XCTAssertEqual(first.manga.key, "manga")
        XCTAssertEqual(first.currentChapter.key, "chapter")
        XCTAssertTrue((first.pageLoader as? ItoRunnerMangaPageLoader)?.runner === runner)
        XCTAssertTrue((second.pageLoader as? ItoRunnerMangaPageLoader)?.runner === runner)
    }

    func testReaderFactoryContainsNoSecondRunnerLookupAndLeavesOtherRoutesTyped() throws {
        let factory = try source("Ito/Views/Browse/MediaDetailViewFactory.swift")

        XCTAssertTrue(factory.contains("ItoRunnerMangaPageLoader(runner: runner)"))
        XCTAssertFalse(factory.contains("getRunner"))
        XCTAssertFalse(factory.contains("PluginManager"))
        XCTAssertTrue(factory.contains("VideoPlayerView("))
        XCTAssertTrue(factory.contains("NovelReaderView("))
        XCTAssertTrue(factory.contains("NovelReaderViewModel"))
        XCTAssertTrue(factory.contains("VideoPlayerViewModel"))
    }

    func testMangaReaderIsPreparedButNotStoredInRootModelStore() throws {
        let appScope = try source("Ito/AppScope.swift")
        let rootStart = try XCTUnwrap(appScope.range(of: "final class RootModelStore"))
        let scopeStart = try XCTUnwrap(
            appScope.range(
                of: "final class AppScope",
                range: rootStart.upperBound..<appScope.endIndex
            )
        )
        let rootStore = String(appScope[rootStart.lowerBound..<scopeStart.lowerBound])

        XCTAssertTrue(appScope.contains("let mangaReader: PreparedMangaReaderDependencies"))
        XCTAssertTrue(appScope.contains("mangaReader: .production("))
        XCTAssertFalse(rootStore.contains("MangaReaderViewModel"))
        XCTAssertFalse(rootStore.contains("storedMangaReader"))
    }

    func testProductionBundleReusesCanonicalManagerInstances() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let defaultsName = "MangaReaderDependencyBoundaryTests.\(UUID().uuidString)"
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
        let settings = AppSettingsStore(dbPool: database.dbPool)
        let discord = DiscordRPCManager(libraryManager: library)
        let plugin = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool)
        )
        let logger = PresentationEventCaptureSpy()

        let dependencies = PreparedMangaReaderDependencies.production(
            readProgressManager: progress,
            historyManager: history,
            trackerManager: tracker,
            settingsStore: settings,
            discordRPCManager: discord,
            pluginManager: plugin,
            presentationLogger: logger
        )

        XCTAssertTrue(dependencies.progress as AnyObject === progress)
        XCTAssertTrue(dependencies.history as AnyObject === history)
        XCTAssertTrue(dependencies.tracker as AnyObject === tracker)
        XCTAssertTrue(dependencies.settings as AnyObject === settings)
        XCTAssertTrue(dependencies.presence as AnyObject === discord)
        XCTAssertTrue(dependencies.pluginMetadata as AnyObject === plugin)
        XCTAssertTrue(dependencies.presentationLogger as AnyObject === logger)
        XCTAssertFalse(
            dependencies.makeImagePrefetcher() === dependencies.makeImagePrefetcher()
        )
    }

    func testPR12HelpersRemainTheOnlyOrderingAndEffectAlgorithms() throws {
        let viewModel = try source("Ito/ViewModels/MangaReaderViewModel.swift")
        let behavior = try source("Ito/Views/Reader/ReaderBehavior.swift")

        XCTAssertTrue(viewModel.contains("ReaderChapterOrdering.mangaChapter("))
        XCTAssertTrue(viewModel.contains("ReaderPageOrdering.ascending("))
        XCTAssertFalse(viewModel.contains("chapterNumberEpsilon"))
        XCTAssertFalse(viewModel.contains("missingChapterNumber"))
        XCTAssertTrue(behavior.contains("static let chapterNumberEpsilon: Float32 = 0.0001"))
    }

    func testLegacyGenericReaderModelIsRemovedAndUnusedByMangaPresentation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let view = try source("Ito/Views/Reader/ReaderView.swift")
        let viewModel = try source("Ito/ViewModels/MangaReaderViewModel.swift")

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Ito/ViewModels/ReaderViewModel.swift").path
            )
        )
        XCTAssertFalse(view.contains("ReaderViewModel("))
        XCTAssertFalse(viewModel.contains("ReaderViewModel<"))
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
