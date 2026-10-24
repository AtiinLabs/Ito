import XCTest
import ito_runner
@testable import Ito

@MainActor
final class SearchCharacterizationTests: XCTestCase {
    func testQueryIsTrimmedBeforeExecutionAndPersistence() async {
        let executor = RecordingSearchExecutor(plugins: [.manga()])
        let store = InMemoryRecentSearchStore()
        let viewModel = makeViewModel(executor: executor, store: store)

        viewModel.performSearch(query: "  \n One Piece \t ")
        await waitUntil { !viewModel.isSearching }

        XCTAssertEqual(executor.invocations.map(\.query), ["One Piece"])
        XCTAssertEqual(viewModel.recentSearches, ["One Piece"])
        XCTAssertEqual(store.savedValues, [["One Piece"]])
    }

    func testPastedLinkIsSearchedButNeverRemembered() async {
        let executor = RecordingSearchExecutor(plugins: [.manga()])
        let store = InMemoryRecentSearchStore(initial: ["typed"])
        let viewModel = makeViewModel(executor: executor, store: store)
        let link = "https://example.org/title/abc?session=private-token"

        viewModel.performSearch(query: " \(link) ")
        await waitUntil { !viewModel.isSearching }

        XCTAssertEqual(executor.invocations.map(\.query), [link])
        XCTAssertEqual(viewModel.recentSearches, ["typed"])
        XCTAssertTrue(store.savedValues.isEmpty)
    }

    func testEmptyOrClearedQueryResetsSearchState() async {
        let executor = RecordingSearchExecutor(plugins: [.manga()])
        let store = InMemoryRecentSearchStore()
        let viewModel = makeViewModel(executor: executor, store: store)

        viewModel.performSearch(query: "existing")
        await waitUntil { !viewModel.isSearching }
        XCTAssertFalse(viewModel.searchResults.isEmpty)

        viewModel.performSearch(query: " \n\t ")

        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertTrue(viewModel.activeTasks.isEmpty)
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertEqual(executor.invocations.map(\.query), ["existing"])
        XCTAssertEqual(store.savedValues, [["existing"]])
    }

    func testAutomaticSearchDebouncesRapidInputUsingTheSevenHundredMillisecondContract() async {
        XCTAssertEqual(SearchViewModel.automaticSearchDebounceMilliseconds, 700)
        let executor = RecordingSearchExecutor(plugins: [.manga()])
        let store = InMemoryRecentSearchStore()
        let viewModel = SearchViewModel(
            searchExecutor: executor,
            recentSearchStore: store,
            debounceMilliseconds: 10,
            presentationLogger: PresentationEventCaptureSpy()
        )

        viewModel.searchText = "first"
        viewModel.searchText = "  second  "

        XCTAssertTrue(executor.invocations.isEmpty)
        await waitUntil { !executor.invocations.isEmpty && !viewModel.isSearching }
        XCTAssertEqual(executor.invocations.map(\.query), ["second"])
        XCTAssertEqual(viewModel.recentSearches, ["second"])
    }

    func testRecentSearchesAreNewestFirst() {
        let executor = RecordingSearchExecutor(plugins: [.manga()])
        let store = InMemoryRecentSearchStore(initial: ["old"])
        let viewModel = makeViewModel(executor: executor, store: store)

        viewModel.performSearch(query: "first")
        viewModel.performSearch(query: "second")

        XCTAssertEqual(viewModel.recentSearches, ["second", "first", "old"])
    }

    func testDuplicateRecentSearchIsNotInsertedOrReordered() {
        let executor = RecordingSearchExecutor(plugins: [.manga()])
        let store = InMemoryRecentSearchStore(initial: ["alpha", "beta"])
        let viewModel = makeViewModel(executor: executor, store: store)

        viewModel.performSearch(query: "beta")

        XCTAssertEqual(viewModel.recentSearches, ["alpha", "beta"])
        XCTAssertTrue(store.savedValues.isEmpty)
    }

