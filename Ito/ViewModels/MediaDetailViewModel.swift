import Combine
import Foundation
import UIKit
import ito_runner

private enum MediaDetailViewModelError: Error {
    case unsupportedMediaType
}

enum ChapterSortOrder: String, CaseIterable {
    case descending = "High to Low"
    case ascending = "Low to High"
    case dateDescending = "Newest First"
    case dateAscending = "Oldest First"

    var icon: String {
        switch self {
        case .descending: return "arrow.down.to.line"
        case .ascending: return "arrow.up.to.line"
        case .dateDescending: return "calendar.badge.clock"
        case .dateAscending: return "calendar"
        }
    }
}

enum ChapterFilterOption: String, CaseIterable {
    case all = "All"
    case unread = "Unread/Unwatched"
    case read = "Read/Watched"

    var icon: String {
        switch self {
        case .all: return "list.bullet"
        case .unread: return "circle"
        case .read: return "checkmark.circle.fill"
        }
    }
}

enum MediaDetailReaderDestination: Identifiable {
    case pages(
        id: UUID,
        runner: ItoRunner,
        pluginID: String,
        entry: MediaEntry,
        chapter: Chapter
    )
    case anime(
        id: UUID,
        runner: ItoRunner,
        pluginID: String,
        media: Anime,
        episode: Anime.Episode
    )
    /// A text chapter, retaining the catalog entry's kind for history and completion.
    case text(
        id: UUID,
        runner: ItoRunner,
        pluginID: String,
        entry: MediaEntry,
        chapter: Chapter
    )

    var id: UUID {
        switch self {
        case .pages(let id, _, _, _, _),
             .anime(let id, _, _, _, _),
             .text(let id, _, _, _, _):
            return id
        }
    }
}

extension MediaDetailReaderDestination {
    /// The chapter's format selects the reader; its catalog identity is unchanged.
    static func reading(_ chapter: Chapter, of entry: MediaEntry, runner: ItoRunner, pluginID: String) -> Self {
        if entry.contentKind(of: chapter) == .text {
            return .text(id: UUID(), runner: runner, pluginID: pluginID, entry: entry, chapter: chapter)
        }
        return .pages(id: UUID(), runner: runner, pluginID: pluginID, entry: entry, chapter: chapter)
    }
}

struct MediaDetailRouteContext<M: MediaDisplayable> {
    let loadDetails: (M) async throws -> M
    let searchForRelink: (String) async throws -> [M]
    let makeReaderDestination: (M, M.Chapter) -> MediaDetailReaderDestination
}

struct MediaDetailTrackerSheetIntent: Identifiable, Equatable {
    let id: UUID
    let mediaIdentity: MediaIdentity
    let title: String
    let isAnime: Bool
}

struct MediaDetailCategoryAssignmentIntent: Identifiable, Equatable {
    let itemID: String
    var id: String { itemID }
}

struct MediaDetailRelinkPresentation: Identifiable, Equatable {
    let id: UUID
    let mediaKey: String
}

@MainActor
final class MediaDetailViewModel<M: MediaDisplayable>: ObservableObject {
    enum DetailLoadState: Equatable {
        case idle
        case loading
        case content
        case failure(String)
    }

    enum RelinkSearchState: Equatable {
        case idle
        case loading
        case results
        case empty
        case failure(String)
    }

    enum RelinkMutationState: Equatable {
        case idle
        case relinking(resultID: String)
        case failure(String)
    }

    enum LibraryMutationState: Equatable {
        case idle
        case saving
        case unsaving
        case failedSaving
        case failedUnsaving
    }

