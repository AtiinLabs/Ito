import XCTest
import ito_runner
@testable import Ito

@MainActor
final class SourceViewModelTests: XCTestCase {
    func testInitialStateContainsOnlyStablePluginIdentity() {
        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertEqual(viewModel.searchPhase, .idle)
        XCTAssertEqual(viewModel.plugin.id, "plugin.manga")
        XCTAssertNil(viewModel.homeLayout)
        XCTAssertNil(viewModel.settingsSchema)
        XCTAssertTrue(viewModel.searchMangas.isEmpty)
    }

    func testSuccessfulHomeLoadPublishesSchemaAndContent() async throws {
        let context = PR7BSourceRunnerContextSpy()
        context.homeResult = .success(pr7bHome(ids: ["home-a", "home-b"]))
        context.settingsResult = .success(try pr7bSettingsSchema(settings: [
            .toggle(id: "enabled", name: "Enabled", summary: nil, defaultValue: true)
        ]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [context])
        let viewModel = makeViewModel(provider: provider)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.phase, .content)
        XCTAssertEqual(viewModel.homeLayout?.components.compactMap(\.title), ["home-a", "home-b"])
        XCTAssertEqual(viewModel.settingsSchema?.settings.count, 1)
        XCTAssertEqual(provider.requestedPluginIDs, ["plugin.manga"])
        XCTAssertEqual(context.settingsLoadCount, 1)
        XCTAssertEqual(context.homeLoadCount, 1)
        XCTAssertEqual(context.loadEvents, ["settings", "home"])
    }