    func testRecentSearchesAreCappedAtTen() {
        let existing = (0..<10).map { "query-\($0)" }
        let executor = RecordingSearchExecutor(plugins: [.manga()])
        let store = InMemoryRecentSearchStore(initial: existing)
        let viewModel = makeViewModel(executor: executor, store: store)

        viewModel.performSearch(query: "new")

        XCTAssertEqual(viewModel.recentSearches.count, 10)
        XCTAssertEqual(viewModel.recentSearches, ["new"] + Array(existing.prefix(9)))
        XCTAssertEqual(store.savedValues.last, viewModel.recentSearches)
    }

    func testClearRecentSearchesClearsMemoryAndPersistence() {
        let store = InMemoryRecentSearchStore(initial: ["alpha", "beta"])
        let viewModel = makeViewModel(store: store)

        viewModel.clearRecentSearches()

        XCTAssertTrue(viewModel.recentSearches.isEmpty)
        XCTAssertEqual(store.clearCallCount, 1)
    }

    func testUserDefaultsRecentSearchAdapterLoadsSavesAndClearsTheExistingKey() throws {
        let suiteName = "SearchCharacterizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["existing"], forKey: UserDefaultsRecentSearchStore.key)
        let store = UserDefaultsRecentSearchStore(defaults: defaults)

        XCTAssertEqual(store.load(), ["existing"])

        store.save(["new", "existing"])
        XCTAssertEqual(defaults.stringArray(forKey: UserDefaultsRecentSearchStore.key), ["new", "existing"])

        store.clear()
        XCTAssertNil(defaults.object(forKey: UserDefaultsRecentSearchStore.key))
    }

    func testNoAvailablePluginEndsWithoutPersistingQuery() {
        let emptyExecutor = RecordingSearchExecutor(plugins: [])
        let emptyStore = InMemoryRecentSearchStore()
        let emptyExecutorViewModel = makeViewModel(executor: emptyExecutor, store: emptyStore)

        emptyExecutorViewModel.performSearch(query: "query")

        XCTAssertFalse(emptyExecutorViewModel.isSearching)
        XCTAssertTrue(emptyExecutorViewModel.searchResults.isEmpty)
        XCTAssertTrue(emptyStore.savedValues.isEmpty)
    }

    func testSearchScopeExecutesOnlyMatchingPluginTypes() async {
        let expectations: [(SearchScope, Set<String>)] = [
            (.all, ["plugin.manga", "plugin.anime", "plugin.novel"]),
            (.manga, ["plugin.manga"]),
            (.anime, ["plugin.anime"]),
            (.novel, ["plugin.novel"])
        ]

        for (scope, expectedPluginIDs) in expectations {
            let executor = RecordingSearchExecutor(
                plugins: [.manga(), .anime(), .novel()]
            )
            let viewModel = makeViewModel(executor: executor)
            viewModel.searchScope = scope

            viewModel.performSearch(query: "query")
            await waitUntil { !viewModel.isSearching }

            XCTAssertEqual(Set(executor.invocations.map(\.pluginID)), expectedPluginIDs)
        }
    }

    func testPluginsExecuteSeriallyInNameOrder() async {
        let executor = SuspendingSearchExecutor(
            plugins: [
                .init(id: "plugin.z", name: "Zulu", kind: .manga),
                .init(id: "plugin.a", name: "Alpha", kind: .anime)
            ]
        )
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { executor.pendingCount == 1 }

        XCTAssertEqual(executor.startedPluginIDs, ["plugin.a"])
        XCTAssertEqual(executor.maximumConcurrentSearches, 1)

        executor.completeNext(with: [.result(id: "alpha")])
        await waitUntil { executor.pendingCount == 1 && executor.startedPluginIDs.count == 2 }

        XCTAssertEqual(executor.startedPluginIDs, ["plugin.a", "plugin.z"])
        XCTAssertEqual(executor.maximumConcurrentSearches, 1)

        executor.completeNext(with: [.result(id: "zulu")])
        await waitUntil { !viewModel.isSearching }
    }

