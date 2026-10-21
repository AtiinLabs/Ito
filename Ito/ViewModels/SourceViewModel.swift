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
    let schema: SettingsSchema
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
    @Published private(set) var settingsSchema: SettingsSchema?
    @Published private(set) var searchMangas: [Manga] = []
    @Published private(set) var searchAnimes: [Anime] = []
    @Published private(set) var searchNovels: [Novel] = []
    @Published var searchQuery = ""
    @Published var showSettings = false
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
    }

    func loadIfNeeded() async {
        guard phase == .idle || phase == .cancelled else { return }
        await load(invalidateCachedRunner: false)
    }

    func retry() async {
        await load(invalidateCachedRunner: false)
    }

    func reloadAfterSettingsChange() async {
        cancelSearch(publishCancelledState: false)
        clearSearchResults()
        searchQuery = ""
        await load(invalidateCachedRunner: true)
    }

    func performSearch(query: String) {
        cancelSearch(publishCancelledState: false)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            clearSearchResults()
            searchPhase = .idle
            return
        }

        let operationID = UUID()
        searchOperationID = operationID
        searchPhase = .loading
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let searchDebounceNanoseconds {
                do {
                    try await Task.sleep(nanoseconds: searchDebounceNanoseconds)
                } catch {
                    finishCancelledSearch(operationID)
                    return
                }
            }
            await executeSearch(query: trimmedQuery, operationID: operationID)
        }
        searchTask = task
    }

    var hasActiveSearchQuery: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func cancelActiveOperations() {
        cancelLoad(publishCancelledState: true)
        cancelSearch(publishCancelledState: true)
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
        guard let settingsSchema else { return nil }
        return SourceSettingsDestination(plugin: plugin, schema: settingsSchema)
    }

    func destination(for manga: Manga) -> SearchDestination? {
        context.map { .manga(pluginID: plugin.id, context: $0, media: manga) }
    }

    func destination(for anime: Anime) -> SearchDestination? {
        context.map { .anime(pluginID: plugin.id, context: $0, media: anime) }
    }

    func destination(for novel: Novel) -> SearchDestination? {
        context.map { .novel(pluginID: plugin.id, context: $0, media: novel) }
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
        let operationID = UUID()
        loadOperationID = operationID
        phase = .loading
        homeLayout = nil

        if invalidateCachedRunner {
            runnerProvider.evictSourceRunner(for: plugin.id)
            context = nil
            settingsSchema = nil
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
        do {
            let nextContext = try await runnerProvider.sourceRunnerContext(for: plugin.id)
            try Task.checkCancellation()
            let schema = try? await nextContext.loadSettingsSchema()
            try Task.checkCancellation()
            let layout = try await nextContext.loadHome()
            try Task.checkCancellation()
            guard isCurrentLoad(operationID) else { return }

            context = nextContext
            settingsSchema = schema
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
            phase = .failure(reason)
            messagePresenter.present(.loadFailed(pluginName: plugin.info.name, reason: reason))
            finishLoad(operationID)
        }
    }

    private func executeSearch(query: String, operationID: UUID) async {
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

        do {
            let page = try await context.search(
                pluginType: plugin.info.type,
                query: query,
                page: 1,
                filters: []
            )
            try Task.checkCancellation()
            guard isCurrentSearch(operationID) else { return }
            publishSearchPage(page)
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
        if context == nil, phase == .loading, let loadTask {
            await loadTask.value
        }
        return context
    }

    private func publishSearchPage(_ page: SourceSearchPage) {
        clearSearchResults()
        switch page {
        case .manga(let mangas):
            searchMangas = mangas
            searchPhase = mangas.isEmpty ? .empty : .content
        case .anime(let animes):
            searchAnimes = animes
            searchPhase = animes.isEmpty ? .empty : .content
        case .novel(let novels):
            searchNovels = novels
            searchPhase = novels.isEmpty ? .empty : .content
        }
    }

    private func publishSearchFailure(_ error: any Error, operationID: UUID) {
        guard isCurrentSearch(operationID), !Task.isCancelled else { return }
        let reason = error.localizedDescription
        searchPhase = .failure(reason)
        messagePresenter.present(.searchFailed(pluginName: plugin.info.name, reason: reason))
        finishSearch(operationID)
        if discardRunnerIfCrashed(error) {
            // The current context holds the crashed runner: load the source again with a new one.
            Task { await self.load(invalidateCachedRunner: false) }
        }
    }

    /// A plugin that crashed may be left in a broken state, so its cached runner is dropped and the
    /// next call starts a new one.
    @discardableResult
    private func discardRunnerIfCrashed(_ error: any Error) -> Bool {
        guard (error as? PluginCallError)?.kind == .crashed else { return false }
        runnerProvider.evictSourceRunner(for: plugin.id)
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
        searchMangas = []
        searchAnimes = []
        searchNovels = []
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
