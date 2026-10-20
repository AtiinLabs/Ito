import XCTest
import ito_runner
@testable import Ito

@MainActor
final class NovelReaderDependencyBoundaryTests: XCTestCase {
    func testNovelReaderPresentationHasNoBusinessEnvironmentOrDirectGlobals() throws {
        let view = try source("Ito/Views/Reader/NovelReaderView.swift")
        let viewModel = try source("Ito/ViewModels/NovelReaderViewModel.swift")
        let forbidden = [
            "@EnvironmentObject",
            "ReadProgressManager",
            "TrackerManager",
            "AppSettingsStore",
            "DiscordRPCManager",
            "HistoryManager",
            "PluginManager",
            "AppDatabase.shared",
            "UserDefaults.standard",
            "URLSession.shared",
            "UIApplication.shared",
            "FileManager.default",
            "SnackBarManager.shared",
            "AppLogger",
            "AnyView",
            ".configure(",
            "getRunner"
        ]

        for text in forbidden {
            XCTAssertFalse(view.contains(text), "NovelReaderView contains \(text)")
            XCTAssertFalse(viewModel.contains(text), "NovelReaderViewModel contains \(text)")
        }
    }

    func testNovelReaderViewOwnsExactlyOneInjectedStateObjectAndRetainsRendering() throws {
        let view = try source("Ito/Views/Reader/NovelReaderView.swift")

        XCTAssertEqual(view.components(separatedBy: "@StateObject").count - 1, 1)
        XCTAssertTrue(view.contains("@StateObject private var viewModel: NovelReaderViewModel"))
        XCTAssertTrue(view.contains("GeometryReader"))
        XCTAssertTrue(view.contains("ScrollView"))
        XCTAssertTrue(view.contains("LazyVStack"))
        XCTAssertTrue(view.contains("SelectableTextView("))
        XCTAssertTrue(view.contains("MangaImage("))
        XCTAssertTrue(view.contains("NovelReaderHeaderView("))
        XCTAssertTrue(view.contains("NovelReaderFooterView("))
        XCTAssertTrue(view.contains("NovelReaderSettingsView("))
    }

    func testFactoryWrapsExactRouteRunnerOnceAndCreatesFreshScreenModels() {
        let chapter = Novel.Chapter(key: "chapter", chapter: 1)
        let novel = Novel(key: "novel", title: "Novel", chapters: [chapter])
        let subject = makeNovelReaderSubject(novel: novel, initialChapter: chapter)
        let dependencies = PreparedNovelReaderDependencies(
            progress: subject.progress,
            history: subject.history,
            tracker: subject.tracker,
            settings: subject.settings,
            presence: subject.presence,
            pluginMetadata: subject.metadata,
            presentationLogger: subject.logger
        )
        let factory = MediaDetailReaderViewFactory(
            mangaReaderDependencies: .unavailable(),
            novelReaderDependencies: dependencies
        )
        let runner = ItoRunner()

        let first = factory.makeNovelViewModel(
            runner: runner,
            pluginID: "plugin",
            novel: novel,
            chapter: chapter
        )
        let second = factory.makeNovelViewModel(
            runner: runner,
            pluginID: "plugin",
            novel: novel,
            chapter: chapter
        )

        XCTAssertFalse(first === second)
        XCTAssertEqual(first.pluginID, "plugin")
        XCTAssertEqual(first.novel.key, "novel")
        XCTAssertEqual(first.currentChapter.key, "chapter")
        XCTAssertTrue((first.chapterLoader as? ItoRunnerNovelChapterLoader)?.runner === runner)
        XCTAssertTrue((second.chapterLoader as? ItoRunnerNovelChapterLoader)?.runner === runner)
    }

