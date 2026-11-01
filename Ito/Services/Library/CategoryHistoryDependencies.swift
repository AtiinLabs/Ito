import Combine
import Foundation
import OSLog
import ito_runner

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

    func removeChapter(_ series: HistorySeriesKey, chapterKey: String) async throws
    func removeSeries(_ series: HistorySeriesKey) async throws
    func clearHistory() async throws
}

extension HistoryManager: HistoryServing {
    var historySnapshot: [HistoryEntry] { history }

    var historySnapshotPublisher: AnyPublisher<[HistoryEntry], Never> {
        $history.eraseToAnyPublisher()
    }

    func removeChapter(_ series: HistorySeriesKey, chapterKey: String) async throws {
        try await removeChapterDurably(series, chapterKey: chapterKey)
    }

    func removeSeries(_ series: HistorySeriesKey) async throws {
        try await removeSeriesDurably(series)
    }

    func clearHistory() async throws {
        try await clearHistoryDurably()
    }
}

/// Whether a chapter in history has been read or watched to the end.
@MainActor
protocol HistoryProgressReading: AnyObject {
    /// Fires before read progress changes.
    var progressWillChange: AnyPublisher<Void, Never> { get }

    func isFinished(_ series: HistorySeriesKey, chapterKey: String, chapterNumber: Float?) -> Bool
}

extension ReadProgressManager: HistoryProgressReading {
    var progressWillChange: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    func isFinished(_ series: HistorySeriesKey, chapterKey: String, chapterNumber: Float?) -> Bool {
        isRead(
            media: MediaIdentity(pluginId: series.pluginId, canonicalMediaId: series.mediaKey, mediaKind: series.mediaKind),
            chapterId: chapterKey,
            chapterNum: chapterNumber
        )
    }
}

/// What opening a series from history shows: its saved library item, else one made from what
/// history recorded, which the series' screen then loads in full from its source.
@MainActor
protocol HistoryLibraryLookup: AnyObject {
    func libraryItem(for record: ReadingHistoryRecord) -> LibraryItem?
}

extension LibraryManager: HistoryLibraryLookup {
    func libraryItem(for record: ReadingHistoryRecord) -> LibraryItem? {
        let media = MediaIdentity(pluginId: record.pluginId, canonicalMediaId: record.mediaKey, mediaKind: record.mediaKind)
        if let saved = items.first(where: { $0.mediaIdentity == media }) {
            return saved
        }
        do {
            return try LibraryItem.unsaved(from: record)
        } catch {
            AppLogger.general.error("[History] Could not prepare a series to open: \(error)")
            return nil
        }
    }
}

extension LibraryItem {
    /// A series that is not in the library, as history recorded it.
    static func unsaved(from record: ReadingHistoryRecord) throws -> LibraryItem {
        let encoder = JSONEncoder()
        let payload: Data = switch record.mediaKind {
        case .manga: try encoder.encode(Manga(key: record.mediaKey, title: record.title, cover: record.coverUrl))
        case .novel: try encoder.encode(Novel(key: record.mediaKey, title: record.title, cover: record.coverUrl))
        case .anime: try encoder.encode(Anime(key: record.mediaKey, title: record.title, cover: record.coverUrl))
        }
        return LibraryItem(
            id: record.mediaKey,
            title: record.title,
            coverUrl: record.coverUrl,
            pluginId: record.pluginId,
            isAnime: record.mediaKind == .anime,
            pluginType: record.mediaKind,
            rawPayload: payload,
            anilistId: nil
        )
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
            return String(localized: "List Not Created")
        case .categoryRenameFailed:
            return String(localized: "List Not Renamed")
        case .categoryDeleteFailed:
            return String(localized: "List Not Deleted")
        case .categoryReorderFailed:
            return String(localized: "Lists Not Reordered")
        case .categoryAssignmentFailed:
            return String(localized: "List Assignment Not Saved")
        case .historyDeleteFailed:
            return String(localized: "History Item Not Deleted")
        case .historyClearFailed:
            return String(localized: "History Not Cleared")
        }
    }

    var alertMessage: String {
        switch self {
        case .categoryCreateFailed:
            return String(localized: "Your list couldn't be created. Please try again.")
        case .categoryRenameFailed:
            return String(localized: "Your list couldn't be renamed. Please try again.")
        case .categoryDeleteFailed:
            return String(localized: "Your list couldn't be deleted. Please try again.")
        case .categoryReorderFailed:
            return String(localized: "Your list order couldn't be saved. Please try again.")
        case .categoryAssignmentFailed:
            return String(localized: "The list assignment couldn't be saved. Please try again.")
        case .categoryCreateAndAssignFailed:
            return String(localized: "The new list and assignment couldn't be saved. Please try again.")
        case .historyDeleteFailed:
            return String(localized: "The history item couldn't be deleted. Please try again.")
        case .historyClearFailed:
            return String(localized: "Your history couldn't be cleared. Please try again.")
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
    let progress: any HistoryProgressReading
    let libraryLookup: any HistoryLibraryLookup

    static func production(
        libraryManager: LibraryManager,
        historyManager: HistoryManager,
        pluginManager: PluginManager,
        readProgressManager: ReadProgressManager
    ) -> Self {
        Self(
            organization: libraryManager,
            history: historyManager,
            sourceNames: pluginManager,
            progress: readProgressManager,
            libraryLookup: libraryManager
        )
    }

    static func unavailable() -> Self {
        let dependency = UnavailableCategoryHistoryDependency()
        return Self(
            organization: dependency,
            history: dependency,
            sourceNames: dependency,
            progress: dependency,
            libraryLookup: dependency
        )
    }
}

private enum UnavailableCategoryHistoryDependencyError: Error {
    case unavailable
}

@MainActor
private final class UnavailableCategoryHistoryDependency: LibraryOrganizationServing,
    HistoryServing, HistorySourceNaming, HistoryProgressReading, HistoryLibraryLookup {
    let organizationSnapshot = LibraryOrganizationSnapshot(categories: [], links: [])
    let historySnapshot: [HistoryEntry] = []

    var organizationSnapshotPublisher: AnyPublisher<LibraryOrganizationSnapshot, Never> {
        Just(organizationSnapshot).eraseToAnyPublisher()
    }

    var historySnapshotPublisher: AnyPublisher<[HistoryEntry], Never> {
        Just(historySnapshot).eraseToAnyPublisher()
    }

    var progressWillChange: AnyPublisher<Void, Never> {
        Empty().eraseToAnyPublisher()
    }

    func displayName(for pluginID: String) -> String? {
        _ = pluginID
        return nil
    }

    func isFinished(_ series: HistorySeriesKey, chapterKey: String, chapterNumber: Float?) -> Bool {
        _ = series
        _ = chapterKey
        _ = chapterNumber
        return false
    }

    func libraryItem(for record: ReadingHistoryRecord) -> LibraryItem? {
        _ = record
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

    func removeChapter(_ series: HistorySeriesKey, chapterKey: String) async throws {
        _ = series
        _ = chapterKey
        throw UnavailableCategoryHistoryDependencyError.unavailable
    }

    func removeSeries(_ series: HistorySeriesKey) async throws {
        _ = series
        throw UnavailableCategoryHistoryDependencyError.unavailable
    }

    func clearHistory() async throws {
        throw UnavailableCategoryHistoryDependencyError.unavailable
    }
}
