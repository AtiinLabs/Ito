import Combine
import Foundation

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

struct LibraryExportPresentation: Identifiable {
    let id: UUID
    let document: BackupDocument
    let defaultFilename: String
}

enum LibraryAlert: Equatable {
    case exportGenerationFailed
    case exporterFailed

    var title: String { "Backup Error" }

    var message: String {
        switch self {
        case .exportGenerationFailed:
            return "The library backup could not be generated. Please try again."
        case .exporterFailed:
            return "The library backup could not be exported. Please try again."
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
    @Published private(set) var pendingRemoval: LibraryItem?
    @Published private(set) var removingItemIDs: Set<String> = []
    @Published private(set) var updateSnapshot: LibraryUpdateSnapshot
    @Published private(set) var installedPluginIDs: Set<String>
    @Published private(set) var isGeneratingExport = false
    @Published private(set) var exportPresentation: LibraryExportPresentation?
    @Published private(set) var alert: LibraryAlert?

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
            LibraryCategoryPresentation(id: $0.id, name: $0.name)
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
                name: category.name,
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

    /// Asks the user to confirm removing a series.
    func requestRemoval(_ item: LibraryItem) {
        guard removalOperationIDs[item.id] == nil, contains(item) else { return }
        pendingRemoval = item
    }

    func cancelRemoval() {
        pendingRemoval = nil
    }

    func confirmRemoval() {
        guard let item = pendingRemoval else { return }
        pendingRemoval = nil
        remove(item)
    }

    private func contains(_ item: LibraryItem) -> Bool {
        snapshot.items.contains { $0.id == item.id && $0.pluginId == item.pluginId }
    }

    private func remove(_ item: LibraryItem) {
        guard removalOperationIDs[item.id] == nil, contains(item) else { return }

        let operationID = UUID()
        removalOperationIDs[item.id] = operationID
        removingItemIDs.insert(item.id)
        logStarted(kind: .libraryMutation, operationID: operationID)
        let library = dependencies.library
        removalTasks[item.id] = Task { @MainActor [weak self, library] in
            do {
                try await library.removeItem(itemID: item.id, pluginID: item.pluginId, mediaKind: item.effectiveType)
                self?.publishRemovalCompletion(
                    itemID: item.id,
                    operationID: operationID,
                    succeeded: true
                )
            } catch {
                self?.publishRemovalCompletion(
                    itemID: item.id,
                    operationID: operationID,
                    succeeded: false
                )
            }
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
        if let pendingRemoval, !contains(pendingRemoval) {
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
        succeeded: Bool
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
        if succeeded {
            logFinished(
                kind: .libraryMutation,
                operationID: operationID,
                outcome: .succeeded
            )
        } else {
            messagePresenter.present(.itemRemovalFailed)
            logFinished(
                kind: .libraryMutation,
                operationID: operationID,
                outcome: .failed(.persistence)
            )
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
        snapshot.categories.first(where: { $0.id == selectedCategoryID })?.name
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