    func testReaderFactoryHasNoSecondLookupAndLeavesMangaAndAnimeOwnershipStable() throws {
        let factory = try source("Ito/Views/Browse/MediaDetailViewFactory.swift")

        XCTAssertTrue(factory.contains("ItoRunnerNovelChapterLoader(runner: runner)"))
        XCTAssertTrue(factory.contains("ItoRunnerMangaPageLoader(runner: runner)"))
        XCTAssertFalse(factory.contains("getRunner"))
        XCTAssertFalse(factory.contains("PluginManager"))
        XCTAssertTrue(factory.contains("ReaderView("))
        XCTAssertTrue(factory.contains("VideoPlayerView("))
        XCTAssertTrue(factory.contains("NovelReaderView("))
        XCTAssertTrue(factory.contains("VideoPlayerViewModel"))
    }

    func testNovelReaderIsPreparedButNotStoredInRootModelStore() throws {
        let appScope = try source("Ito/AppScope.swift")
        let rootStart = try XCTUnwrap(appScope.range(of: "final class RootModelStore"))
        let scopeStart = try XCTUnwrap(
            appScope.range(
                of: "final class AppScope",
                range: rootStart.upperBound..<appScope.endIndex
            )
        )
        let rootStore = String(appScope[rootStart.lowerBound..<scopeStart.lowerBound])

        XCTAssertTrue(appScope.contains("let novelReader: PreparedNovelReaderDependencies"))
        XCTAssertTrue(appScope.contains("novelReader: .production("))
        XCTAssertFalse(rootStore.contains("NovelReaderViewModel"))
        XCTAssertFalse(rootStore.contains("storedNovelReader"))
        XCTAssertFalse(rootStore.contains("makeNovelReader"))
    }

    func testProductionBundleReusesCanonicalManagerInstances() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let defaultsName = "NovelReaderDependencyBoundaryTests.\(UUID().uuidString)"
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

        let dependencies = PreparedNovelReaderDependencies.production(
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
    }

    func testPR12HelpersRemainOnlyNovelOrderingAndEffectAlgorithms() throws {
        let viewModel = try source("Ito/ViewModels/NovelReaderViewModel.swift")
        let behavior = try source("Ito/Views/Reader/ReaderBehavior.swift")

        XCTAssertTrue(viewModel.contains("ReaderChapterOrdering.novelChapter("))
        XCTAssertTrue(viewModel.contains("ReaderPageOrdering.ascending("))
        XCTAssertFalse(viewModel.contains("chapterNumberEpsilon"))
        XCTAssertFalse(viewModel.contains("missingChapterNumber"))
        XCTAssertTrue(behavior.contains("static let chapterNumberEpsilon: Float32 = 0.0001"))
    }

    func testPaginationUIKitAndPageStateRemainInPagingView() throws {
        let paging = try source("Ito/Views/Reader/NovelPagingReaderView.swift")
        let viewModel = try source("Ito/ViewModels/NovelReaderViewModel.swift")

        for required in [
            "@State private var paginatedCache",
            "@State private var flattenedPages",
            "@State private var currentPageIndex",
            "@State private var pageSize",
            "NovelPaginationEngine.paginate(",
            "UIPageViewController",
            "PageContentViewController",
            "BatteryIndicator("
        ] {
            XCTAssertTrue(paging.contains(required), "Paging view missing \(required)")
            XCTAssertFalse(viewModel.contains(required), "ViewModel contains \(required)")
        }
    }

    func testLegacyGenericReaderIsRemovedAndOtherModelsRemainOutsideNovelMigration() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let novelView = try source("Ito/Views/Reader/NovelReaderView.swift")
        let novelViewModel = try source("Ito/ViewModels/NovelReaderViewModel.swift")

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Ito/ViewModels/ReaderViewModel.swift").path
            )
        )
        XCTAssertFalse(novelView.contains("ReaderViewModel("))
        XCTAssertFalse(novelViewModel.contains("ReaderViewModel<"))
        for excluded in [
            "VideoPlayerViewModel",
            "BackupSettingsViewModel",
            "MigrationReportViewModel"
        ] {
            XCTAssertFalse(novelView.contains(excluded))
            XCTAssertFalse(novelViewModel.contains(excluded))
        }
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
