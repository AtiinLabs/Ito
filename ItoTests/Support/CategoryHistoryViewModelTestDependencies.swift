import Combine
import Foundation
@testable import Ito

enum CategoryHistoryTestFailure: Error {
    case expected
}

@MainActor
final class CategoryHistoryMessageSpy: CategoryHistoryMessagePresenting {
    private(set) var messages: [CategoryHistoryMessage] = []

    func present(_ message: CategoryHistoryMessage) {
        messages.append(message)
    }
}

final class CategoryHistoryPresentationLogSpy: PresentationEventLogging {
    private(set) var events: [PresentationLogEvent] = []

    func log(_ event: PresentationLogEvent) {
        events.append(event)
    }
}

@MainActor
final class LibraryOrganizationFake: LibraryOrganizationServing {
    enum VoidResponse {
        case immediate(Result<Void, any Error>)
        case suspended
    }

    enum StringResponse {
        case immediate(Result<String, any Error>)
        case suspended
    }

    private let subject: CurrentValueSubject<LibraryOrganizationSnapshot, Never>
    var createResponses: [StringResponse] = []
    var renameResponses: [VoidResponse] = []
    var deleteResponses: [VoidResponse] = []
    var reorderResponses: [VoidResponse] = []
    var toggleResponses: [VoidResponse] = []
    var createAndAssignResponses: [StringResponse] = []

    private var createContinuations: [CheckedContinuation<String, any Error>] = []
    private var renameContinuations: [CheckedContinuation<Void, any Error>] = []
    private var deleteContinuations: [CheckedContinuation<Void, any Error>] = []
    private var reorderContinuations: [CheckedContinuation<Void, any Error>] = []
    private var toggleContinuations: [CheckedContinuation<Void, any Error>] = []
    private var createAndAssignContinuations: [CheckedContinuation<String, any Error>] = []

    private(set) var createdNames: [String] = []
    private(set) var renameRequests: [(id: String, name: String)] = []
    private(set) var deleteRequests: [String] = []
    private(set) var reorderRequests: [[String]] = []
    private(set) var toggleRequests: [(itemID: String, categoryID: String)] = []
    private(set) var createAndAssignRequests: [(name: String, itemID: String)] = []

    init(snapshot: LibraryOrganizationSnapshot = .init(categories: [], links: [])) {
        subject = CurrentValueSubject(snapshot)
    }

    var organizationSnapshot: LibraryOrganizationSnapshot { subject.value }

    var organizationSnapshotPublisher: AnyPublisher<LibraryOrganizationSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    var pendingCreateCount: Int { createContinuations.count }
    var pendingRenameCount: Int { renameContinuations.count }
    var pendingDeleteCount: Int { deleteContinuations.count }
    var pendingReorderCount: Int { reorderContinuations.count }
    var pendingToggleCount: Int { toggleContinuations.count }
    var pendingCreateAndAssignCount: Int { createAndAssignContinuations.count }

    func publish(categories: [LibraryCategory]? = nil, links: [ItemCategoryLink]? = nil) {
        subject.send(
            LibraryOrganizationSnapshot(
                categories: categories ?? subject.value.categories,
                links: links ?? subject.value.links
            )
        )
    }

    func createCategory(name: String) async throws -> String {
        createdNames.append(name)
        let defaultID = "created-\(createdNames.count)"
        let response = createResponses.isEmpty ? nil : createResponses.removeFirst()
        let categoryID: String
        switch response {
        case .immediate(let result):
            categoryID = try result.get()
        case .suspended:
            categoryID = try await withCheckedThrowingContinuation {
                createContinuations.append($0)
            }
        case nil:
            categoryID = defaultID
        }
        var categories = subject.value.categories
        let maxOrder = categories.map(\.sortOrder).max() ?? 0
        categories.append(LibraryCategory(id: categoryID, name: name, sortOrder: maxOrder + 1))
        publish(categories: categories)
        return categoryID
    }

