import Combine
import Foundation
import UIKit
import ito_runner

private enum MediaDetailViewModelError: Error {
    case unsupportedMediaType
}

@MainActor
final class MediaDetailViewModel<M: MediaDisplayable>: ObservableObject {
    enum DetailLoadState: Equatable {
        case idle
        case loading
        case content
        case savedOnly
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

    @Published private(set) var media: M {
        didSet {
            cancelGroupSwitch()
            downloadBatch.mediaDidChange()
        }
    }
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
    /// How many queued downloads the last relink cancelled. Zero when it cancelled none.
    @Published private(set) var relinkCancelledDownloadCount = 0
    @Published private(set) var libraryMutationState: LibraryMutationState = .idle
    @Published private(set) var readerDestination: MediaDetailReaderDestination?
    @Published private(set) var trackerSheetIntent: MediaDetailTrackerSheetIntent?
    @Published private(set) var categoryAssignmentIntent: MediaDetailCategoryAssignmentIntent?
    @Published private(set) var relinkPresentation: MediaDetailRelinkPresentation?
    /// This series' chapter download states, keyed by chapter key.
    @Published private(set) var chapterDownloadStates: [String: ChapterDownloadState] = [:]
    /// Whether the device reports no network.
    @Published private(set) var isOffline: Bool
    /// When the saved details of this series were last refreshed from their source; nil when unknown. Read
    /// only for the screens that show saved details, and set again when a refresh replaces them.
    @Published var snapshotRefreshedAt: Date?

    let pluginID: String

    /// The installed plugin's name, or its id once the plugin is gone.
    var sourceName: String {
        dependencies.pluginMetadata.displayName(for: pluginID) ?? pluginID
    }

    private let routeContext: MediaDetailRouteContext<M>
    let dependencies: PreparedMediaDetailDependencies
    let messagePresenter: any MediaDetailMessagePresenting
    /// Downloads for this series' chapters. Unavailable where offline chapters are not composed.
    let downloads: any MediaDetailDownloadServing
    /// The presets, scanlator choice, preview and saved-only rows of the download controls.
    let downloadBatch: MediaDetailDownloadBatchModel
    let snapshots: MediaDetailSnapshotRefresher
    private let presentationLogger: any PresentationEventLogging

    private var detailTask: Task<Void, Never>?
    private var detailTaskOperationID: UUID?
    private var themeTask: Task<Void, Never>?
    private var relinkSearchTask: Task<Void, Never>?
    private var baselineTask: Task<Void, Never>?
    private var trackerProgressTask: Task<Void, Never>?
    private var savedChapterTask: Task<Void, Never>?
    private var savedChapterOperationID: UUID?
    var snapshotDateTask: Task<Void, Never>?
    private var detailOperationID: UUID?
    private var themeOperationID: UUID?
    private var relinkSearchOperationID: UUID?
    private var relinkMutationOperationID: UUID?
    private var libraryMutationOperationID: UUID?
    private var baselineOperationID: UUID?
    private var trackerProgressOperationID: UUID?
    private var completedBaselineSignatures = Set<String>()
    private struct TrackerProgressSnapshot: Equatable {
        let maximumChapterNumber: Float
        let availableChapterNumbers: Set<Float>
    }
    private var lastSynchronizedTrackerProgress: [MediaIdentity: TrackerProgressSnapshot] = [:]
    private var hasStarted = false
    /// Applied after the first successful detail load, then cleared.
    private var pendingOpenIntent: MediaDetailOpenIntent?
    /// The group History last saw for this series, used when the series' own record cannot name
    /// one (such as after it moved to another source).
    var historyScanlator: String?
    var historyScanlatorID: String?
    @Published var groupSwitchConsent: ReaderGroupSwitchConsent<M.Chapter>?
    var continuationSession = UUID()
    var resumeTask: Task<Void, Never>?
    private var isAppeared = false
    private var cancellables = Set<AnyCancellable>()

