import XCTest
import ito_runner
@testable import Ito

@MainActor
final class SearchViewModelTests: XCTestCase {
    func testSettingsFailureIsActionableAndRetryClearsPriorFailuresImmediately() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        executor.errorsByPluginID["plugin.manga"] = PluginCallError(
            kind: .needsSettings, message: "Sign in to search."
        )
        let failed = expectation(description: "Settings failure finishes")
        let retried = expectation(description: "Retry succeeds")
        let logger = SearchFailureEventLogger { event in
            guard event.kind == .operation else { return }
            if event.outcome == .failed(.pluginExecution) { failed.fulfill() }
            if event.outcome == .succeeded { retried.fulfill() }
        }
        let viewModel = makeViewModel(executor: executor, logger: logger)

        viewModel.performSearch(query: "query")
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(viewModel.pluginFailures, [
            .init(
                pluginID: "plugin.manga", pluginName: "Manga Plugin",
                message: "Sign in to search.", canOpenSettings: true
            )
        ])
        guard case .failure(.pluginExecution) = viewModel.state else {
            return XCTFail("Expected total failure")
        }

        executor.errorsByPluginID = [:]
        viewModel.performSearch(query: "query")
        XCTAssertTrue(viewModel.pluginFailures.isEmpty)
        await fulfillment(of: [retried], timeout: 1)
        XCTAssertTrue(viewModel.pluginFailures.isEmpty)
    }

    func testNonPluginFailureUsesGenericMessageWithoutSettingsAction() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        executor.errorsByPluginID["plugin.manga"] = NSError(
            domain: "private", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "sentinel-private-internal-error"]
        )
        let finished = expectation(description: "Generic failure finishes")
        let logger = SearchFailureEventLogger { event in
            if event.kind == .operation, event.outcome == .failed(.pluginExecution) {
                finished.fulfill()
            }
        }
        let viewModel = makeViewModel(executor: executor, logger: logger)

        viewModel.performSearch(query: "query")
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(viewModel.pluginFailures.first?.message, "This source could not be searched.")
        XCTAssertEqual(viewModel.pluginFailures.first?.canOpenSettings, false)
        XCTAssertFalse(logger.messages.joined().contains("sentinel-private-internal-error"))
    }

    func testExecutorPreservesTypedErrorsAndGenericFallbackCategories() {
        for kind: PluginCallError.Kind in [.reported, .needsSettings, .crashed, .incompatible, .host] {
            let error = PluginCallError(kind: kind, message: "Source's own reason")
            for fallback: SearchPluginExecutionError in [.pluginUnavailable, .pluginExecution] {
                XCTAssertEqual(
                    PluginManagerSearchExecutor.classify(error, fallback: fallback) as? PluginCallError,
                    error
                )
                XCTAssertEqual(
                    PluginManagerSearchExecutor.classify(URLError(.notConnectedToInternet), fallback: fallback)
                        as? SearchPluginExecutionError,
                    fallback
                )
            }
        }
    }

    func testTypedFailuresPreserveMessagesAndSettingsActionsWithPartialSuccess() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [
            .init(id: "plugin.a", name: "Alpha", kind: .manga),
            .init(id: "plugin.b", name: "Beta", kind: .anime),
            .init(id: "plugin.c", name: "Gamma", kind: .novel)
        ])
        let privateReason = "sentinel-private-settings-reason"
        executor.errorsByPluginID["plugin.a"] = PluginManagerSearchExecutor.classify(
            PluginCallError(kind: .needsSettings, message: privateReason),
            fallback: .pluginExecution
        )
        executor.errorsByPluginID["plugin.b"] = PluginCallError(kind: .reported, message: "Try another title.")
        executor.resultsByPluginID["plugin.c"] = [.result(id: "success")]
        let finished = expectation(description: "Search finishes")
        let logger = SearchFailureEventLogger { event in
            if event.kind == .operation, event.outcome == .partiallySucceeded(.pluginExecution) {
                finished.fulfill()
            }
        }
        let viewModel = makeViewModel(executor: executor, logger: logger)

        viewModel.performSearch(query: "query")
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(viewModel.pluginFailures, [
            .init(pluginID: "plugin.a", pluginName: "Alpha", message: privateReason, canOpenSettings: true),
            .init(pluginID: "plugin.b", pluginName: "Beta", message: "Try another title.", canOpenSettings: false)
        ])
        XCTAssertEqual(viewModel.searchResults["Gamma"]?.map(\.id), ["success"])
        XCTAssertTrue(executor.evictedPluginIDs.isEmpty)
        XCTAssertFalse(logger.messages.joined().contains(privateReason))

        viewModel.performSearch(query: "")
        XCTAssertTrue(viewModel.pluginFailures.isEmpty)
    }

    func testTypedTotalFailureRetainsMessageAndCrashEviction() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        executor.errorsByPluginID["plugin.manga"] = PluginCallError(
            kind: .crashed, message: "The source stopped unexpectedly. Try again."
        )
        let finished = expectation(description: "Crash finishes")
        let logger = SearchFailureEventLogger { event in
            if event.kind == .operation, event.outcome == .failed(.pluginTrap) {
                finished.fulfill()
            }
        }
        let viewModel = makeViewModel(executor: executor, logger: logger)

        viewModel.performSearch(query: "query")
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(viewModel.pluginFailures.first?.message, "The source stopped unexpectedly. Try again.")
        XCTAssertEqual(viewModel.pluginFailures.first?.canOpenSettings, false)
        XCTAssertEqual(executor.evictedPluginIDs, ["plugin.manga"])
        guard case .failure(.pluginTrap) = viewModel.state else {
            return XCTFail("Expected total crash failure")
        }
    }

    func testCancelledAndSupersededTypedFailuresCannotLeakIntoCurrentSearch() async {
        let executor = SearchViewModelSuspendingExecutor(plugins: [.manga()])
        let firstStarted = expectation(description: "First search starts")
        let secondStarted = expectation(description: "Second search starts")
        let thirdStarted = expectation(description: "Third search starts")
        executor.onStart = { query in
            switch query {
            case "first": firstStarted.fulfill()
            case "second": secondStarted.fulfill()
            case "third": thirdStarted.fulfill()
            default: break
            }
        }
        let staleFirst = expectation(description: "Superseded failure ignored")
        let staleSecond = expectation(description: "Cancelled failure ignored")
        let thirdFinished = expectation(description: "Current search finishes")
        var ignoredCount = 0
        let logger = SearchFailureEventLogger { event in
            if event.outcome == .ignoredStale {
                ignoredCount += 1
                if ignoredCount == 1 { staleFirst.fulfill() } else { staleSecond.fulfill() }
            }
            if event.kind == .operation, event.outcome == .succeeded { thirdFinished.fulfill() }
        }
        let viewModel = makeViewModel(executor: executor, logger: logger)
        let error = PluginCallError(kind: .needsSettings, message: "Stale private reason")

        viewModel.performSearch(query: "first")
        await fulfillment(of: [firstStarted], timeout: 1)
        viewModel.performSearch(query: "second")
        await fulfillment(of: [secondStarted], timeout: 1)
        executor.fail(query: "first", with: error)
        await fulfillment(of: [staleFirst], timeout: 1)
        XCTAssertTrue(viewModel.pluginFailures.isEmpty)
        XCTAssertTrue(viewModel.isSearching)

        viewModel.cancelSearch()
        executor.fail(query: "second", with: error)
        await fulfillment(of: [staleSecond], timeout: 1)
        XCTAssertTrue(viewModel.pluginFailures.isEmpty)
        guard case .cancelled = viewModel.state else { return XCTFail("Expected cancellation") }

        viewModel.performSearch(query: "third")
        await fulfillment(of: [thirdStarted], timeout: 1)
        executor.complete(query: "third", with: [.result(id: "fresh")])
        await fulfillment(of: [thirdFinished], timeout: 1)
        XCTAssertTrue(viewModel.pluginFailures.isEmpty)
        XCTAssertEqual(viewModel.searchResults["Manga Plugin"]?.map(\.id), ["fresh"])
    }

    func testConstructorInjectionRequiresNoLaterConfigurationCall() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        XCTAssertEqual(executor.invocations.map(\.query), ["query"])
    }

    func testInitialStateIsIdle() {
        let viewModel = makeViewModel()

        guard case .idle = viewModel.state else {
            return XCTFail("Expected idle state")
        }
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testLoadingStateDuringActiveOperation() async {
        let executor = SearchViewModelSuspendingExecutor(plugins: [.manga()])
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { executor.pendingCount == 1 }

        guard case .loading(let results, let activePluginIDs) = viewModel.state else {
            return XCTFail("Expected loading state")
        }
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(activePluginIDs, ["plugin.manga"])

        executor.complete(query: "query", with: [])
        await waitUntil { !viewModel.isSearching }
    }

    func testContentStateAfterSuccessfulResults() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        executor.resultsByPluginID["plugin.manga"] = [.result(id: "content")]
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        guard case .content(let results) = viewModel.state else {
            return XCTFail("Expected content state")
        }
        XCTAssertEqual(results["Manga Plugin"]?.map(\.id), ["content"])
    }

    func testEmptyStateAfterSuccessfulZeroResultSearch() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        executor.resultsByPluginID["plugin.manga"] = []
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        guard case .empty = viewModel.state else {
            return XCTFail("Expected empty state")
        }
    }

    func testPartialFailurePreservesSuccessfulPluginResults() async {
        let executor = SearchViewModelRecordingExecutor(
            plugins: [
                .init(id: "plugin.a", name: "Alpha", kind: .manga),
                .init(id: "plugin.b", name: "Beta", kind: .anime)
            ]
        )
        executor.errorsByPluginID["plugin.a"] = SearchPluginExecutionError.pluginExecution
        executor.resultsByPluginID["plugin.b"] = [.result(id: "success")]
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        guard case .partialFailure(let results, let failedPluginCount) = viewModel.state else {
            return XCTFail("Expected partial-failure state")
        }
        XCTAssertEqual(failedPluginCount, 1)
        XCTAssertEqual(results["Beta"]?.map(\.id), ["success"])
        XCTAssertNil(results["Alpha"])
    }

    func testTotalFailureIsDistinctFromEmpty() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        executor.errorsByPluginID["plugin.manga"] = SearchPluginExecutionError.pluginExecution
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        guard case .failure(.pluginExecution) = viewModel.state else {
            return XCTFail("Expected total plugin-execution failure")
        }
    }

    func testCancelledStateIsTerminalForCancelledOperation() async {
        let executor = SearchViewModelSuspendingExecutor(plugins: [.manga()])
        let viewModel = makeViewModel(executor: executor)

        viewModel.performSearch(query: "query")
        await waitUntil { executor.pendingCount == 1 }
        viewModel.cancelSearch()

        guard case .cancelled = viewModel.state else {
            return XCTFail("Expected cancelled state")
        }

        executor.complete(query: "query", with: [.result(id: "stale")])
        await waitUntil { executor.pendingCount == 0 }
        await Task.yield()

        guard case .cancelled = viewModel.state else {
            return XCTFail("Stale completion must not replace cancelled state")
        }
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testNewerOperationSupersedesPriorAndStaleResultsCannotMutateState() async throws {
        let executor = SearchViewModelSuspendingExecutor(plugins: [.manga()])
        let logger = PresentationEventCaptureSpy()
        let viewModel = makeViewModel(executor: executor, logger: logger)

        viewModel.performSearch(query: "first")
        await waitUntil { executor.pendingQueries == ["first"] }
        let firstOperationID = try XCTUnwrap(logger.operationStartedIDs.first)

        viewModel.performSearch(query: "second")
        await waitUntil { executor.pendingQueries == ["first", "second"] }
        let secondOperationID = try XCTUnwrap(logger.operationStartedIDs.last)
        XCTAssertNotEqual(firstOperationID, secondOperationID)

        executor.complete(query: "first", with: [.result(id: "stale")])
        await waitUntil {
            logger.events.contains {
                $0.operationID == firstOperationID && $0.outcome == .ignoredStale
            }
        }
        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertTrue(viewModel.isSearching)

        executor.complete(query: "second", with: [.result(id: "fresh")])
        await waitUntil { !viewModel.isSearching }

        XCTAssertEqual(viewModel.searchResults["Manga Plugin"]?.map(\.id), ["fresh"])
        XCTAssertTrue(logger.events.contains {
            $0.operationID == firstOperationID && $0.outcome == .cancelled
        })
        XCTAssertTrue(logger.events.contains {
            $0.operationID == firstOperationID && $0.outcome == .ignoredStale
        })
    }

    func testSuccessEventSequenceUsesOneOperationUUID() async throws {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        let logger = PresentationEventCaptureSpy()
        let viewModel = makeViewModel(executor: executor, logger: logger)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        let operationID = try XCTUnwrap(logger.events.first?.operationID)
        XCTAssertTrue(logger.events.allSatisfy { $0.operationID == operationID })
        XCTAssertEqual(
            logger.events.map(\.kind),
            [.operation, .pluginExecution, .pluginExecution, .operation]
        )
        XCTAssertEqual(
            logger.events.map(\.phase),
            [.started, .started, .finished, .finished]
        )
        XCTAssertEqual(
            logger.events.map(\.outcome),
            [nil, nil, .succeeded, .succeeded]
        )
    }

    func testPartialAndTotalFailureEmitDistinctTypedOutcomes() async {
        let partialExecutor = SearchViewModelRecordingExecutor(
            plugins: [
                .init(id: "plugin.a", name: "Alpha", kind: .manga),
                .init(id: "plugin.b", name: "Beta", kind: .anime)
            ]
        )
        partialExecutor.errorsByPluginID["plugin.a"] = SearchPluginExecutionError.pluginExecution
        let partialLogger = PresentationEventCaptureSpy()
        let partialViewModel = makeViewModel(
            executor: partialExecutor,
            logger: partialLogger
        )

        partialViewModel.performSearch(query: "partial")
        await waitUntil { !partialViewModel.isSearching }

        XCTAssertEqual(
            partialLogger.events.last?.outcome,
            .partiallySucceeded(.pluginExecution)
        )

        let failedExecutor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        failedExecutor.errorsByPluginID["plugin.manga"] = SearchPluginExecutionError.pluginExecution
        let failedLogger = PresentationEventCaptureSpy()
        let failedViewModel = makeViewModel(executor: failedExecutor, logger: failedLogger)

        failedViewModel.performSearch(query: "failure")
        await waitUntil { !failedViewModel.isSearching }

        XCTAssertEqual(failedLogger.events.last?.outcome, .failed(.pluginExecution))
    }

    func testPluginTrapEmitsSafeTypedEventAndEvictsRunner() async {
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        executor.errorsByPluginID["plugin.manga"] = SearchPluginExecutionError.pluginTrap
        let logger = PresentationEventCaptureSpy()
        let viewModel = makeViewModel(executor: executor, logger: logger)

        viewModel.performSearch(query: "query")
        await waitUntil { !viewModel.isSearching }

        XCTAssertEqual(executor.evictedPluginIDs, ["plugin.manga"])
        XCTAssertTrue(logger.events.contains {
            $0.kind == .pluginExecution && $0.outcome == .failed(.pluginTrap)
        })
        XCTAssertEqual(logger.events.last?.outcome, .failed(.pluginTrap))
    }

    func testSensitiveValuesNeverAppearInEventsOrFormattedOutput() async {
        let sensitiveQuery = "sentinel-private-query"
        let sensitiveTitle = "sentinel-private-media-title"
        let executor = SearchViewModelRecordingExecutor(plugins: [.manga()])
        executor.resultsByPluginID["plugin.manga"] = [
            .result(id: "result", title: sensitiveTitle)
        ]
        let logger = PresentationEventCaptureSpy()
        let viewModel = makeViewModel(executor: executor, logger: logger)

        viewModel.performSearch(query: sensitiveQuery)
        await waitUntil { !viewModel.isSearching }

        let eventDescription = String(reflecting: logger.events)
        let formattedOutput = logger.formattedMessages.joined(separator: "\n")
        XCTAssertFalse(eventDescription.contains(sensitiveQuery))
        XCTAssertFalse(eventDescription.contains(sensitiveTitle))
        XCTAssertFalse(formattedOutput.contains(sensitiveQuery))
        XCTAssertFalse(formattedOutput.contains(sensitiveTitle))
    }

    func testSourceContainsNoGlobalDefaultsMutableConfigurationOrSwiftUIDestination() throws {
        let source = try sourceFile("Ito/ViewModels/SearchViewModel.swift")

        for forbidden in [
            ".shared",
            "UserDefaults.standard",
            "AppLogger",
            "AnyView",
            "configure(pluginManager:"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Found forbidden source: \(forbidden)")
        }
    }

    private func makeViewModel(
        executor: any SearchPluginExecuting = SearchViewModelRecordingExecutor(plugins: []),
        store: SearchViewModelRecentStore = SearchViewModelRecentStore(),
        logger: any PresentationEventLogging = PresentationEventCaptureSpy()
    ) -> SearchViewModel {
        SearchViewModel(
            searchExecutor: executor,
            recentSearchStore: store,
            debounceMilliseconds: nil,
            presentationLogger: logger
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

@MainActor
private final class SearchViewModelRecentStore: RecentSearchPersisting {
    func load() -> [String] { [] }
    func save(_ searches: [String]) { _ = searches }
    func clear() {}
}

@MainActor
private final class SearchViewModelRecordingExecutor: SearchPluginExecuting {
    struct Invocation {
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
        if let error = errorsByPluginID[plugin.id] { throw error }
        return resultsByPluginID[plugin.id] ?? [.result(id: plugin.id)]
    }

    func evictRunner(for pluginID: String) {
        evictedPluginIDs.append(pluginID)
    }
}

@MainActor
private final class SearchViewModelSuspendingExecutor: SearchPluginExecuting {
    private struct PendingSearch {
        let query: String
        let continuation: CheckedContinuation<[PluginSearchResult], any Error>
    }

    let plugins: [SearchPluginDescriptor]
    private var pending: [PendingSearch] = []
    var onStart: ((String) -> Void)?

    init(plugins: [SearchPluginDescriptor]) {
        self.plugins = plugins
    }

    var pendingCount: Int { pending.count }
    var pendingQueries: [String] { pending.map(\.query) }

    func search(
        plugin: SearchPluginDescriptor,
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult] {
        _ = plugin
        _ = limit
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(.init(query: query, continuation: continuation))
            onStart?(query)
        }
    }

    func evictRunner(for pluginID: String) {
        _ = pluginID
    }

    func complete(query: String, with results: [PluginSearchResult]) {
        guard let index = pending.firstIndex(where: { $0.query == query }) else { return }
        let search = pending.remove(at: index)
        search.continuation.resume(returning: results)
    }

    func fail(query: String, with error: any Error) {
        guard let index = pending.firstIndex(where: { $0.query == query }) else { return }
        let search = pending.remove(at: index)
        search.continuation.resume(throwing: error)
    }
}

private final class SearchFailureEventLogger: PresentationEventLogging {
    private let onEvent: (PresentationLogEvent) -> Void
    private(set) var messages: [String] = []

    init(onEvent: @escaping (PresentationLogEvent) -> Void) {
        self.onEvent = onEvent
    }

    func log(_ event: PresentationLogEvent) {
        messages.append(PresentationLogFormatter.format(event))
        onEvent(event)
    }
}

@MainActor
private extension PresentationEventCaptureSpy {
    var operationStartedIDs: [UUID] {
        events.compactMap { event in
            guard event.kind == .operation, event.phase == .started else { return nil }
            return event.operationID
        }
    }
}

private extension SearchPluginDescriptor {
    static func manga() -> Self {
        .init(id: "plugin.manga", name: "Manga Plugin", kind: .manga)
    }
}

private extension PluginSearchResult {
    @MainActor
    static func result(id: String, title: String? = nil) -> Self {
        let runner = ItoRunner()
        return .init(
            id: id,
            title: title ?? id,
            cover: nil,
            subtitle: nil,
            destination: .manga(
                pluginID: "plugin.manga",
                context: ItoRunnerSearchContext(runner: runner),
                media: Manga(key: id, title: title ?? id)
            )
        )
    }
}