    func renameCategory(id: String, to name: String) async throws {
        renameRequests.append((id, name))
        let response = renameResponses.isEmpty ? nil : renameResponses.removeFirst()
        switch response {
        case .immediate(let result):
            try result.get()
        case .suspended:
            try await withCheckedThrowingContinuation { renameContinuations.append($0) }
        case nil:
            break
        }
        var categories = subject.value.categories
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[index].name = name
        publish(categories: categories)
    }

    func deleteCategory(id: String) async throws {
        deleteRequests.append(id)
        let response = deleteResponses.isEmpty ? nil : deleteResponses.removeFirst()
        switch response {
        case .immediate(let result):
            try result.get()
        case .suspended:
            try await withCheckedThrowingContinuation { deleteContinuations.append($0) }
        case nil:
            break
        }
        publish(
            categories: subject.value.categories.filter { $0.id != id },
            links: subject.value.links.filter { $0.categoryId != id }
        )
    }

    func reorderCategories(userCategoryIDs: [String]) async throws {
        reorderRequests.append(userCategoryIDs)
        let response = reorderResponses.isEmpty ? nil : reorderResponses.removeFirst()
        switch response {
        case .immediate(let result):
            try result.get()
        case .suspended:
            try await withCheckedThrowingContinuation { reorderContinuations.append($0) }
        case nil:
            break
        }
        let categoriesByID = Dictionary(
            uniqueKeysWithValues: subject.value.categories.map { ($0.id, $0) }
        )
        var ordered = subject.value.categories.filter(\.isSystemCategory)
        ordered.append(contentsOf: userCategoryIDs.compactMap { categoriesByID[$0] })
        for index in ordered.indices {
            ordered[index].sortOrder = index
        }
        publish(categories: ordered)
    }

    func toggleCategory(forItemID itemID: String, categoryID: String) async throws {
        toggleRequests.append((itemID, categoryID))
        let response = toggleResponses.isEmpty ? nil : toggleResponses.removeFirst()
        switch response {
        case .immediate(let result):
            try result.get()
        case .suspended:
            try await withCheckedThrowingContinuation { toggleContinuations.append($0) }
        case nil:
            break
        }
        var links = subject.value.links
        if let index = links.firstIndex(where: {
            $0.itemId == itemID && $0.categoryId == categoryID
        }) {
            links.remove(at: index)
            if !links.contains(where: { $0.itemId == itemID }),
               let systemID = subject.value.categories.first(where: \.isSystemCategory)?.id {
                links.append(ItemCategoryLink(itemId: itemID, categoryId: systemID))
            }
        } else {
            links.append(ItemCategoryLink(itemId: itemID, categoryId: categoryID))
            let systemIDs = Set(subject.value.categories.filter(\.isSystemCategory).map(\.id))
            links.removeAll {
                $0.itemId == itemID && systemIDs.contains($0.categoryId)
            }
        }
        publish(links: links)
    }

    func createCategoryAndAssign(name: String, itemID: String) async throws -> String {
        createAndAssignRequests.append((name, itemID))
        let defaultID = "created-assigned-\(createAndAssignRequests.count)"
        let response = createAndAssignResponses.isEmpty
            ? nil
            : createAndAssignResponses.removeFirst()
        let categoryID: String
        switch response {
        case .immediate(let result):
            categoryID = try result.get()
        case .suspended:
            categoryID = try await withCheckedThrowingContinuation {
                createAndAssignContinuations.append($0)
            }
        case nil:
            categoryID = defaultID
        }
        var categories = subject.value.categories
        let maxOrder = categories.map(\.sortOrder).max() ?? 0
        categories.append(LibraryCategory(id: categoryID, name: name, sortOrder: maxOrder + 1))
        let systemIDs = Set(subject.value.categories.filter(\.isSystemCategory).map(\.id))
        var links = subject.value.links.filter {
            $0.itemId != itemID || !systemIDs.contains($0.categoryId)
        }
        links.append(ItemCategoryLink(itemId: itemID, categoryId: categoryID))
        publish(categories: categories, links: links)
        return categoryID
    }

