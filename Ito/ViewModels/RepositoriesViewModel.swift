import Combine
import Foundation

@MainActor
final class RepositoriesViewModel: ObservableObject {
    @Published var showingAddRepository = false
    @Published var repositoryURLInput = ""
    @Published private(set) var repositories: [Repository]
    @Published private(set) var isAddingRepository = false
    @Published private(set) var addFailureMessage: String?
    @Published private(set) var pendingDeleteRepositoryURL: String?
    @Published private(set) var showDeleteConfirmation = false
    @Published private(set) var deletingRepositoryURLs: Set<String> = []
    @Published private(set) var deleteFailureMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshFailureMessage: String?

    private let repositoryManager: any RepositoryListManaging
    private let messagePresenter: any RepositoryManagementMessagePresenting
    private var deleteOperations: [String: UUID] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(
        repositoryManager: any RepositoryListManaging,
        messagePresenter: any RepositoryManagementMessagePresenting
    ) {
        self.repositoryManager = repositoryManager
        self.messagePresenter = messagePresenter
        repositories = repositoryManager.repositories

        repositoryManager.repositoriesPublisher
            .sink { @MainActor [weak self] repositories in
                self?.repositories = repositories
            }
            .store(in: &cancellables)
    }

    var isEmpty: Bool {
        repositories.isEmpty
    }

    var canSubmitRepository: Bool {
        !isAddingRepository && !trimmedRepositoryURL.isEmpty
    }

    func presentAddRepository() {
        addFailureMessage = nil
        showingAddRepository = true
    }

    func cancelAddRepository() {
        guard !isAddingRepository else { return }
        showingAddRepository = false
        repositoryURLInput = ""
        addFailureMessage = nil
    }

    func addRepository() async {
        let repositoryURL = trimmedRepositoryURL
        guard !repositoryURL.isEmpty, !isAddingRepository else { return }

        isAddingRepository = true
        addFailureMessage = nil
        defer { isAddingRepository = false }

        do {
            let result = try await repositoryManager.addRepository(url: repositoryURL)
            repositoryURLInput = ""
            showingAddRepository = false
            if result == .alreadyPresent {
                messagePresenter.present(.alreadyAdded)
            }
        } catch {
            addFailureMessage = "Failed to add repository. Please check the URL and try again."
        }
    }

    func requestDelete(repositoryURL: String) {
        guard !deletingRepositoryURLs.contains(repositoryURL) else { return }
        pendingDeleteRepositoryURL = repositoryURL
        deleteFailureMessage = nil
        showDeleteConfirmation = true
    }

    func cancelDelete() {
        pendingDeleteRepositoryURL = nil
        showDeleteConfirmation = false
    }

    /// Called when the confirmation dialog is dismissed by the system. SwiftUI may
    /// report the dismissal before running the Remove action, so the pending target
    /// must survive it; `requestDelete` replaces it on the next request.
    func deleteConfirmationDismissed() {
        showDeleteConfirmation = false
    }

    @discardableResult
    func confirmDelete() -> Task<Void, Never>? {
        guard let repositoryURL = pendingDeleteRepositoryURL,
              !deletingRepositoryURLs.contains(repositoryURL) else {
            return nil
        }

        let operationID = UUID()
        deleteOperations[repositoryURL] = operationID
        deletingRepositoryURLs.insert(repositoryURL)
        pendingDeleteRepositoryURL = nil
        showDeleteConfirmation = false
        deleteFailureMessage = nil

        return Task { await performDelete(repositoryURL: repositoryURL, operationID: operationID) }
    }

    private func performDelete(repositoryURL: String, operationID: UUID) async {
        defer {
            if deleteOperations[repositoryURL] == operationID {
                deleteOperations[repositoryURL] = nil
                deletingRepositoryURLs.remove(repositoryURL)
            }
        }

        do {
            try await repositoryManager.removeRepository(url: repositoryURL)
        } catch {
            deleteFailureMessage = error.localizedDescription
            messagePresenter.present(.removeFailed(reason: error.localizedDescription))
        }
    }

    func refreshRepositories() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshFailureMessage = nil
        defer { isRefreshing = false }

        do {
            try await repositoryManager.refreshAllReportingFailures()
        } catch {
            refreshFailureMessage = error.localizedDescription
            messagePresenter.present(.refreshFailed(reason: error.localizedDescription))
        }
    }

    private var trimmedRepositoryURL: String {
        repositoryURLInput.trimmingCharacters(in: .whitespaces)
    }
}
