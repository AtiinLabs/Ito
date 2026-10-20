import Combine
import Foundation

@MainActor
final class CategoryAssignmentViewModel: ObservableObject {
    let itemID: String

    @Published private(set) var categories: [LibraryCategory]
    @Published private(set) var links: [ItemCategoryLink]
    @Published var isAddCategoryPresented = false
    @Published var newCategoryName = ""
    @Published private(set) var newlyCreatedCategoryID: String?
    @Published private(set) var assigningCategoryIDs = Set<String>()
    @Published private(set) var isCreatingAndAssigning = false
    @Published private(set) var failure: CategoryHistoryMessage?

    private let organization: any LibraryOrganizationServing
    private let messagePresenter: any CategoryHistoryMessagePresenting
    private let presentationLogger: any PresentationEventLogging
    private var cancellables = Set<AnyCancellable>()
    private var assignmentOperationIDs: [String: UUID] = [:]
    private var createOperationID: UUID?
    private var addSessionID: UUID?
    private var isPresentationActive = true

    init(
        itemID: String,
        organization: any LibraryOrganizationServing,
        messagePresenter: any CategoryHistoryMessagePresenting,
        presentationLogger: any PresentationEventLogging
    ) {
        self.itemID = itemID
        self.organization = organization
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger
        let snapshot = organization.organizationSnapshot
        categories = snapshot.categories
        links = snapshot.links
        organization.organizationSnapshotPublisher
            .sink { [weak self] snapshot in
                self?.categories = snapshot.categories
                self?.links = snapshot.links
            }
            .store(in: &cancellables)
    }

    var userCategories: [LibraryCategory] {
        categories.filter { !$0.isSystemCategory }
    }

    var activeCategoryIDs: Set<String> {
        Set(links.lazy.filter { $0.itemId == self.itemID }.map(\.categoryId))
    }

    var canCreateAndAssign: Bool {
        !isCreatingAndAssigning
            && !newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isAssigned(to categoryID: String) -> Bool {
        activeCategoryIDs.contains(categoryID)
    }

    func presentAddCategory() {
        guard !isCreatingAndAssigning else { return }
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

    func toggleCategory(categoryID: String) async {
        guard isPresentationActive,
              assignmentOperationIDs[categoryID] == nil,
              userCategories.contains(where: { $0.id == categoryID }) else { return }
        let operationID = UUID()
        assignmentOperationIDs[categoryID] = operationID
        assigningCategoryIDs.insert(categoryID)
        failure = nil
        logStarted(.categoryAssignment, operationID: operationID)
        do {
            try await organization.toggleCategory(forItemID: itemID, categoryID: categoryID)
            logFinished(.categoryAssignment, operationID: operationID, outcome: .succeeded)
        } catch is CancellationError {
            logFinished(.categoryAssignment, operationID: operationID, outcome: .cancelled)
        } catch {
            logFinished(
                .categoryAssignment,
                operationID: operationID,
                outcome: .failed(.persistence)
            )
            if isPresentationActive, assignmentOperationIDs[categoryID] == operationID {
                publishFailure(.categoryAssignmentFailed)
            }
        }
        if assignmentOperationIDs[categoryID] == operationID {
            assignmentOperationIDs[categoryID] = nil
            assigningCategoryIDs.remove(categoryID)
        }
    }

    func createAndAssignCategory() async {
        guard isPresentationActive,
              createOperationID == nil,
              isAddCategoryPresented,
              let sessionID = addSessionID,
              canCreateAndAssign else { return }
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let operationID = UUID()
        createOperationID = operationID
        isCreatingAndAssigning = true
        failure = nil
        logStarted(.categoryCreateAndAssign, operationID: operationID)
        do {
            let categoryID = try await organization.createCategoryAndAssign(
                name: name,
                itemID: itemID
            )
            logFinished(
                .categoryCreateAndAssign,
                operationID: operationID,
                outcome: .succeeded
            )
            if isPresentationActive,
               createOperationID == operationID,
               addSessionID == sessionID,
               isAddCategoryPresented {
                newlyCreatedCategoryID = categoryID
                newCategoryName = ""
                isAddCategoryPresented = false
                addSessionID = nil
            }
        } catch is CancellationError {
            logFinished(.categoryCreateAndAssign, operationID: operationID, outcome: .cancelled)
        } catch {
            logFinished(
                .categoryCreateAndAssign,
                operationID: operationID,
                outcome: .failed(.persistence)
            )
            if isPresentationActive,
               createOperationID == operationID,
               addSessionID == sessionID {
                publishFailure(.categoryCreateAndAssignFailed)
            }
        }
        if createOperationID == operationID {
            createOperationID = nil
            isCreatingAndAssigning = false
        }
    }

    func consumeNewlyCreatedCategoryID(_ categoryID: String) {
        guard newlyCreatedCategoryID == categoryID else { return }
        newlyCreatedCategoryID = nil
    }

    func dismissFailure() {
        failure = nil
    }

    func dismissPresentation() {
        isPresentationActive = false
        addSessionID = UUID()
        isAddCategoryPresented = false
        newCategoryName = ""
        newlyCreatedCategoryID = nil
        failure = nil
    }

    private func publishFailure(_ message: CategoryHistoryMessage) {
        failure = message
        messagePresenter.present(message)
    }

    private func logStarted(_ kind: PresentationEventKind, operationID: UUID) {
        presentationLogger.log(
            .started(feature: .categoryAssignment, kind: kind, operationID: operationID)
        )
    }

    private func logFinished(
        _ kind: PresentationEventKind,
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        presentationLogger.log(
            .finished(
                feature: .categoryAssignment,
                kind: kind,
                operationID: operationID,
                outcome: outcome
            )
        )
    }
}