    func resolveCreate(at index: Int, result: Result<String, any Error>) {
        createContinuations.remove(at: index).resume(with: result)
    }

    func resolveRename(at index: Int, result: Result<Void, any Error>) {
        renameContinuations.remove(at: index).resume(with: result)
    }

    func resolveDelete(at index: Int, result: Result<Void, any Error>) {
        deleteContinuations.remove(at: index).resume(with: result)
    }

    func resolveReorder(at index: Int, result: Result<Void, any Error>) {
        reorderContinuations.remove(at: index).resume(with: result)
    }

    func resolveToggle(at index: Int, result: Result<Void, any Error>) {
        toggleContinuations.remove(at: index).resume(with: result)
    }

    func resolveCreateAndAssign(at index: Int, result: Result<String, any Error>) {
        createAndAssignContinuations.remove(at: index).resume(with: result)
    }
}

@MainActor
final class HistorySourceNamesFake: HistorySourceNaming {
    var names: [String: String]

    init(names: [String: String] = [:]) {
        self.names = names
    }

    func displayName(for pluginID: String) -> String? {
        names[pluginID]
    }
}

@MainActor
final class HistoryServiceFake: HistoryServing {
    enum Response {
        case immediate(Result<Void, any Error>)
        case suspended
    }

    private let subject: CurrentValueSubject<[HistoryEntry], Never>
    var deleteResponses: [Response] = []
    var clearResponses: [Response] = []
    private var deleteContinuations: [CheckedContinuation<Void, any Error>] = []
    private var clearContinuations: [CheckedContinuation<Void, any Error>] = []
    private(set) var deleteRequests: [String] = []
    private(set) var clearRequestCount = 0

    init(history: [HistoryEntry] = []) {
        subject = CurrentValueSubject(history)
    }

    var historySnapshot: [HistoryEntry] { subject.value }

    var historySnapshotPublisher: AnyPublisher<[HistoryEntry], Never> {
        subject.eraseToAnyPublisher()
    }

    var pendingDeleteCount: Int { deleteContinuations.count }
    var pendingClearCount: Int { clearContinuations.count }

    func publish(_ history: [HistoryEntry]) {
        subject.send(history)
    }

    func removeEntry(id: String) async throws {
        deleteRequests.append(id)
        let response = deleteResponses.isEmpty ? nil : deleteResponses.removeFirst()
        switch response {
        case .immediate(let result):
            try result.get()
        case .suspended:
            try await withCheckedThrowingContinuation { deleteContinuations.append($0) }
        case nil:
            break
        }
        publish(subject.value.filter { $0.id != id })
    }

    func clearHistory() async throws {
        clearRequestCount += 1
        let response = clearResponses.isEmpty ? nil : clearResponses.removeFirst()
        switch response {
        case .immediate(let result):
            try result.get()
        case .suspended:
            try await withCheckedThrowingContinuation { clearContinuations.append($0) }
        case nil:
            break
        }
        publish([])
    }

    func resolveDelete(at index: Int, result: Result<Void, any Error>) {
        deleteContinuations.remove(at: index).resume(with: result)
    }

    func resolveClear(at index: Int, result: Result<Void, any Error>) {
        clearContinuations.remove(at: index).resume(with: result)
    }
}

func pr11bCategory(
    id: String,
    name: String? = nil,
    order: Int,
    isSystem: Bool = false
) -> LibraryCategory {
    LibraryCategory(
        id: id,
        name: name ?? id,
        sortOrder: order,
        isSystemCategory: isSystem,
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

func pr11bHistoryEntry(id: String, readAt: TimeInterval) -> HistoryEntry {
    HistoryEntry(
        record: ReadingHistoryRecord(
            id: id,
            mediaKey: "media-\(id)",
            title: "Title \(id)",
            coverUrl: nil,
            pluginId: "plugin",
            chapterKey: "chapter-\(id)",
            chapterTitle: "Chapter \(id)",
            readAt: Date(timeIntervalSince1970: readAt)
        )
    )
}
