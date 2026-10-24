import Combine
import Foundation

@MainActor
public final class SearchViewModel: ObservableObject {
    static let automaticSearchDebounceMilliseconds = 700
    private static let resultLimit = 25
    private static let recentSearchLimit = 10

    @Published public var searchText = ""
    @Published public var searchScope: SearchScope = .all
    @Published public private(set) var state: SearchPresentationState = .idle
    @Published public private(set) var recentSearches: [String]
    @Published public private(set) var pluginFailures: [SearchPluginFailure] = []

    public var searchResults: SearchResults { state.results }
    public var isSearching: Bool { state.isLoading }
    public var activeTasks: Set<String> { state.activePluginIDs }

    private let searchExecutor: any SearchPluginExecuting
    private let recentSearchStore: any RecentSearchPersisting
    private let presentationLogger: any PresentationEventLogging
    private var cancellables = Set<AnyCancellable>()
    private var currentTask: Task<Void, Never>?
    private var currentOperationID: UUID?

    init(
        searchExecutor: any SearchPluginExecuting,
        recentSearchStore: any RecentSearchPersisting,
        debounceMilliseconds: Int?,
        presentationLogger: any PresentationEventLogging
    ) {
        self.searchExecutor = searchExecutor
        self.recentSearchStore = recentSearchStore
        self.presentationLogger = presentationLogger
        self.recentSearches = recentSearchStore.load()

        if let debounceMilliseconds {
            Publishers.CombineLatest($searchText, $searchScope)
                .dropFirst()
                .debounce(for: .milliseconds(debounceMilliseconds), scheduler: RunLoop.main)
                .sink { [weak self] query, _ in
                    self?.performSearch(query: query)
                }
                .store(in: &cancellables)
        }
    }

    public func performSearch(query: String) {
        cancelCurrentOperation(publishCancelledState: false)

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .idle
            return
        }

        let operationID = UUID()
        currentOperationID = operationID
        presentationLogger.log(.started(feature: .search, operationID: operationID))

        let plugins = filteredPlugins().sorted { $0.name < $1.name }
        guard !plugins.isEmpty else {
            state = .failure(.pluginUnavailable)
            finishOperation(
                operationID,
                outcome: .failed(.pluginUnavailable)
            )
            return
        }

