import Combine
import Foundation
import ito_runner

struct SourceListingDestination {
    let plugin: InstalledPlugin
    let context: any SourceRunnerContext
    let listing: Listing
    let title: String
}

struct SourceSettingsDestination {
    let plugin: InstalledPlugin
    let surface: SettingsSurface
}

@MainActor
final class SourceViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case content
        case empty
        case failure(String)
        case cancelled
    }

    enum SearchPhase: Equatable {
        case idle
        case loading
        case content
        case empty
        case failure(String)
        case cancelled
    }

    let plugin: InstalledPlugin

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var searchPhase: SearchPhase = .idle
    @Published private(set) var homeLayout: HomeLayout?
    @Published private(set) var settingsSurface: SettingsSurface?
    /// Why the plugin's settings can't be shown, when it has settings but they couldn't be read.
    @Published private(set) var settingsUnavailableReason: String?
    /// Whether the last load failed because the plugin needs settings (missing, or rejected
    /// credentials), so the failure offers to open them.
    @Published private(set) var failureNeedsSettings = false
    /// The same for the last search.
    @Published private(set) var searchFailureNeedsSettings = false
    /// Whether the last load failed because the source needs a sign-in on its website.
    @Published private(set) var failureNeedsLogin = false
    /// Whether the last load failed and has an untrusted certificate waiting for user decision.
    @Published private(set) var failurePendingTrust: PendingTrust?
    /// The same for the last search.
    @Published private(set) var searchFailureNeedsLogin = false
    /// The pending trust for the last search failure, if any.
    @Published private(set) var searchFailurePendingTrust: PendingTrust?
    @Published var showSignIn = false
    @Published var selectedKind: MediaKind? {
        didSet {
            guard selectedKind != oldValue else { return }
            scopeDidChange()
        }
    }
    @Published private(set) var searchEntries: [MediaEntry] = []
    @Published var searchQuery = ""
    @Published var showSettings = false
    @Published private(set) var searchCapabilities: SearchCapabilities?
    @Published private(set) var searchSuggestions: [SearchSuggestion] = []
    @Published var showSearchFilters = false
    @Published var showArchivedPluginDeleteConfirmation = false
    @Published private(set) var isDeletingArchivedPlugin = false
    @Published private(set) var archivedPluginDeleteError: String?
    @Published private(set) var shouldDismiss = false

    private let runnerProvider: any SourceRunnerProviding
    private let pluginStatePublisher: any SourcePluginStatePublishing
    private let fileDeletion: any SourcePluginFileDeleting
    private let messagePresenter: any SourceMessagePresenting
    private let searchDebounceNanoseconds: UInt64?
    private var context: (any SourceRunnerContext)?
    private var loadTask: Task<Void, Never>?
    private var loadOperationID: UUID?
    private var searchTask: Task<Void, Never>?
    private let searchFilters = SourceSearchFilters()
    private var capabilitiesTask: Task<Void, Never>?
    private var capabilitiesOperationID: UUID?
    private var suggestionTask: Task<Void, Never>?
    private var suggestionGeneration = UUID()
    private var searchOperationID: UUID?
    private var deleteOperationID: UUID?
    private var archivedPluginFileSnapshot: SourcePluginFileSnapshot?

    init(
        plugin: InstalledPlugin,
        runnerProvider: any SourceRunnerProviding,
        pluginStatePublisher: any SourcePluginStatePublishing,
        fileDeletion: any SourcePluginFileDeleting,
        messagePresenter: any SourceMessagePresenting,
        searchDebounceNanoseconds: UInt64? = 500_000_000
    ) {
        self.plugin = plugin
        self.runnerProvider = runnerProvider
        self.pluginStatePublisher = pluginStatePublisher
        self.fileDeletion = fileDeletion
        self.messagePresenter = messagePresenter
        self.searchDebounceNanoseconds = searchDebounceNanoseconds
    }
    deinit {
        loadTask?.cancel()
        searchTask?.cancel()
        capabilitiesTask?.cancel()
        suggestionTask?.cancel()
    }

    func loadIfNeeded() async {
        if phase == .content || phase == .empty, searchCapabilities == nil {
            await refreshSearchCapabilities()
            return
        }
        guard phase == .idle || phase == .cancelled else { return }
        await load(invalidateCachedRunner: false)
    }

    func retry() async {
        await load(invalidateCachedRunner: false)
    }

    /// Reloads the source after its settings sheet closes. When the settings couldn't be shown
    /// nothing could have changed, so the search and home are kept.
    func reloadAfterSettingsChange() async {
        guard settingsUnavailableReason == nil else { return }
        cancelSearch(publishCancelledState: false)
        clearSearchResults()
        searchQuery = ""
        await load(invalidateCachedRunner: true)
    }

    var isMultiKind: Bool {
        plugin.info.distinctKinds.count > 1
    }

    func performSearch(query: String) {
        startSearch(query: query, debounce: true)
    }

    func submitSearch() {
        startSearch(query: searchQuery, debounce: false)
    }

    private func startSearch(query: String, debounce: Bool) {
        cancelSuggestions()
        cancelSearch(publishCancelledState: false)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = effectiveSearchKind(for: selectedKind)
        let filters = searchFilters.values(for: kind)
        guard !trimmedQuery.isEmpty || (searchCapabilities?.flags.contains(.browse) == true && !filters.isEmpty) else {
            clearSearchResults()
            searchPhase = .idle
            refreshSuggestions(for: query)
            return
        }
        let operationID = UUID()
        searchOperationID = operationID
        searchPhase = .loading
        searchFailureNeedsSettings = false
        searchFailureNeedsLogin = false
        searchFailurePendingTrust = nil
        let requestedSuggestionGeneration = suggestionGeneration
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounce, let searchDebounceNanoseconds {
                do {
                    try await Task.sleep(nanoseconds: searchDebounceNanoseconds)
                } catch {
                    finishCancelledSearch(operationID)
                    return
                }
            }
            await executeSearch(query: trimmedQuery, kind: kind, filterValues: filters, operationID: operationID)
            guard suggestionGeneration == requestedSuggestionGeneration,
                  isCurrentQuery(query, kind: kind), !Task.isCancelled else { return }
            if debounce { refreshSuggestions(for: query) }
        }
    }

    private func scopeDidChange() {
        cancelSearch(publishCancelledState: false)
        cancelSuggestions()
        showSearchFilters = false
        searchCapabilities = nil
        capabilitiesTask?.cancel()
        capabilitiesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshSearchCapabilities()
            guard !Task.isCancelled else { return }
            startSearch(query: searchQuery, debounce: false)
        }
    }

    var filterValues: [String: ControlValue] {
        searchFilters.values(for: effectiveSearchKind(for: selectedKind))
    }

    var sortEnabled: Bool {
        !hasActiveSearchQuery || searchCapabilities?.flags.contains(.sortWithQuery) == true
    }

    var filtersEnabled: Bool {
        !hasActiveSearchQuery || searchCapabilities?.flags.contains(.filtersWithQuery) == true
    }

    func selectSort(_ value: ControlValue) {
        guard sortEnabled, let sort = searchCapabilities?.sort else { return }
        searchFilters.setValue(value, for: sort, kind: effectiveSearchKind(for: selectedKind))
        objectWillChange.send()
        submitSearch()
    }

    func applyFilters(_ values: [String: ControlValue]) {
        guard filtersEnabled else { return }
        searchFilters.apply(values, kind: effectiveSearchKind(for: selectedKind))
        objectWillChange.send()
        showSearchFilters = false
        submitSearch()
    }

    func makeOptionCatalogModel(_ catalog: OptionCatalog) -> OptionCatalogModel {
        OptionCatalogModel(
            catalog: catalog,
            runnerProvider: runnerProvider,
            pluginID: plugin.id,
            debounceNanoseconds: searchDebounceNanoseconds ?? 0
        )
    }

    private func refreshSearchCapabilities() async {
        guard let context else { return }
        let kind = effectiveSearchKind(for: selectedKind)
        let operationID = UUID()
        capabilitiesOperationID = operationID
        let result: SearchCapabilities?
        do {
            result = try await context.loadSearchCapabilities(kind: kind)
        } catch {
            guard !(error is CancellationError) else { return }
            result = nil
        }
        guard capabilitiesOperationID == operationID, !Task.isCancelled,
              effectiveSearchKind(for: selectedKind) == kind else { return }
        searchFilters.updateCapabilities(result, kind: kind)
        searchCapabilities = result
    }

    private func isCurrentQuery(_ query: String, kind: MediaKind?) -> Bool {
        searchQuery == query && effectiveSearchKind(for: selectedKind) == kind
    }

    private func cancelSuggestions() {
        suggestionGeneration = UUID()
        suggestionTask?.cancel()
        suggestionTask = nil
        searchSuggestions = []
    }

    private func refreshSuggestions(for query: String) {
        cancelSuggestions()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              searchCapabilities?.flags.contains(.suggestions) == true, let context else { return }
        let generation = suggestionGeneration
        let kind = effectiveSearchKind(for: selectedKind)
        suggestionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let searchDebounceNanoseconds { try await Task.sleep(nanoseconds: searchDebounceNanoseconds) }
                let suggestions = try await context.loadSearchSuggestions(query: query, kind: kind)
                guard !Task.isCancelled, suggestionGeneration == generation,
                      isCurrentQuery(query, kind: kind) else { return }
                searchSuggestions = suggestions ?? []
            } catch {
                // Suggestions are optional and must never replace search errors or results.
            }
        }
    }
    private func effectiveSearchKind(for kind: MediaKind?) -> MediaKind? {
        isMultiKind ? kind : kind ?? plugin.info.distinctKinds.first
    }

    var hasActiveSearchQuery: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasActiveSearch: Bool {
        hasActiveSearchQuery || (searchCapabilities?.flags.contains(.browse) == true && !filterValues.isEmpty)
    }

    func cancelActiveOperations() {
        cancelLoad(publishCancelledState: true)
        cancelSearch(publishCancelledState: true)
        capabilitiesOperationID = nil
        capabilitiesTask?.cancel()
        cancelSuggestions()
    }

    func listingDestination(listing: Listing, title: String) -> SourceListingDestination? {
        guard let context else { return nil }
        return SourceListingDestination(
            plugin: plugin,
            context: context,
            listing: listing,
            title: title
        )
    }

    var settingsDestination: SourceSettingsDestination? {
        guard let settingsSurface else { return nil }
        return SourceSettingsDestination(plugin: plugin, surface: settingsSurface)
    }
    /// Whether the source offers settings, even ones that can't be shown right now.
    var hasSettings: Bool {
        settingsSurface != nil || settingsUnavailableReason != nil
    }

    /// Whether the load failure should offer the settings: it needs them and they can be edited.
    var failureOffersSettings: Bool {
        failureNeedsSettings && settingsDestination != nil
    }

    /// Whether the search failure should offer the settings, as for a load failure.
    var searchFailureOffersSettings: Bool {
        searchFailureNeedsSettings && settingsDestination != nil
    }

    func destination(for entry: MediaEntry) -> SearchDestination? {
        guard let context else { return nil }
        switch entry {
        case .manga(let manga):
            return .manga(pluginID: plugin.id, context: context, media: manga)
        case .anime(let anime):
            return .anime(pluginID: plugin.id, context: context, media: anime)
        case .novel(let novel):
            return .novel(pluginID: plugin.id, context: context, media: novel)
        }
    }

    func destination(for manga: Manga) -> SearchDestination? {
        destination(for: .manga(manga))
    }

    func destination(for anime: Anime) -> SearchDestination? {
        destination(for: .anime(anime))
    }

    func destination(for novel: Novel) -> SearchDestination? {
        destination(for: .novel(novel))
    }

    func requestArchivedPluginDeletion() {
        guard plugin.info.isArchived, !isDeletingArchivedPlugin else { return }
        archivedPluginDeleteError = nil
        do {
            archivedPluginFileSnapshot = try fileDeletion.snapshotPluginFile(for: plugin)
            showArchivedPluginDeleteConfirmation = true
        } catch {
            archivedPluginFileSnapshot = nil
            showArchivedPluginDeleteConfirmation = false
            publishArchivedPluginDeletionFailure(error)
        }
    }

    func cancelArchivedPluginDeletion() {
        guard !isDeletingArchivedPlugin else { return }
        showArchivedPluginDeleteConfirmation = false
        archivedPluginFileSnapshot = nil
    }

    func confirmArchivedPluginDeletion() async {
        guard plugin.info.isArchived,
              !isDeletingArchivedPlugin,
              let archivedPluginFileSnapshot else { return }
        showArchivedPluginDeleteConfirmation = false
        archivedPluginDeleteError = nil
        isDeletingArchivedPlugin = true
        let operationID = UUID()
        deleteOperationID = operationID

        var transaction: (any PluginFileDeletionTransaction)?
        do {
            let currentIdentity = pluginStatePublisher.currentSourcePlugin(for: plugin.id).map {
                SourcePluginDeletionIdentity(plugin: $0)
            }
            guard currentIdentity == archivedPluginFileSnapshot.identity else {
                throw SourcePluginFileError.stalePluginIdentity
            }
            try await pluginStatePublisher.holdCompletionDelivery(for: plugin.id)
            try pluginStatePublisher.revokeTrust(for: plugin.id)
            transaction = try fileDeletion.stagePluginFileDeletion(
                from: archivedPluginFileSnapshot
            )
            let publication = try await pluginStatePublisher.prepareSourcePluginStatePublication()
            try publication.validateCurrentState()
            try transaction?.commit()
            publication.publish()
            pluginStatePublisher.removeSecrets(for: plugin.id)
            shouldDismiss = true
            finishDeletion(operationID)
            await pluginStatePublisher.purgeCompletionDelivery(for: plugin.id)
        } catch {
            let failure = restoreAfterFailedDeletion(
                transaction: transaction,
                primaryError: error
            )
            guard deleteOperationID == operationID else { return }
            publishArchivedPluginDeletionFailure(failure)
            finishDeletion(operationID)
        }
    }

    private func load(invalidateCachedRunner: Bool) async {
        cancelLoad(publishCancelledState: false)
        capabilitiesOperationID = nil
        capabilitiesTask?.cancel()
        cancelSuggestions()
        let operationID = UUID()
        loadOperationID = operationID
        phase = .loading
        homeLayout = nil
        failureNeedsSettings = false
        failureNeedsLogin = false
        failurePendingTrust = nil

        if invalidateCachedRunner {
            runnerProvider.evictSourceRunner(for: plugin.id)
            context = nil
            settingsSurface = nil
            settingsUnavailableReason = nil
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await executeLoad(operationID: operationID)
        }
        loadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func executeLoad(operationID: UUID) async {
        runnerProvider.clearPendingTrust(for: plugin.id)
        do {
            let nextContext = try await runnerProvider.sourceRunnerContext(for: plugin.id)
            try Task.checkCancellation()
            let settings = try await loadSettings(from: nextContext)
            try Task.checkCancellation()
            guard isCurrentLoad(operationID) else { return }
            // Published before the home loads: a home that fails for want of settings needs the
            // settings button to recover.
            switch settings {
            case .surface(let surface):
                settingsSurface = surface
                settingsUnavailableReason = nil
            case .unavailable(let reason):
                settingsSurface = nil
                settingsUnavailableReason = reason
            }
            context = nextContext
            await refreshSearchCapabilities()
            try Task.checkCancellation()
            guard isCurrentLoad(operationID) else { return }
            let layout = try await nextContext.loadHome()
            try Task.checkCancellation()
            guard isCurrentLoad(operationID) else { return }

            context = nextContext
            homeLayout = layout
            phase = layout.components.isEmpty ? .empty : .content
            finishLoad(operationID)
        } catch is CancellationError {
            guard isCurrentLoad(operationID) else { return }
            phase = .cancelled
            finishLoad(operationID)
        } catch {
            guard isCurrentLoad(operationID), !Task.isCancelled else { return }
            discardRunnerIfCrashed(error)
            let reason = error.localizedDescription
            failureNeedsSettings = (error as? PluginCallError)?.kind == .needsSettings
            failureNeedsLogin = (error as? PluginCallError)?.kind == .needsLogin
            failurePendingTrust = runnerProvider.pendingTrust(for: plugin.id)
            phase = .failure(reason)
            messagePresenter.present(.loadFailed(pluginName: plugin.info.name, reason: reason))
            finishLoad(operationID)
        }
    }

    private func executeSearch(query: String, kind: MediaKind?, filterValues: [String: ControlValue], operationID: UUID) async {
        guard let context = await loadedContext() else {
            guard isCurrentSearch(operationID), !Task.isCancelled else {
                finishCancelledSearch(operationID)
                return
            }
            let failure: any Error = if case .failure(let reason) = phase {
                SourceDependencyUnavailableErrorForPresentation.loadFailed(reason)
            } else {
                SourceDependencyUnavailableErrorForPresentation.runnerUnavailable
            }
            publishSearchFailure(failure, operationID: operationID)
            return
        }
        guard isCurrentSearch(operationID), !Task.isCancelled else {
            finishCancelledSearch(operationID)
            return
        }
        runnerProvider.clearPendingTrust(for: plugin.id)
        do {
            let page = try await context.search(
                kind: kind,
                query: query,
                page: 1,
                filterValues: filterValues
            )
            try Task.checkCancellation()
            guard isCurrentSearch(operationID) else { return }
            // A source may answer a scoped search with other kinds; only the chosen kind is shown.
            publishSearchPage(kind.map { kind in page.entries.filter { $0.kind == kind } } ?? page.entries)
            finishSearch(operationID)
        } catch is CancellationError {
            finishCancelledSearch(operationID)
        } catch {
            publishSearchFailure(error, operationID: operationID)
        }
    }

    /// The runner context, once the home load that creates it has finished. A search typed
    /// while the source is still loading waits for that load instead of failing.
    private func loadedContext() async -> (any SourceRunnerContext)? {
        if phase == .loading, let loadTask {
            await loadTask.value
        }
        guard phase == .content || phase == .empty else { return nil }
        return context
    }

    private func publishSearchPage(_ entries: [MediaEntry]) {
        clearSearchResults()
        searchEntries = entries
        searchPhase = entries.isEmpty ? .empty : .content
    }

    private func publishSearchFailure(_ error: any Error, operationID: UUID) {
        guard isCurrentSearch(operationID), !Task.isCancelled else { return }
        let reason = error.localizedDescription
        searchFailureNeedsSettings = (error as? PluginCallError)?.kind == .needsSettings
        searchFailureNeedsLogin = (error as? PluginCallError)?.kind == .needsLogin
        searchFailurePendingTrust = runnerProvider.pendingTrust(for: plugin.id)
        searchPhase = .failure(reason)
        messagePresenter.present(.searchFailed(pluginName: plugin.info.name, reason: reason))
        finishSearch(operationID)
        if discardRunnerIfCrashed(error) {
            // Load the source again so the next search runs on a new runner.
            Task { [weak self] in await self?.load(invalidateCachedRunner: false) }
        }
    }

    private enum SettingsLoad {
        case surface(SettingsSurface?)
        case unavailable(reason: String)
    }

    /// The plugin's settings schema (nil when it has none), or why it couldn't be read. A crash
    /// is not kept as a reason: the home would otherwise load on the crashed runner.
    private func loadSettings(from context: any SourceRunnerContext) async throws -> SettingsLoad {
        do {
            return .surface(try await context.loadSettingsSurface())
        } catch let error as PluginCallError where error.kind == .crashed {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    /// A plugin that crashed may be left in a broken state, so its cached runner and the context
    /// holding it are dropped, and the next call starts a new one.
    @discardableResult
    private func discardRunnerIfCrashed(_ error: any Error) -> Bool {
        guard (error as? PluginCallError)?.kind == .crashed else { return false }
        runnerProvider.evictSourceRunner(for: plugin.id)
        context = nil
        return true
    }

    private func restoreAfterFailedDeletion(
        transaction: (any PluginFileDeletionTransaction)?,
        primaryError: any Error
    ) -> any Error {
        guard let transaction else { return primaryError }
        do {
            try transaction.rollback()
        } catch {
            return error
        }
        return primaryError
    }

    private func publishArchivedPluginDeletionFailure(_ error: any Error) {
        let reason = error.localizedDescription
        archivedPluginDeleteError = reason
        messagePresenter.present(
            .archivedPluginDeleteFailed(pluginName: plugin.info.name, reason: reason)
        )
    }

    private func clearSearchResults() {
        searchEntries = []
    }

    private func cancelLoad(publishCancelledState: Bool) {
        guard loadOperationID != nil else {
            loadTask?.cancel()
            loadTask = nil
            return
        }
        loadTask?.cancel()
        loadTask = nil
        loadOperationID = nil
        if publishCancelledState {
            phase = .cancelled
        }
    }

    private func cancelSearch(publishCancelledState: Bool) {
        guard searchOperationID != nil else {
            searchTask?.cancel()
            searchTask = nil
            return
        }
        searchTask?.cancel()
        searchTask = nil
        searchOperationID = nil
        if publishCancelledState {
            searchPhase = .cancelled
        }
    }

    private func finishCancelledSearch(_ operationID: UUID) {
        guard isCurrentSearch(operationID) else { return }
        searchPhase = .cancelled
        finishSearch(operationID)
    }

    private func finishLoad(_ operationID: UUID) {
        guard isCurrentLoad(operationID) else { return }
        loadOperationID = nil
        loadTask = nil
    }

    private func finishSearch(_ operationID: UUID) {
        guard isCurrentSearch(operationID) else { return }
        searchOperationID = nil
        searchTask = nil
    }

    private func finishDeletion(_ operationID: UUID) {
        guard deleteOperationID == operationID else { return }
        deleteOperationID = nil
        archivedPluginFileSnapshot = nil
        isDeletingArchivedPlugin = false
    }

    private func isCurrentLoad(_ operationID: UUID) -> Bool {
        loadOperationID == operationID
    }

    private func isCurrentSearch(_ operationID: UUID) -> Bool {
        searchOperationID == operationID
    }
}

private enum SourceDependencyUnavailableErrorForPresentation: LocalizedError {
    case runnerUnavailable
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .runnerUnavailable:
            "The source is not ready."
        case .loadFailed(let reason):
            reason
        }
    }
}