    init(
        media: M,
        pluginID: String,
        routeContext: MediaDetailRouteContext<M>,
        dependencies: PreparedMediaDetailDependencies,
        messagePresenter: any MediaDetailMessagePresenting,
        presentationLogger: any PresentationEventLogging,
        snapshotEncoder: any MediaDetailSnapshotEncoding = JSONMediaDetailSnapshotEncoder(),
        openIntent: MediaDetailOpenIntent? = nil
    ) {
        self.media = media
        self.pluginID = pluginID
        self.routeContext = routeContext
        self.dependencies = dependencies
        self.messagePresenter = messagePresenter
        downloads = dependencies.downloads
        snapshots = MediaDetailSnapshotRefresher(library: dependencies.library, encoder: snapshotEncoder)
        downloadBatch = MediaDetailDownloadBatchModel(
            downloads: dependencies.downloads,
            progress: dependencies.progress,
            snapshots: snapshots,
            inventory: routeContext.inventoryChapters,
            loadsFromSource: routeContext.loadDetails != nil
        )
        self.presentationLogger = presentationLogger
        pendingOpenIntent = openIntent

        let identity = MediaIdentity(pluginId: pluginID, canonicalMediaId: media.key, mediaKind: media.mediaKind)
        let libraryState = dependencies.library.state
        isSaved = libraryState.isSaved(media: identity)
        isOffline = dependencies.connectivity.isOffline
        hasCustomCategories = libraryState.hasCustomCategories
        let trackerState = dependencies.tracker.state(for: identity, isAnime: media is Anime)
        isTrackingAvailable = trackerState.isAvailable
        isTracked = trackerState.isTracked
        selectedGroup = Self.preferredAnimeGroup(for: media)

        downloadBatch.host = self
        downloadBatch.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
        // Follows the series identity, so a relink observes the new series' chapters.
        let downloads = dependencies.downloads
        $media
            .map { [pluginID] in MediaIdentity(pluginId: pluginID, canonicalMediaId: $0.key, mediaKind: $0.mediaKind) }
            .removeDuplicates()
            .map { identity in downloads.chapterStates(for: identity).map { (identity, $0) } }
            .switchToLatest()
            .sink { [weak self] identity, states in
                self?.chapterDownloadStates = states
                self?.downloadBatch.statesDidChange(states, for: identity)
            }
            .store(in: &cancellables)
        dependencies.connectivity.isOfflinePublisher
            .sink { [weak self] isOffline in
                self?.isOffline = isOffline
            }
            .store(in: &cancellables)
    }

    deinit {
        detailTask?.cancel()
        themeTask?.cancel()
        relinkSearchTask?.cancel()
        baselineTask?.cancel()
        trackerProgressTask?.cancel()
        savedChapterTask?.cancel()
        snapshotDateTask?.cancel()
    }

    var mediaIdentity: MediaIdentity {
        MediaIdentity(pluginId: pluginID, canonicalMediaId: media.key, mediaKind: media.mediaKind)
    }

    /// Presents a download message only while this screen may still show output.
    func presentDownloadMessage(_ message: MediaDetailMessage) {
        guard mayPresentUserOutput else { return }
        messagePresenter.present(message)
    }

    var isDetailLoading: Bool {
        detailLoadState == .loading
    }

    /// Relinking needs an installed source to search.
    var canRelink: Bool { routeContext.searchForRelink != nil }

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

    /// What Resume opens; a known lock on it is a boundary, not a reason to skip ahead.
    var resumeChapter: M.Chapter? {
        guard let candidate = resumeTarget?.chapter, !candidate.isPaywalled else { return nil }
        return candidate
    }

    /// Whether Resume starts a finished series over.
    var isResumeRereading: Bool {
        resumeTarget?.isRereading == true
    }

