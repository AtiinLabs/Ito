import Combine
import Foundation
import ito_runner

@MainActor
final class ListingViewModel: ObservableObject {
    struct Identity: Equatable {
        let pluginID: String
        let listingID: String
        let listingKind: Int32
        let title: String
    }

    enum Phase: Equatable {
        case idle
        case loading
        case content
        case empty
        case failure(String)
        case cancelled
    }

    enum PaginationState: Equatable {
        case idle
        case loading(page: Int32)
        case failure(page: Int32, reason: String)
        case continuationRequired(page: Int32)
        case exhausted
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var paginationState: PaginationState = .idle
    @Published private(set) var entries: [MediaEntry] = []
    @Published private(set) var hasNextPage = true
    @Published private(set) var nextPage: Int32 = 1

    private(set) var destination: SourceListingDestination
    let identity: Identity
    private let runnerProvider: any SourceRunnerProviding
    private var sessionID = UUID()
    private var requestID: UUID?
    private var requestTask: Task<Void, Never>?
    /// Set once the runner behind `destination.context` crashed: the next request reacquires a context from
    /// the provider instead of reusing the retired instance. Ordinary failures never set it.
    private var contextNeedsReacquisition = false

    init(destination: SourceListingDestination, runnerProvider: any SourceRunnerProviding) {
        self.destination = destination
        self.runnerProvider = runnerProvider
        identity = Self.identity(for: destination)
    }

    deinit {
        requestTask?.cancel()
    }

    var title: String { destination.title }
    var isEmpty: Bool { entries.isEmpty }

    func loadInitialIfNeeded() async {
        guard phase == .idle || phase == .cancelled else { return }
        await loadInitial()
    }

    func loadInitial() async {
        resetForNewSession()
        phase = .loading
        await request(page: 1, isInitial: true)
    }

    func loadMore() async {
        guard requestID == nil,
              hasNextPage,
              phase == .content || phase == .empty else { return }
        await request(page: nextPage, isInitial: false)
    }

    func retry() async {
        if case .failure = paginationState {
            await loadMore()
        } else if isEmpty {
            await loadInitial()
        } else {
            await loadMore()
        }
    }

    func cancel() {
        cancelActiveRequest(publishCancelledState: true)
    }

    func destination(for entry: MediaEntry) -> SearchDestination {
        switch entry {
        case .manga(let manga):
            return .manga(pluginID: destination.plugin.id, context: destination.context, media: manga)
        case .anime(let anime):
            return .anime(pluginID: destination.plugin.id, context: destination.context, media: anime)
        case .novel(let novel):
            return .novel(pluginID: destination.plugin.id, context: destination.context, media: novel)
        }
    }

    func destination(for manga: Manga) -> SearchDestination {
        destination(for: .manga(manga))
    }

    func destination(for anime: Anime) -> SearchDestination {
        destination(for: .anime(anime))
    }

    func destination(for novel: Novel) -> SearchDestination {
        destination(for: .novel(novel))
    }

