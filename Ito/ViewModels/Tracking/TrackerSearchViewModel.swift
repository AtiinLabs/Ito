import Combine
import Foundation

enum TrackerSearchPresentationState: Equatable {
    case idle
    case loading
    case content
    case empty
    case failure
}

struct TrackerDetailsDestination: Equatable {
    let providerID: String
    let providerName: String
    let mediaIdentity: MediaIdentity
    let media: TrackerMedia
    let showCancelButton: Bool
    let isLocallyLinked: Bool
}

@MainActor
final class TrackerSearchViewModel: ObservableObject {
    let providerID: String
    let providerName: String
    let mediaIdentity: MediaIdentity
    let isAnime: Bool

    @Published var searchQuery: String
    @Published private(set) var state: TrackerSearchPresentationState = .idle
    @Published private(set) var results: [TrackerMedia] = []
    @Published private(set) var selectedMedia: TrackerMedia?
    @Published private(set) var destination: TrackerDetailsDestination?
    @Published var isPresentingDetails = false {
        didSet {
            if !isPresentingDetails {
                destination = nil
            }
        }
    }

    private let searchService: any TrackerSearchServicing
    private let presentationLogger: any PresentationEventLogging
    private var searchTask: Task<Void, Never>?
    private var searchOperationID: UUID?
    private var hasStarted = false

    init(
        providerID: String,
        providerName: String,
        mediaIdentity: MediaIdentity,
        title: String,
        isAnime: Bool,
        searchService: any TrackerSearchServicing,
        presentationLogger: any PresentationEventLogging
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.mediaIdentity = mediaIdentity
        self.isAnime = isAnime
        searchQuery = title
        self.searchService = searchService
        self.presentationLogger = presentationLogger
    }

    var isLoading: Bool { state == .loading }

    var errorMessage: String? {
        state == .failure ? "Search failed. Please try again." : nil
    }

    /// Shown when a MyAnimeList search is too short for MyAnimeList to accept (it needs 3 characters).
    var queryHint: String? {
        guard providerID == MALCredentialRepository.providerID,
              searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 else { return nil }
        return "Enter at least 3 characters to search MyAnimeList."
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        performSearch()
    }

    func performSearch() {
        cancelCurrentSearch(publishCancellation: false)

        guard !searchQuery.isEmpty else {
            state = results.isEmpty ? .idle : .content
            return
        }

        if queryHint != nil {
            isPresentingDetails = false
            results = []
            selectedMedia = nil
            state = .idle
            return
        }

        isPresentingDetails = false
        results = []
        selectedMedia = nil

        let operationID = UUID()
        searchOperationID = operationID
        state = .loading
        presentationLogger.log(
            .started(
                feature: .trackerSearch,
                kind: .trackerSearch,
                operationID: operationID
            )
        )
        let query = searchQuery

        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let searchResults = try await searchService.searchMedia(
                    providerID: providerID,
                    title: query,
                    isAnime: isAnime
                )
                guard isCurrent(operationID), !Task.isCancelled else {
                    logIgnoredStale(operationID)
                    return
                }
                results = searchResults
                if let firstResult = searchResults.first,
                   firstResult.title.lowercased() == query.lowercased() {
                    selectedMedia = firstResult
                }
                state = searchResults.isEmpty ? .empty : .content
                finishSearch(operationID, outcome: .succeeded)
            } catch is CancellationError {
                guard isCurrent(operationID) else {
                    logIgnoredStale(operationID)
                    return
                }
                state = results.isEmpty ? .idle : .content
                finishSearch(operationID, outcome: .cancelled)
            } catch {
                guard isCurrent(operationID), !Task.isCancelled else {
                    logIgnoredStale(operationID)
                    return
                }
                state = .failure
                finishSearch(operationID, outcome: .failed(.network))
            }
        }
    }

    func retry() {
        performSearch()
    }

    func select(mediaID: String) {
        guard state == .content,
              let media = results.first(where: { $0.id == mediaID }) else { return }
        selectedMedia = media
        destination = nil
    }

    func presentSelectedDetails() {
        guard state == .content,
              let selectedMedia,
              results.contains(where: { $0.id == selectedMedia.id }) else { return }
        destination = TrackerDetailsDestination(
            providerID: providerID,
            providerName: providerName,
            mediaIdentity: mediaIdentity,
            media: selectedMedia,
            showCancelButton: false,
            isLocallyLinked: false
        )
        isPresentingDetails = true
    }

    func navigationBindingDidSet(_ isPresented: Bool) {
        isPresentingDetails = isPresented
    }

    func cancelOwnedWork() {
        cancelCurrentSearch(publishCancellation: true)
        isPresentingDetails = false
        selectedMedia = nil
    }

    private func cancelCurrentSearch(publishCancellation: Bool) {
        guard let operationID = searchOperationID else {
            searchTask?.cancel()
            searchTask = nil
            return
        }
        searchOperationID = nil
        searchTask?.cancel()
        searchTask = nil
        presentationLogger.log(
            .finished(
                feature: .trackerSearch,
                kind: .trackerSearch,
                operationID: operationID,
                outcome: .cancelled
            )
        )
        if publishCancellation {
            state = results.isEmpty ? .idle : .content
        }
    }

    private func finishSearch(
        _ operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        guard isCurrent(operationID) else { return }
        presentationLogger.log(
            .finished(
                feature: .trackerSearch,
                kind: .trackerSearch,
                operationID: operationID,
                outcome: outcome
            )
        )
        searchOperationID = nil
        searchTask = nil
    }

    private func logIgnoredStale(_ operationID: UUID) {
        presentationLogger.log(
            .finished(
                feature: .trackerSearch,
                kind: .trackerSearch,
                operationID: operationID,
                outcome: .ignoredStale
            )
        )
    }

    private func isCurrent(_ operationID: UUID) -> Bool {
        searchOperationID == operationID
    }
}
