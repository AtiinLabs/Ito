import Combine
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class BrowseViewModelTests: XCTestCase {
    func testInitialInstalledPluginStateIsPublishedImmediately() {
        let plugins = BrowsePluginManagerSpy(installedPlugins: [
            "manga": makePlugin(id: "manga", name: "Manga", type: .manga)
        ])
        let viewModel = makeViewModel(plugins: plugins)

        XCTAssertEqual(viewModel.sortedPlugins.map(\.id), ["manga"])
        XCTAssertEqual(viewModel.phase, .content)
    }

    func testDerivedPluginOrderingGroupingAndUpdateSectionsRemainStable() {
        let plugins = BrowsePluginManagerSpy(installedPlugins: [
            "novel": makePlugin(id: "novel", name: "Zulu", type: .novel),
            "anime": makePlugin(id: "anime", name: "Alpha", type: .anime),
            "manga": makePlugin(id: "manga", name: "Middle", type: .manga)
        ])
        let repositories = BrowseRepositoryManagerSpy(repositories: [
            makeRepository(packages: [
                makePackage(id: "manga", name: "Middle", version: "2.0")
            ])
        ])
        let viewModel = makeViewModel(plugins: plugins, repositories: repositories)

        XCTAssertEqual(viewModel.sortedPlugins.map(\.id), ["anime", "manga", "novel"])
        XCTAssertEqual(viewModel.pluginGroups.map(\.type), [.anime, .manga, .novel])
        XCTAssertEqual(viewModel.pluginGroups.map { $0.plugins.map(\.id) }, [["anime"], ["manga"], ["novel"]])
        XCTAssertEqual(viewModel.availableUpdates.map(\.id), ["manga"])
    }

    func testUpdateAvailabilityUsesNewestPackageAndStableNameOrdering() {
        let plugins = BrowsePluginManagerSpy(installedPlugins: [
            "alpha": makePlugin(id: "alpha", name: "Alpha", version: "1.0", type: .anime),
            "zulu": makePlugin(id: "zulu", name: "Zulu", version: "1.0", type: .manga)
        ])
        let repositories = BrowseRepositoryManagerSpy(repositories: [
            makeRepository(url: "https://one.example", packages: [
                makePackage(id: "zulu", name: "Zulu", version: "1.5"),
                makePackage(id: "alpha", name: "Alpha", version: "2.0")
            ]),
            makeRepository(url: "https://two.example", packages: [
                makePackage(id: "zulu", name: "Zulu", version: "3.0"),
                makePackage(id: "missing", name: "Missing", version: "9.0")
            ])
        ])
        let viewModel = makeViewModel(plugins: plugins, repositories: repositories)

        XCTAssertEqual(viewModel.availableUpdates.map(\.id), ["alpha", "zulu"])
        XCTAssertEqual(viewModel.availableUpdates.map(\.pkg.version), ["2.0", "3.0"])
        XCTAssertEqual(viewModel.availableUpdates.map(\.repoURL), ["https://one.example", "https://two.example"])
    }

    func testStartingUpdateInvokesDependencyExactlyOnce() async throws {
        let plugins = BrowsePluginManagerSpy(installedPlugins: [
            "plugin": makePlugin(id: "plugin", name: "Plugin")
        ])
        let repositories = BrowseRepositoryManagerSpy(repositories: [
            makeRepository(packages: [makePackage(id: "plugin", name: "Plugin", version: "2.0")])
        ])
        let viewModel = makeViewModel(plugins: plugins, repositories: repositories)
        let update = try XCTUnwrap(viewModel.availableUpdates.first)

        await viewModel.installUpdate(update)

        XCTAssertEqual(repositories.installInvocations.count, 1)
        XCTAssertEqual(repositories.installInvocations.first?.packageID, "plugin")
    }

    func testSuccessfulUpdateRepublishesPluginState() async throws {
        let plugins = BrowsePluginManagerSpy(installedPlugins: [
            "plugin": makePlugin(id: "plugin", name: "Plugin", version: "1.0")
        ])
        let repositories = BrowseRepositoryManagerSpy(repositories: [
            makeRepository(packages: [makePackage(id: "plugin", name: "Plugin", version: "2.0")])
        ])
        repositories.onInstall = {
            plugins.installedPlugins = [
                "plugin": self.makePlugin(id: "plugin", name: "Plugin", version: "2.0")
            ]
        }
        let viewModel = makeViewModel(plugins: plugins, repositories: repositories)

        await viewModel.installUpdate(try XCTUnwrap(viewModel.availableUpdates.first))

        XCTAssertEqual(viewModel.sortedPlugins.first?.info.version, "2.0")
        XCTAssertTrue(viewModel.availableUpdates.isEmpty)
    }

    func testFailedUpdatePreservesPluginAndSurfacesTypedMessage() async throws {
        let plugins = BrowsePluginManagerSpy(installedPlugins: [
            "plugin": makePlugin(id: "plugin", name: "Plugin", version: "1.0")
        ])
        let repositories = BrowseRepositoryManagerSpy(repositories: [
            makeRepository(packages: [makePackage(id: "plugin", name: "Plugin", version: "2.0")])
        ])
        repositories.installError = BrowseTestFailure.failed
        let messages = BrowseMessagePresenterSpy()
        let viewModel = makeViewModel(plugins: plugins, repositories: repositories, messages: messages)

        await viewModel.installUpdate(try XCTUnwrap(viewModel.availableUpdates.first))

        XCTAssertEqual(viewModel.sortedPlugins.first?.info.version, "1.0")
        XCTAssertEqual(messages.messages, [.updateFailed(reason: "fixture failure")])
        XCTAssertEqual(viewModel.phase, .content)
    }

    func testDeleteRequestDoesNotTouchFilesBeforeConfirmation() {
        let plugin = makePlugin(id: "plugin", name: "Plugin")
        let files = BrowsePluginFileOperationsSpy()
        let viewModel = makeViewModel(
            plugins: BrowsePluginManagerSpy(installedPlugins: [plugin.id: plugin]),
            files: files
        )

        viewModel.requestDelete(plugin)

        XCTAssertTrue(viewModel.showDeleteConfirmation)
        XCTAssertEqual(viewModel.pendingDeletePluginID, plugin.id)
        XCTAssertEqual(files.deleteInvocations, [])
    }

    func testCancellingDeletePerformsNoFileOperation() async {
        let plugin = makePlugin(id: "plugin", name: "Plugin")
        let files = BrowsePluginFileOperationsSpy()
        let viewModel = makeViewModel(
            plugins: BrowsePluginManagerSpy(installedPlugins: [plugin.id: plugin]),
            files: files
        )

        viewModel.requestDelete(plugin)
        viewModel.cancelDelete()
        await viewModel.confirmDelete()

        XCTAssertFalse(viewModel.showDeleteConfirmation)
        XCTAssertNil(viewModel.pendingDeletePluginID)
        XCTAssertEqual(files.deleteInvocations, [])
    }

    func testConfirmedDeleteInvokesFileBoundaryExactlyOnce() async {
        let plugin = makePlugin(id: "plugin", name: "Plugin")
        let plugins = BrowsePluginManagerSpy(installedPlugins: [plugin.id: plugin])
        plugins.onReload = { plugins.installedPlugins = [:] }
        let files = BrowsePluginFileOperationsSpy()
        let viewModel = makeViewModel(plugins: plugins, files: files)

        viewModel.requestDelete(plugin)
        await viewModel.confirmDelete()

        XCTAssertEqual(files.deleteInvocations, [plugin.url])
        XCTAssertEqual(plugins.reloadCallCount, 1)
        XCTAssertEqual(plugins.removedSecretsPluginIDs, [plugin.id])
    }

    func testFailedDeletePreservesVisiblePluginAndSurfacesError() async {
        let plugin = makePlugin(id: "plugin", name: "Plugin")
        let plugins = BrowsePluginManagerSpy(installedPlugins: [plugin.id: plugin])
        let files = BrowsePluginFileOperationsSpy()
        files.deleteError = BrowseTestFailure.failed
        let messages = BrowseMessagePresenterSpy()
        let viewModel = makeViewModel(plugins: plugins, files: files, messages: messages)

        viewModel.requestDelete(plugin)
        await viewModel.confirmDelete()

        XCTAssertEqual(viewModel.sortedPlugins.map(\.id), [plugin.id])
        XCTAssertEqual(plugins.reloadCallCount, 0)
        XCTAssertTrue(plugins.removedSecretsPluginIDs.isEmpty)
        XCTAssertEqual(messages.messages, [.deleteFailed(pluginName: "Plugin", reason: "fixture failure")])
    }

    func testSuccessfulDeleteRefreshesOnlyAfterFileOperationSucceeds() async {
        let plugin = makePlugin(id: "plugin", name: "Plugin")
        let plugins = BrowsePluginManagerSpy(installedPlugins: [plugin.id: plugin])
        let files = BrowsePluginFileOperationsSpy()
        files.onDelete = {
            XCTAssertEqual(plugins.reloadCallCount, 0)
        }
        plugins.onReload = { plugins.installedPlugins = [:] }
        let viewModel = makeViewModel(plugins: plugins, files: files)

        viewModel.requestDelete(plugin)
        await viewModel.confirmDelete()

        XCTAssertTrue(viewModel.sortedPlugins.isEmpty)
        XCTAssertEqual(viewModel.phase, .empty)
    }

    func testRapidDuplicateDeleteConfirmationsDoNotOverlap() async {
        let plugin = makePlugin(id: "plugin", name: "Plugin")
        let plugins = BrowsePluginManagerSpy(installedPlugins: [plugin.id: plugin])
        plugins.suspendReload = true
        let files = BrowsePluginFileOperationsSpy()
        let viewModel = makeViewModel(plugins: plugins, files: files)
        viewModel.requestDelete(plugin)

        let first = Task { await viewModel.confirmDelete() }
        await waitUntil { plugins.reloadCallCount == 1 }
        await viewModel.confirmDelete()

        XCTAssertEqual(files.deleteInvocations.count, 1)
        plugins.resumeReload()
        await first.value
    }

    func testSupportedDroppedPluginUsesExistingImportAndReloadPath() async {
        let plugins = BrowsePluginManagerSpy()
        let files = BrowsePluginFileOperationsSpy()
        let viewModel = makeViewModel(plugins: plugins, files: files)
        let URL = URL(fileURLWithPath: "/tmp/plugin.ito")

        let accepted = await viewModel.importPluginFile(at: URL, source: .drop)

        XCTAssertTrue(accepted)
        XCTAssertEqual(files.installInvocations, [URL])
        XCTAssertEqual(plugins.reloadCallCount, 1)
    }

    func testUnsupportedDropIsRejectedWithoutMutation() async {
        let plugins = BrowsePluginManagerSpy(installedPlugins: [
            "existing": makePlugin(id: "existing", name: "Existing")
        ])
        let files = BrowsePluginFileOperationsSpy()
        let messages = BrowseMessagePresenterSpy()
        let viewModel = makeViewModel(plugins: plugins, files: files, messages: messages)

        let accepted = await viewModel.importPluginFile(
            at: URL(fileURLWithPath: "/tmp/not-a-plugin.zip"),
            source: .drop
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(files.installInvocations, [])
        XCTAssertEqual(plugins.reloadCallCount, 0)
        XCTAssertEqual(viewModel.sortedPlugins.map(\.id), ["existing"])
        XCTAssertEqual(messages.messages, [.unsupportedPluginFile])
    }

    func testFailedDropImportPreservesExistingStateAndSurfacesError() async {
        let plugins = BrowsePluginManagerSpy(installedPlugins: [
            "existing": makePlugin(id: "existing", name: "Existing")
        ])
        let files = BrowsePluginFileOperationsSpy()
        files.installError = BrowseTestFailure.failed
        let messages = BrowseMessagePresenterSpy()
        let viewModel = makeViewModel(plugins: plugins, files: files, messages: messages)

        let accepted = await viewModel.importPluginFile(
            at: URL(fileURLWithPath: "/tmp/plugin.ito"),
            source: .drop
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(plugins.reloadCallCount, 0)
        XCTAssertEqual(viewModel.sortedPlugins.map(\.id), ["existing"])
        XCTAssertEqual(messages.messages, [.importFailed(source: .drop, reason: "fixture failure")])
    }

    func testDropImportsAreSerialized() async {
        let plugins = BrowsePluginManagerSpy()
        plugins.suspendReload = true
        let files = BrowsePluginFileOperationsSpy()
        let viewModel = makeViewModel(plugins: plugins, files: files)
        let firstURL = URL(fileURLWithPath: "/tmp/first.ito")
        let secondURL = URL(fileURLWithPath: "/tmp/second.ito")

        let first = Task { await viewModel.importPluginFile(at: firstURL, source: .drop) }
        await waitUntil { plugins.reloadCallCount == 1 }
        let secondAccepted = await viewModel.importPluginFile(at: secondURL, source: .drop)

        XCTAssertFalse(secondAccepted)
        XCTAssertEqual(files.installInvocations, [firstURL])
        plugins.resumeReload()
        let firstAccepted = await first.value
        XCTAssertTrue(firstAccepted)
    }

    func testProductionFileAdapterInstallsIntoExistingPluginsLocation() throws {
        let fixture = try BrowseFileFixture()
        defer { fixture.cleanup() }
        let sourceURL = fixture.root.appendingPathComponent("plugin.ito")
        try Data("new plugin".utf8).write(to: sourceURL)
        let files = LocalBrowsePluginFileOperations(
            applicationSupportDirectory: fixture.applicationSupport
        )

        try files.installPluginFile(from: sourceURL)

        let installedURL = fixture.applicationSupport
            .appendingPathComponent("Plugins")
            .appendingPathComponent("plugin.ito")
        XCTAssertEqual(try Data(contentsOf: installedURL), Data("new plugin".utf8))

        try Data("updated plugin".utf8).write(to: sourceURL)
        try files.installPluginFile(from: sourceURL)
        XCTAssertEqual(try Data(contentsOf: installedURL), Data("updated plugin".utf8))
    }

    func testProductionFileAdapterReplacesOnlyAfterStagingSucceeds() throws {
        let fixture = try BrowseFileFixture()
        defer { fixture.cleanup() }
        let pluginsDirectory = fixture.applicationSupport.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(
            at: pluginsDirectory,
            withIntermediateDirectories: true
        )
        let installedURL = pluginsDirectory.appendingPathComponent("plugin.ito")
        try Data("existing plugin".utf8).write(to: installedURL)
        let missingSource = fixture.root.appendingPathComponent("plugin.ito")
        let files = LocalBrowsePluginFileOperations(
            applicationSupportDirectory: fixture.applicationSupport
        )

        XCTAssertThrowsError(try files.installPluginFile(from: missingSource))

        XCTAssertEqual(try Data(contentsOf: installedURL), Data("existing plugin".utf8))
    }

    func testProductionFileAdapterDeletesOnlyRequestedPluginFile() throws {
        let fixture = try BrowseFileFixture()
        defer { fixture.cleanup() }
        let pluginsDirectory = fixture.applicationSupport.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(
            at: pluginsDirectory,
            withIntermediateDirectories: true
        )
        let selectedURL = pluginsDirectory.appendingPathComponent("selected.ito")
        let retainedURL = pluginsDirectory.appendingPathComponent("retained.ito")
        try Data().write(to: selectedURL)
        try Data().write(to: retainedURL)
        let files = LocalBrowsePluginFileOperations(
            applicationSupportDirectory: fixture.applicationSupport
        )

        try files.deletePluginFile(at: selectedURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: selectedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
    }

    func testLoadingPhaseIsRepresentedDuringActiveUpdate() async throws {
        let plugins = BrowsePluginManagerSpy(installedPlugins: [
            "plugin": makePlugin(id: "plugin", name: "Plugin")
        ])
        let repositories = BrowseRepositoryManagerSpy(repositories: [
            makeRepository(packages: [makePackage(id: "plugin", name: "Plugin", version: "2.0")])
        ])
        repositories.suspendInstall = true
        let viewModel = makeViewModel(plugins: plugins, repositories: repositories)
        let update = try XCTUnwrap(viewModel.availableUpdates.first)

        let task = Task { await viewModel.installUpdate(update) }
        await waitUntil { repositories.installInvocations.count == 1 }

        XCTAssertEqual(viewModel.phase, .loading)
        XCTAssertEqual(viewModel.isInstallingUpdate, "plugin")
        repositories.resumeInstall()
        await task.value
        XCTAssertEqual(viewModel.phase, .content)
    }

    func testEmptyPhaseIsRepresented() {
        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.phase, .empty)
        XCTAssertTrue(viewModel.sortedPlugins.isEmpty)
    }

    func testErrorPresentationIsRecoverable() async throws {
        let plugins = BrowsePluginManagerSpy(installedPlugins: [
            "plugin": makePlugin(id: "plugin", name: "Plugin")
        ])
        let repositories = BrowseRepositoryManagerSpy(repositories: [
            makeRepository(packages: [makePackage(id: "plugin", name: "Plugin", version: "2.0")])
        ])
        let messages = BrowseMessagePresenterSpy()
        let viewModel = makeViewModel(plugins: plugins, repositories: repositories, messages: messages)
        let update = try XCTUnwrap(viewModel.availableUpdates.first)
        repositories.installError = BrowseTestFailure.failed

        await viewModel.installUpdate(update)
        repositories.installError = nil
        await viewModel.installUpdate(update)

        XCTAssertEqual(repositories.installInvocations.count, 2)
        XCTAssertEqual(messages.messages.count, 1)
        XCTAssertEqual(viewModel.phase, .content)
    }

    func testBrowseViewModelIdentityIsStableAcrossFactoryRecomputation() {
        let scope = makeScope()

        let first = scope.rootModels.browseViewModel
        _ = scope.viewFactory.makeBrowseView()
        let second = scope.rootModels.browseViewModel
        _ = scope.viewFactory.makeBrowseView()
        let third = scope.viewFactory.rootModels.browseViewModel

        XCTAssertTrue(first === second)
        XCTAssertTrue(second === third)
    }

    func testPendingRepositoryIntentIsConsumedAndAddedOnce() async throws {
        let router = AppRouter()
        let repositories = BrowseRepositoryManagerSpy()
        let viewModel = makeViewModel(repositories: repositories, router: router)
        router.handleRepositoryDeepLink(
            repositoryDeepLink("https://fixture.example/repository")
        )

        await viewModel.consumePendingRepositoryIntents()

        XCTAssertEqual(repositories.addInvocations, ["https://fixture.example/repository"])
        XCTAssertNil(router.repositoryIntentDelivery)
    }

    func testSuccessfulRepositoryAdditionAcknowledgesExactToken() async throws {
        let router = AppRouter()
        router.handleRepositoryDeepLink(repositoryDeepLink("https://fixture.example"))
        let token = try XCTUnwrap(router.repositoryIntentDelivery?.intent.token)
        let viewModel = makeViewModel(router: router)

        await viewModel.consumePendingRepositoryIntents()

        XCTAssertNil(router.repositoryIntentDelivery)
        router.acknowledgeRepositoryIntent(token: token)
        XCTAssertNil(router.repositoryIntentDelivery)
    }

    func testDuplicateConsumeCallsDoNotAddRepositoryAgain() async {
        let router = AppRouter()
        let repositories = BrowseRepositoryManagerSpy()
        router.handleRepositoryDeepLink(repositoryDeepLink("https://fixture.example"))
        let viewModel = makeViewModel(repositories: repositories, router: router)

        await viewModel.consumePendingRepositoryIntents()
        await viewModel.consumePendingRepositoryIntents()
        await viewModel.consumePendingRepositoryIntents()

        XCTAssertEqual(repositories.addInvocations.count, 1)
    }

    func testWrongAcknowledgmentCannotClearNewerPendingIntent() async throws {
        let router = AppRouter()
        router.handleRepositoryDeepLink(repositoryDeepLink("https://one.example"))
        let first = try XCTUnwrap(router.claimPendingRepositoryIntent())
        router.handleRepositoryDeepLink(repositoryDeepLink("https://two.example"))
        router.acknowledgeRepositoryIntent(token: first.token)
        let second = try XCTUnwrap(router.claimPendingRepositoryIntent())

        router.acknowledgeRepositoryIntent(token: first.token)

        XCTAssertEqual(router.repositoryIntentDelivery, .claimed(second))
    }

    func testFailedRepositoryAdditionPreservesStatePublishesOnceAndDoesNotRetry() async {
        let existing = makeRepository(url: "https://existing.example", packages: [])
        let repositories = BrowseRepositoryManagerSpy(repositories: [existing])
        repositories.addError = BrowseTestFailure.failed
        let messages = BrowseMessagePresenterSpy()
        let router = AppRouter()
        router.handleRepositoryDeepLink(repositoryDeepLink("https://failing.example"))
        let viewModel = makeViewModel(
            repositories: repositories,
            messages: messages,
            router: router
        )

        await viewModel.consumePendingRepositoryIntents()
        await viewModel.consumePendingRepositoryIntents()

        XCTAssertEqual(repositories.repositories, [existing])
        XCTAssertEqual(repositories.addInvocations, ["https://failing.example"])
        XCTAssertEqual(messages.messages, [.repositoryAddFailed])
        XCTAssertNil(router.repositoryIntentDelivery)
    }

    func testAlreadyPresentRepositoryIsAcknowledgedAndReportedAsAlreadyAdded() async {
        let repositories = BrowseRepositoryManagerSpy()
        repositories.addResult = .alreadyPresent
        let messages = BrowseMessagePresenterSpy()
        let router = AppRouter()
        router.handleRepositoryDeepLink(repositoryDeepLink("https://existing.example"))
        let viewModel = makeViewModel(
            repositories: repositories,
            messages: messages,
            router: router
        )

        await viewModel.consumePendingRepositoryIntents()

        XCTAssertEqual(repositories.addInvocations.count, 1)
        XCTAssertEqual(messages.messages, [.repositoryAlreadyAdded])
        XCTAssertTrue(viewModel.showRepositories)
        XCTAssertNil(router.repositoryIntentDelivery)
    }

    func testAddedRepositoryIsConfirmedAndRepositoryListOpens() async {
        let repositories = BrowseRepositoryManagerSpy()
        let messages = BrowseMessagePresenterSpy()
        let router = AppRouter()
        router.handleRepositoryDeepLink(repositoryDeepLink("https://new.example"))
        let viewModel = makeViewModel(
            repositories: repositories,
            messages: messages,
            router: router
        )

        await viewModel.consumePendingRepositoryIntents()

        XCTAssertEqual(messages.messages, [.repositoryAdded])
        XCTAssertTrue(viewModel.showRepositories)
    }

    func testStaleRepositoryRefreshRunsOnlyWhenAnIndexIsOlderThanMaxAge() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var fresh = makeRepository(url: "https://fresh.example", packages: [])
        fresh.lastFetched = now.addingTimeInterval(-599)
        let repositories = BrowseRepositoryManagerSpy(repositories: [fresh])
        let viewModel = makeViewModel(repositories: repositories)

        await viewModel.refreshStaleRepositories(now: now, maxAge: 600)
        XCTAssertEqual(repositories.refreshCallCount, 0)

        repositories.repositories[0].lastFetched = now.addingTimeInterval(-600)
        await viewModel.refreshStaleRepositories(now: now, maxAge: 600)
        XCTAssertEqual(repositories.refreshCallCount, 1)

        repositories.repositories[0].lastFetched = nil
        await viewModel.refreshStaleRepositories(now: now, maxAge: 600)
        XCTAssertEqual(repositories.refreshCallCount, 2)

        // A recent fetch whose stored index couldn't be read still needs refreshing.
        repositories.repositories[0].lastFetched = now.addingTimeInterval(-10)
        repositories.repositories[0].index = nil
        await viewModel.refreshStaleRepositories(now: now, maxAge: 600)
        XCTAssertEqual(repositories.refreshCallCount, 3)
        XCTAssertFalse(viewModel.isRefreshing)
    }

    func testRapidConsumeCallsDoNotOverlapRepositoryAdditions() async {
        let repositories = BrowseRepositoryManagerSpy()
        repositories.suspendAdd = true
        let router = AppRouter()
        router.handleRepositoryDeepLink(repositoryDeepLink("https://fixture.example"))
        let viewModel = makeViewModel(repositories: repositories, router: router)

        let first = Task { await viewModel.consumePendingRepositoryIntents() }
        await waitUntil { repositories.addInvocations.count == 1 }
        let second = Task { await viewModel.consumePendingRepositoryIntents() }
        await Task.yield()

        XCTAssertEqual(repositories.addInvocations.count, 1)
        repositories.resumeAdd()
        await first.value
        await second.value
    }

    func testOldEpochCancellationDoesNotCommitPublishOrAcknowledgeSuspendedIntent() async throws {
        let repositories = BrowseRepositoryManagerSpy()
        repositories.suspendAdd = true
        let messages = BrowseMessagePresenterSpy()
        let router = AppRouter()
        router.handleRepositoryDeepLink(repositoryDeepLink("https://fixture.example"))
        var viewModel: BrowseViewModel? = makeViewModel(
            repositories: repositories,
            messages: messages,
            router: router
        )

        await waitUntil { repositories.addInvocations.count == 1 }
        let claimedIntent = try XCTUnwrap(router.repositoryIntentDelivery?.intent)
        weak var releasedViewModel = viewModel

        viewModel = nil
        XCTAssertNil(releasedViewModel)
        repositories.resumeAdd()
        await waitUntil { repositories.cancelledAddCallCount == 1 }

        XCTAssertTrue(repositories.committedAddInvocations.isEmpty)
        XCTAssertTrue(messages.messages.isEmpty)
        XCTAssertEqual(router.repositoryIntentDelivery, .claimed(claimedIntent))
    }

    func testLaterDistinctRepositoryIntentIsStillHandled() async {
        let repositories = BrowseRepositoryManagerSpy()
        let router = AppRouter()
        let viewModel = makeViewModel(repositories: repositories, router: router)

        router.handleRepositoryDeepLink(repositoryDeepLink("https://one.example"))
        await viewModel.consumePendingRepositoryIntents()
        router.handleRepositoryDeepLink(repositoryDeepLink("https://two.example"))
        await viewModel.consumePendingRepositoryIntents()

        XCTAssertEqual(
            repositories.addInvocations,
            ["https://one.example", "https://two.example"]
        )
    }

    func testSourceContractsKeepBrowseBoundariesNarrowAndRootStable() throws {
        let modelSource = try sourceFile("Ito/ViewModels/BrowseViewModel.swift")
        let viewSource = try sourceFile("Ito/Views/Browse/BrowseView.swift")
        let appSource = try sourceFile("Ito/ItoApp.swift")

        for forbidden in [
            "FileManager.default",
            "UIApplication.shared",
            "SnackBarManager.shared",
            "AppRouter",
            "func configure("
        ] {
            XCTAssertFalse(modelSource.contains(forbidden), "Found forbidden BrowseViewModel source: \(forbidden)")
        }

        let rootStart = try XCTUnwrap(viewSource.range(of: "struct BrowseView: View"))
        let contentStart = try XCTUnwrap(viewSource.range(of: "private struct BrowseContentView: View"))
        let rootSource = String(viewSource[rootStart.lowerBound..<contentStart.lowerBound])
        XCTAssertTrue(rootSource.contains("NavigationView"))
        XCTAssertFalse(rootSource.contains("@ObservedObject"))
        XCTAssertTrue(viewSource.contains(".confirmationDialog("))
        XCTAssertTrue(viewSource.contains("await viewModel.confirmDelete()"))

        XCTAssertTrue(modelSource.contains("BrowseRepositoryIntentRouting"))
        XCTAssertTrue(modelSource.contains("consumePendingRepositoryIntents"))
        XCTAssertTrue(appSource.contains("appScope.router.handleRepositoryDeepLink(url)"))
        XCTAssertFalse(appSource.contains("repoManager.addRepository"))
        XCTAssertFalse(viewSource.contains("pendingRepository"))
        XCTAssertFalse(viewSource.contains("acknowledgmentToken"))
    }

    private func makeViewModel(
        plugins: BrowsePluginManagerSpy = BrowsePluginManagerSpy(),
        repositories: BrowseRepositoryManagerSpy = BrowseRepositoryManagerSpy(),
        files: BrowsePluginFileOperationsSpy = BrowsePluginFileOperationsSpy(),
        messages: BrowseMessagePresenterSpy = BrowseMessagePresenterSpy(),
        router: AppRouter = AppRouter()
    ) -> BrowseViewModel {
        BrowseViewModel(
            repositoryManager: repositories,
            pluginManager: plugins,
            fileOperations: files,
            messagePresenter: messages,
            repositoryIntentRouter: router
        )
    }

    private func makeScope() -> AppScope {
        AppScope(
            preparedDependencies: PreparedApplicationDependencies(
                settings: makeTestPreparedSettingsDependencies(),
                searchExecutor: BrowseSearchExecutor(),
                recentSearchStore: BrowseRecentSearchStore(),
                searchDebounceMilliseconds: nil,
                presentationLogger: PresentationEventCaptureSpy(),
                browseRepositoryManager: BrowseRepositoryManagerSpy(),
                repositoryManagement: makeTestRepositoryManagementDependencies(),
                browsePluginManager: BrowsePluginManagerSpy(),
                browseFileOperations: BrowsePluginFileOperationsSpy()
            )
        )
    }

    private func repositoryDeepLink(_ repositoryURL: String) -> URL {
        var components = URLComponents()
        components.scheme = "ito"
        components.host = "repo"
        components.path = "/add"
        components.queryItems = [URLQueryItem(name: "url", value: repositoryURL)]
        return components.url!
    }

    private func makePlugin(
        id: String,
        name: String,
        version: String = "1.0",
        type: PluginType = .manga
    ) -> InstalledPlugin {
        InstalledPlugin(
            url: URL(fileURLWithPath: "/plugins/\(id).ito"),
            info: PluginInfo(
                id: id,
                name: name,
                version: version,
                minAppVersion: "1.0",
                type: type
            ),
            iconData: nil
        )
    }

    private func makePackage(id: String, name: String, version: String) -> RepoPackage {
        RepoPackage(
            id: id,
            name: name,
            version: version,
            minAppVersion: "1.0",
            downloadUrl: "\(id).ito",
            iconUrl: nil,
            sha256: "fixture",
            pluginType: "manga",
            archived: false,
            archivedReason: nil,
            archivedDate: nil
        )
    }

    private func makeRepository(
        url: String = "https://repo.example",
        packages: [RepoPackage]
    ) -> Repository {
        Repository(
            url: url,
            index: RepoIndex(
                repoName: "Fixture",
                repoUrl: url,
                description: "",
                packages: packages
            )
        )
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Condition was not met before timeout", file: file, line: line)
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

private enum BrowseTestFailure: LocalizedError {
    case failed

    var errorDescription: String? { "fixture failure" }
}

private struct BrowseFileFixture {
    let root: URL
    let applicationSupport: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowseViewModelTests-\(UUID().uuidString)")
        applicationSupport = root.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class BrowsePluginManagerSpy: BrowsePluginManaging {
    @Published var installedPlugins: [String: InstalledPlugin]
    private(set) var reloadCallCount = 0
    private(set) var removedSecretsPluginIDs: [String] = []
    var onReload: (() -> Void)?
    var suspendReload = false
    private var reloadContinuation: CheckedContinuation<Void, Never>?

    init(installedPlugins: [String: InstalledPlugin] = [:]) {
        self.installedPlugins = installedPlugins
    }

    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        $installedPlugins.eraseToAnyPublisher()
    }

    func reloadInstalledPlugins() async {
        reloadCallCount += 1
        if suspendReload {
            await withCheckedContinuation { reloadContinuation = $0 }
        }
        onReload?()
    }

    func removeSecrets(for pluginID: String) {
        removedSecretsPluginIDs.append(pluginID)
    }

    func resumeReload() {
        suspendReload = false
        reloadContinuation?.resume()
        reloadContinuation = nil
    }
}

@MainActor
private final class BrowseRepositoryManagerSpy: BrowseRepositoryManaging {
    struct InstallInvocation {
        let packageID: String
        let repositoryURL: String
    }

    @Published var repositories: [Repository]
    private(set) var installInvocations: [InstallInvocation] = []
    private(set) var addInvocations: [String] = []
    private(set) var committedAddInvocations: [String] = []
    private(set) var cancelledAddCallCount = 0
    private(set) var refreshCallCount = 0
    var addResult: RepositoryAdditionResult = .added
    var addError: (any Error)?
    var suspendAdd = false
    var installError: (any Error)?
    var onInstall: (() -> Void)?
    var suspendInstall = false
    private var installContinuation: CheckedContinuation<Void, Never>?
    private var addContinuation: CheckedContinuation<Void, Never>?

    init(repositories: [Repository] = []) {
        self.repositories = repositories
    }

    var repositoriesPublisher: AnyPublisher<[Repository], Never> {
        $repositories.eraseToAnyPublisher()
    }

    func addRepository(url: String) async throws -> RepositoryAdditionResult {
        addInvocations.append(url)
        if suspendAdd {
            await withCheckedContinuation { addContinuation = $0 }
        }
        if Task.isCancelled {
            cancelledAddCallCount += 1
            throw CancellationError()
        }
        if let addError { throw addError }
        committedAddInvocations.append(url)
        return addResult
    }

    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws {
        installInvocations.append(.init(packageID: package.id, repositoryURL: repositoryURL))
        if suspendInstall {
            await withCheckedContinuation { installContinuation = $0 }
        }
        if let installError { throw installError }
        onInstall?()
    }

    func refreshAll() async {
        refreshCallCount += 1
    }

    func resumeInstall() {
        suspendInstall = false
        installContinuation?.resume()
        installContinuation = nil
    }

    func resumeAdd() {
        suspendAdd = false
        addContinuation?.resume()
        addContinuation = nil
    }
}

@MainActor
private final class BrowsePluginFileOperationsSpy: BrowsePluginFileOperating {
    private(set) var installInvocations: [URL] = []
    private(set) var deleteInvocations: [URL] = []
    var installError: (any Error)?
    var deleteError: (any Error)?
    var onDelete: (() -> Void)?

    func supportsPluginFile(at URL: URL) -> Bool {
        URL.pathExtension.lowercased() == "ito"
    }

    func installPluginFile(from URL: URL) throws {
        installInvocations.append(URL)
        if let installError { throw installError }
    }

    func deletePluginFile(at URL: URL) throws {
        deleteInvocations.append(URL)
        onDelete?()
        if let deleteError { throw deleteError }
    }
}

@MainActor
private final class BrowseMessagePresenterSpy: BrowseMessagePresenting {
    private(set) var messages: [BrowseMessage] = []

    func present(_ message: BrowseMessage) {
        messages.append(message)
    }
}

@MainActor
private final class BrowseSearchExecutor: SearchPluginExecuting {
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
private final class BrowseRecentSearchStore: RecentSearchPersisting {
    func load() -> [String] { [] }
    func save(_ searches: [String]) { _ = searches }
    func clear() {}
}