    private func request(page: Int32, isInitial: Bool) async {
        guard requestID == nil else { return }
        let currentSessionID = sessionID
        let currentRequestID = UUID()
        requestID = currentRequestID
        if isInitial {
            phase = .loading
        } else {
            paginationState = .loading(page: page)
        }

        let requestDestination = destination
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await executeRequest(
                destination: requestDestination,
                page: page,
                isInitial: isInitial,
                sessionID: currentSessionID,
                requestID: currentRequestID
            )
        }
        requestTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func executeRequest(
        destination: SourceListingDestination,
        page: Int32,
        isInitial: Bool,
        sessionID: UUID,
        requestID: UUID
    ) async {
        var failedContext: (any SourceRunnerContext)?
        do {
            let context = try await requestContext(for: destination, sessionID: sessionID, requestID: requestID)
            failedContext = context
            let result = try await context.loadListing(
                listing: destination.listing,
                page: page,
                operationID: destination.operationID
            )
            try Task.checkCancellation()
            guard isCurrent(sessionID: sessionID, requestID: requestID) else { return }
            let publishedCount = publish(result, isInitial: isInitial)
            nextPage = page + 1
            if hasNextPage, !isInitial, publishedCount == 0 {
                paginationState = .continuationRequired(page: nextPage)
            } else {
                paginationState = hasNextPage ? .idle : .exhausted
            }
            phase = isEmpty ? .empty : .content
            finishRequest(requestID)
        } catch {
            // The failed instance is retired whether or not this request is still current: a cancelled or
            // superseded request can still have trapped its runner. Nothing else it holds is published.
            retireCrashedRunner(error, pluginID: destination.plugin.id, context: failedContext)
            guard isCurrent(sessionID: sessionID, requestID: requestID) else { return }
            // A request its caller cancelled can end in a host error rather than CancellationError, such as
            // URLError(.cancelled). That is still a cancellation: it is never shown as a failure.
            if error is CancellationError || Task.isCancelled {
                if isInitial {
                    phase = .cancelled
                } else {
                    paginationState = .continuationRequired(page: page)
                }
                finishRequest(requestID)
                return
            }
            let reason = error.localizedDescription
            if isInitial {
                phase = .failure(reason)
            } else {
                paginationState = .failure(page: page, reason: reason)
            }
            finishRequest(requestID)
        }
    }

    /// The context a request runs on: the retained one, or a freshly acquired one once its runner crashed. The
    /// fresh context replaces the retained one only while the request is still current.
    private func requestContext(
        for destination: SourceListingDestination,
        sessionID: UUID,
        requestID: UUID
    ) async throws -> any SourceRunnerContext {
        guard contextNeedsReacquisition else { return destination.context }
        let fresh = try await runnerProvider.sourceRunnerContext(for: destination.plugin.id)
        try Task.checkCancellation()
        guard isCurrent(sessionID: sessionID, requestID: requestID) else { throw CancellationError() }
        self.destination = destination.replacingContext(fresh)
        contextNeedsReacquisition = false
        return fresh
    }

    /// Retires the runner a crashed request used, matched by instance, so an old crash can't evict a newer runner.
    /// The retained context is flagged for reacquisition only while it is still that instance.
    private func retireCrashedRunner(_ error: any Error, pluginID: String, context failed: (any SourceRunnerContext)?) {
        guard let failed, (error as? PluginCallError)?.kind == .crashed else { return }
        runnerProvider.retireSourceRunner(for: pluginID, matching: failed)
        if destination.context.runnerIdentity == failed.runnerIdentity {
            contextNeedsReacquisition = true
        }
    }

    private func publish(_ result: MediaPageResult, isInitial: Bool) -> Int {
        entries = isInitial ? result.entries : entries + result.entries
        hasNextPage = result.hasNextPage
        return result.entries.count
    }

    private func resetForNewSession() {
        cancelActiveRequest(publishCancelledState: false)
        sessionID = UUID()
        requestID = nil
        requestTask = nil
        entries = []
        hasNextPage = true
        nextPage = 1
        paginationState = .idle
        phase = .idle
    }

    private func cancelActiveRequest(publishCancelledState: Bool) {
        let hadActiveRequest = requestID != nil
        requestTask?.cancel()
        requestTask = nil
        requestID = nil
        sessionID = UUID()
        guard publishCancelledState, hadActiveRequest else { return }
        if isEmpty {
            phase = .cancelled
        } else {
            paginationState = .continuationRequired(page: nextPage)
        }
    }

    private func finishRequest(_ requestID: UUID) {
        guard self.requestID == requestID else { return }
        self.requestID = nil
        requestTask = nil
    }

    private func isCurrent(sessionID: UUID, requestID: UUID) -> Bool {
        self.sessionID == sessionID && self.requestID == requestID
    }

    private static func identity(for destination: SourceListingDestination) -> Identity {
        Identity(
            pluginID: destination.plugin.id,
            listingID: destination.listing.id,
            listingKind: destination.listing.kind,
            title: destination.title
        )
    }
}
