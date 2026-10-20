import Combine
import Foundation

struct LibraryOrganizationSnapshot: Equatable, Sendable {
    let categories: [LibraryCategory]
    let links: [ItemCategoryLink]
}

@MainActor
protocol LibraryOrganizationServing: AnyObject {
    var organizationSnapshot: LibraryOrganizationSnapshot { get }
    var organizationSnapshotPublisher: AnyPublisher<LibraryOrganizationSnapshot, Never> { get }

    func createCategory(name: String) async throws -> String
    func renameCategory(id: String, to name: String) async throws
    func deleteCategory(id: String) async throws
    func reorderCategories(userCategoryIDs: [String]) async throws
    func toggleCategory(forItemID itemID: String, categoryID: String) async throws
    func createCategoryAndAssign(name: String, itemID: String) async throws -> String
}

extension LibraryManager: LibraryOrganizationServing {
    var organizationSnapshot: LibraryOrganizationSnapshot {
        LibraryOrganizationSnapshot(categories: categories, links: links)
    }

    var organizationSnapshotPublisher: AnyPublisher<LibraryOrganizationSnapshot, Never> {
        Publishers.CombineLatest($categories, $links)
            .map { LibraryOrganizationSnapshot(categories: $0, links: $1) }
            .eraseToAnyPublisher()
    }

    func deleteCategory(id: String) async throws {
        try await deleteCategoryDurably(id: id)
    }

    func reorderCategories(userCategoryIDs: [String]) async throws {
        try await reorderCategoriesDurably(userCategoryIDs: userCategoryIDs)
    }

    func toggleCategory(forItemID itemID: String, categoryID: String) async throws {
        try await toggleCategoryDurably(forItemID: itemID, categoryID: categoryID)
    }

    func createCategoryAndAssign(name: String, itemID: String) async throws -> String {
        try await createCategoryAndAssignDurably(name: name, itemID: itemID)
    }
}

@MainActor
protocol HistoryServing: AnyObject {
    var historySnapshot: [HistoryEntry] { get }
    var historySnapshotPublisher: AnyPublisher<[HistoryEntry], Never> { get }

    func removeEntry(id: String) async throws
    func clearHistory() async throws
}

extension HistoryManager: HistoryServing {
    var historySnapshot: [HistoryEntry] { history }

    var historySnapshotPublisher: AnyPublisher<[HistoryEntry], Never> {
        $history.eraseToAnyPublisher()
    }

    func removeEntry(id: String) async throws {
        try await removeEntryDurably(id: id)
    }

    func clearHistory() async throws {
        try await clearHistoryDurably()
    }
}

enum CategoryHistoryMessage: Equatable {
    case categoryCreateFailed
    case categoryRenameFailed
    case categoryDeleteFailed
    case categoryReorderFailed
    case categoryAssignmentFailed
    case categoryCreateAndAssignFailed
    case historyDeleteFailed
    case historyClearFailed

    var alertTitle: String {
        switch self {
        case .categoryCreateFailed, .categoryCreateAndAssignFailed:
            return "List Not Created"
        case .categoryRenameFailed:
            return "List Not Renamed"
        case .categoryDeleteFailed:
            return "List Not Deleted"
        case .categoryReorderFailed:
            return "Lists Not Reordered"
        case .categoryAssignmentFailed:
            return "List Assignment Not Saved"
        case .historyDeleteFailed:
            return "History Item Not Deleted"
        case .historyClearFailed:
            return "History Not Cleared"
        }
    }

    var alertMessage: String {
        switch self {
        case .categoryCreateFailed:
            return "Your list couldn't be created. Please try again."
        case .categoryRenameFailed:
            return "Your list couldn't be renamed. Please try again."
        case .categoryDeleteFailed:
            return "Your list couldn't be deleted. Please try again."
        case .categoryReorderFailed:
            return "Your list order couldn't be saved. Please try again."
        case .categoryAssignmentFailed:
            return "The list assignment couldn't be saved. Please try again."
        case .categoryCreateAndAssignFailed:
            return "The new list and assignment couldn't be saved. Please try again."
        case .historyDeleteFailed:
            return "The history item couldn't be deleted. Please try again."
        case .historyClearFailed:
            return "Your history couldn't be cleared. Please try again."
        }
    }
}