        // Links can carry account or session tokens; only typed searches are remembered.
        if SearchLink(query: trimmed) == nil {
            addRecentSearch(trimmed)
        }
        let initialActivePluginIDs = Set(plugins.map(\.id))
        state = .loading(results: [:], activePluginIDs: initialActivePluginIDs)

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await execute(
                plugins: plugins,
                query: trimmed,
                operationID: operationID
            )
        }
    }

    public func cancelSearch() {
        cancelCurrentOperation(publishCancelledState: true)
    }

    public func clearRecentSearches() {
        recentSearches.removeAll()
        recentSearchStore.clear()
    }

    public func isPluginActive(named pluginName: String) -> Bool {
        let activePluginIDs = activeTasks
        return searchExecutor.plugins.contains { plugin in
            plugin.name == pluginName && activePluginIDs.contains(plugin.id)
        }
    }

    private func execute(
        plugins: [SearchPluginDescriptor],
        query: String,
        operationID: UUID
    ) async {
        var results: SearchResults = [:]
        var failures: [SearchFailure] = []
        var successfulPluginCount = 0
        var activePluginIDs = Set(plugins.map(\.id))

        for plugin in plugins {
            guard isCurrent(operationID), !Task.isCancelled else {
                ignoreStaleResult(for: operationID)
                return
            }

            presentationLogger.log(
                .started(
                    feature: .search,
                    kind: .pluginExecution,
                    operationID: operationID
                )
            )

            do {
                let pluginResults = try await searchExecutor.search(
                    plugin: plugin,
                    query: query,
                    limit: Self.resultLimit
                )

                guard isCurrent(operationID), !Task.isCancelled else {
                    ignoreStaleResult(for: operationID)
                    return
                }

                successfulPluginCount += 1
                let cappedResults = Array(pluginResults.prefix(Self.resultLimit))
                if !cappedResults.isEmpty {
                    results[plugin.name] = cappedResults
                }
                presentationLogger.log(
                    .finished(
                        feature: .search,
                        kind: .pluginExecution,
                        operationID: operationID,
                        outcome: .succeeded
                    )
                )
            } catch is CancellationError {
                guard isCurrent(operationID) else {
                    ignoreStaleResult(for: operationID)
                    return
                }
                presentationLogger.log(
                    .finished(
                        feature: .search,
                        kind: .pluginExecution,
                        operationID: operationID,
                        outcome: .cancelled
                    )
                )
                pluginFailures = []
                state = .cancelled
                finishOperation(operationID, outcome: .cancelled)
                return
            } catch {
                guard isCurrent(operationID), !Task.isCancelled else {
                    ignoreStaleResult(for: operationID)
                    return
                }
                let failure = classify(error)
                failures.append(failure)
                let pluginError = error as? PluginCallError
                pluginFailures.append(
                    SearchPluginFailure(
                        pluginID: plugin.id,
                        pluginName: plugin.name,
                        message: pluginError?.message ?? "This source could not be searched.",
                        canOpenSettings: pluginError?.kind == .needsSettings
                    )
                )
                if failure == .pluginTrap {
                    searchExecutor.evictRunner(for: plugin.id)
                }
                presentationLogger.log(
                    .finished(
                        feature: .search,
                        kind: .pluginExecution,
                        operationID: operationID,
                        outcome: .failed(failure.presentationCategory)
                    )
                )
            }

            activePluginIDs.remove(plugin.id)
            state = .loading(results: results, activePluginIDs: activePluginIDs)
        }

        guard isCurrent(operationID), !Task.isCancelled else {
            ignoreStaleResult(for: operationID)
            return
        }

        publishTerminalState(
            results: results,
            failures: failures,
            successfulPluginCount: successfulPluginCount,
            operationID: operationID
        )
    }

    private func publishTerminalState(
        results: SearchResults,
        failures: [SearchFailure],
        successfulPluginCount: Int,
        operationID: UUID
    ) {
        if failures.isEmpty {
            state = results.isEmpty ? .empty : .content(results: results)
            finishOperation(operationID, outcome: .succeeded)
            return
        }

        let failure = aggregateFailure(failures)
        if successfulPluginCount > 0 {
            state = .partialFailure(
                results: results,
                failedPluginCount: failures.count
            )
            finishOperation(
                operationID,
                outcome: .partiallySucceeded(failure.presentationCategory)
            )
        } else {
            state = .failure(failure)
            finishOperation(
                operationID,
                outcome: .failed(failure.presentationCategory)
            )
        }
    }

    private func cancelCurrentOperation(publishCancelledState: Bool) {
        pluginFailures = []
        guard let operationID = currentOperationID else {
            currentTask?.cancel()
            currentTask = nil
            return
        }

        currentTask?.cancel()
        currentTask = nil
        currentOperationID = nil
        logCancellation(for: operationID)
        if publishCancelledState {
            state = .cancelled
        }
    }

    private func finishOperation(
        _ operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        guard isCurrent(operationID) else { return }
        presentationLogger.log(
            .finished(
                feature: .search,
                operationID: operationID,
                outcome: outcome
            )
        )
        currentOperationID = nil
        currentTask = nil
    }

    private func logCancellation(for operationID: UUID) {
        presentationLogger.log(
            .finished(
                feature: .search,
                operationID: operationID,
                outcome: .cancelled
            )
        )
    }

    private func ignoreStaleResult(for operationID: UUID) {
        presentationLogger.log(
            .finished(
                feature: .search,
                operationID: operationID,
                outcome: .ignoredStale
            )
        )
    }

    private func isCurrent(_ operationID: UUID) -> Bool {
        currentOperationID == operationID
    }

    private func filteredPlugins() -> [SearchPluginDescriptor] {
        searchExecutor.plugins.filter { plugin in
            switch searchScope {
            case .all:
                return true
            case .manga:
                return plugin.kind == .manga
            case .anime:
                return plugin.kind == .anime
            case .novel:
                return plugin.kind == .novel
            }
        }
    }

    private func addRecentSearch(_ query: String) {
        guard !recentSearches.contains(query) else { return }
        recentSearches.insert(query, at: 0)
        if recentSearches.count > Self.recentSearchLimit {
            recentSearches.removeLast()
        }
        recentSearchStore.save(recentSearches)
    }

    private func classify(_ error: any Error) -> SearchFailure {
        if let error = error as? PluginCallError {
            return error.kind == .crashed ? .pluginTrap : .pluginExecution
        }
        guard let error = error as? SearchPluginExecutionError else {
            return .pluginExecution
        }
        switch error {
        case .pluginUnavailable:
            return .pluginUnavailable
        case .pluginExecution:
            return .pluginExecution
        case .pluginTrap:
            return .pluginTrap
        }
    }

    private func aggregateFailure(_ failures: [SearchFailure]) -> SearchFailure {
        if failures.contains(.pluginTrap) { return .pluginTrap }
        if failures.allSatisfy({ $0 == .pluginUnavailable }) {
            return .pluginUnavailable
        }
        return .pluginExecution
    }
}