    func testSupersededSessionCannotPublishStaleResults() async {
        let executor = SuspendingSearchExecutor(plugins: [.manga()])
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "first")
        await waitUntil { executor.pendingQueries == ["first"] }

        viewModel.performSearch(query: "second")
        await waitUntil { executor.pendingQueries == ["first", "second"] }

        executor.complete(query: "first", with: [.result(id: "stale")])
        await waitUntil { executor.pendingQueries == ["second"] }
        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertTrue(viewModel.isSearching)

        executor.complete(query: "second", with: [.result(id: "fresh")])
        await waitUntil { !viewModel.isSearching }

        XCTAssertEqual(viewModel.searchResults["Manga Plugin"]?.map(\.id), ["fresh"])
        XCTAssertEqual(viewModel.recentSearches, ["second", "first"])
    }

    func testResultCountIsCappedAtTwentyFive() async {
        let executor = RecordingSearchExecutor(plugins: [.manga()])
        executor.resultsByPluginID["plugin.manga"] = (0..<30).map {
            .result(id: "result-\($0)")
        }
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        XCTAssertEqual(executor.invocations.map(\.limit), [25])
        XCTAssertEqual(viewModel.searchResults["Manga Plugin"]?.count, 25)
        XCTAssertEqual(viewModel.searchResults["Manga Plugin"]?.last?.id, "result-24")
    }

    func testFailureContinuesToNextPluginAndDoesNotPublishFailedResults() async {
        let executor = RecordingSearchExecutor(
            plugins: [
                .init(id: "plugin.a", name: "Alpha", kind: .manga),
                .init(id: "plugin.b", name: "Beta", kind: .anime)
            ]
        )
        executor.errorsByPluginID["plugin.a"] = SearchStubError.failure
        executor.resultsByPluginID["plugin.b"] = [.result(id: "success")]
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        XCTAssertEqual(executor.invocations.map(\.pluginID), ["plugin.a", "plugin.b"])
        XCTAssertNil(viewModel.searchResults["Alpha"])
        XCTAssertEqual(viewModel.searchResults["Beta"]?.map(\.id), ["success"])
        XCTAssertTrue(executor.evictedPluginIDs.isEmpty)

    }

    func testWasmTrapFailureEvictsRunner() async {
        let executor = RecordingSearchExecutor(plugins: [.manga()])
        executor.errorsByPluginID["plugin.manga"] = SearchPluginExecutionError.pluginTrap
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        XCTAssertEqual(executor.evictedPluginIDs, ["plugin.manga"])
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testCancellationStopsRemainingPluginExecution() async {
        let executor = RecordingSearchExecutor(
            plugins: [
                .init(id: "plugin.a", name: "Alpha", kind: .manga),
                .init(id: "plugin.b", name: "Beta", kind: .anime)
            ]
        )
        executor.errorsByPluginID["plugin.a"] = CancellationError()
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        XCTAssertEqual(executor.invocations.map(\.pluginID), ["plugin.a"])
        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertTrue(viewModel.activeTasks.isEmpty)
    }

    func testPresentationCaptureSpyIsUsableWithoutCallingAppLogger() {
        let capture = PresentationEventCaptureSpy()
        let operationID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        capture.log(.started(feature: .search, operationID: operationID))

        XCTAssertEqual(capture.events.map(\.operationID), [operationID])
        XCTAssertEqual(capture.events.map(\.phase), [.started])
    }

    private func makeViewModel(
        executor: any SearchPluginExecuting = RecordingSearchExecutor(plugins: []),
        store: InMemoryRecentSearchStore = InMemoryRecentSearchStore()
    ) -> SearchViewModel {
        SearchViewModel(
            searchExecutor: executor,
            recentSearchStore: store,
            debounceMilliseconds: nil,
            presentationLogger: PresentationEventCaptureSpy()
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

}

@MainActor
private final class InMemoryRecentSearchStore: RecentSearchPersisting {
    private let initial: [String]
    private(set) var savedValues: [[String]] = []
    private(set) var clearCallCount = 0

    init(initial: [String] = []) {
        self.initial = initial
    }

    func load() -> [String] {
        initial
    }

    func save(_ searches: [String]) {
        savedValues.append(searches)
    }

    func clear() {
        clearCallCount += 1
    }
}

@MainActor
private final class RecordingSearchExecutor: SearchPluginExecuting {
    struct Invocation: Equatable {
        let pluginID: String
        let query: String
        let limit: Int
    }

    let plugins: [SearchPluginDescriptor]
    var resultsByPluginID: [String: [PluginSearchResult]] = [:]
    var errorsByPluginID: [String: any Error] = [:]
    private(set) var invocations: [Invocation] = []
    private(set) var evictedPluginIDs: [String] = []

    init(plugins: [SearchPluginDescriptor]) {
        self.plugins = plugins
    }

    func search(
        plugin: SearchPluginDescriptor,
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult] {
        invocations.append(.init(pluginID: plugin.id, query: query, limit: limit))
        if let error = errorsByPluginID[plugin.id] {
            throw error
        }
        return resultsByPluginID[plugin.id] ?? [.result(id: plugin.id)]
    }

    func evictRunner(for pluginID: String) {
        evictedPluginIDs.append(pluginID)
    }
}

@MainActor
private final class SuspendingSearchExecutor: SearchPluginExecuting {
    private struct PendingSearch {
        let query: String
        let continuation: CheckedContinuation<[PluginSearchResult], any Error>
    }

    let plugins: [SearchPluginDescriptor]
    private var pending: [PendingSearch] = []
    private var concurrentSearches = 0
    private(set) var maximumConcurrentSearches = 0
    private(set) var startedPluginIDs: [String] = []

    init(plugins: [SearchPluginDescriptor]) {
        self.plugins = plugins
    }

    var pendingCount: Int {
        pending.count
    }

    var pendingQueries: [String] {
        pending.map(\.query)
    }

    func search(
        plugin: SearchPluginDescriptor,
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult] {
        _ = limit
        startedPluginIDs.append(plugin.id)
        concurrentSearches += 1
        maximumConcurrentSearches = max(maximumConcurrentSearches, concurrentSearches)

        return try await withCheckedThrowingContinuation { continuation in
            pending.append(.init(query: query, continuation: continuation))
        }
    }

    func evictRunner(for pluginID: String) {
        _ = pluginID
    }

    func completeNext(with results: [PluginSearchResult]) {
        guard !pending.isEmpty else { return }
        let search = pending.removeFirst()
        concurrentSearches -= 1
        search.continuation.resume(returning: results)
    }

    func complete(query: String, with results: [PluginSearchResult]) {
        guard let index = pending.firstIndex(where: { $0.query == query }) else { return }
        let search = pending.remove(at: index)
        concurrentSearches -= 1
        search.continuation.resume(returning: results)
    }
}

private enum SearchStubError: Error, CustomStringConvertible {
    case failure

    var description: String {
        switch self {
        case .failure:
            return "failure"
        }
    }
}

private extension SearchPluginDescriptor {
    static func manga() -> Self {
        .init(id: "plugin.manga", name: "Manga Plugin", kind: .manga)
    }

    static func anime() -> Self {
        .init(id: "plugin.anime", name: "Anime Plugin", kind: .anime)
    }

    static func novel() -> Self {
        .init(id: "plugin.novel", name: "Novel Plugin", kind: .novel)
    }
}

private extension PluginSearchResult {
    @MainActor
    static func result(id: String) -> Self {
        let runner = ItoRunner()
        return .init(
            id: id,
            title: id,
            cover: nil,
            subtitle: nil,
            destination: .manga(
                pluginID: "plugin.manga",
                context: ItoRunnerSearchContext(runner: runner),
                media: Manga(key: id, title: id)
            )
        )
    }
}
