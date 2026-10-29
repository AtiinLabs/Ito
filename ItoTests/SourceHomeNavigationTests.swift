import Combine
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class SourceHomeNavigationTests: XCTestCase {
    func testReturnHomeClearsQueryAndResultsButRetainsCatalogChoices() async {
        let context = PR7BSourceRunnerContextSpy()
        context.homeResult = .success(pr7bHome(ids: ["featured"]))
        context.searchResult = .success(.init(
            entries: [.manga(.init(key: "query-result", title: "Query result"))], hasNextPage: false
        ))
        let sort = Control(id: "sort", title: "Sort", kind: .select(.init(
            options: .inline([.init(value: "title", label: "Title")]), defaultValue: "title"
        )))
        let toggle = Control(id: "enabled", title: "Enabled", kind: .toggle(.init(defaultValue: false)))
        context.capabilitiesResult = .success(.init(
            flags: [.browse, .sortWithQuery, .filtersWithQuery], sort: sort,
            sections: [.init(id: "filters", title: "Filters", controls: [toggle])]
        ))
        let viewModel = makeViewModel(provider: PR7BSourceRunnerProviderSpy(contexts: [context]), debounce: nil)
        await viewModel.loadIfNeeded()
        let choices: [String: ControlValue] = ["sort": .select("title"), "enabled": .toggle(true)]
        let queryResults = expectation(description: "query results")
        let querySubscription = viewModel.$searchPhase.dropFirst().filter { $0 == .content }
            .sink { _ in queryResults.fulfill() }
        viewModel.applyFilters(choices)
        viewModel.searchQuery = "query"
        viewModel.performSearch(query: "query")
        await fulfillment(of: [queryResults], timeout: 2)
        querySubscription.cancel()
        XCTAssertEqual(viewModel.searchEntries.map(\.key), ["query-result"])
        let searchesBeforeHome = context.searchInvocations.count

        viewModel.returnToHome()
        XCTAssertFalse(viewModel.hasActiveSearch)
        XCTAssertEqual(viewModel.searchQuery, "")
        XCTAssertTrue(viewModel.searchEntries.isEmpty)
        XCTAssertEqual(viewModel.searchPhase, .idle)
        XCTAssertEqual(viewModel.phase, .content)
        XCTAssertEqual(viewModel.filterValues, choices)
        XCTAssertEqual(context.homeLoadCount, 1)
        XCTAssertEqual(context.searchInvocations.count, searchesBeforeHome)

        context.searchResult = .success(.init(
            entries: [.manga(.init(key: "catalog-result", title: "Catalog result"))], hasNextPage: false
        ))
        let catalogResults = expectation(description: "catalog results after source home")
        let subscription = viewModel.$searchPhase.dropFirst().filter { $0 == .content }
            .sink { _ in catalogResults.fulfill() }
        viewModel.selectSort(.select("title"))
        await fulfillment(of: [catalogResults], timeout: 2)
        subscription.cancel()
        XCTAssertTrue(viewModel.hasActiveSearch)
        XCTAssertEqual(viewModel.searchEntries.map(\.key), ["catalog-result"])
        XCTAssertEqual(viewModel.filterValues, choices)
        XCTAssertEqual(context.searchInvocations.last?.query, "")
        XCTAssertEqual(context.homeLoadCount, 1)
        viewModel.cancelActiveOperations()
    }

    func testReturnHomeDuringKindRefreshDoesNotReopenCatalog() async {
        let context = PR7BSourceRunnerContextSpy()
        context.homeResult = .success(pr7bHome(ids: ["featured"]))
        let toggle = Control(id: "enabled", title: "Enabled", kind: .toggle(.init(defaultValue: false)))
        let capabilities = SearchCapabilities(
            flags: [.browse], sections: [.init(id: "filters", title: "Filters", controls: [toggle])]
        )
        let started = expectation(description: "kind capabilities pending")
        var pending: CheckedContinuation<SearchCapabilities?, Never>?
        context.capabilitiesHandler = { kind in
            if kind == .manga {
                return await withCheckedContinuation { pending = $0; started.fulfill() }
            }
            return capabilities
        }
        let viewModel = makeViewModel(
            plugin: pr7bPlugin(kinds: [.manga, .novel]),
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]), debounce: nil
        )
        await viewModel.loadIfNeeded()
        let initial = expectation(description: "initial catalog")
        let initialSubscription = viewModel.$searchPhase.dropFirst().filter { $0 == .empty }
            .sink { _ in initial.fulfill() }
        viewModel.applyFilters(["enabled": .toggle(true)])
        await fulfillment(of: [initial], timeout: 2)
        initialSubscription.cancel()
        viewModel.selectedKind = .manga
        await fulfillment(of: [started], timeout: 2)
        viewModel.returnToHome()

        let resolved = expectation(description: "pending scope resolved on home")
        let subscription = viewModel.$searchPhase.dropFirst().filter { $0 == .idle }
            .sink { _ in resolved.fulfill() }
        pending?.resume(returning: capabilities)
        await fulfillment(of: [resolved], timeout: 2)
        subscription.cancel()
        XCTAssertFalse(viewModel.hasActiveSearch)
        XCTAssertEqual(viewModel.selectedKind, .manga)
        XCTAssertEqual(viewModel.phase, .content)
        XCTAssertEqual(context.searchInvocations.count, 1)
        XCTAssertEqual(context.homeLoadCount, 1)
        viewModel.cancelActiveOperations()
    }

    private func makeViewModel(
        plugin: InstalledPlugin = pr7bPlugin(),
        provider: PR7BSourceRunnerProviderSpy,
        debounce: UInt64? = nil
    ) -> SourceViewModel {
        let publisher = PR7BPluginStatePublisherSpy()
        publisher.currentPlugins[plugin.id] = plugin
        return SourceViewModel(
            plugin: plugin,
            runnerProvider: provider,
            pluginStatePublisher: publisher,
            fileDeletion: PR7BFileDeletionSpy(),
            messagePresenter: PR7BMessagePresenterSpy(),
            searchDebounceNanoseconds: debounce
        )
    }
}
