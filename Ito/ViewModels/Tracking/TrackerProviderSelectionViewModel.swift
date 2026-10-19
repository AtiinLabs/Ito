import Combine
import Foundation

enum TrackerProviderEntrySummary: Equatable {
    case notTracked
    case loading
    case notOnList
    case unavailable
    case entry(status: String, progress: Int?)
}

/// Shows where each tracker stands for one series in the provider picker. Only reads; never writes.
@MainActor
final class TrackerProviderSelectionViewModel: ObservableObject {
    @Published private(set) var summaries: [String: TrackerProviderEntrySummary]

    private let linkedRemoteMediaIDs: [String: String]
    private let isReadingFormat: Bool
    private let detailsService: any TrackerDetailsServicing
    private var loadTasks: [String: Task<Void, Never>] = [:]
    private var hasStarted = false

    init(configuration: TrackerSheetConfiguration, detailsService: any TrackerDetailsServicing) {
        var summaries: [String: TrackerProviderEntrySummary] = [:]
        var linkedRemoteMediaIDs: [String: String] = [:]
        for provider in configuration.providers {
            if let remoteMediaID = provider.linkedRemoteMediaID {
                summaries[provider.id] = .loading
                linkedRemoteMediaIDs[provider.id] = remoteMediaID
            } else {
                summaries[provider.id] = .notTracked
            }
        }
        self.summaries = summaries
        self.linkedRemoteMediaIDs = linkedRemoteMediaIDs
        isReadingFormat = !configuration.isAnime
        self.detailsService = detailsService
    }

    /// Loads the entry of every linked tracker. Runs once.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        for (providerID, remoteMediaID) in linkedRemoteMediaIDs {
            loadTasks[providerID] = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let entry = try await detailsService.getMediaListEntry(
                        providerID: providerID,
                        mediaID: remoteMediaID
                    )
                    guard !Task.isCancelled else { return }
                    if let entry {
                        summaries[providerID] = .entry(status: entry.status ?? "PLANNING", progress: entry.progress)
                    } else {
                        summaries[providerID] = .notOnList
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    summaries[providerID] = .unavailable
                }
            }
        }
    }

    func label(for providerID: String) -> String {
        switch summaries[providerID] ?? .notTracked {
        case .notTracked:
            return "Not tracked"
        case .loading:
            return "Checking…"
        case .notOnList:
            return "Not on list"
        case .unavailable:
            return "Tracked"
        case .entry(let status, let progress):
            let statusLabel = TrackerDetailsViewModel.statusLabel(for: status, isReadingFormat: isReadingFormat)
            guard let progress else { return statusLabel }
            return "\(statusLabel) · \(progress)"
        }
    }

    func cancelOwnedWork() {
        for task in loadTasks.values {
            task.cancel()
        }
        loadTasks.removeAll()
    }
}