    func testEmptyHomeIsAStableEmptyState() async {
        let viewModel = makeViewModel()

        await viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.phase, .empty)
        XCTAssertEqual(viewModel.homeLayout?.components.count, 0)
    }

    func testLoadFailureLeavesRetryableFailureAndPresentsMessage() async {
        let context = PR7BSourceRunnerContextSpy()
        context.homeResult = .failure(PR7BTestFailure.failed)
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]),
            messages: messages
        )

        await viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.phase, .failure("fixture failure"))
        XCTAssertEqual(
            messages.messages,
            [.loadFailed(pluginName: "Fixture Source", reason: "fixture failure")]
        )
    }

    func testRetryCreatesANewOperationAndCanRecover() async {
        let failed = PR7BSourceRunnerContextSpy()
        failed.homeResult = .failure(PR7BTestFailure.failed)
        let recovered = PR7BSourceRunnerContextSpy()
        recovered.homeResult = .success(pr7bHome(ids: ["recovered"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [failed, recovered])
        let viewModel = makeViewModel(provider: provider)

        await viewModel.loadIfNeeded()
        await viewModel.retry()

        XCTAssertEqual(provider.requestedPluginIDs.count, 2)
        XCTAssertEqual(viewModel.phase, .content)
        XCTAssertEqual(viewModel.homeLayout?.components.first?.title, "recovered")
    }

    func testSupersededNonCooperativeHomeCompletionCannotReplaceNewerState() async {
        let stale = PR7BSourceRunnerContextSpy()
        stale.suspendsHome = true
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.homeResult = .success(pr7bHome(ids: ["fresh"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [stale, fresh])
        let viewModel = makeViewModel(provider: provider)

        let oldTask = Task { await viewModel.loadIfNeeded() }
        await pr7bWaitUntil { stale.homeLoadCount == 1 }
        await viewModel.retry()
        XCTAssertEqual(viewModel.homeLayout?.components.first?.title, "fresh")

        stale.completeHome(with: .success(pr7bHome(ids: ["stale"])))
        await oldTask.value
        await Task.yield()

        XCTAssertEqual(viewModel.phase, .content)
        XCTAssertEqual(viewModel.homeLayout?.components.first?.title, "fresh")
    }

    func testCancellationSuppressesNonCooperativeCompletion() async {
        let context = PR7BSourceRunnerContextSpy()
        context.suspendsHome = true
        let viewModel = makeViewModel(provider: PR7BSourceRunnerProviderSpy(contexts: [context]))

        let task = Task { await viewModel.loadIfNeeded() }
        await pr7bWaitUntil { context.homeLoadCount == 1 }
        viewModel.cancelActiveOperations()
        context.completeHome(with: .success(pr7bHome(ids: ["obsolete"])))
        await task.value

        XCTAssertEqual(viewModel.phase, .cancelled)
        XCTAssertNil(viewModel.homeLayout)
    }

    func testSettingsTriggeredReloadEvictsRunnerAndPublishesOnlyReloadedSource() async {
        let initial = PR7BSourceRunnerContextSpy()
        initial.homeResult = .success(pr7bHome(ids: ["initial"]))
        let reloaded = PR7BSourceRunnerContextSpy()
        reloaded.homeResult = .success(pr7bHome(ids: ["reloaded"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [initial, reloaded])
        let viewModel = makeViewModel(provider: provider)

        await viewModel.loadIfNeeded()
        await viewModel.reloadAfterSettingsChange()

        XCTAssertEqual(provider.evictedPluginIDs, ["plugin.manga"])
        XCTAssertEqual(provider.requestedPluginIDs.count, 2)
        XCTAssertEqual(viewModel.homeLayout?.components.first?.title, "reloaded")
    }

    func testSettingsTriggeredReloadFailureIsTerminalAndVisible() async {
        let initial = PR7BSourceRunnerContextSpy()
        initial.homeResult = .success(pr7bHome(ids: ["initial"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [initial])
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(provider: provider, messages: messages)

        await viewModel.loadIfNeeded()
        provider.error = PR7BTestFailure.failed
        await viewModel.reloadAfterSettingsChange()

        XCTAssertEqual(viewModel.phase, .failure("fixture failure"))
        XCTAssertEqual(messages.messages.last, .loadFailed(
            pluginName: "Fixture Source",
            reason: "fixture failure"
        ))
    }

    func testAPluginThatCrashesWhileLoadingIsReplacedOnRetry() async {
        let crashed = PR7BSourceRunnerContextSpy()
        crashed.homeResult = .failure(PluginCallError(kind: .crashed, message: "The source stopped unexpectedly."))
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.homeResult = .success(pr7bHome(ids: ["fresh"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [crashed, fresh])
        let viewModel = makeViewModel(provider: provider)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.phase, .failure("The source stopped unexpectedly."))
        XCTAssertEqual(provider.evictedPluginIDs, ["plugin.manga"])

        await viewModel.retry()

        XCTAssertEqual(viewModel.homeLayout?.components.first?.title, "fresh")
    }

    func testAFailureThePluginReportedKeepsItsRunner() async {
        let context = PR7BSourceRunnerContextSpy()
        context.homeResult = .failure(PluginCallError(kind: .reported, message: "Add your server URL"))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [context])
        let viewModel = makeViewModel(provider: provider)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.phase, .failure("Add your server URL"))
        XCTAssertTrue(provider.evictedPluginIDs.isEmpty)
    }

    func testAPluginThatCrashesWhileSearchingIsReplacedBeforeTheNextSearch() async {
        let crashed = PR7BSourceRunnerContextSpy()
        crashed.searchResult = .failure(PluginCallError(kind: .crashed, message: "The source stopped unexpectedly."))
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.searchResult = .success(.manga([Manga(key: "fresh", title: "Fresh")]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [crashed, fresh])
        let viewModel = makeViewModel(provider: provider, debounce: nil)
        await viewModel.loadIfNeeded()

        viewModel.performSearch(query: "query")
        await pr7bWaitUntil { provider.requestedPluginIDs.count == 2 && viewModel.phase != .loading }

        XCTAssertEqual(viewModel.searchPhase, .failure("The source stopped unexpectedly."))
        XCTAssertEqual(provider.evictedPluginIDs, ["plugin.manga"])

        viewModel.performSearch(query: "again")
        await pr7bWaitUntil { viewModel.searchPhase == .content }

        XCTAssertEqual(crashed.searchInvocations.map(\.query), ["query"])
        XCTAssertEqual(fresh.searchInvocations.map(\.query), ["again"])
    }

    func testAPluginThatCrashesWhileReadingItsSettingsIsReplaced() async {
        let context = PR7BSourceRunnerContextSpy()
        context.settingsResult = .failure(PluginCallError(kind: .crashed, message: "The source stopped unexpectedly."))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [context])
        let viewModel = makeViewModel(provider: provider)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.phase, .failure("The source stopped unexpectedly."))
        XCTAssertEqual(provider.evictedPluginIDs, ["plugin.manga"])
        XCTAssertEqual(context.homeLoadCount, 0)
    }

    func testSettingsThatCantBeReadStayVisibleWithTheReasonAndTheHomeStillLoads() async {
        let context = PR7BSourceRunnerContextSpy()
        context.homeResult = .success(pr7bHome(ids: ["home-a"]))
        context.settingsResult = .failure(PluginCallError(kind: .incompatible, message: "Needs a newer Ito."))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [context])
        let viewModel = makeViewModel(provider: provider)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.phase, .content)
        XCTAssertTrue(viewModel.hasSettings)
        XCTAssertNil(viewModel.settingsDestination)
        XCTAssertEqual(viewModel.settingsUnavailableReason, "Needs a newer Ito.")
        XCTAssertTrue(provider.evictedPluginIDs.isEmpty)
    }

    func testSearchPreservesPageOneEmptyFilterInvocationAndResultOrdering() async {
        let context = PR7BSourceRunnerContextSpy()
        context.searchResult = .success(.manga([
            Manga(key: "b", title: "B"),
            Manga(key: "a", title: "A")
        ]))
        let viewModel = makeViewModel(
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]),
            debounce: nil
        )
        await viewModel.loadIfNeeded()

        viewModel.performSearch(query: " query ")
        await pr7bWaitUntil { viewModel.searchPhase != .loading }

        XCTAssertEqual(
            context.searchInvocations,
            [.init(pluginType: .manga, query: "query", page: 1, filterCount: 0)]
        )
        XCTAssertEqual(viewModel.searchMangas.map(\.key), ["b", "a"])
        XCTAssertEqual(viewModel.searchPhase, .content)
    }

    func testSearchTypedWhileSourceLoadsRunsOnceTheLoadFinishes() async {
        let context = PR7BSourceRunnerContextSpy()
        context.suspendsHome = true
        context.searchResult = .success(.manga([Manga(key: "a", title: "A")]))
        let viewModel = makeViewModel(
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]),
            debounce: nil
        )
        let load = Task { await viewModel.loadIfNeeded() }
        await pr7bWaitUntil { context.homeLoadCount == 1 }

        viewModel.performSearch(query: "query")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(viewModel.searchPhase, .loading)
        XCTAssertTrue(context.searchInvocations.isEmpty)

        context.completeHome(with: .success(HomeLayout(components: [])))
        await load.value
        await pr7bWaitUntil { viewModel.searchPhase != .loading }

        XCTAssertEqual(context.searchInvocations.map(\.query), ["query"])
        XCTAssertEqual(viewModel.searchMangas.map(\.key), ["a"])
        XCTAssertEqual(viewModel.searchPhase, .content)
    }

    func testSearchWaitingOnAFailedLoadShowsTheLoadFailure() async {
        let context = PR7BSourceRunnerContextSpy()
        context.suspendsHome = true
        let viewModel = makeViewModel(
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]),
            debounce: nil
        )
        let load = Task { await viewModel.loadIfNeeded() }
        await pr7bWaitUntil { context.homeLoadCount == 1 }

        viewModel.performSearch(query: "query")
        context.completeHome(with: .failure(PR7BTestFailure.failed))
        await load.value
        await pr7bWaitUntil { viewModel.searchPhase != .loading }

        XCTAssertTrue(context.searchInvocations.isEmpty)
        XCTAssertEqual(viewModel.searchPhase, .failure("fixture failure"))
    }

    func testNewSearchSuppressesOlderNonCooperativeCompletion() async {
        let context = PR7BSourceRunnerContextSpy()
        context.suspendsSearch = true
        let viewModel = makeViewModel(
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]),
            debounce: nil
        )
        await viewModel.loadIfNeeded()

        viewModel.performSearch(query: "old")
        await pr7bWaitUntil { context.pendingSearches.count == 1 }
        viewModel.performSearch(query: "new")
        await pr7bWaitUntil { context.pendingSearches.count == 2 }

        context.completeSearch(
            query: "new",
            with: .success(.manga([Manga(key: "new", title: "New")]))
        )
        await pr7bWaitUntil { viewModel.searchMangas.map(\.key) == ["new"] }
        context.completeSearch(
            query: "old",
            with: .success(.manga([Manga(key: "old", title: "Old")]))
        )
        await Task.yield()

        XCTAssertEqual(viewModel.searchMangas.map(\.key), ["new"])
        XCTAssertEqual(viewModel.searchPhase, .content)
    }

    func testWhitespaceOnlySearchReturnsPresentationToHomeWithoutStartingWork() async {
        let context = PR7BSourceRunnerContextSpy()
        let viewModel = makeViewModel(
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]),
            debounce: nil
        )
        await viewModel.loadIfNeeded()
        viewModel.searchQuery = "  \n\t "

        viewModel.performSearch(query: viewModel.searchQuery)

        XCTAssertFalse(viewModel.hasActiveSearchQuery)
        XCTAssertEqual(viewModel.searchPhase, .idle)
        XCTAssertTrue(context.searchInvocations.isEmpty)
        let viewSource = try? sourceFile("Ito/Views/Browse/SourceView.swift")
        XCTAssertTrue(viewSource?.contains("if !viewModel.hasActiveSearchQuery") == true)
    }

    func testTypedRoutesPreserveSourceContextPluginAndPayload() async throws {
        let context = PR7BSourceRunnerContextSpy()
        context.homeResult = .success(pr7bHome(ids: ["home"]))
        context.settingsResult = .success(try pr7bSettingsSchema())
        let plugin = pr7bPlugin()
        let viewModel = makeViewModel(
            plugin: plugin,
            provider: PR7BSourceRunnerProviderSpy(contexts: [context])
        )
        await viewModel.loadIfNeeded()

        let listing = Listing(id: "popular", name: "Popular", kind: 7)
        let listingRoute = try XCTUnwrap(viewModel.listingDestination(listing: listing, title: "Title"))
        XCTAssertEqual(listingRoute.plugin.id, plugin.id)
        XCTAssertTrue(listingRoute.context === context)
        XCTAssertEqual(listingRoute.listing.id, "popular")
        XCTAssertEqual(listingRoute.title, "Title")
        XCTAssertEqual(viewModel.settingsDestination?.plugin.id, plugin.id)

        let manga = Manga(key: "media", title: "Media")
        guard case .manga(let pluginID, let routeContext, let payload) = viewModel.destination(for: manga) else {
            return XCTFail("Expected typed manga destination")
        }
        XCTAssertEqual(pluginID, plugin.id)
        XCTAssertTrue(routeContext === context)
        XCTAssertEqual(payload.key, "media")
    }

    func testArchivedDeleteRequiresStablePluginConfirmation() {
        let plugin = pr7bPlugin(archived: true)
        let files = PR7BFileDeletionSpy()
        let viewModel = makeViewModel(plugin: plugin, files: files)

        viewModel.requestArchivedPluginDeletion()

        XCTAssertTrue(viewModel.showArchivedPluginDeleteConfirmation)
        XCTAssertEqual(viewModel.plugin.id, plugin.id)
        XCTAssertEqual(files.snapshotPlugins.map(\.id), [plugin.id])
        XCTAssertTrue(files.stagedSnapshots.isEmpty)
    }

    func testArchivedDeletePreparesPublicationCommitsPublishesThenDismisses() async {
        let plugin = pr7bPlugin(archived: true)
        let files = PR7BFileDeletionSpy()
        let publisher = PR7BPluginStatePublisherSpy()
        var commitCountAtPublication = 0
        publisher.onPublish = {
            commitCountAtPublication = files.transaction.commitCount
        }
        let viewModel = makeViewModel(plugin: plugin, publisher: publisher, files: files)
        viewModel.requestArchivedPluginDeletion()

        await viewModel.confirmArchivedPluginDeletion()

        XCTAssertEqual(files.stagedSnapshots.map(\.identity.fileURL), [plugin.url])
        XCTAssertEqual(publisher.callCount, 1)
        XCTAssertEqual(publisher.publishCount, 1)
        XCTAssertEqual(publisher.removedSecretsPluginIDs, [plugin.id])
        XCTAssertEqual(files.transaction.commitCount, 1)
        XCTAssertEqual(commitCountAtPublication, 1)
        XCTAssertEqual(files.transaction.rollbackCount, 0)
        XCTAssertTrue(viewModel.shouldDismiss)
        XCTAssertFalse(viewModel.isDeletingArchivedPlugin)
    }

    func testArchivedDeleteFileFailureDoesNotPublishDismissOrReportSuccess() async {
        let files = PR7BFileDeletionSpy()
        files.stageError = PR7BTestFailure.failed
        let publisher = PR7BPluginStatePublisherSpy()
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(
            plugin: pr7bPlugin(archived: true),
            publisher: publisher,
            files: files,
            messages: messages
        )
        viewModel.requestArchivedPluginDeletion()

        await viewModel.confirmArchivedPluginDeletion()

        XCTAssertEqual(publisher.callCount, 0)
        XCTAssertEqual(publisher.publishCount, 0)
        XCTAssertFalse(viewModel.shouldDismiss)
        XCTAssertEqual(viewModel.archivedPluginDeleteError, "fixture failure")
        XCTAssertEqual(messages.messages.count, 1)
    }

    func testArchivedDeletePublicationFailureRollsBackAndDoesNotDismiss() async {
        let files = PR7BFileDeletionSpy()
        let publisher = PR7BPluginStatePublisherSpy()
        publisher.results = [.failure(PR7BTestFailure.failed)]
        let viewModel = makeViewModel(
            plugin: pr7bPlugin(archived: true),
            publisher: publisher,
            files: files
        )
        viewModel.requestArchivedPluginDeletion()

        await viewModel.confirmArchivedPluginDeletion()

        XCTAssertEqual(files.transaction.commitCount, 0)
        XCTAssertEqual(files.transaction.rollbackCount, 1)
        XCTAssertEqual(publisher.publishCount, 0)
        XCTAssertTrue(publisher.removedSecretsPluginIDs.isEmpty)
        XCTAssertFalse(viewModel.shouldDismiss)
        XCTAssertNotNil(viewModel.archivedPluginDeleteError)
    }

    func testArchivedDeleteRejectsChangedAuthoritativePluginBeforeStaging() async {
        let plugin = pr7bPlugin(archived: true)
        let files = PR7BFileDeletionSpy()
        let publisher = PR7BPluginStatePublisherSpy()
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(
            plugin: plugin,
            publisher: publisher,
            files: files,
            messages: messages
        )
        viewModel.requestArchivedPluginDeletion()
        publisher.currentPlugins[plugin.id] = pr7bPlugin(
            id: plugin.id,
            name: "Replacement",
            archived: true,
            url: plugin.url
        )

        await viewModel.confirmArchivedPluginDeletion()

        XCTAssertTrue(files.stagedSnapshots.isEmpty)
        XCTAssertEqual(publisher.callCount, 0)
        XCTAssertEqual(publisher.publishCount, 0)
        XCTAssertFalse(viewModel.shouldDismiss)
        XCTAssertEqual(
            viewModel.archivedPluginDeleteError,
            SourcePluginFileError.stalePluginIdentity.localizedDescription
        )
        XCTAssertEqual(messages.messages.count, 1)
    }

    func testArchivedDeleteCommitFailureKeepsAuthoritativePluginAndDoesNotDismiss() async {
        let plugin = pr7bPlugin(archived: true)
        let files = PR7BFileDeletionSpy()
        files.transaction.commitError = PR7BTestFailure.failed
        let publisher = PR7BPluginStatePublisherSpy()
        let viewModel = makeViewModel(plugin: plugin, publisher: publisher, files: files)
        viewModel.requestArchivedPluginDeletion()

        await viewModel.confirmArchivedPluginDeletion()

        XCTAssertEqual(publisher.callCount, 1)
        XCTAssertEqual(publisher.publishCount, 0)
        XCTAssertEqual(publisher.currentSourcePlugin(for: plugin.id)?.id, plugin.id)
        XCTAssertEqual(files.transaction.rollbackCount, 1)
        XCTAssertFalse(viewModel.shouldDismiss)
    }

    func testDuplicateArchivedDeleteConfirmationsCannotOverlap() async {
        let files = PR7BFileDeletionSpy()
        let publisher = PR7BPluginStatePublisherSpy()
        publisher.suspends = true
        let viewModel = makeViewModel(
            plugin: pr7bPlugin(archived: true),
            publisher: publisher,
            files: files
        )
        viewModel.requestArchivedPluginDeletion()

        let first = Task { await viewModel.confirmArchivedPluginDeletion() }
        await pr7bWaitUntil { publisher.callCount == 1 }
        XCTAssertNotNil(publisher.currentSourcePlugin(for: viewModel.plugin.id))
        XCTAssertEqual(files.transaction.commitCount, 0)
        XCTAssertEqual(publisher.publishCount, 0)
        await viewModel.confirmArchivedPluginDeletion()
        XCTAssertEqual(files.stagedSnapshots.count, 1)
        XCTAssertEqual(publisher.callCount, 1)

        publisher.complete()
        await first.value
        XCTAssertTrue(viewModel.shouldDismiss)
    }

    func testStaleDeletionPreparationCannotOverwriteNewerPluginManagerState() async {
        let plugin = pr7bPlugin(archived: true)
        let files = PR7BFileDeletionSpy()
        let publisher = PR7BPluginStatePublisherSpy()
        publisher.suspends = true
        let viewModel = makeViewModel(plugin: plugin, publisher: publisher, files: files)
        viewModel.requestArchivedPluginDeletion()

        let deletion = Task { await viewModel.confirmArchivedPluginDeletion() }
        await pr7bWaitUntil { publisher.callCount == 1 }
        let newlyInstalledPlugin = pr7bPlugin(id: "newer.plugin", name: "Newer Plugin")
        publisher.currentPlugins[newlyInstalledPlugin.id] = newlyInstalledPlugin
        publisher.complete()
        await deletion.value

        XCTAssertEqual(files.transaction.commitCount, 0)
        XCTAssertEqual(files.transaction.rollbackCount, 1)
        XCTAssertEqual(publisher.publishCount, 0)
        XCTAssertNotNil(publisher.currentSourcePlugin(for: newlyInstalledPlugin.id))
        XCTAssertFalse(viewModel.shouldDismiss)
        XCTAssertEqual(
            viewModel.archivedPluginDeleteError,
            SourcePluginFileError.stalePluginState.localizedDescription
        )
    }

    func testMigratedSourceLayerContainsNoPresentationGlobalsOrTypeErasedRoutes() throws {
        let paths = [
            "Ito/ViewModels/SourceViewModel.swift",
            "Ito/Views/Browse/SourceView.swift"
        ]
        for path in paths {
            let source = try sourceFile(path)
            for forbidden in [
                "PluginManager.shared", "RepoManager.shared", "SnackBarManager.shared",
                "AppDatabase.shared", "URLSession.shared", "FileManager.default",
                "UIApplication.shared", "UserDefaults.standard", "AppLogger", "AnyView",
                "configure("
            ] {
                XCTAssertFalse(source.contains(forbidden), "Forbidden \(forbidden) in \(path)")
            }
        }
    }

    func testProductionCompositionKeepsNavigatedModelsFactoryOwnedAndOutOfRootStore() throws {
        let factorySource = try sourceFile("Ito/Views/Search/SearchRouteFactory.swift")
        let scopeSource = try sourceFile("Ito/AppScope.swift")

        for factoryMethod in [
            "func makeSourceViewModel(plugin:",
            "func makeListingViewModel(destination:",
            "func makePluginSettingsViewModel("
        ] {
            XCTAssertTrue(factorySource.contains(factoryMethod))
        }
        XCTAssertTrue(factorySource.contains("runnerProvider: sourceDependencies.runnerProvider"))
        XCTAssertTrue(factorySource.contains("settingsStore: sourceDependencies.settingsStore"))
        XCTAssertTrue(factorySource.contains("messagePresenter: sourceMessagePresenter"))
        XCTAssertTrue(scopeSource.contains("let fileOperations = LocalBrowsePluginFileOperations("))
        XCTAssertEqual(
            scopeSource.components(separatedBy: "LocalBrowsePluginFileOperations(").count - 1,
            1
        )
        for forbidden in [
            "storedSourceViewModel", "storedListingViewModel", "storedPluginSettingsViewModel"
        ] {
            XCTAssertFalse(scopeSource.contains(forbidden))
        }
    }

    func testProductionRunnerAdapterPreservesInjectedRunnerIdentity() {
        let runner = ItoRunner()
        let context = ItoRunnerSourceContext(runner: runner)

        XCTAssertTrue(context.runner === runner)
    }

    private func makeViewModel(
        plugin: InstalledPlugin = pr7bPlugin(),
        provider: PR7BSourceRunnerProviderSpy = PR7BSourceRunnerProviderSpy(),
        publisher: PR7BPluginStatePublisherSpy = PR7BPluginStatePublisherSpy(),
        files: PR7BFileDeletionSpy = PR7BFileDeletionSpy(),
        messages: PR7BMessagePresenterSpy = PR7BMessagePresenterSpy(),
        debounce: UInt64? = nil
    ) -> SourceViewModel {
        publisher.currentPlugins[plugin.id] = plugin
        return SourceViewModel(
            plugin: plugin,
            runnerProvider: provider,
            pluginStatePublisher: publisher,
            fileDeletion: files,
            messagePresenter: messages,
            searchDebounceNanoseconds: debounce
        )
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
