import Combine
import Foundation
import ito_runner

@MainActor
final class ListingViewModel: ObservableObject {
    struct Identity: Equatable {
        let pluginID: String
        let pluginType: MediaKind
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
    @Published private(set) var mangas: [Manga] = []
    @Published private(set) var animes: [Anime] = []
    @Published private(set) var novels: [Novel] = []
    @Published private(set) var hasNextPage = true
    @Published private(set) var nextPage: Int32 = 1

    private(set) var destination: SourceListingDestination
    private(set) var identity: Identity
    private var sessionID = UUID()
    private var requestID: UUID?
    private var requestTask: Task<Void, Never>?

    init(destination: SourceListingDestination) {
        self.destination = destination
        identity = Self.identity(for: destination)
    }

    deinit {
        requestTask?.cancel()
    }

    var title: String { destination.title }
    var pluginType: MediaKind { destination.plugin.info.type }
    var isEmpty: Bool { mangas.isEmpty && animes.isEmpty && novels.isEmpty }

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

    func replaceDestination(_ destination: SourceListingDestination) async {
        guard Self.identity(for: destination) != identity
                || ObjectIdentifier(destination.context) != ObjectIdentifier(self.destination.context) else {
            return
        }
        cancelActiveRequest(publishCancelledState: false)
        self.destination = destination
        identity = Self.identity(for: destination)
        await loadInitial()
    }

    func cancel() {
        cancelActiveRequest(publishCancelledState: true)
    }

    func destination(for manga: Manga) -> SearchDestination {
        .manga(pluginID: destination.plugin.id, context: destination.context, media: manga)
    }

    func destination(for anime: Anime) -> SearchDestination {
        .anime(pluginID: destination.plugin.id, context: destination.context, media: anime)
    }

    func destination(for novel: Novel) -> SearchDestination {
        .novel(pluginID: destination.plugin.id, context: destination.context, media: novel)
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
        do {
            let result = try await destination.context.loadListing(
                kind: destination.plugin.info.type,
                listing: destination.listing,
                page: page
            )
            try Task.checkCancellation()
            guard isCurrent(sessionID: sessionID, requestID: requestID) else { return }
            let publishedCount = try publish(result, isInitial: isInitial)
            nextPage = page + 1
            if hasNextPage, !isInitial, publishedCount == 0 {
                paginationState = .continuationRequired(page: nextPage)
            } else {
                paginationState = hasNextPage ? .idle : .exhausted
            }
            phase = isEmpty ? .empty : .content
            finishRequest(requestID)
        } catch is CancellationError {
            guard isCurrent(sessionID: sessionID, requestID: requestID) else { return }
            if isInitial {
                phase = .cancelled
            } else {
                paginationState = .continuationRequired(page: page)
            }
            finishRequest(requestID)
        } catch {
            guard isCurrent(sessionID: sessionID, requestID: requestID), !Task.isCancelled else {
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

    private func publish(_ result: ListingContentPage, isInitial: Bool) throws -> Int {
        switch (pluginType, result) {
        case (.manga, .manga(let entries, let responseHasNextPage)):
            mangas = isInitial ? entries : mangas + entries
            hasNextPage = responseHasNextPage
            return entries.count
        case (.anime, .anime(let entries, let responseHasNextPage)):
            animes = isInitial ? entries : animes + entries
            hasNextPage = responseHasNextPage
            return entries.count
        case (.novel, .novel(let entries, let responseHasNextPage)):
            novels = isInitial ? entries : novels + entries
            hasNextPage = responseHasNextPage
            return entries.count
        default:
            throw ListingViewModelError.responseTypeMismatch
        }
    }

    private func resetForNewSession() {
        cancelActiveRequest(publishCancelledState: false)
        sessionID = UUID()
        requestID = nil
        requestTask = nil
        mangas = []
        animes = []
        novels = []
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
            pluginType: destination.plugin.info.type,
            listingID: destination.listing.id,
            listingKind: destination.listing.kind,
            title: destination.title
        )
    }
}

private enum ListingViewModelError: LocalizedError {
    case responseTypeMismatch

    var errorDescription: String? {
        "The source returned an unexpected listing type."
    }
}