    var resumeTarget: MediaDetailResumeTarget<M.Chapter>? {
        MediaDetailResumeTarget(
            chapters: media.chapterList ?? [],
            lastReadKey: dependencies.progress.lastReadChapter(for: mediaIdentity),
            fallbackGroup: historyScanlator,
            fallbackGroupID: historyScanlatorID,
            useGroupIDs: dependencies.settings.askBeforeSwitchingGroups,
            isCompleted: media.isCompleted,
            isRead: isRead
        )
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
                _ = beginDetailLoad(advanceBaselineWhenFinished: true, purpose: .seriesMetadata)
            }
            if theme == nil, themeTask == nil {
                loadCachedTheme()
            }
            return
        }
        hasStarted = true
        downloadBatch.reload()
        loadCachedTheme()
        _ = beginDetailLoad(advanceBaselineWhenFinished: true, purpose: .seriesMetadata)
    }

    func refresh() async {
        let task = beginDetailLoad(advanceBaselineWhenFinished: false, purpose: .manualCatalogRefresh)
        await task.value
    }

    func retryDetailLoad() {
        _ = beginDetailLoad(advanceBaselineWhenFinished: true, purpose: .seriesMetadata)
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
                try await dependencies.library.unsave(media: sourceIdentity)
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
        let snapshot = TrackerProgressSnapshot(
            maximumChapterNumber: value,
            availableChapterNumbers: Set((media.chapterList ?? []).lazy.compactMap(\.chapterNumber).filter {
                $0.isFinite && $0 <= value
            })
        )
        // The same tracker maximum can cover newly discovered chapter 0 or fractional releases.
        guard lastSynchronizedTrackerProgress[identity] != snapshot else { return }
        trackerProgressTask?.cancel()
        let operationID = UUID()
        trackerProgressOperationID = operationID
        let progressService = dependencies.progress
        trackerProgressTask = Task { [weak self, progressService] in
            do {
                try await progressService.markReadUpTo(
                    media: identity,
                    maximumChapterNumber: snapshot.maximumChapterNumber,
                    availableChapterNumbers: snapshot.availableChapterNumbers
                )
                guard self?.trackerProgressOperationID == operationID,
                      self?.mediaIdentity == identity else { return }
                self?.trackerProgressOperationID = nil
                self?.trackerProgressTask = nil
                self?.lastSynchronizedTrackerProgress[identity] = snapshot
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
        cancelGroupSwitch()
        // A row or Resume action can retain a chapter value from before a metadata refresh.
        let current = media.chapterList?.first { $0.key == chapter.key } ?? chapter
        guard !current.isPaywalled else { return }
        guard detailLoadState == .savedOnly else {
            // Offline, only a downloaded chapter can open: any other would fail to load.
            if showsDownloadControls, isOffline, downloadState(for: current) != .downloaded {
                presentDownloadMessage(.chapterNotDownloaded)
                return
            }
            readerDestination = routeContext.makeReaderDestination(media, current)
            return
        }
        openSavedChapter(current)
    }

    /// Opens a downloaded chapter from its source for this reading only. Nothing is stored: the next
    /// opening reads the downloaded copy again, and a locked chapter or a series without a source never
    /// gets here.
    func readOnlineThisTime(_ chapter: M.Chapter) {
        let current = media.chapterList?.first { $0.key == chapter.key } ?? chapter
        guard !current.isPaywalled, detailLoadState != .savedOnly else { return }
        readerDestination = routeContext.makeReaderDestination(media, current)
            .preferring(.remoteThisTime(chapterKey: current.key))
    }

    /// A saved-only series reads its downloaded chapters only. The copy is checked at the tap, so a
    /// download that finished after the route opened still reads. A tap while a check is running does
    /// nothing.
    private func openSavedChapter(_ chapter: M.Chapter) {
        guard savedChapterTask == nil else { return }
        let mediaKey = media.key
        let isAvailable = routeContext.isChapterAvailableOffline
        let operationID = UUID()
        savedChapterOperationID = operationID
        savedChapterTask = Task { [weak self] in
            let available = (await isAvailable?(chapter)) ?? false
            guard let self, self.savedChapterOperationID == operationID, !Task.isCancelled else { return }
            self.savedChapterOperationID = nil
            self.savedChapterTask = nil
            guard self.media.key == mediaKey, self.detailLoadState == .savedOnly else { return }
            if available {
                self.readerDestination = self.routeContext.makeReaderDestination(self.media, chapter)
            } else if self.mayPresentUserOutput {
                self.messagePresenter.present(.chapterNotDownloaded)
            }
        }
    }

    func dismissReader() {
        readerDestination = nil
    }

    func openRelink() {
        guard !isRelinkMutationInFlight, routeContext.searchForRelink != nil else { return }
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

    func dismissRelinkDownloadsNotice() {
        relinkCancelledDownloadCount = 0
    }

    func performRelink(with selectedMedia: M) async {
        guard let loadDetails = routeContext.loadDetails,
              let presentation = relinkPresentation,
              !isRelinkMutationInFlight else { return }
        let operationID = UUID()
        let oldMedia = media
        let oldKey = oldMedia.key
        let selectedKey = selectedMedia.key
        relinkMutationOperationID = operationID
        relinkMutationState = .relinking(resultID: selectedKey)
        relinkCancelledDownloadCount = 0
        logStarted(kind: .relink, operationID: operationID)

        do {
            let hydrated = try await loadDetails(
                selectedMedia, PluginNetworkOperation(purpose: .seriesMetadata, operationID: operationID)
            )
            let payload = try JSONEncoder().encode(hydrated)
            let cancelledDownloadCount = try await dependencies.relink.relink(
                pluginID: pluginID,
                mediaKind: hydrated.mediaKind,
                possibleSourceItemIDs: [
                    oldKey,
                    "\(pluginID)_\(oldKey)",
                    "\(pluginID)\u{1F}\(hydrated.mediaKind.rawValue)\u{1F}\(oldKey)"
                ],
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
            cancelGroupSwitch()
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
            relinkCancelledDownloadCount = cancelledDownloadCount
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
            _ = beginDetailLoad(advanceBaselineWhenFinished: true, purpose: .seriesMetadata)
        }
        if hasStarted, theme == nil, themeTask == nil {
            loadCachedTheme()
        }
        publishDiscordActivity()
    }

    func disappear() {
        cancelGroupSwitch()
        guard isAppeared else { return }
        isAppeared = false
        dependencies.discord.clear()
        cancelSupersedableOperations()
    }

    func cancelScreenOperations() {
        cancelGroupSwitch()
        cancelSupersedableOperations()
        relinkMutationOperationID = nil
        libraryMutationOperationID = nil
        libraryMutationState = .idle
        relinkMutationState = .idle
    }

    private func beginDetailLoad(
        advanceBaselineWhenFinished: Bool,
        purpose: NetworkOperationContext.Purpose
    ) -> Task<Void, Never> {
        cancelGroupSwitch()
        detailTask?.cancel()
        let operationID = UUID()
        let requestedMedia = media
        let requestedKey = requestedMedia.key
        guard let loader = routeContext.loadDetails else {
            return beginSavedOnly()
        }
        detailOperationID = operationID
        detailLoadState = .loading
        logStarted(kind: .detailLoad, operationID: operationID)
        let snapshots = snapshots
        let tokenIdentity: MediaIdentity? = isSaved ? mediaIdentity : nil
        let task = Task { [weak self] in
            defer { self?.clearDetailTask(operationID: operationID) }
            do {
                // Read before the source is asked: a refresh may replace only the details this load started
                // from. A token that cannot be read means no refresh, never a failed load.
                var snapshotToken: LibrarySnapshotToken?
                if let tokenIdentity { snapshotToken = await snapshots.token(for: tokenIdentity) }
                let updated = try await loader(requestedMedia, PluginNetworkOperation(purpose: purpose, operationID: operationID))
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
                self?.performPendingOpenIntent()
                if let snapshotToken {
                    await self?.refreshSavedSnapshot(snapshotToken, with: updated, requestedKey: requestedKey)
                }
            } catch is CancellationError {
                self?.publishDetailCancellation(operationID: operationID)
            } catch {
                self?.publishDetailFailure(operationID: operationID, mediaKey: requestedKey)
            }
        }
        detailTaskOperationID = operationID
        detailTask = task
        return task
    }

    /// A saved-only route has no installed source to refresh from, so the saved series is shown as it is.
    /// Nothing new was checked: the baseline does not advance and badges are left alone.
    private func beginSavedOnly() -> Task<Void, Never> {
        detailTask?.cancel()
        detailTask = nil
        detailTaskOperationID = nil
        detailOperationID = nil
        detailLoadState = .savedOnly
        loadSnapshotRefreshDate()
        performPendingOpenIntent()
        return Task {}
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
        guard let search = routeContext.searchForRelink else { return }
        relinkSearchOperationID = operationID
        relinkSearchResults = []
        relinkSearchState = .loading
        relinkMutationState = .idle
        logStarted(kind: .relinkSearch, operationID: operationID)
        relinkSearchTask = Task { [weak self] in
            do {
                let results = try await search(query, operationID)
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
        // An empty list is not evidence that the chapters are gone (a source can return one when
        // a request is refused), so it does not overwrite the known count or clear the badge.
        guard count > 0 else { return }
        let signature = "\(identity.pluginId)|\(identity.mediaKind.rawValue)|\(identity.canonicalMediaId)|\(count)"
        guard !completedBaselineSignatures.contains(signature) else { return }
        baselineTask?.cancel()
        let operationID = UUID()
        baselineOperationID = operationID
        let baseline = dependencies.baseline
        logStarted(kind: .baseline, operationID: operationID)
        baselineTask = Task { [weak self, baseline] in
            do {
                try await baseline.advanceBaseline(media: identity, knownChapterCount: count)
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
        downloadBatch.reload()
    }

    private func applyLibraryState(_ state: MediaDetailLibraryState) {
        let isSaved = state.isSaved(media: mediaIdentity)
        self.isSaved = isSaved
        downloadBatch.librarySavedStateDidChange(isSaved)
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
            ?? String(localized: "Unknown Plugin")
        dependencies.discord.present(
            MediaDetailDiscordActivity(
                details: media.title,
                state: String(localized: "Viewing Details", comment: "Discord status"),
                activityType: 3,
                detailsURL: detailsURL,
                largeImageText: String(localized: "Browsing at \(pluginName)", comment: "Discord status: source name"),
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

    private func publishDetailFailure(operationID: UUID, mediaKey: String) {
        guard isCurrentDetailOperation(operationID, mediaKey: mediaKey) else { return }
        detailOperationID = nil
        detailTask = nil
        // A screen that could not load stays on its error instead of opening a stale chapter.
        pendingOpenIntent = nil
        detailLoadState = .failure(String(localized: "Failed to load details. Please try again."))
        loadSnapshotRefreshDate()
        messagePresenter.present(.detailLoadFailed)
        logFinished(
            kind: .detailLoad,
            operationID: operationID,
            outcome: .failed(.pluginExecution)
        )
        // The new chapters were not shown, so the badge and the known chapter count stay as
        // they are: the saved chapter list is older than the one the last update check counted.
    }

    /// Opens what History asked for, or says why it cannot.
    private func performPendingOpenIntent() {
        guard let intent = pendingOpenIntent else { return }
        pendingOpenIntent = nil
        historyScanlator = intent.preferredScanlator
        historyScanlatorID = intent.preferredScanlatorID
        if case .resume = intent {
            resumeReading(continuation: true)
            return
        }
        let isEpisode = media.mediaKind == .anime
        switch intent.target(in: media.chapterList ?? [], resume: resumeTarget?.continuationChapter) {
        case .open(let chapter): selectChapter(chapter)
        case .locked: messagePresenter.present(.chapterLocked(isEpisode: isEpisode))
        case .unavailable: messagePresenter.present(.chapterUnavailable(isEpisode: isEpisode))
        case nil: break
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
        relinkSearchState = .failure(String(localized: "Search failed. Please try again."))
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
        relinkMutationState = .failure(String(localized: "Re-link failed. Please try again."))
        logFinished(
            kind: .relink,
            operationID: operationID,
            outcome: .failed(.persistence)
        )
    }

    private func invalidateOperationsForIdentityTransition() {
        // A series relinked to another source does not open the chapter asked for the old one.
        pendingOpenIntent = nil
        detailOperationID = nil
        themeOperationID = nil
        relinkSearchOperationID = nil
        libraryMutationOperationID = nil
        baselineOperationID = nil
        trackerProgressOperationID = nil
        savedChapterOperationID = nil
        detailTask?.cancel()
        themeTask?.cancel()
        relinkSearchTask?.cancel()
        baselineTask?.cancel()
        trackerProgressTask?.cancel()
        savedChapterTask?.cancel()
        detailTaskOperationID = nil
        detailTask = nil
        themeTask = nil
        relinkSearchTask = nil
        baselineTask = nil
        trackerProgressTask = nil
        savedChapterTask = nil
        snapshotDateTask?.cancel()
        snapshotDateTask = nil
        snapshotRefreshedAt = nil
        downloadBatch.reset()
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
        savedChapterOperationID = nil
        detailTask?.cancel()
        themeTask?.cancel()
        relinkSearchTask?.cancel()
        baselineTask?.cancel()
        trackerProgressTask?.cancel()
        savedChapterTask?.cancel()
        detailTaskOperationID = nil
        detailTask = nil
        themeTask = nil
        relinkSearchTask = nil
        baselineTask = nil
        trackerProgressTask = nil
        savedChapterTask = nil
        if detailLoadState == .loading { detailLoadState = .idle }
        if relinkSearchState == .loading { relinkSearchState = .idle }
    }

    private func clearDetailTask(operationID: UUID) {
        guard detailTaskOperationID == operationID else { return }
        detailTask = nil
        detailTaskOperationID = nil
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

#if DEBUG
    func waitForTrackerProgressForTesting() async {
        await trackerProgressTask?.value
    }
#endif
}
