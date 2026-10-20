import Combine
import Foundation

@MainActor
final class CategorySettingsViewModel: ObservableObject {
    @Published private(set) var categories: [LibraryCategory]
    @Published var isAddCategoryPresented = false
    @Published var newCategoryName = ""
    @Published private(set) var failure: CategoryHistoryMessage?
    @Published private(set) var categoryPendingDeletionID: String?
    @Published private(set) var editingCategoryID: String?
    @Published var editedCategoryName = ""
    @Published private(set) var renameDismissalID: String?
    @Published private(set) var isCreating = false
    @Published private(set) var isDeleting = false
    @Published private(set) var isRenaming = false
    @Published private(set) var isReordering = false

    private let organization: any LibraryOrganizationServing
    private let messagePresenter: any CategoryHistoryMessagePresenting
    private let presentationLogger: any PresentationEventLogging
    private var cancellables = Set<AnyCancellable>()
    private var addSessionID: UUID?
    private var renameSessionID: UUID?
    private var createOperationID: UUID?
    private var deleteOperationID: UUID?
    private var renameOperationID: UUID?
    private var pendingUserCategoryIDs: [String]?
    private var queuedReorderIDs: [String]?
    private var reorderTask: Task<Void, Never>?
    private var deleteTask: Task<Void, Never>?

    init(
        organization: any LibraryOrganizationServing,
        messagePresenter: any CategoryHistoryMessagePresenting,
        presentationLogger: any PresentationEventLogging
    ) {
        self.organization = organization
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger
        categories = organization.organizationSnapshot.categories
        organization.organizationSnapshotPublisher
            .sink { [weak self] snapshot in
                self?.apply(snapshot)
            }
            .store(in: &cancellables)
    }

    deinit {
        reorderTask?.cancel()
        deleteTask?.cancel()
    }

    var systemCategory: LibraryCategory? {
        categories.first(where: \.isSystemCategory)
    }

    var userCategories: [LibraryCategory] {
        let authoritative = categories.filter { !$0.isSystemCategory }
        guard let pendingUserCategoryIDs else { return authoritative }
        let byID = Dictionary(uniqueKeysWithValues: authoritative.map { ($0.id, $0) })
        let pending = pendingUserCategoryIDs.compactMap { byID[$0] }
        let included = Set(pending.map(\.id))
        return pending + authoritative.filter { !included.contains($0.id) }
    }

    var categoryPendingDeletion: LibraryCategory? {
        guard let categoryPendingDeletionID else { return nil }
        return categories.first { $0.id == categoryPendingDeletionID }
    }

    var canCreateCategory: Bool {
        !isCreating && Self.isValid(name: newCategoryName)
    }

    var canSaveRename: Bool {
        !isRenaming && editingCategoryID != nil && Self.isValid(name: editedCategoryName)
    }

    func presentAddCategory() {
        guard !isCreating else { return }
        addSessionID = UUID()
        newCategoryName = ""
        failure = nil
        isAddCategoryPresented = true
    }

    func cancelAddCategory() {
        addSessionID = UUID()
        newCategoryName = ""
        isAddCategoryPresented = false
    }

    func createCategory() async {
        guard createOperationID == nil,
              isAddCategoryPresented,
              let sessionID = addSessionID,
              Self.isValid(name: newCategoryName) else { return }
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let operationID = UUID()
        createOperationID = operationID
        isCreating = true
        failure = nil
        logStarted(.categoryCreate, operationID: operationID)
        do {
            _ = try await organization.createCategory(name: name)
            logFinished(.categoryCreate, operationID: operationID, outcome: .succeeded)
            guard createOperationID == operationID,
                  addSessionID == sessionID,
                  isAddCategoryPresented else {
                finishCreateIfCurrent(operationID)
                return
            }
            newCategoryName = ""
            isAddCategoryPresented = false
            addSessionID = nil
        } catch is CancellationError {
            logFinished(.categoryCreate, operationID: operationID, outcome: .cancelled)
        } catch {
            logFinished(
                .categoryCreate,
                operationID: operationID,
                outcome: .failed(.persistence)
            )
            if createOperationID == operationID, addSessionID == sessionID {
                publishFailure(.categoryCreateFailed)
            }
        }
        finishCreateIfCurrent(operationID)
    }

    func beginRename(categoryID: String) {
        guard !(isRenaming && editingCategoryID == categoryID),
              let category = categories.first(where: { $0.id == categoryID }),
              !category.isSystemCategory else { return }
        renameSessionID = UUID()
        editingCategoryID = categoryID
        editedCategoryName = category.name
        renameDismissalID = nil
        failure = nil
    }

    func saveRename() async {
        guard renameOperationID == nil,
              let categoryID = editingCategoryID,
              let sessionID = renameSessionID,
              Self.isValid(name: editedCategoryName) else { return }
        let name = editedCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let operationID = UUID()
        renameOperationID = operationID
        isRenaming = true
        failure = nil
        logStarted(.categoryRename, operationID: operationID)
        do {
            try await organization.renameCategory(id: categoryID, to: name)
            logFinished(.categoryRename, operationID: operationID, outcome: .succeeded)
            if renameOperationID == operationID,
               renameSessionID == sessionID,
               editingCategoryID == categoryID {
                renameDismissalID = categoryID
            }
        } catch is CancellationError {
            logFinished(.categoryRename, operationID: operationID, outcome: .cancelled)
        } catch {
            logFinished(
                .categoryRename,
                operationID: operationID,
                outcome: .failed(.persistence)
            )
            if renameOperationID == operationID,
               renameSessionID == sessionID,
               editingCategoryID == categoryID {
                publishFailure(.categoryRenameFailed)
            }
        }
        if renameOperationID == operationID {
            renameOperationID = nil
            isRenaming = false
        }
    }

