import Combine
import Foundation
import UIKit

struct LibraryPresentationGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let isSystem: Bool
    let items: [LibraryItem]
}

struct LibraryCategoryPresentation: Identifiable, Equatable {
    let id: String
    let name: String
}

/// A removal waiting for the user's confirmation. Whether the series holds downloads is fixed when it is
/// requested, so the dialog and the removal agree on what was shown.
struct LibraryRemovalRequest: Equatable {
    let item: LibraryItem
    /// The series holds a copy of any state, or a queue entry.
    let hasDownloads: Bool
    /// Its verified saved chapters.
    let savedChapterCount: Int

    /// Reading history and progress are kept either way. The dialog shows this one message above all its
    /// buttons, so it says which button keeps the downloads; Remove Library and Downloads deletes them.
    var message: String {
        switch (hasDownloads, savedChapterCount > 0) {
        case (false, _):
            return String(
                localized: "\(item.title) is also removed from your lists. Reading history and progress are kept.",
                comment: "Confirm removing a series from the Library. The placeholder is the series title."
            )
        case (true, true):
            return String(
                localized: "\(item.title) is also removed from your lists. Reading history and progress are kept. Remove from Library keeps its \(savedChapterCount) downloaded chapters.",
                comment: "Confirm removing a series that has saved chapters. The dialog also has a Remove Library and Downloads button that deletes them, so the keeping is tied to the Remove from Library button. The first placeholder is the series title, the second the number of saved chapters."
            )
        case (true, false):
            return String(
                localized: "\(item.title) is also removed from your lists. Reading history and progress are kept. Remove from Library keeps its downloads.",
                comment: "Confirm removing a series whose downloads are damaged or still queued. The dialog also has a Remove Library and Downloads button that deletes them, so the keeping is tied to the Remove from Library button. The placeholder is the series title."
            )
        }
    }
}

struct LibraryExportPresentation: Identifiable {
    let id: UUID
    let document: BackupDocument
    let defaultFilename: String
}

enum LibraryAlert: Equatable {
    case exportGenerationFailed
    case exporterFailed

    var title: String { String(localized: "Backup Error") }

    var message: String {
        switch self {
        case .exportGenerationFailed:
            return String(localized: "The library backup could not be generated. Please try again.")
        case .exporterFailed:
            return String(localized: "The library backup could not be exported. Please try again.")
        }
    }
}

