import Combine
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class SourceViewModelTests: XCTestCase {
    func testEmptyQueryWithFiltersDoesNotBrowseWithoutCapabilityFlag() async {
        let context = PR7BSourceRunnerContextSpy()
        let toggle = Control(id: "enabled", title: "Enabled", kind: .toggle(.init(defaultValue: false)))
        context.capabilitiesResult = .success(.init(sections: [.init(id: "filters", title: "Filters", controls: [toggle])]))
        let viewModel = makeViewModel(provider: PR7BSourceRunnerProviderSpy(contexts: [context]), debounce: nil)
        await viewModel.loadIfNeeded()
        viewModel.applyFilters(["enabled": .toggle(true)])
        XCTAssertEqual(viewModel.filterValues, ["enabled": .toggle(true)])
        XCTAssertEqual(viewModel.searchPhase, .idle)
        XCTAssertFalse(viewModel.hasActiveSearch)
        XCTAssertTrue(context.searchInvocations.isEmpty)
    }

    func testCapabilitiesLoadAllKindsAndEachSelectedKind() async {
        let context = PR7BSourceRunnerContextSpy()
        var requested: [MediaKind?] = []
        let mangaLoaded = expectation(description: "manga capabilities")
        context.capabilitiesHandler = { kind in
            requested.append(kind)
            if kind == .manga { mangaLoaded.fulfill() }
            return .init(sections: [])
        }
        let viewModel = makeViewModel(plugin: pr7bPlugin(kinds: [.manga, .anime]),
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]), debounce: nil)
        await viewModel.loadIfNeeded()
        XCTAssertEqual(requested.count, 1)
        XCTAssertNil(requested[0])
        viewModel.selectedKind = .manga
        await fulfillment(of: [mangaLoaded], timeout: 2)
        XCTAssertEqual(requested.compactMap { $0 }, [.manga])
        viewModel.cancelActiveOperations()
    }

    func testSortedBrowseKeepsResultsOpenAcrossKindsWithoutCopyingOverrides() async {
        let context = PR7BSourceRunnerContextSpy()
        let sort = Control(id: "sort", title: "Sort", kind: .select(.init(
            options: .inline([.init(value: "title", label: "Title")]), defaultValue: "title"
        )))
        let capabilities = SearchCapabilities(flags: [.browse], sort: sort, sections: [])
        let mangaCapabilitiesStarted = expectation(description: "manga capabilities pending")
        var mangaCapabilities: CheckedContinuation<SearchCapabilities?, Never>?
        context.capabilitiesHandler = { kind in
            if kind == .manga {
                return await withCheckedContinuation {
                    mangaCapabilities = $0
                    mangaCapabilitiesStarted.fulfill()
                }
            }
            return capabilities
        }
        var requestedValues: [[String: ControlValue]] = []
        var requestedQueries: [String] = []
        context.searchHandler = { _, query, _, values in
            requestedQueries.append(query)
            requestedValues.append(values)
            return .init(entries: [
                .manga(.init(key: "comic", title: "Comic")),
                .novel(.init(key: "novel", title: "Novel"))
            ], hasNextPage: false)
        }
        let viewModel = makeViewModel(
            plugin: pr7bPlugin(kinds: [.manga, .novel]),
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]), debounce: nil
        )
        await viewModel.loadIfNeeded()
        let initialResults = expectation(description: "sorted all-kind results")
        let initialSubscription = viewModel.$searchPhase.dropFirst().filter { $0 == .content }
            .sink { _ in initialResults.fulfill() }
        viewModel.selectSort(.select("title"))
        await fulfillment(of: [initialResults], timeout: 2)
        initialSubscription.cancel()
        XCTAssertTrue(viewModel.hasActiveSearch)
        let queryResults = expectation(description: "query within sorted catalog")
        let querySubscription = viewModel.$searchPhase.dropFirst().filter { $0 == .content }
            .sink { _ in queryResults.fulfill() }
        viewModel.searchQuery = "Comic"
        viewModel.performSearch(query: "Comic")
        await fulfillment(of: [queryResults], timeout: 2)
        querySubscription.cancel()

        let kinds: [MediaKind?] = [.manga, .novel, nil]
        for kind in kinds {
            viewModel.selectedKind = kind
            if kind == .manga {
                await fulfillment(of: [mangaCapabilitiesStarted], timeout: 2)
                XCTAssertNil(viewModel.searchCapabilities)
                viewModel.searchQuery = ""
                viewModel.performSearch(query: "")
                guard viewModel.hasActiveSearch else {
                    mangaCapabilities?.resume(returning: capabilities)
                    XCTFail("Changing kind must not replace the results view with source home")
                    viewModel.cancelActiveOperations()
                    return
                }
            }
            let results = expectation(description: "results for \(String(describing: kind))")
            let subscription = viewModel.$searchPhase.dropFirst().filter { $0 == .content }
                .sink { _ in results.fulfill() }
            if kind == .manga { mangaCapabilities?.resume(returning: capabilities) }
            await fulfillment(of: [results], timeout: 2)
            subscription.cancel()
            XCTAssertTrue(viewModel.hasActiveSearch)
            XCTAssertEqual(context.searchInvocations.last?.pluginType, kind)
            XCTAssertEqual(viewModel.searchEntries.map(\.kind), kind.map { [$0] } ?? [.manga, .novel])
            XCTAssertEqual(viewModel.filterValues, kind == nil ? ["sort": .select("title")] : [:])
        }
        XCTAssertEqual(requestedQueries, ["", "Comic", "", "", ""])
        XCTAssertEqual(requestedValues, [
            ["sort": .select("title")], ["sort": .select("title")], [:], [:], ["sort": .select("title")]
        ])
        viewModel.cancelActiveOperations()
    }

    func testClearingFiltersReturnsToHomeWithoutAnEmptyBrowseRequest() async {
        let context = PR7BSourceRunnerContextSpy()
        let toggle = Control(id: "enabled", title: "Enabled", kind: .toggle(.init(defaultValue: false)))
        context.capabilitiesResult = .success(.init(
            flags: [.browse], sections: [.init(id: "filters", title: "Filters", controls: [toggle])]
        ))
        let viewModel = makeViewModel(provider: PR7BSourceRunnerProviderSpy(contexts: [context]), debounce: nil)
        await viewModel.loadIfNeeded()
        let results = expectation(description: "filtered browse finished")
        let subscription = viewModel.$searchPhase.dropFirst().filter { $0 == .empty }
            .sink { _ in results.fulfill() }
        viewModel.applyFilters(["enabled": .toggle(true)])
        await fulfillment(of: [results], timeout: 2)
        subscription.cancel()
        XCTAssertTrue(viewModel.hasActiveSearch)
        viewModel.applyFilters([:])
        XCTAssertFalse(viewModel.hasActiveSearch)
        XCTAssertEqual(viewModel.searchPhase, .idle)
        XCTAssertEqual(context.searchInvocations.count, 1)
        viewModel.cancelActiveOperations()
    }

    func testResolvedKindWithoutBrowseSupportReturnsHomeWithoutDispatching() async {
        let context = PR7BSourceRunnerContextSpy()
        let toggle = Control(id: "enabled", title: "Enabled", kind: .toggle(.init(defaultValue: false)))
        let capabilities = SearchCapabilities(
            flags: [.browse], sections: [.init(id: "filters", title: "Filters", controls: [toggle])]
        )
        context.capabilitiesHandler = { kind in kind == .manga ? .init(sections: []) : capabilities }
        let viewModel = makeViewModel(
            plugin: pr7bPlugin(kinds: [.manga, .novel]),
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]), debounce: nil
        )
        await viewModel.loadIfNeeded()
        let results = expectation(description: "initial filtered browse")
        let initialSubscription = viewModel.$searchPhase.dropFirst().filter { $0 == .empty }
            .sink { _ in results.fulfill() }
        viewModel.applyFilters(["enabled": .toggle(true)])
        await fulfillment(of: [results], timeout: 2)
        initialSubscription.cancel()
        XCTAssertTrue(viewModel.hasActiveSearch)

        let resolved = expectation(description: "unsupported kind resolved")
        let subscription = viewModel.$searchPhase.dropFirst().filter { $0 == .idle }
            .sink { _ in resolved.fulfill() }
        viewModel.selectedKind = .manga
        await fulfillment(of: [resolved], timeout: 2)
        subscription.cancel()
        XCTAssertFalse(viewModel.hasActiveSearch)
        XCTAssertEqual(context.searchInvocations.count, 1)
        viewModel.cancelActiveOperations()
    }

    func testSuggestionsDropStaleTextAndDisappearCompletion() async {
        let context = PR7BSourceRunnerContextSpy()
        context.capabilitiesResult = .success(.init(flags: [.suggestions], sections: []))
        let viewModel = makeViewModel(provider: PR7BSourceRunnerProviderSpy(contexts: [context]), debounce: nil)
        await viewModel.loadIfNeeded()
        var first: CheckedContinuation<[SearchSuggestion]?, Never>?
        var second: CheckedContinuation<[SearchSuggestion]?, Never>?
        let firstStarted = expectation(description: "old suggestions started")
        let secondStarted = expectation(description: "new suggestions started")
        let oldReturned = expectation(description: "old suggestions returned")
        let newReturned = expectation(description: "new suggestions returned")
        context.suggestionsHandler = { query, _ in
            if query == "old" {
                let result = await withCheckedContinuation { first = $0; firstStarted.fulfill() }
                oldReturned.fulfill()
                return result
            }
            let result = await withCheckedContinuation { second = $0; secondStarted.fulfill() }
            newReturned.fulfill()
            return result
        }
        viewModel.searchQuery = "old"
        viewModel.performSearch(query: "old")
        await fulfillment(of: [firstStarted], timeout: 2)
        viewModel.searchQuery = "new"
        viewModel.performSearch(query: "new")
        await fulfillment(of: [secondStarted], timeout: 2)
        first?.resume(returning: [.init(query: "stale")])
        await fulfillment(of: [oldReturned], timeout: 2)
        viewModel.cancelActiveOperations()
        second?.resume(returning: [.init(query: "also stale")])
        await fulfillment(of: [newReturned], timeout: 2)
        XCTAssertTrue(viewModel.searchSuggestions.isEmpty)
    }

    func testSortAndApplyEachCaptureOneSearchAndBrowseRequiresAnOverride() async {
        let context = PR7BSourceRunnerContextSpy()
        let sort = Control(id: "sort", title: "Sort", kind: .select(.init(options: .inline([
            .init(value: "new", label: "Newest"), .init(value: "old", label: "Oldest")
        ]), defaultValue: "new")))
        let toggle = Control(id: "enabled", title: "Enabled", kind: .toggle(.init(defaultValue: false)))
        context.capabilitiesResult = .success(.init(flags: [.browse, .sortWithQuery, .filtersWithQuery],
            sort: sort, sections: [.init(id: "filters", title: "Filters", controls: [toggle])]))
        let viewModel = makeViewModel(provider: PR7BSourceRunnerProviderSpy(contexts: [context]), debounce: nil)
        await viewModel.loadIfNeeded()
        viewModel.performSearch(query: "")
        XCTAssertEqual(viewModel.searchPhase, .idle)
        XCTAssertTrue(context.searchInvocations.isEmpty)

        let sorted = expectation(description: "sort search")
        context.searchHandler = { _, query, _, values in
            XCTAssertEqual(query, "")
            XCTAssertEqual(values, ["sort": .select("old")])
            sorted.fulfill()
            return .init(entries: [], hasNextPage: false)
        }
        viewModel.selectSort(.select("old"))
        await fulfillment(of: [sorted], timeout: 2)
        XCTAssertEqual(context.searchInvocations.count, 1)
        let applied = expectation(description: "apply search")
        context.searchHandler = { _, _, _, values in
            XCTAssertEqual(values, ["sort": .select("old"), "enabled": .toggle(true)])
            applied.fulfill()
            return .init(entries: [], hasNextPage: false)
        }
        viewModel.applyFilters(["sort": .select("old"), "enabled": .toggle(true)])
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(context.searchInvocations.count, 2)
    }

    func testFilterChangeDropsNonCooperativeSearchCompletion() async {
        let context = PR7BSourceRunnerContextSpy()
        let toggle = Control(id: "enabled", title: "Enabled", kind: .toggle(.init(defaultValue: false)))
        context.capabilitiesResult = .success(.init(flags: [.filtersWithQuery], sections: [
            .init(id: "filters", title: "Filters", controls: [toggle])
        ]))
        let viewModel = makeViewModel(provider: PR7BSourceRunnerProviderSpy(contexts: [context]), debounce: nil)
        await viewModel.loadIfNeeded()
        var first: CheckedContinuation<MediaPageResult, Never>?
        var second: CheckedContinuation<MediaPageResult, Never>?
        let firstStarted = expectation(description: "first started")
        let secondStarted = expectation(description: "second started")
        let firstReturned = expectation(description: "first returned")
        context.searchHandler = { _, _, _, values in
            if values.isEmpty {
                let result = await withCheckedContinuation { first = $0; firstStarted.fulfill() }
                firstReturned.fulfill()
                return result
            }
            return await withCheckedContinuation { second = $0; secondStarted.fulfill() }
        }
        viewModel.searchQuery = "query"
        viewModel.performSearch(query: "query")
        await fulfillment(of: [firstStarted], timeout: 2)
        viewModel.applyFilters(["enabled": .toggle(true)])
        await fulfillment(of: [secondStarted], timeout: 2)
        first?.resume(returning: .init(entries: [.manga(.init(key: "stale", title: "Stale"))], hasNextPage: false))
        await fulfillment(of: [firstReturned], timeout: 2)
        let content = expectation(description: "fresh published")
        let observation = viewModel.$searchPhase.filter { $0 == .content }.prefix(1).sink { _ in content.fulfill() }
        second?.resume(returning: .init(entries: [.manga(.init(key: "fresh", title: "Fresh"))], hasNextPage: false))
        await fulfillment(of: [content], timeout: 2)
        XCTAssertEqual(viewModel.searchEntries.map(\.key), ["fresh"])
        observation.cancel()
    }

    func testInitialStateContainsOnlyStablePluginIdentity() {
        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertEqual(viewModel.searchPhase, .idle)
        XCTAssertEqual(viewModel.plugin.id, "plugin.manga")
        XCTAssertNil(viewModel.homeLayout)
        XCTAssertNil(viewModel.settingsSurface)
        XCTAssertTrue(viewModel.searchEntries.isEmpty)
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
        guard case .legacy(let schema, _) = viewModel.settingsSurface else {
            return XCTFail("Expected legacy settings surface")
        }
        XCTAssertEqual(schema.settings.count, 1)
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

    func testClosingSettingsThatCouldNotBeShownKeepsTheSourceAndSearch() async {
        let context = PR7BSourceRunnerContextSpy()
        context.homeResult = .success(pr7bHome(ids: ["initial"]))
        context.settingsResult = .failure(PluginCallError(kind: .incompatible, message: "Needs a newer Ito."))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [context])
        let viewModel = makeViewModel(provider: provider)

        await viewModel.loadIfNeeded()
        viewModel.searchQuery = "kept"
        await viewModel.reloadAfterSettingsChange()

        XCTAssertEqual(viewModel.searchQuery, "kept")
        XCTAssertTrue(provider.evictedPluginIDs.isEmpty)
        XCTAssertEqual(provider.requestedPluginIDs.count, 1)
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
        fresh.searchResult = .success(MediaPageResult(entries: [.manga(Manga(key: "fresh", title: "Fresh"))], hasNextPage: false))
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

    func testAHomeThatNeedsSettingsOffersThemAndOtherFailuresDoNot() async throws {
        let unconfigured = PR7BSourceRunnerContextSpy()
        unconfigured.settingsResult = .success(try pr7bSettingsSchema(settings: [
            .text(id: "server_url", name: "Server URL", summary: nil, defaultValue: "")
        ]))
        unconfigured.homeResult = .failure(PluginCallError(kind: .needsSettings, message: "Add your server URL"))
        let unreachable = PR7BSourceRunnerContextSpy()
        unreachable.homeResult = .failure(PluginCallError(kind: .reported, message: "Komga didn't respond"))
        let viewModel = makeViewModel(provider: PR7BSourceRunnerProviderSpy(contexts: [unconfigured, unreachable]))

        await viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.phase, .failure("Add your server URL"))
        XCTAssertTrue(viewModel.failureOffersSettings)
        XCTAssertNotNil(viewModel.settingsDestination, "the settings must be reachable from the failure")

        await viewModel.reloadAfterSettingsChange()

        XCTAssertEqual(viewModel.phase, .failure("Komga didn't respond"))
        XCTAssertFalse(viewModel.failureOffersSettings)
    }

    func testSettingsAreOnlyOfferedWhenTheyCanBeEdited() async {
        let context = PR7BSourceRunnerContextSpy()
        context.settingsResult = .failure(PluginCallError(kind: .incompatible, message: "Needs a newer Ito."))
        context.homeResult = .failure(PluginCallError(kind: .needsSettings, message: "Add your server URL"))
        let viewModel = makeViewModel(provider: PR7BSourceRunnerProviderSpy(contexts: [context]))

        await viewModel.loadIfNeeded()

        XCTAssertTrue(viewModel.failureNeedsSettings)
        XCTAssertFalse(viewModel.failureOffersSettings, "the unavailable-settings sheet can't fix anything")
    }

    func testASearchThatNeedsSettingsOffersThem() async throws {
        let context = PR7BSourceRunnerContextSpy()
        context.settingsResult = .success(try pr7bSettingsSchema(settings: [
            .secret(id: "api_key", name: "API key", summary: nil)
        ]))
        context.homeResult = .success(pr7bHome(ids: ["home"]))
        context.searchResult = .failure(PluginCallError(kind: .needsSettings, message: "Komga rejected the API key"))
        let viewModel = makeViewModel(provider: PR7BSourceRunnerProviderSpy(contexts: [context]), debounce: nil)
        await viewModel.loadIfNeeded()

        viewModel.performSearch(query: "night")
        await pr7bWaitUntil { viewModel.searchPhase != .loading }

        XCTAssertEqual(viewModel.searchPhase, .failure("Komga rejected the API key"))
        XCTAssertTrue(viewModel.searchFailureOffersSettings)
    }

    func testSearchPreservesPageOneEmptyFilterInvocationAndResultOrdering() async {
        let context = PR7BSourceRunnerContextSpy()
        context.searchResult = .success(MediaPageResult(entries: [
            .manga(Manga(key: "b", title: "B")),
            .manga(Manga(key: "a", title: "A"))
        ], hasNextPage: false))
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
        XCTAssertEqual(viewModel.searchEntries.map(\.key), ["b", "a"])
        XCTAssertEqual(viewModel.searchPhase, .content)
    }

    func testSearchTypedWhileSourceLoadsRunsOnceTheLoadFinishes() async {
        let context = PR7BSourceRunnerContextSpy()
        context.suspendsHome = true
        context.searchResult = .success(MediaPageResult(entries: [.manga(Manga(key: "a", title: "A"))], hasNextPage: false))
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
        XCTAssertEqual(viewModel.searchEntries.map(\.key), ["a"])
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
            with: .success(MediaPageResult(entries: [.manga(Manga(key: "new", title: "New"))], hasNextPage: false))
        )
        await pr7bWaitUntil { viewModel.searchEntries.map(\.key) == ["new"] }
        context.completeSearch(
            query: "old",
            with: .success(MediaPageResult(entries: [.manga(Manga(key: "old", title: "Old"))], hasNextPage: false))
        )
        await Task.yield()

        XCTAssertEqual(viewModel.searchEntries.map(\.key), ["new"])
        XCTAssertEqual(viewModel.searchPhase, .content)
    }

    func testMultiKindPluginSearchDefaultsToAllAndScopeChangeReexecutesWithCapturedKind() async {
        let context = PR7BSourceRunnerContextSpy()
        let multiKindPlugin = pr7bPlugin(id: "plugin.multi", kinds: [.manga, .anime, .novel])
        let viewModel = makeViewModel(
            plugin: multiKindPlugin,
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]),
            debounce: nil
        )
        await viewModel.loadIfNeeded()

        XCTAssertTrue(viewModel.isMultiKind)
        XCTAssertNil(viewModel.selectedKind)

        context.searchResult = .success(MediaPageResult(entries: [
            .manga(Manga(key: "m1", title: "Manga 1")),
            .anime(Anime(key: "a1", title: "Anime 1"))
        ], hasNextPage: false))
        viewModel.searchQuery = "hero"
        viewModel.performSearch(query: "hero")
        await pr7bWaitUntil { viewModel.searchPhase == .content }

        XCTAssertEqual(context.searchInvocations.last?.pluginType, nil)
        XCTAssertEqual(viewModel.searchEntries.map(\.key), ["m1", "a1"])

        // The source answers the anime scope with a stray manga; only anime is shown.
        context.searchResult = .success(MediaPageResult(entries: [
            .manga(Manga(key: "m1", title: "Manga 1")),
            .anime(Anime(key: "a1", title: "Anime 1"))
        ], hasNextPage: false))
        viewModel.selectedKind = .anime
        await pr7bWaitUntil { context.searchInvocations.count == 2 && viewModel.searchPhase == .content }

        XCTAssertEqual(context.searchInvocations.last?.pluginType, .anime)
        XCTAssertEqual(viewModel.searchEntries.map(\.key), ["a1"])

        context.searchResult = .success(MediaPageResult(entries: [
            .manga(Manga(key: "m1", title: "Manga 1"))
        ], hasNextPage: false))
        viewModel.selectedKind = nil
        await pr7bWaitUntil { context.searchInvocations.count == 3 && viewModel.searchPhase == .content }

        XCTAssertEqual(context.searchInvocations.last?.pluginType, nil)
        XCTAssertEqual(viewModel.searchEntries.map(\.key), ["m1"])
    }

    func testScopeChangeRaceInvalidatesStaleOldScopeResponse() async {
        let context = PR7BSourceRunnerContextSpy()
        context.suspendsSearch = true
        let multiKindPlugin = pr7bPlugin(id: "plugin.multi", kinds: [.manga, .anime])
        let viewModel = makeViewModel(
            plugin: multiKindPlugin,
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]),
            debounce: nil
        )
        await viewModel.loadIfNeeded()

        viewModel.searchQuery = "clash"
        viewModel.selectedKind = .manga
        await pr7bWaitUntil { context.pendingSearches.count == 1 }

        viewModel.selectedKind = .anime
        await pr7bWaitUntil { context.pendingSearches.count == 2 }

        // Complete stale manga search first
        context.completeSearch(
            query: "clash",
            kind: .manga,
            with: .success(MediaPageResult(entries: [.manga(Manga(key: "stale-manga", title: "Stale"))], hasNextPage: false))
        )
        await Task.yield()
        XCTAssertEqual(viewModel.searchPhase, .loading)
        XCTAssertTrue(viewModel.searchEntries.isEmpty)

        // Complete fresh anime search
        context.completeSearch(
            query: "clash",
            kind: .anime,
            with: .success(MediaPageResult(entries: [.anime(Anime(key: "fresh-anime", title: "Fresh"))], hasNextPage: false))
        )
        await pr7bWaitUntil { viewModel.searchPhase == .content }
        XCTAssertEqual(viewModel.searchEntries.map(\.key), ["fresh-anime"])
    }

    func testMixedSearchResultsPreserveMixedOrderAndRoutePerKind() async throws {
        let context = PR7BSourceRunnerContextSpy()
        let multiKindPlugin = pr7bPlugin(id: "plugin.multi", kinds: [.manga, .anime, .novel])
        let manga = Manga(key: "m1", title: "Manga 1")
        let anime = Anime(key: "a1", title: "Anime 1")
        let novel = Novel(key: "n1", title: "Novel 1")
        context.searchResult = .success(MediaPageResult(entries: [
            .novel(novel),
            .manga(manga),
            .anime(anime)
        ], hasNextPage: false))
        let viewModel = makeViewModel(
            plugin: multiKindPlugin,
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]),
            debounce: nil
        )
        await viewModel.loadIfNeeded()

        viewModel.performSearch(query: "all")
        await pr7bWaitUntil { viewModel.searchPhase == .content }

        XCTAssertEqual(viewModel.searchEntries.map(\.key), ["n1", "m1", "a1"])
        XCTAssertEqual(viewModel.searchEntries.map(\.kind), [.novel, .manga, .anime])

        guard case .novel(let novelPlugin, _, let novelPayload) = viewModel.destination(for: .novel(novel)) else {
            return XCTFail("Expected novel destination")
        }
        XCTAssertEqual(novelPlugin, "plugin.multi")
        XCTAssertEqual(novelPayload.key, "n1")

        guard case .manga(let mangaPlugin, _, let mangaPayload) = viewModel.destination(for: .manga(manga)) else {
            return XCTFail("Expected manga destination")
        }
        XCTAssertEqual(mangaPlugin, "plugin.multi")
        XCTAssertEqual(mangaPayload.key, "m1")

        guard case .anime(let animePlugin, _, let animePayload) = viewModel.destination(for: .anime(anime)) else {
            return XCTFail("Expected anime destination")
        }
        XCTAssertEqual(animePlugin, "plugin.multi")
        XCTAssertEqual(animePayload.key, "a1")
    }

    func testSingleKindPluginPreservesDefaultScope() async {
        let context = PR7BSourceRunnerContextSpy()
        let singleKindPlugin = pr7bPlugin(id: "plugin.single", type: .manga, kinds: nil)
        let viewModel = makeViewModel(
            plugin: singleKindPlugin,
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]),
            debounce: nil
        )
        await viewModel.loadIfNeeded()

        XCTAssertFalse(viewModel.isMultiKind)
        XCTAssertNil(viewModel.selectedKind)

        context.searchResult = .success(MediaPageResult(entries: [.manga(Manga(key: "m1", title: "M1"))], hasNextPage: false))
        viewModel.performSearch(query: "test")
        await pr7bWaitUntil { viewModel.searchPhase == .content }

        XCTAssertEqual(context.searchInvocations.last?.pluginType, .manga)
        XCTAssertEqual(viewModel.searchEntries.map(\.key), ["m1"])
    }

    func testAManifestRepeatingOneKindIsSingleKindAndSearchesThatKind() async {
        let context = PR7BSourceRunnerContextSpy()
        let novelPlugin = pr7bPlugin(id: "plugin.novel", type: .manga, kinds: [.novel, .novel])
        let viewModel = makeViewModel(
            plugin: novelPlugin,
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]),
            debounce: nil
        )
        await viewModel.loadIfNeeded()

        XCTAssertFalse(viewModel.isMultiKind)
        context.searchResult = .success(MediaPageResult(entries: [.novel(Novel(key: "n1", title: "N1"))], hasNextPage: false))
        viewModel.performSearch(query: "test")
        await pr7bWaitUntil { viewModel.searchPhase == .content }

        XCTAssertEqual(context.searchInvocations.last?.pluginType, .novel)
        XCTAssertEqual(viewModel.searchEntries.map(\.key), ["n1"])
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
        XCTAssertEqual(publisher.purgedCompletionPluginIDs, [plugin.id])
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

    func testArchivedDeleteCompletionCancellationFailureStagesNothing() async {
        let files = PR7BFileDeletionSpy()
        let publisher = PR7BPluginStatePublisherSpy()
        publisher.completionHoldError = PR7BTestFailure.failed
        let viewModel = makeViewModel(
            plugin: pr7bPlugin(archived: true),
            publisher: publisher,
            files: files
        )
        viewModel.requestArchivedPluginDeletion()

        await viewModel.confirmArchivedPluginDeletion()

        XCTAssertTrue(files.stagedSnapshots.isEmpty)
        XCTAssertEqual(publisher.callCount, 0)
        XCTAssertTrue(publisher.removedSecretsPluginIDs.isEmpty)
        XCTAssertFalse(viewModel.shouldDismiss)
        XCTAssertEqual(viewModel.archivedPluginDeleteError, "fixture failure")
    }

    func testArchivedDeleteTrustRevocationFailureStagesNothing() async {
        let files = PR7BFileDeletionSpy()
        let publisher = PR7BPluginStatePublisherSpy()
        publisher.trustRevocationError = PR7BTestFailure.failed
        let viewModel = makeViewModel(
            plugin: pr7bPlugin(archived: true),
            publisher: publisher,
            files: files
        )
        viewModel.requestArchivedPluginDeletion()

        await viewModel.confirmArchivedPluginDeletion()

        XCTAssertEqual(publisher.revokedTrustPluginIDs, [pr7bPlugin(archived: true).id])
        XCTAssertTrue(files.stagedSnapshots.isEmpty)
        XCTAssertEqual(publisher.callCount, 0)
        XCTAssertTrue(publisher.removedSecretsPluginIDs.isEmpty)
        XCTAssertFalse(viewModel.shouldDismiss)
        XCTAssertEqual(viewModel.archivedPluginDeleteError, "fixture failure")
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
        XCTAssertTrue(publisher.purgedCompletionPluginIDs.isEmpty)
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
}