    func consumeRenameDismissal(categoryID: String) {
        guard renameDismissalID == categoryID else { return }
        renameDismissalID = nil
        editingCategoryID = nil
        renameSessionID = nil
    }

    func endRename(categoryID: String) {
        guard editingCategoryID == categoryID else { return }
        editingCategoryID = nil
        renameSessionID = nil
        renameDismissalID = nil
    }

    func requestDelete(categoryID: String) {
        guard !isDeleting,
              categories.contains(where: { $0.id == categoryID && !$0.isSystemCategory }) else {
            return
        }
        failure = nil
        categoryPendingDeletionID = categoryID
    }

    func cancelDelete() {
        categoryPendingDeletionID = nil
    }

    func confirmDelete() {
        guard deleteOperationID == nil,
              let categoryID = categoryPendingDeletionID,
              categories.contains(where: { $0.id == categoryID && !$0.isSystemCategory }) else {
            return
        }
        categoryPendingDeletionID = nil
        let operationID = UUID()
        deleteOperationID = operationID
        isDeleting = true
        failure = nil
        logStarted(.categoryDelete, operationID: operationID)
        deleteTask = Task { [weak self] in
            await self?.performDelete(categoryID: categoryID, operationID: operationID)
        }
    }

    private func performDelete(categoryID: String, operationID: UUID) async {
        do {
            try await organization.deleteCategory(id: categoryID)
            logFinished(.categoryDelete, operationID: operationID, outcome: .succeeded)
        } catch is CancellationError {
            logFinished(.categoryDelete, operationID: operationID, outcome: .cancelled)
        } catch {
            logFinished(
                .categoryDelete,
                operationID: operationID,
                outcome: .failed(.persistence)
            )
            if deleteOperationID == operationID {
                publishFailure(.categoryDeleteFailed)
            }
        }
        if deleteOperationID == operationID {
            deleteOperationID = nil
            isDeleting = false
            deleteTask = nil
        }
    }

    func moveUserCategories(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let currentIDs = userCategories.map(\.id)
        let movedIDs = Self.moving(currentIDs, fromOffsets: offsets, toOffset: destination)
        guard movedIDs != currentIDs else { return }
        pendingUserCategoryIDs = movedIDs
        queuedReorderIDs = movedIDs
        guard reorderTask == nil else { return }
        isReordering = true
        reorderTask = Task { [weak self] in
            await self?.drainReorders()
        }
    }

    func dismissFailure() {
        failure = nil
    }

    private func drainReorders() async {
        while !Task.isCancelled, let requestedIDs = queuedReorderIDs {
            queuedReorderIDs = nil
            let operationID = UUID()
            logStarted(.categoryReorder, operationID: operationID)
            do {
                try await organization.reorderCategories(userCategoryIDs: requestedIDs)
                logFinished(.categoryReorder, operationID: operationID, outcome: .succeeded)
                if queuedReorderIDs == nil, pendingUserCategoryIDs == requestedIDs {
                    pendingUserCategoryIDs = nil
                }
            } catch is CancellationError {
                logFinished(.categoryReorder, operationID: operationID, outcome: .cancelled)
                break
            } catch {
                logFinished(
                    .categoryReorder,
                    operationID: operationID,
                    outcome: .failed(.persistence)
                )
                if queuedReorderIDs == nil, pendingUserCategoryIDs == requestedIDs {
                    pendingUserCategoryIDs = nil
                    publishFailure(.categoryReorderFailed)
                }
            }
        }
        reorderTask = nil
        isReordering = false
    }

    private func apply(_ snapshot: LibraryOrganizationSnapshot) {
        categories = snapshot.categories
        let existingIDs = Set(categories.map(\.id))
        if let categoryPendingDeletionID,
           !existingIDs.contains(categoryPendingDeletionID) {
            self.categoryPendingDeletionID = nil
        }
        if let editingCategoryID, !existingIDs.contains(editingCategoryID) {
            self.editingCategoryID = nil
            renameSessionID = nil
            renameDismissalID = nil
        }
        if let pendingUserCategoryIDs {
            let userIDs = Set(categories.filter { !$0.isSystemCategory }.map(\.id))
            if Set(pendingUserCategoryIDs) != userIDs {
                self.pendingUserCategoryIDs = nil
                queuedReorderIDs = nil
            }
        }
    }

    private func finishCreateIfCurrent(_ operationID: UUID) {
        guard createOperationID == operationID else { return }
        createOperationID = nil
        isCreating = false
    }

    private func publishFailure(_ message: CategoryHistoryMessage) {
        failure = message
        messagePresenter.present(message)
    }

    private func logStarted(_ kind: PresentationEventKind, operationID: UUID) {
        presentationLogger.log(
            .started(feature: .categorySettings, kind: kind, operationID: operationID)
        )
    }

    private func logFinished(
        _ kind: PresentationEventKind,
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        presentationLogger.log(
            .finished(
                feature: .categorySettings,
                kind: kind,
                operationID: operationID,
                outcome: outcome
            )
        )
    }

    nonisolated private static func isValid(name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated private static func moving(
        _ values: [String],
        fromOffsets offsets: IndexSet,
        toOffset destination: Int
    ) -> [String] {
        let validOffsets = offsets.filter { values.indices.contains($0) }.sorted()
        guard !validOffsets.isEmpty else { return values }
        let movingValues = validOffsets.map { values[$0] }
        let movingSet = Set(validOffsets)
        var remaining = values.enumerated()
            .filter { !movingSet.contains($0.offset) }
            .map(\.element)
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = min(max(0, destination - removedBeforeDestination), remaining.count)
        remaining.insert(contentsOf: movingValues, at: insertionIndex)
        return remaining
    }
}
