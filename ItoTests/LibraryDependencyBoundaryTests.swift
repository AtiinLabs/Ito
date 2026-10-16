import Combine
import XCTest
import ito_runner
@testable import Ito

final class LibraryDependencyBoundaryTests: XCTestCase {
    func testMigratedPresentationHasNoDirectGlobalsManagersOrTypeErasure() throws {
        let paths = [
            "Ito/Views/Library/LibraryView.swift",
            "Ito/ViewModels/LibraryViewModel.swift",
            "Ito/ViewModels/DeferredPluginViewModel.swift"
        ]
        let forbidden = [
            "@EnvironmentObject",
            ".shared",
            "AppDatabase.shared",
            "SnackBarManager.shared",
            "UserDefaults.standard",
            "URLSession.shared",
            "FileManager.default",
            "UIApplication.shared",
            "AppLogger",
            "AnyView",
            "configure("
        ]

        for path in paths {
            let source = try sourceFile(path)
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "Forbidden \(token) in \(path)")
            }
        }
    }

    func testRootAndScreenOwnershipAreExplicitInComposition() throws {
        let appScope = try sourceFile("Ito/AppScope.swift")
        let factory = try sourceFile("Ito/Views/Search/SearchRouteFactory.swift")
        let view = try sourceFile("Ito/Views/Library/LibraryView.swift")

        XCTAssertTrue(appScope.contains("private var storedLibraryViewModel: LibraryViewModel?"))
        XCTAssertTrue(appScope.contains("var libraryViewModel: LibraryViewModel"))
        XCTAssertFalse(appScope.contains("storedDeferredPluginViewModel"))
        XCTAssertTrue(factory.contains("viewModel: rootModels.libraryViewModel"))
        XCTAssertTrue(factory.contains("func makeDeferredPluginViewModel(item: LibraryItem)"))
        XCTAssertTrue(view.contains("@StateObject private var viewModel: DeferredPluginViewModel"))
        XCTAssertTrue(view.contains("wrappedValue: viewFactory.makeDeferredPluginViewModel(item: item)"))
    }

    func testDeferredDestinationDelegatesToPR10MediaDetailFactoryWithoutPluginLookup() throws {
        let source = try sourceFile("Ito/Views/Search/SearchRouteFactory.swift")
        let start = try XCTUnwrap(source.range(of: "func makeDeferredPluginDestination"))
        let end = try XCTUnwrap(
            source.range(of: "func makeBrowseView", range: start.upperBound..<source.endIndex)
        )
        let method = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(method.contains("makeMangaDetailView"))
        XCTAssertTrue(method.contains("makeAnimeDetailView"))
        XCTAssertTrue(method.contains("makeNovelDetailView"))
        XCTAssertFalse(method.contains("getRunner"))
        XCTAssertFalse(method.contains("libraryRunner"))
        XCTAssertFalse(method.contains("installedPlugins"))
        XCTAssertFalse(method.contains("RepoManager"))
        XCTAssertFalse(method.contains("PluginManager"))
        XCTAssertFalse(method.contains("AnyView"))
    }

    @MainActor
    func testProductionPluginBoundaryPreservesExactIdentityAndPublicationRevision() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent()
        )
        let pluginURL = URL(fileURLWithPath: "/test/plugin.exact.ito")
        let installed = InstalledPlugin(
            url: pluginURL,
            info: PluginInfo(
                id: "plugin.exact",
                name: "Exact",
                version: "2.0.0",
                minAppVersion: "1.0",
                type: .novel
            ),
            iconData: nil
        )
        var revisions: [UInt64] = []
        let cancellable = manager.libraryPluginSnapshotPublisher
            .sink { revisions.append($0.publicationRevision) }

        manager.publishPreparedInstalledPlugins([installed.id: installed])
        let first = try XCTUnwrap(manager.libraryPluginSnapshot.plugins[installed.id])
        manager.publishPreparedInstalledPlugins([installed.id: installed])

        XCTAssertEqual(first.id, installed.id)
        XCTAssertEqual(first.version, "2.0.0")
        XCTAssertEqual(first.pluginType, .novel)
        XCTAssertEqual(first.fileIdentity, pluginURL.standardizedFileURL)
        XCTAssertEqual(revisions, [0, 1, 2])
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testCanonicalRunnerCacheRejectsLateLoadFromReplacedSameIDPlugin() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let staleRunner = ItoRunner()
        let replacementRunner = ItoRunner()
        let loader = NonCooperativePluginRunnerLoader(
            responses: [.suspended, .immediate(replacementRunner)]
        )
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: loader.load
        )
        let pluginURL = URL(fileURLWithPath: "/test/plugin.exact.ito")
        let first = installedPlugin(url: pluginURL, version: "1.0.0")
        let replacement = installedPlugin(url: pluginURL, version: "2.0.0")
        manager.publishPreparedInstalledPlugins([first.id: first])

        let staleTask = Task { try await manager.getRunner(for: first.id) }
        await waitUntil { loader.pendingCount == 1 }
        manager.publishPreparedInstalledPlugins([replacement.id: replacement])
        loader.resolvePending(with: staleRunner)

        do {
            _ = try await staleTask.value
            XCTFail("A replaced plugin load must not enter the canonical runner cache")
        } catch {
            // Expected: the captured publication authority changed while loading.
        }

        let loadedReplacement = try await manager.getRunner(for: replacement.id)
        let cachedReplacement = try await manager.getRunner(for: replacement.id)
        XCTAssertTrue(loadedReplacement === replacementRunner)
        XCTAssertTrue(cachedReplacement === replacementRunner)
        XCTAssertEqual(loader.requests, [first.id, replacement.id])
    }

    func testPR16BMigrationReportViewModelJoinsCompletedScreenModels() throws {
        let viewModelsURL = repositoryRoot.appendingPathComponent("Ito/ViewModels")
        let names = try FileManager.default.contentsOfDirectory(
            at: viewModelsURL,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)

        XCTAssertTrue(names.contains("BackupSettingsViewModel.swift"))
        XCTAssertTrue(names.contains("MigrationReportViewModel.swift"))
        XCTAssertTrue(names.contains("MangaReaderViewModel.swift"))
        XCTAssertTrue(names.contains("NovelReaderViewModel.swift"))
        XCTAssertTrue(names.contains("VideoPlayerViewModel.swift"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceFile(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func installedPlugin(url: URL, version: String) -> InstalledPlugin {
        InstalledPlugin(
            url: url,
            info: PluginInfo(
                id: "plugin.exact",
                name: "Exact",
                version: version,
                minAppVersion: "1.0",
                type: .manga
            ),
            iconData: nil
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class NonCooperativePluginRunnerLoader {
    enum Response {
        case suspended
        case immediate(ItoRunner)
    }

    private var responses: [Response]
    private var pending: CheckedContinuation<ItoRunner, Error>?
    private(set) var requests: [String] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    var pendingCount: Int { pending == nil ? 0 : 1 }

    func load(
        pluginID: String,
        pluginURL: URL,
        settingsStore: PluginSettingsStore
    ) async throws -> ItoRunner {
        _ = pluginURL
        _ = settingsStore
        requests.append(pluginID)
        guard !responses.isEmpty else { throw RunnerLoaderTestError.missingResponse }
        switch responses.removeFirst() {
        case .suspended:
            return try await withCheckedThrowingContinuation { pending = $0 }
        case .immediate(let runner):
            return runner
        }
    }

    func resolvePending(with runner: ItoRunner) {
        pending?.resume(returning: runner)
        pending = nil
    }
}

private enum RunnerLoaderTestError: Error {
    case missingResponse
}
