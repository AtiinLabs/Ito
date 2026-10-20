import Combine
import Foundation

@MainActor
final class HistoryViewModel: ObservableObject {
    enum Phase: Equatable {
        case empty
        case content
    }

    @Published private(set) var history: [HistoryEntry]
    @Published private(set) var deletingEntryIDs = Set<String>()
    @Published private(set) var isClearing = false
    @Published private(set) var isClearConfirmationPresented = false
    @Published private(set) var failure: CategoryHistoryMessage?

    private let historyService: any HistoryServing
    private let messagePresenter: any CategoryHistoryMessagePresenting
    private let presentationLogger: any PresentationEventLogging
    private var deleteOperationIDs: [String: UUID] = [:]
    private var clearOperationID: UUID?
    private var cancellables = Set<AnyCancellable>()

    init(
        historyService: any HistoryServing,
        messagePresenter: any CategoryHistoryMessagePresenting,
        presentationLogger: any PresentationEventLogging
    ) {
        self.historyService = historyService
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger
        history = historyService.historySnapshot
        historyService.historySnapshotPublisher
            .sink { [weak self] history in
                self?.history = history
            }
            .store(in: &cancellables)
    }

    var phase: Phase {
        history.isEmpty ? .empty : .content
    }

    var isClearVisible: Bool {
        !history.isEmpty
    }

    func requestClear() {
        guard !history.isEmpty, !isClearing else { return }
        isClearConfirmationPresented = true
    }

    func cancelClear() {
        isClearConfirmationPresented = false
    }

    func confirmClear() async {
        isClearConfirmationPresented = false
        await clearHistory()
    }

    func deleteEntry(id: String) async {
        guard deleteOperationIDs[id] == nil,
              history.contains(where: { $0.id == id }) else { return }
        let operationID = UUID()
        deleteOperationIDs[id] = operationID
        deletingEntryIDs.insert(id)
        failure = nil
        logStarted(.historyDelete, operationID: operationID)
        do {
            try await historyService.removeEntry(id: id)
            logFinished(.historyDelete, operationID: operationID, outcome: .succeeded)
        } catch is CancellationError {
            logFinished(.historyDelete, operationID: operationID, outcome: .cancelled)
        } catch {
            logFinished(
                .historyDelete,
                operationID: operationID,
                outcome: .failed(.persistence)
            )
            if deleteOperationIDs[id] == operationID {
                publishFailure(.historyDeleteFailed)
            }
        }
        if deleteOperationIDs[id] == operationID {
            deleteOperationIDs[id] = nil
            deletingEntryIDs.remove(id)
        }
    }

    func clearHistory() async {
        guard clearOperationID == nil, !history.isEmpty else { return }
        let operationID = UUID()
        clearOperationID = operationID
        isClearing = true
        failure = nil
        logStarted(.historyClear, operationID: operationID)
        do {
            try await historyService.clearHistory()
            logFinished(.historyClear, operationID: operationID, outcome: .succeeded)
        } catch is CancellationError {
            logFinished(.historyClear, operationID: operationID, outcome: .cancelled)
        } catch {
            logFinished(
                .historyClear,
                operationID: operationID,
                outcome: .failed(.persistence)
            )
            if clearOperationID == operationID {
                publishFailure(.historyClearFailed)
            }
        }
        if clearOperationID == operationID {
            clearOperationID = nil
            isClearing = false
        }
    }

    func dismissFailure() {
        failure = nil
    }

    private func publishFailure(_ message: CategoryHistoryMessage) {
        failure = message
        messagePresenter.present(message)
    }

    private func logStarted(_ kind: PresentationEventKind, operationID: UUID) {
        presentationLogger.log(.started(feature: .history, kind: kind, operationID: operationID))
    }

    private func logFinished(
        _ kind: PresentationEventKind,
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        presentationLogger.log(
            .finished(
                feature: .history,
                kind: kind,
                operationID: operationID,
                outcome: outcome
            )
        )
    }
}