    @Published private(set) var media: M
    @Published private(set) var detailLoadState: DetailLoadState = .idle
    @Published var sortOrder: ChapterSortOrder = .descending
    @Published var filterOption: ChapterFilterOption = .all
    @Published var selectedGroup: String?
    @Published private(set) var theme: ThemeColors?
    @Published private(set) var isSaved: Bool
    @Published private(set) var hasCustomCategories: Bool
    @Published private(set) var isTrackingAvailable: Bool
    @Published private(set) var isTracked: Bool
    @Published private(set) var relinkSearchResults: [M] = []
    @Published private(set) var relinkSearchState: RelinkSearchState = .idle
    @Published private(set) var relinkMutationState: RelinkMutationState = .idle
    @Published private(set) var libraryMutationState: LibraryMutationState = .idle
    @Published private(set) var readerDestination: MediaDetailReaderDestination?
    @Published private(set) var trackerSheetIntent: MediaDetailTrackerSheetIntent?
    @Published private(set) var categoryAssignmentIntent: MediaDetailCategoryAssignmentIntent?
    @Published private(set) var relinkPresentation: MediaDetailRelinkPresentation?

    let pluginID: String

    /// The installed plugin's name, or its id once the plugin is gone.
    var sourceName: String {
        dependencies.pluginMetadata.displayName(for: pluginID) ?? pluginID
    }

    private let routeContext: MediaDetailRouteContext<M>
    private let dependencies: PreparedMediaDetailDependencies
    private let messagePresenter: any MediaDetailMessagePresenting
    private let presentationLogger: any PresentationEventLogging

    private var detailTask: Task<Void, Never>?
    private var themeTask: Task<Void, Never>?
    private var relinkSearchTask: Task<Void, Never>?
    private var baselineTask: Task<Void, Never>?
    private var trackerProgressTask: Task<Void, Never>?
    private var detailOperationID: UUID?
    private var themeOperationID: UUID?
    private var relinkSearchOperationID: UUID?
    private var relinkMutationOperationID: UUID?
    private var libraryMutationOperationID: UUID?
    private var baselineOperationID: UUID?
    private var trackerProgressOperationID: UUID?
    private var completedBaselineSignatures = Set<String>()
    private var lastSynchronizedTrackerProgress: [MediaIdentity: Float] = [:]
    private var hasStarted = false
    private var isAppeared = false
    private var cancellables = Set<AnyCancellable>()