@MainActor
protocol CategoryHistoryMessagePresenting: AnyObject {
    func present(_ message: CategoryHistoryMessage)
}

@MainActor
final class AppMessageCategoryHistoryPresenter: CategoryHistoryMessagePresenting {
    private let messageCenter: AppMessageCenter

    init(messageCenter: AppMessageCenter) {
        self.messageCenter = messageCenter
    }

    func present(_ message: CategoryHistoryMessage) {
        switch message {
        case .categoryCreateFailed:
            messageCenter.publish(.categoryCreateFailed)
        case .categoryRenameFailed:
            messageCenter.publish(.categoryRenameFailed)
        case .categoryDeleteFailed:
            messageCenter.publish(.categoryDeleteFailed)
        case .categoryReorderFailed:
            messageCenter.publish(.categoryReorderFailed)
        case .categoryAssignmentFailed:
            messageCenter.publish(.categoryAssignmentFailed)
        case .categoryCreateAndAssignFailed:
            messageCenter.publish(.categoryCreateAndAssignFailed)
        case .historyDeleteFailed:
            messageCenter.publish(.historyDeleteFailed)
        case .historyClearFailed:
            messageCenter.publish(.historyClearFailed)
        }
    }
}

/// Names the source a history entry was read on.
@MainActor
protocol HistorySourceNaming: AnyObject {
    func displayName(for pluginID: String) -> String?
}

extension PluginManager: HistorySourceNaming {}

@MainActor
struct PreparedCategoryHistoryDependencies {
    let organization: any LibraryOrganizationServing
    let history: any HistoryServing
    let sourceNames: any HistorySourceNaming

    static func production(
        libraryManager: LibraryManager,
        historyManager: HistoryManager,
        pluginManager: PluginManager
    ) -> Self {
        Self(organization: libraryManager, history: historyManager, sourceNames: pluginManager)
    }

    static func unavailable() -> Self {
        let dependency = UnavailableCategoryHistoryDependency()
        return Self(organization: dependency, history: dependency, sourceNames: dependency)
    }
}

private enum UnavailableCategoryHistoryDependencyError: Error {
    case unavailable
}

@MainActor
private final class UnavailableCategoryHistoryDependency: LibraryOrganizationServing,
    HistoryServing, HistorySourceNaming {
    let organizationSnapshot = LibraryOrganizationSnapshot(categories: [], links: [])
    let historySnapshot: [HistoryEntry] = []

    var organizationSnapshotPublisher: AnyPublisher<LibraryOrganizationSnapshot, Never> {
        Just(organizationSnapshot).eraseToAnyPublisher()
    }

    var historySnapshotPublisher: AnyPublisher<[HistoryEntry], Never> {
        Just(historySnapshot).eraseToAnyPublisher()
    }

    func displayName(for pluginID: String) -> String? {
        _ = pluginID
        return nil
    }

    func createCategory(name: String) async throws -> String {
        _ = name
        throw UnavailableCategoryHistoryDependencyError.unavailable
    }

    func renameCategory(id: String, to name: String) async throws {
        _ = id
        _ = name
        throw UnavailableCategoryHistoryDependencyError.unavailable
    }

    func deleteCategory(id: String) async throws {
        _ = id
        throw UnavailableCategoryHistoryDependencyError.unavailable
    }

    func reorderCategories(userCategoryIDs: [String]) async throws {
        _ = userCategoryIDs
        throw UnavailableCategoryHistoryDependencyError.unavailable
    }

    func toggleCategory(forItemID itemID: String, categoryID: String) async throws {
        _ = itemID
        _ = categoryID
        throw UnavailableCategoryHistoryDependencyError.unavailable
    }

    func createCategoryAndAssign(name: String, itemID: String) async throws -> String {
        _ = name
        _ = itemID
        throw UnavailableCategoryHistoryDependencyError.unavailable
    }

    func removeEntry(id: String) async throws {
        _ = id
        throw UnavailableCategoryHistoryDependencyError.unavailable
    }

    func clearHistory() async throws {
        throw UnavailableCategoryHistoryDependencyError.unavailable
    }
}
