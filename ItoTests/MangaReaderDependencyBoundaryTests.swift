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
            makeImagePrefetcher: { _ in subject.imagePrefetcher },
            presentationLogger: subject.logger
        )
        let factory = MediaDetailReaderViewFactory(
            mangaReaderDependencies: dependencies,
            networkContexts: PluginNetworkContexts(policy: NetworkPolicyCenter())
        )
        let runner = ItoRunner()

        let first = factory.makeRoute(
            content: ReaderContentSource(remote: runner),
            pluginID: "plugin",
            entry: .manga(manga),
            chapter: chapter,
            format: .pages
        )
        let second = factory.makeRoute(
            content: ReaderContentSource(remote: runner),
            pluginID: "plugin",
            entry: .manga(manga),
            chapter: chapter,
            format: .pages
        )
        guard case .pages(_, let firstModel)? = first.active, case .pages(_, let secondModel)? = second.active else {
            return XCTFail("A pages opening starts in the page reader")
        }

        XCTAssertFalse(firstModel === secondModel)
        XCTAssertEqual(firstModel.pluginID, "plugin")
        XCTAssertEqual(firstModel.entry.key, "manga")
        XCTAssertEqual(firstModel.currentChapter.key, "chapter")
        let firstPreparer = firstModel.chapterPreparer as? MediaDetailReaderChapterPreparer
        let secondPreparer = secondModel.chapterPreparer as? MediaDetailReaderChapterPreparer
        XCTAssertTrue((firstPreparer?.remoteManga as? ItoRunnerMangaPageLoader)?.runner === runner)
        XCTAssertTrue((secondPreparer?.remoteManga as? ItoRunnerMangaPageLoader)?.runner === runner)
        XCTAssertFalse(firstPreparer === secondPreparer)
    }

    func testReaderFactoryContainsNoSecondRunnerLookupAndLeavesOtherRoutesTyped() throws {
        let factory = try source("Ito/Views/Browse/MediaDetailViewFactory.swift")

        XCTAssertFalse(factory.contains("getRunner"))
        XCTAssertFalse(factory.contains("PluginManager"))
        XCTAssertTrue(factory.contains("VideoPlayerView("))
        XCTAssertTrue(factory.contains("ReaderRouteView("))
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
        let settings = AppSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter())
        let discord = DiscordRPCManager(libraryManager: library)
        let plugin = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter())
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
            dependencies.makeImagePrefetcher("source") === dependencies.makeImagePrefetcher("source")
        )
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