    init(
        media: M,
        pluginID: String,
        routeContext: MediaDetailRouteContext<M>,
        dependencies: PreparedMediaDetailDependencies,
        messagePresenter: any MediaDetailMessagePresenting,
        presentationLogger: any PresentationEventLogging
    ) {
        self.media = media
        self.pluginID = pluginID
        self.routeContext = routeContext
        self.dependencies = dependencies
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger

        let identity = MediaIdentity(pluginId: pluginID, itemId: media.key)
        let libraryState = dependencies.library.state
        isSaved = libraryState.isSaved(media: identity, sourceItemID: media.key)
        hasCustomCategories = libraryState.hasCustomCategories
        let trackerState = dependencies.tracker.state(for: identity, isAnime: media is Anime)
        isTrackingAvailable = trackerState.isAvailable
        isTracked = trackerState.isTracked
        selectedGroup = Self.preferredAnimeGroup(for: media)

        dependencies.library.statePublisher
            .sink { [weak self] state in
                self?.applyLibraryState(state)
            }
            .store(in: &cancellables)
        dependencies.tracker.statePublisher
            .sink { [weak self] in
                self?.refreshTrackerState()
            }
            .store(in: &cancellables)
        dependencies.progress.progressPublisher
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    deinit {
        detailTask?.cancel()
        themeTask?.cancel()
        relinkSearchTask?.cancel()
        baselineTask?.cancel()
        trackerProgressTask?.cancel()
    }

    var mediaIdentity: MediaIdentity {
        MediaIdentity(pluginId: pluginID, itemId: media.key)
    }

    var isDetailLoading: Bool {
        detailLoadState == .loading
    }

    var isLibraryMutationInFlight: Bool {
        libraryMutationState == .saving || libraryMutationState == .unsaving
    }

    var isRelinkMutationInFlight: Bool {
        if case .relinking = relinkMutationState { return true }
        return false
    }

    var hasReadProgress: Bool {
        let identity = mediaIdentity
        return dependencies.progress.lastReadChapter(for: identity) != nil
            || !dependencies.progress.readChapterNumbers(for: identity).isEmpty
    }

    var displayedChapters: [M.Chapter] {
        guard let chapters = media.chapterList else { return [] }
        let identity = mediaIdentity
        let filtered: [M.Chapter]
        switch filterOption {
        case .all:
            filtered = chapters
        case .unread:
            filtered = chapters.filter {
                !dependencies.progress.isRead(
                    media: identity,
                    chapterID: $0.key,
                    chapterNumber: $0.chapterNumber
                )
            }
        case .read:
            filtered = chapters.filter {
                dependencies.progress.isRead(
                    media: identity,
                    chapterID: $0.key,
                    chapterNumber: $0.chapterNumber
                )
            }
        }

        switch sortOrder {
        case .descending:
            return filtered.sorted {
                ($0.chapterNumber ?? -Float.infinity) >
                    ($1.chapterNumber ?? -Float.infinity)
            }
        case .ascending:
            return filtered.sorted {
                ($0.chapterNumber ?? Float.infinity) <
                    ($1.chapterNumber ?? Float.infinity)
            }
        case .dateDescending:
            return filtered.sorted { ($0.dateUpload ?? "") > ($1.dateUpload ?? "") }
        case .dateAscending:
            return filtered.sorted { ($0.dateUpload ?? "") < ($1.dateUpload ?? "") }
        }
    }

    /// The chapter Resume opens: the last one opened if it is not finished, otherwise the
    /// first unread one, otherwise the last.
    var resumeChapter: M.Chapter? {
        guard let chapters = media.chapterList, !chapters.isEmpty else { return nil }
        let identity = mediaIdentity
        if let lastKey = dependencies.progress.lastReadChapter(for: identity),
           let last = chapters.first(where: { $0.key == lastKey }),
           !isRead(last) {
            return last
        }
        let ascending = chapters.sorted {
            ($0.chapterNumber ?? Float.infinity) < ($1.chapterNumber ?? Float.infinity)
        }
        return ascending.first {
            !dependencies.progress.isRead(
                media: identity,
                chapterID: $0.key,
                chapterNumber: $0.chapterNumber
            )
        } ?? ascending.last
    }

    func isRead(_ chapter: M.Chapter) -> Bool {
        dependencies.progress.isRead(
            media: mediaIdentity,
            chapterID: chapter.key,
            chapterNumber: chapter.chapterNumber
        )
    }

    func start() {
        if hasStarted {
            if detailLoadState == .idle {
                _ = beginDetailLoad(advanceBaselineWhenFinished: true)
            }
            if theme == nil, themeTask == nil {
                loadCachedTheme()
            }
            return
        }
        hasStarted = true
        loadCachedTheme()
        _ = beginDetailLoad(advanceBaselineWhenFinished: true)
    }

    func refresh() async {
        let task = beginDetailLoad(advanceBaselineWhenFinished: false)
        await task.value
    }

    func retryDetailLoad() {
        _ = beginDetailLoad(advanceBaselineWhenFinished: true)
    }

    func heroImageLoaded(_ image: UIImage) {
        themeTask?.cancel()
        let operationID = UUID()
        let mediaKey = media.key
        themeOperationID = operationID
        let service = dependencies.theme
        themeTask = Task { [weak self, service] in
            let extracted = await service.extractTheme(from: image, for: mediaKey)
            self?.publishTheme(extracted, operationID: operationID, mediaKey: mediaKey)
        }
    }

    func toggleSave() async {
        guard !isLibraryMutationInFlight else { return }
        let operationID = UUID()
        let sourceMedia = media
        let sourceKey = sourceMedia.key
        let sourceIdentity = mediaIdentity
        let saving = !isSaved
        libraryMutationOperationID = operationID
        libraryMutationState = saving ? .saving : .unsaving
        logStarted(kind: .libraryMutation, operationID: operationID)

        do {
            let savedItemID: String?
            if saving {
                savedItemID = try await save(sourceMedia)
            } else {
                savedItemID = nil
                try await dependencies.library.unsave(
                    sourceItemID: sourceKey,
                    pluginID: pluginID
                )
            }
            guard isCurrentLibraryMutation(
                operationID,
                sourceIdentity: sourceIdentity,
                sourceKey: sourceKey
            ) else {
                logFinished(
                    kind: .libraryMutation,
                    operationID: operationID,
                    outcome: .ignoredStale
                )
                return
            }
            libraryMutationOperationID = nil
            libraryMutationState = .idle
            applyLibraryState(dependencies.library.state)
            logFinished(
                kind: .libraryMutation,
                operationID: operationID,
                outcome: .succeeded
            )
            guard saving else { return }
            guard mayPresentUserOutput else { return }
            let durableItemID = savedItemID ?? sourceKey
            if dependencies.settings.alwaysShowCategoryPicker && hasCustomCategories {
                categoryAssignmentIntent = MediaDetailCategoryAssignmentIntent(
                    itemID: durableItemID
                )
            } else {
                messagePresenter.presentSaved(itemID: durableItemID)
            }
        } catch is CancellationError {
            publishLibraryMutationCancellation(operationID: operationID)
        } catch {
            publishLibraryMutationFailure(operationID: operationID, saving: saving)
        }
    }

    func dismissCategoryAssignment() {
        categoryAssignmentIntent = nil
    }

    func openTrackerSheet() {
        guard isTrackingAvailable else { return }
        trackerSheetIntent = MediaDetailTrackerSheetIntent(
            id: UUID(),
            mediaIdentity: mediaIdentity,
            title: media.title,
            isAnime: media is Anime
        )
    }

    func dismissTrackerSheet() {
        trackerSheetIntent = nil
    }

    func trackerDidSave(progress: Int?) {
        guard dependencies.settings.autoSyncTrackersToLocal,
              let progress else { return }
        let value = Float(progress)
        let identity = mediaIdentity
        guard lastSynchronizedTrackerProgress[identity] != value else { return }
        trackerProgressTask?.cancel()
        let operationID = UUID()
        trackerProgressOperationID = operationID
        let progressService = dependencies.progress
        trackerProgressTask = Task { [weak self, progressService] in
            do {
                try await progressService.markReadUpTo(
                    media: identity,
                    maximumChapterNumber: value
                )
                guard self?.trackerProgressOperationID == operationID,
                      self?.mediaIdentity == identity else { return }
                self?.trackerProgressOperationID = nil
                self?.trackerProgressTask = nil
                self?.lastSynchronizedTrackerProgress[identity] = value
                self?.objectWillChange.send()
            } catch is CancellationError {
                guard self?.trackerProgressOperationID == operationID else { return }
                self?.trackerProgressOperationID = nil
                self?.trackerProgressTask = nil
            } catch {
                guard self?.trackerProgressOperationID == operationID,
                      self?.mediaIdentity == identity else { return }
                self?.trackerProgressOperationID = nil
                self?.trackerProgressTask = nil
                if self?.mayPresentUserOutput == true {
                    self?.messagePresenter.present(.trackerProgressFailed)
                }
            }
        }
    }

    func selectChapter(_ chapter: M.Chapter) {
        readerDestination = routeContext.makeReaderDestination(media, chapter)
    }

    func dismissReader() {
        readerDestination = nil
    }

    func openRelink() {
        guard !isRelinkMutationInFlight else { return }
        relinkPresentation = MediaDetailRelinkPresentation(
            id: UUID(),
            mediaKey: media.key
        )
        beginRelinkSearch()
    }

    func retryRelinkSearch() {
        guard relinkPresentation != nil, !isRelinkMutationInFlight else { return }
        beginRelinkSearch()
    }

    func dismissRelink() {
        guard !isRelinkMutationInFlight else { return }
        relinkSearchOperationID = nil
        relinkSearchTask?.cancel()
        relinkSearchTask = nil
        relinkSearchResults = []
        relinkSearchState = .idle
        relinkMutationState = .idle
        relinkPresentation = nil
    }

    func performRelink(with selectedMedia: M) async {
        guard let presentation = relinkPresentation,
              !isRelinkMutationInFlight else { return }
        let operationID = UUID()
        let oldMedia = media
        let oldKey = oldMedia.key
        let selectedKey = selectedMedia.key
        relinkMutationOperationID = operationID
        relinkMutationState = .relinking(resultID: selectedKey)
        logStarted(kind: .relink, operationID: operationID)

        do {
            let hydrated = try await routeContext.loadDetails(selectedMedia)
            let payload = try JSONEncoder().encode(hydrated)
            try await dependencies.relink.relink(
                pluginID: pluginID,
                possibleSourceItemIDs: [oldKey, "\(pluginID)_\(oldKey)"],
                destinationItemID: selectedKey,
                title: hydrated.title,
                coverURL: hydrated.cover,
                rawPayload: payload
            )
            guard relinkMutationOperationID == operationID,
                  relinkPresentation?.id == presentation.id,
                  media.key == oldKey else {
                logFinished(kind: .relink, operationID: operationID, outcome: .ignoredStale)
                return
            }

            invalidateOperationsForIdentityTransition()
            media = hydrated
            selectedGroup = Self.preferredAnimeGroup(for: hydrated)
            detailLoadState = .content
            theme = nil
            readerDestination = nil
            trackerSheetIntent = nil
            categoryAssignmentIntent = nil
            relinkSearchResults = []
            relinkSearchState = .idle
            relinkMutationState = .idle
            libraryMutationState = .idle
            relinkMutationOperationID = nil
            isSaved = true
            lastSynchronizedTrackerProgress.removeAll()

            await refreshIdentityServicesAfterRelink()
            loadCachedTheme()
            beginBaselineAdvanceIfNeeded()
            if isAppeared {
                publishDiscordActivity()
            }
            relinkPresentation = nil
            logFinished(kind: .relink, operationID: operationID, outcome: .succeeded)
        } catch is CancellationError {
            publishRelinkCancellation(operationID: operationID)
        } catch {
            publishRelinkFailure(operationID: operationID)
        }
    }

    func appear() {
        guard !isAppeared else { return }
        isAppeared = true
        if hasStarted, detailLoadState == .idle {
            _ = beginDetailLoad(advanceBaselineWhenFinished: true)
        }
        if hasStarted, theme == nil, themeTask == nil {
            loadCachedTheme()
        }
        publishDiscordActivity()
    }

    func disappear() {
        guard isAppeared else { return }
        isAppeared = false
        dependencies.discord.clear()
        cancelSupersedableOperations()
    }

    func cancelScreenOperations() {
        cancelSupersedableOperations()
        relinkMutationOperationID = nil
        libraryMutationOperationID = nil
        libraryMutationState = .idle
        relinkMutationState = .idle
    }

    private func beginDetailLoad(
        advanceBaselineWhenFinished: Bool
    ) -> Task<Void, Never> {
        detailTask?.cancel()
        let operationID = UUID()
        let requestedMedia = media
        let requestedKey = requestedMedia.key
        let loader = routeContext.loadDetails
        detailOperationID = operationID
        detailLoadState = .loading
        logStarted(kind: .detailLoad, operationID: operationID)
        let task = Task { [weak self] in
            do {
                let updated = try await loader(requestedMedia)
                guard self?.isCurrentDetailOperation(operationID, mediaKey: requestedKey) == true else {
                    self?.logFinished(
                        kind: .detailLoad,
                        operationID: operationID,
                        outcome: .ignoredStale
                    )
                    return
                }
                self?.media = updated
                self?.selectedGroup = Self.preferredAnimeGroup(for: updated)
                self?.detailOperationID = nil
                self?.detailTask = nil
                self?.detailLoadState = .content
                self?.refreshIdentitySnapshots()
                self?.logFinished(
                    kind: .detailLoad,
                    operationID: operationID,
                    outcome: .succeeded
                )
                if advanceBaselineWhenFinished {
                    self?.beginBaselineAdvanceIfNeeded()
                }
            } catch is CancellationError {
                self?.publishDetailCancellation(operationID: operationID)
            } catch {
                self?.publishDetailFailure(
                    operationID: operationID,
                    mediaKey: requestedKey,
                    advanceBaselineWhenFinished: advanceBaselineWhenFinished
                )
            }
        }
        detailTask = task
        return task
    }

    private func loadCachedTheme() {
        themeTask?.cancel()
        let operationID = UUID()
        let mediaKey = media.key
        let service = dependencies.theme
        themeOperationID = operationID
        themeTask = Task { [weak self, service] in
            let cached = await service.cachedTheme(for: mediaKey)
            self?.publishTheme(cached, operationID: operationID, mediaKey: mediaKey)
        }
    }

    private func beginRelinkSearch() {
        relinkSearchTask?.cancel()
        let operationID = UUID()
        let presentationID = relinkPresentation?.id
        let mediaKey = media.key
        let query = media.title
        let search = routeContext.searchForRelink
        relinkSearchOperationID = operationID
        relinkSearchResults = []
        relinkSearchState = .loading
        relinkMutationState = .idle
        logStarted(kind: .relinkSearch, operationID: operationID)
        relinkSearchTask = Task { [weak self] in
            do {
                let results = try await search(query)
                guard self?.isCurrentRelinkSearch(
                    operationID,
                    presentationID: presentationID,
                    mediaKey: mediaKey
                ) == true else {
                    self?.logFinished(
                        kind: .relinkSearch,
                        operationID: operationID,
                        outcome: .ignoredStale
                    )
                    return
                }
                self?.relinkSearchOperationID = nil
                self?.relinkSearchTask = nil
                self?.relinkSearchResults = results
                self?.relinkSearchState = results.isEmpty ? .empty : .results
                self?.logFinished(
                    kind: .relinkSearch,
                    operationID: operationID,
                    outcome: .succeeded
                )
            } catch is CancellationError {
                self?.publishRelinkSearchCancellation(operationID: operationID)
            } catch {
                self?.publishRelinkSearchFailure(
                    operationID: operationID,
                    presentationID: presentationID,
                    mediaKey: mediaKey
                )
            }
        }
    }

    private func beginBaselineAdvanceIfNeeded() {
        guard isSaved else { return }
        let identity = mediaIdentity
        let count = media.chapterList?.distinctChapterCount ?? 0
        let signature = "\(identity.pluginId)|\(identity.canonicalMediaId)|\(count)"
        guard !completedBaselineSignatures.contains(signature) else { return }
        baselineTask?.cancel()
        let operationID = UUID()
        baselineOperationID = operationID
        let baseline = dependencies.baseline
        let itemID = media.key
        logStarted(kind: .baseline, operationID: operationID)
        baselineTask = Task { [weak self, baseline] in
            do {
                try await baseline.advanceBaseline(
                    itemID: itemID,
                    media: identity,
                    knownChapterCount: count
                )
                guard self?.baselineOperationID == operationID,
                      self?.mediaIdentity == identity else {
                    self?.logFinished(
                        kind: .baseline,
                        operationID: operationID,
                        outcome: .ignoredStale
                    )
                    return
                }
                self?.baselineOperationID = nil
                self?.baselineTask = nil
                self?.completedBaselineSignatures.insert(signature)
                self?.logFinished(
                    kind: .baseline,
                    operationID: operationID,
                    outcome: .succeeded
                )
            } catch is CancellationError {
                guard self?.baselineOperationID == operationID else { return }
                self?.baselineOperationID = nil
                self?.baselineTask = nil
                self?.logFinished(
                    kind: .baseline,
                    operationID: operationID,
                    outcome: .cancelled
                )
            } catch {
                guard self?.baselineOperationID == operationID,
                      self?.mediaIdentity == identity else { return }
                self?.baselineOperationID = nil
                self?.baselineTask = nil
                self?.logFinished(
                    kind: .baseline,
                    operationID: operationID,
                    outcome: .failed(.persistence)
                )
            }
        }
    }

    private func save(_ sourceMedia: M) async throws -> String {
        if let manga = sourceMedia as? Manga {
            return try await dependencies.library.saveManga(manga, pluginID: pluginID)
        } else if let anime = sourceMedia as? Anime {
            return try await dependencies.library.saveAnime(anime, pluginID: pluginID)
        } else if let novel = sourceMedia as? Novel {
            return try await dependencies.library.saveNovel(novel, pluginID: pluginID)
        }
        throw MediaDetailViewModelError.unsupportedMediaType
    }

    private func refreshIdentityServicesAfterRelink() async {
        try? await dependencies.library.refresh()
        try? await dependencies.progress.refresh()
        try? await dependencies.tracker.refresh()
        try? await dependencies.baseline.refresh()
        refreshIdentitySnapshots()
    }

    private func refreshIdentitySnapshots() {
        applyLibraryState(dependencies.library.state)
        refreshTrackerState()
        objectWillChange.send()
    }

    private func applyLibraryState(_ state: MediaDetailLibraryState) {
        isSaved = state.isSaved(media: mediaIdentity, sourceItemID: media.key)
        hasCustomCategories = state.hasCustomCategories
    }

    private func refreshTrackerState() {
        let state = dependencies.tracker.state(for: mediaIdentity, isAnime: media is Anime)
        isTrackingAvailable = state.isAvailable
        isTracked = state.isTracked
    }

    private func publishDiscordActivity() {
        let trackerState = dependencies.tracker.state(for: mediaIdentity, isAnime: media is Anime)
        let detailsURL = trackerState.anilistID.map {
            "https://anilist.co/\(media is Anime ? "anime" : "manga")/\($0)"
        }
        let pluginName = dependencies.pluginMetadata.displayName(for: pluginID)
            ?? "Unknown Plugin"
        dependencies.discord.present(
            MediaDetailDiscordActivity(
                details: media.title,
                state: "Viewing Details",
                activityType: 3,
                detailsURL: detailsURL,
                largeImageText: "Browsing at \(pluginName)",
                imageURL: media.cover,
                resetTimer: true
            )
        )
    }

    private func publishTheme(
        _ publishedTheme: ThemeColors?,
        operationID: UUID,
        mediaKey: String
    ) {
        guard themeOperationID == operationID,
              media.key == mediaKey,
              !Task.isCancelled else { return }
        if let publishedTheme {
            theme = publishedTheme
        }
        themeOperationID = nil
        themeTask = nil
    }

    private func publishDetailCancellation(operationID: UUID) {
        guard detailOperationID == operationID else { return }
        detailOperationID = nil
        detailTask = nil
        detailLoadState = .idle
        logFinished(kind: .detailLoad, operationID: operationID, outcome: .cancelled)
    }

    private func publishDetailFailure(
        operationID: UUID,
        mediaKey: String,
        advanceBaselineWhenFinished: Bool
    ) {
        guard isCurrentDetailOperation(operationID, mediaKey: mediaKey) else { return }
        detailOperationID = nil
        detailTask = nil
        detailLoadState = .failure("Failed to load details. Please try again.")
        messagePresenter.present(.detailLoadFailed)
        logFinished(
            kind: .detailLoad,
            operationID: operationID,
            outcome: .failed(.pluginExecution)
        )
        if advanceBaselineWhenFinished {
            beginBaselineAdvanceIfNeeded()
        }
    }

    private func publishLibraryMutationCancellation(operationID: UUID) {
        guard libraryMutationOperationID == operationID else { return }
        libraryMutationOperationID = nil
        libraryMutationState = .idle
        logFinished(
            kind: .libraryMutation,
            operationID: operationID,
            outcome: .cancelled
        )
    }

    private func publishLibraryMutationFailure(operationID: UUID, saving: Bool) {
        guard libraryMutationOperationID == operationID else { return }
        libraryMutationOperationID = nil
        libraryMutationState = saving ? .failedSaving : .failedUnsaving
        applyLibraryState(dependencies.library.state)
        if mayPresentUserOutput {
            messagePresenter.present(saving ? .saveFailed : .unsaveFailed)
        }
        logFinished(
            kind: .libraryMutation,
            operationID: operationID,
            outcome: .failed(.persistence)
        )
    }

    private func publishRelinkSearchCancellation(operationID: UUID) {
        guard relinkSearchOperationID == operationID else { return }
        relinkSearchOperationID = nil
        relinkSearchTask = nil
        relinkSearchState = .idle
        logFinished(kind: .relinkSearch, operationID: operationID, outcome: .cancelled)
    }

    private func publishRelinkSearchFailure(
        operationID: UUID,
        presentationID: UUID?,
        mediaKey: String
    ) {
        guard isCurrentRelinkSearch(
            operationID,
            presentationID: presentationID,
            mediaKey: mediaKey
        ) else { return }
        relinkSearchOperationID = nil
        relinkSearchTask = nil
        relinkSearchResults = []
        relinkSearchState = .failure("Search failed. Please try again.")
        logFinished(
            kind: .relinkSearch,
            operationID: operationID,
            outcome: .failed(.pluginExecution)
        )
    }

    private func publishRelinkCancellation(operationID: UUID) {
        guard relinkMutationOperationID == operationID else { return }
        relinkMutationOperationID = nil
        relinkMutationState = .idle
        logFinished(kind: .relink, operationID: operationID, outcome: .cancelled)
    }

    private func publishRelinkFailure(operationID: UUID) {
        guard relinkMutationOperationID == operationID else { return }
        relinkMutationOperationID = nil
        relinkMutationState = .failure("Re-link failed. Please try again.")
        logFinished(
            kind: .relink,
            operationID: operationID,
            outcome: .failed(.persistence)
        )
    }

    private func invalidateOperationsForIdentityTransition() {
        detailOperationID = nil
        themeOperationID = nil
        relinkSearchOperationID = nil
        libraryMutationOperationID = nil
        baselineOperationID = nil
        trackerProgressOperationID = nil
        detailTask?.cancel()
        themeTask?.cancel()
        relinkSearchTask?.cancel()
        baselineTask?.cancel()
        trackerProgressTask?.cancel()
        detailTask = nil
        themeTask = nil
        relinkSearchTask = nil
        baselineTask = nil
        trackerProgressTask = nil
    }

    private var mayPresentUserOutput: Bool {
        !hasStarted || isAppeared
    }

    private func cancelSupersedableOperations() {
        detailOperationID = nil
        themeOperationID = nil
        relinkSearchOperationID = nil
        baselineOperationID = nil
        trackerProgressOperationID = nil
        detailTask?.cancel()
        themeTask?.cancel()
        relinkSearchTask?.cancel()
        baselineTask?.cancel()
        trackerProgressTask?.cancel()
        detailTask = nil
        themeTask = nil
        relinkSearchTask = nil
        baselineTask = nil
        trackerProgressTask = nil
        if detailLoadState == .loading { detailLoadState = .idle }
        if relinkSearchState == .loading { relinkSearchState = .idle }
    }

    private func isCurrentDetailOperation(_ operationID: UUID, mediaKey: String) -> Bool {
        detailOperationID == operationID && media.key == mediaKey && !Task.isCancelled
    }

    private func isCurrentLibraryMutation(
        _ operationID: UUID,
        sourceIdentity: MediaIdentity,
        sourceKey: String
    ) -> Bool {
        libraryMutationOperationID == operationID
            && mediaIdentity == sourceIdentity
            && media.key == sourceKey
            && !Task.isCancelled
    }

    private func isCurrentRelinkSearch(
        _ operationID: UUID,
        presentationID: UUID?,
        mediaKey: String
    ) -> Bool {
        relinkSearchOperationID == operationID
            && relinkPresentation?.id == presentationID
            && media.key == mediaKey
            && !Task.isCancelled
    }

    private static func preferredAnimeGroup(for media: M) -> String? {
        guard let anime = media as? Anime else { return nil }
        return (anime.seasons?.first { $0.isCurrent } ?? anime.seasons?.first)?.key
    }

    private func logStarted(kind: PresentationEventKind, operationID: UUID) {
        presentationLogger.log(
            .started(feature: .mediaDetail, kind: kind, operationID: operationID)
        )
    }

    private func logFinished(
        kind: PresentationEventKind,
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        presentationLogger.log(
            .finished(
                feature: .mediaDetail,
                kind: kind,
                operationID: operationID,
                outcome: outcome
            )
        )
    }
}