@MainActor
final class LibraryViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case empty
        case content
    }

    @Published private(set) var snapshot: LibraryRootSnapshot {
        didSet { categoryMembers = Self.members(of: snapshot) }
    }
    /// Series IDs per list ID, rebuilt with each snapshot.
    private var categoryMembers: [String: Set<String>]
    @Published var searchText = ""
    @Published private(set) var layoutStyle: LibraryLayoutStyle
    @Published private(set) var selectedCategoryID: String?
    @Published private(set) var isEditing = false
    @Published private(set) var categoryAssignmentItemID: String?
    @Published private(set) var pendingRemoval: LibraryRemovalRequest?
    @Published private(set) var removingItemIDs: Set<String> = []
    @Published private(set) var updateSnapshot: LibraryUpdateSnapshot
    @Published private(set) var installedPluginIDs: Set<String>
    @Published private(set) var isGeneratingExport = false
    @Published private(set) var exportPresentation: LibraryExportPresentation?
    @Published private(set) var alert: LibraryAlert?
    /// Whether the device reports no network. The Library says so and keeps showing what is saved.
    @Published private(set) var isOffline: Bool
    /// Saved chapters per series and which series hold downloads, from one observation of the whole Library.
    @Published private(set) var downloadSummary: LibraryDownloadSummary

    private let dependencies: PreparedLibraryDependencies
    private let tabRouter: any LibraryTabRouting
    private let messagePresenter: any LibraryMessagePresenting
    private let presentationLogger: any PresentationEventLogging

    private var authoritativeLayoutStyle: LibraryLayoutStyle
    private var intendedLayoutStyle: LibraryLayoutStyle?
    private var layoutOperationID: UUID?
    private var layoutTask: Task<Void, Never>?
    private var removalOperationIDs: [String: UUID] = [:]
    private var removalTasks: [String: Task<Void, Never>] = [:]
    private var badgeOperationIDs: [MediaIdentity: UUID] = [:]
    private var badgeTasks: [MediaIdentity: Task<Void, Never>] = [:]
    private var updateOperationID: UUID?
    private var updateTask: Task<Void, Never>?
    private var exportOperationID: UUID?
    private var exportTask: Task<Void, Never>?
    private var isVisible = false
    private var lastPresentedDiscordCategoryName: String?
    private var hasPresentedDiscord = false
    private var cancellables: Set<AnyCancellable> = []

    init(
        dependencies: PreparedLibraryDependencies,
        tabRouter: any LibraryTabRouting,
        messagePresenter: any LibraryMessagePresenting,
        presentationLogger: any PresentationEventLogging
    ) {
        self.dependencies = dependencies
        self.tabRouter = tabRouter
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger
        snapshot = dependencies.library.rootSnapshot
        categoryMembers = Self.members(of: dependencies.library.rootSnapshot)
        let initialLayout = Self.layoutStyle(from: dependencies.layout.storedLibraryLayoutStyle)
        authoritativeLayoutStyle = initialLayout
        layoutStyle = initialLayout
        updateSnapshot = dependencies.updates.libraryUpdateSnapshot
        installedPluginIDs = Set(dependencies.plugins.libraryPluginSnapshot.plugins.keys)
        isOffline = dependencies.connectivity.isOffline
        downloadSummary = dependencies.downloads.downloadSummary

        dependencies.library.rootSnapshotPublisher
            .sink { [weak self] snapshot in
                self?.applyLibrarySnapshot(snapshot)
            }
            .store(in: &cancellables)
        dependencies.layout.storedLibraryLayoutStylePublisher
            .sink { [weak self] rawValue in
                self?.applyAuthoritativeLayout(rawValue)
            }
            .store(in: &cancellables)
        dependencies.updates.libraryUpdateSnapshotPublisher
            .sink { [weak self] snapshot in
                self?.updateSnapshot = snapshot
            }
            .store(in: &cancellables)
        dependencies.plugins.libraryPluginSnapshotPublisher
            .sink { [weak self] snapshot in
                self?.installedPluginIDs = Set(snapshot.plugins.keys)
            }
            .store(in: &cancellables)
        dependencies.connectivity.isOfflinePublisher
            .sink { [weak self] isOffline in
                self?.isOffline = isOffline
            }
            .store(in: &cancellables)
        dependencies.downloads.downloadSummaryPublisher
            .sink { [weak self] summary in
                self?.downloadSummary = summary
            }
            .store(in: &cancellables)
    }

    deinit {
        layoutTask?.cancel()
        removalTasks.values.forEach { $0.cancel() }
        badgeTasks.values.forEach { $0.cancel() }
        updateTask?.cancel()
        exportTask?.cancel()
    }

    var phase: Phase {
        if snapshot.isLoading { return .loading }
        return snapshot.items.isEmpty ? .empty : .content
    }

    var filteredItems: [LibraryItem] {
        guard !searchText.isEmpty else { return snapshot.items }
        return snapshot.items.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var categories: [LibraryCategoryPresentation] {
        snapshot.categories.map {
            LibraryCategoryPresentation(id: $0.id, name: $0.displayName)
        }
    }

    var groups: [LibraryPresentationGroup] {
        let items = filteredItems
        return snapshot.categories.compactMap { category in
            if layoutStyle == .tabbed,
               let selectedCategoryID,
               selectedCategoryID != category.id {
                return nil
            }
            let memberIDs = categoryMembers[category.id] ?? []
            let categoryItems = items.filter { memberIDs.contains($0.id) }
            if layoutStyle == .sectioned,
               categoryItems.isEmpty,
               snapshot.categories.count > 1 {
                return nil
            }
            return LibraryPresentationGroup(
                id: category.id,
                name: category.displayName,
                isSystem: category.isSystemCategory,
                items: categoryItems
            )
        }
    }

    private static func members(of snapshot: LibraryRootSnapshot) -> [String: Set<String>] {
        snapshot.links.reduce(into: [:]) { members, link in
            members[link.categoryId, default: []].insert(link.itemId)
        }
    }

    /// Whether a search matches nothing on screen. "All" in the tabbed layout lists every series,
    /// while the other views list the series of each list.
    var showsNoResults: Bool {
        guard !searchText.isEmpty else { return false }
        if layoutStyle == .tabbed && selectedCategoryID == nil {
            return filteredItems.isEmpty
        }
        return groups.allSatisfy(\.items.isEmpty)
    }

    var updateProgressCurrent: Int { updateSnapshot.current }
    var updateProgressTotal: Int { updateSnapshot.total }
    var isRefreshing: Bool { updateSnapshot.isRefreshing }
    var updateFailures: [LibraryUpdateFailure] {
        updateSnapshot.sourceFailures.sorted { $0.pluginID < $1.pluginID }
    }
    var hasItems: Bool { !snapshot.items.isEmpty }

    func isPluginInstalled(for item: LibraryItem) -> Bool {
        installedPluginIDs.contains(item.pluginId)
    }

    func badgeCount(for item: LibraryItem) -> Int {
        updateSnapshot.badgeCount(for: mediaIdentity(for: item))
    }

    /// Keeps the cover a card displayed, so the card can show it again without the network.
    func coverLoaded(for item: LibraryItem, image: UIImage) {
        guard let coverUrl = item.coverUrl else { return }
        dependencies.coverThumbnails.capture(itemID: item.id, coverUrl: coverUrl, image: image)
    }

    /// The durable cover of a card whose cover could not be loaded from the network cache. It is used only
    /// while it was captured for the card's current cover address.
    func durableCover(for item: LibraryItem) async -> UIImage? {
        guard let coverUrl = item.coverUrl,
              let cover = await dependencies.coverThumbnails.thumbnail(for: item.id),
              cover.coverURLSHA256 == LibraryCoverThumbnailStore.coverHash(coverUrl) else { return nil }
        return cover.image
    }

    func selectCategory(_ categoryID: String?) {
        guard categoryID == nil || snapshot.categories.contains(where: { $0.id == categoryID }) else {
            return
        }
        guard selectedCategoryID != categoryID else { return }
        selectedCategoryID = categoryID
        presentDiscordIfNeeded()
    }

    func toggleEditing() {
        guard hasItems else {
            isEditing = false
            return
        }
        isEditing.toggle()
    }

    func presentCategoryAssignment(for itemID: String) {
        guard snapshot.items.contains(where: { $0.id == itemID }) else { return }
        categoryAssignmentItemID = itemID
    }

    func dismissCategoryAssignment() {
        categoryAssignmentItemID = nil
    }

    func browseDiscover() {
        tabRouter.showDiscover()
    }

    func toggleLayout() {
        let requested: LibraryLayoutStyle = layoutStyle == .sectioned ? .tabbed : .sectioned
        intendedLayoutStyle = requested
        layoutStyle = requested
        guard layoutTask == nil else { return }
        startLayoutPersistence(requested)
    }

    private func startLayoutPersistence(_ requested: LibraryLayoutStyle) {
        let operationID = UUID()
        layoutOperationID = operationID
        logStarted(kind: .preferenceWrite, operationID: operationID)
        let layout = dependencies.layout
        layoutTask = Task { @MainActor [weak self, layout] in
            do {
                try await layout.persistLibraryLayoutStyle(requested.rawValue)
                self?.publishLayoutCompletion(
                    operationID: operationID,
                    requested: requested,
                    succeeded: true
                )
            } catch {
                self?.publishLayoutCompletion(
                    operationID: operationID,
                    requested: requested,
                    succeeded: false
                )
            }
        }
    }

    /// Asks the user to confirm removing a series. Whether it holds downloads is read now, so the dialog and
    /// the removal agree on what the user was shown.
    func requestRemoval(_ item: LibraryItem) {
        guard removalOperationIDs[item.id] == nil, contains(item) else { return }
        let media = item.mediaIdentity
        pendingRemoval = LibraryRemovalRequest(
            item: item,
            hasDownloads: downloadSummary.mediaWithDownloads.contains(media),
            savedChapterCount: downloadSummary.savedCount(for: media)
        )
    }

    func cancelRemoval() {
        pendingRemoval = nil
    }

    /// Removes the series the confirmation dialog presented. The dialog may already have reset
    /// `pendingRemoval` while dismissing, so the request comes from the dialog, and `remove` re-checks that
    /// the series is still in the library. `includingDownloads` also deletes its downloads, when the dialog
    /// showed that it had any.
    func confirmRemoval(_ request: LibraryRemovalRequest, includingDownloads: Bool) {
        if pendingRemoval == request { pendingRemoval = nil }
        remove(request.item, includingDownloads: includingDownloads && request.hasDownloads)
    }

    /// Saved chapters on a card. Zero hides the count, including when there is no offline store.
    func savedCount(for item: LibraryItem) -> Int {
        downloadSummary.savedCount(for: item.mediaIdentity)
    }

    private func contains(_ item: LibraryItem) -> Bool {
        snapshot.items.contains { $0.id == item.id && $0.pluginId == item.pluginId }
    }

    private enum RemovalResult {
        case removed
        case removedButDownloadsRemain
        case libraryFailed
    }

    /// The Library removal commits first. Only when it has, are the downloads deleted, so a Library removal
    /// that fails deletes nothing. A download deletion that fails leaves the series removed from the Library,
    /// and says so.
    private func remove(_ item: LibraryItem, includingDownloads: Bool) {
        guard removalOperationIDs[item.id] == nil, contains(item) else { return }

        let operationID = UUID()
        removalOperationIDs[item.id] = operationID
        removingItemIDs.insert(item.id)
        logStarted(kind: .libraryMutation, operationID: operationID)
        let library = dependencies.library
        let downloads = dependencies.downloads
        removalTasks[item.id] = Task { @MainActor [weak self, library, downloads] in
            var result = RemovalResult.removed
            do {
                try await library.removeItem(itemID: item.id, pluginID: item.pluginId, mediaKind: item.effectiveType)
                if includingDownloads {
                    do {
                        try await downloads.deleteDownloads(of: item.mediaIdentity)
                    } catch {
                        result = .removedButDownloadsRemain
                    }
                }
            } catch {
                result = .libraryFailed
            }
            self?.publishRemovalCompletion(itemID: item.id, operationID: operationID, result: result)
        }
    }

    func itemSelected(_ item: LibraryItem) {
        guard !isEditing else { return }
        let media = mediaIdentity(for: item)
        guard updateSnapshot.badgeCount(for: media) > 0,
              badgeOperationIDs[media] == nil else { return }

        let operationID = UUID()
        badgeOperationIDs[media] = operationID
        logStarted(kind: .libraryMutation, operationID: operationID)
        let updates = dependencies.updates
        badgeTasks[media] = Task { @MainActor [weak self, updates] in
            do {
                try await updates.clearLibraryBadge(for: media)
                self?.publishBadgeCompletion(
                    media: media,
                    operationID: operationID,
                    succeeded: true
                )
            } catch {
                self?.publishBadgeCompletion(
                    media: media,
                    operationID: operationID,
                    succeeded: false
                )
            }
        }
    }

    func requestUpdate() async {
        if let updateTask {
            await updateTask.value
            return
        }

        let operationID = UUID()
        updateOperationID = operationID
        logStarted(kind: .remoteUpdate, operationID: operationID)
        let updates = dependencies.updates
        let task = Task { @MainActor [weak self, updates] in
            do {
                try await updates.checkLibraryForUpdates()
                self?.publishUpdateCompletion(operationID: operationID, failure: nil)
            } catch {
                self?.publishUpdateCompletion(operationID: operationID, failure: error)
            }
        }
        updateTask = task
        await task.value
    }

    func beginExport() {
        guard exportTask == nil, !isGeneratingExport else { return }
        let operationID = UUID()
        exportOperationID = operationID
        isGeneratingExport = true
        exportPresentation = nil
        alert = nil
        logStarted(kind: .backupExport, operationID: operationID)
        let exportService = dependencies.export
        exportTask = Task { @MainActor [weak self, exportService] in
            do {
                let artifact = try await exportService.generateLibraryExport()
                self?.publishExportCompletion(
                    artifact,
                    operationID: operationID
                )
            } catch {
                self?.publishExportFailure(operationID: operationID)
            }
        }
    }

    func cancelExportGeneration() {
        guard let operationID = exportOperationID else { return }
        exportOperationID = nil
        exportTask?.cancel()
        exportTask = nil
        isGeneratingExport = false
        logFinished(
            kind: .backupExport,
            operationID: operationID,
            outcome: .cancelled
        )
    }

    func dismissExportPresentation() {
        exportPresentation = nil
    }

    func exporterDidSucceed() {
        exportPresentation = nil
        alert = nil
    }

    func exporterDidFail() {
        exportPresentation = nil
        alert = .exporterFailed
    }

    func dismissAlert() {
        alert = nil
    }

    func appear() {
        guard !isVisible else { return }
        isVisible = true
        hasPresentedDiscord = false
        presentDiscordIfNeeded()
    }

    func disappear() {
        // The existing Library screen does not clear Discord presence on disappear.
        isVisible = false
    }

    private func mediaIdentity(for item: LibraryItem) -> MediaIdentity {
        item.mediaIdentity
    }

    private static func layoutStyle(from rawValue: Int) -> LibraryLayoutStyle {
        LibraryLayoutStyle(rawValue: rawValue) ?? .sectioned
    }

    private func applyLibrarySnapshot(_ newSnapshot: LibraryRootSnapshot) {
        let oldCategoryName = selectedCategoryName
        let removedItemIDs = Set(snapshot.items.map(\.id)).subtracting(newSnapshot.items.map(\.id))
        if !removedItemIDs.isEmpty { dependencies.coverThumbnails.forget(itemIDs: removedItemIDs) }
        snapshot = newSnapshot
        if let selectedCategoryID,
           !newSnapshot.categories.contains(where: { $0.id == selectedCategoryID }) {
            self.selectedCategoryID = nil
        }
        if isEditing && newSnapshot.items.isEmpty {
            isEditing = false
        }
        if categoryAssignmentItemID.map({ itemID in
            !newSnapshot.items.contains(where: { $0.id == itemID })
        }) == true {
            categoryAssignmentItemID = nil
        }
        if let pendingRemoval, !contains(pendingRemoval.item) {
            self.pendingRemoval = nil
        }
        if oldCategoryName != selectedCategoryName || selectedCategoryID == nil {
            presentDiscordIfNeeded()
        }
    }

    private func applyAuthoritativeLayout(_ rawValue: Int) {
        authoritativeLayoutStyle = Self.layoutStyle(from: rawValue)
        if let intendedLayoutStyle {
            layoutStyle = intendedLayoutStyle
        } else {
            layoutStyle = authoritativeLayoutStyle
        }
    }

    private func publishLayoutCompletion(
        operationID: UUID,
        requested: LibraryLayoutStyle,
        succeeded: Bool
    ) {
        guard layoutOperationID == operationID else {
            logFinished(
                kind: .preferenceWrite,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }
        layoutOperationID = nil
        layoutTask = nil
        authoritativeLayoutStyle = Self.layoutStyle(
            from: dependencies.layout.storedLibraryLayoutStyle
        )
        if let intendedLayoutStyle, intendedLayoutStyle != requested {
            layoutStyle = intendedLayoutStyle
            logFinished(
                kind: .preferenceWrite,
                operationID: operationID,
                outcome: succeeded ? .succeeded : .failed(.persistence)
            )
            startLayoutPersistence(intendedLayoutStyle)
            return
        }
        intendedLayoutStyle = nil
        layoutStyle = authoritativeLayoutStyle
        if succeeded {
            logFinished(
                kind: .preferenceWrite,
                operationID: operationID,
                outcome: .succeeded
            )
        } else {
            messagePresenter.present(.layoutPersistenceFailed)
            logFinished(
                kind: .preferenceWrite,
                operationID: operationID,
                outcome: .failed(.persistence)
            )
        }
    }

    private func publishRemovalCompletion(
        itemID: String,
        operationID: UUID,
        result: RemovalResult
    ) {
        guard removalOperationIDs[itemID] == operationID else {
            logFinished(
                kind: .libraryMutation,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }
        removalOperationIDs[itemID] = nil
        removalTasks[itemID] = nil
        removingItemIDs.remove(itemID)
        switch result {
        case .removed:
            logFinished(kind: .libraryMutation, operationID: operationID, outcome: .succeeded)
        case .removedButDownloadsRemain:
            messagePresenter.present(.downloadsNotDeleted)
            logFinished(kind: .libraryMutation, operationID: operationID, outcome: .partiallySucceeded(.persistence))
        case .libraryFailed:
            messagePresenter.present(.itemRemovalFailed)
            logFinished(kind: .libraryMutation, operationID: operationID, outcome: .failed(.persistence))
        }
    }

    private func publishBadgeCompletion(
        media: MediaIdentity,
        operationID: UUID,
        succeeded: Bool
    ) {
        guard badgeOperationIDs[media] == operationID else { return }
        badgeOperationIDs[media] = nil
        badgeTasks[media] = nil
        logFinished(
            kind: .libraryMutation,
            operationID: operationID,
            outcome: succeeded ? .succeeded : .failed(.persistence)
        )
    }

    private func publishUpdateCompletion(operationID: UUID, failure: Error?) {
        guard updateOperationID == operationID else {
            logFinished(
                kind: .remoteUpdate,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }
        updateOperationID = nil
        updateTask = nil
        let outcome: PresentationEventOutcome
        switch failure {
        case nil:
            outcome = .succeeded
        case UpdateRunError.alreadyRunning?:
            // The running check already shows its progress banner.
            outcome = .cancelled
        case UpdateRunError.noSources?:
            messagePresenter.present(.noUpdateSources)
            outcome = .failed(.pluginUnavailable)
        default:
            messagePresenter.present(.updateFailed)
            outcome = .failed(.unknown)
        }
        logFinished(kind: .remoteUpdate, operationID: operationID, outcome: outcome)
    }

    private func publishExportCompletion(
        _ artifact: LibraryExportArtifact,
        operationID: UUID
    ) {
        guard exportOperationID == operationID else {
            logFinished(
                kind: .backupExport,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }
        exportOperationID = nil
        exportTask = nil
        isGeneratingExport = false
        exportPresentation = LibraryExportPresentation(
            id: operationID,
            document: artifact.document,
            defaultFilename: artifact.defaultFilename
        )
        logFinished(
            kind: .backupExport,
            operationID: operationID,
            outcome: .succeeded
        )
    }

    private func publishExportFailure(operationID: UUID) {
        guard exportOperationID == operationID else {
            logFinished(
                kind: .backupExport,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }
        exportOperationID = nil
        exportTask = nil
        isGeneratingExport = false
        exportPresentation = nil
        alert = .exportGenerationFailed
        logFinished(
            kind: .backupExport,
            operationID: operationID,
            outcome: .failed(.persistence)
        )
    }

    private var selectedCategoryName: String? {
        snapshot.categories.first(where: { $0.id == selectedCategoryID })?.displayName
    }

    private func presentDiscordIfNeeded() {
        guard isVisible else { return }
        let categoryName = selectedCategoryName
        guard !hasPresentedDiscord || lastPresentedDiscordCategoryName != categoryName else {
            return
        }
        dependencies.discord.presentLibrary(categoryName: categoryName)
        lastPresentedDiscordCategoryName = categoryName
        hasPresentedDiscord = true
    }

    private func logStarted(kind: PresentationEventKind, operationID: UUID) {
        presentationLogger.log(
            .started(feature: .library, kind: kind, operationID: operationID)
        )
    }

    private func logFinished(
        kind: PresentationEventKind,
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        presentationLogger.log(
            .finished(
                feature: .library,
                kind: kind,
                operationID: operationID,
                outcome: outcome
            )
        )
    }
}
