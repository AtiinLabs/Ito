import Combine
import Foundation
import ito_runner

@MainActor
final class MangaReaderViewModel: ObservableObject {
    let pluginID: String
    let entry: MediaEntry
    /// Loads a chapter with the form it is actually stored or served in.
    let chapterPreparer: any ReaderChapterPreparing
    /// What every renderer visit of this route shares: History, completion and position writes.
    let routeSession: ReaderRouteSession
    /// Identifies this renderer visit among the route's.
    let routeVisitID: UUID
    /// Stored copies and the route's source: where reading stops, and the downloaded copy to offer.
    let offline: ReaderOfflineContext

    /// Live, or built behind the visible reader for one handoff request.
    @Published private(set) var presentationMode: ReaderPresentationMode
    weak var handoffRouter: (any ReaderHandoffRouting)?
    /// The handoff request this reader was built for, kept after it goes live.
    var arrivalRequestID: UUID?
    /// The request of the first image the destination shows, for handing the route's lease over.
    var preparedImageKey: ReaderPageImageKey?

    @Published private(set) var currentChapter: Manga.Chapter
    @Published private(set) var loadPhase: MangaReaderLoadPhase = .idle
    @Published private(set) var overrideViewer: Manga.Viewer = .Default
    @Published private(set) var preloadImageCount: Int
    @Published private(set) var groupSwitchConsent: ReaderGroupSwitchConsent<Manga.Chapter>?
    var askBeforeSwitchingGroups: Bool { dependencies.settings.askBeforeSwitchingGroups }

    @Published private(set) var pagedPages: [Page] = [] {
        didSet { retainImageRequestsForChapterWindow() }
    }
    @Published private(set) var pagedIndex = 0
    @Published private(set) var prefetchedChapters: [String: [Page]] = [:] {
        didSet { retainImageRequestsForChapterWindow() }
    }

    @Published var segments: [ChapterSegment] = [] {
        didSet { rebuildFlatPages() }
    }
    /// Every page of `segments` in reading order; rebuilt only when `segments` changes.
    @Published private(set) var flatPages: [FlatPage] = []
    @Published private(set) var continuousPageIndex = 0
    @Published private(set) var continuousSnapshot = MangaContinuousReaderSnapshot.empty
    @Published private(set) var scrollTarget: MangaScrollRequest?
    @Published var loadingNextChapter = false {
        didSet { publishContinuousSnapshot() }
    }
    @Published var loadingPrevChapter = false {
        didSet { publishContinuousSnapshot() }
    }
    @Published var appendFailed = false {
        didSet { publishContinuousSnapshot() }
    }
    @Published var prependFailed = false {
        didSet { publishContinuousSnapshot() }
    }

    /// The chapters this route marked read, by exact key.
    var markedChapterKeys: Set<String> { routeSession.claimedCompletionKeys }

    let dependencies: PreparedMangaReaderDependencies
    let imagePrefetcher: any MangaReaderImagePrefetching
    let imageSession: ReaderPageImageSession
    let mediaIdentity: MediaIdentity
    /// Captured once per route; every chapter and both readers share it.
    var completionContext: PluginCompletionContext { routeSession.completionContext }

    private(set) var isActive = true
    var hasPresentedPresence = false
    private(set) var sessionID = UUID()
    var contentGeneration: UInt64 = 0
    /// Set when the route replaced this reader with the other one, not when it was closed.
    var handoffRetired = false
    /// The reader's view is mounted; a destination uses it to present itself once it goes live.
    var viewAppeared = false
    var effectGate = ReaderEffectGate()
    var handoffLatch: ReaderHandoffLatch?
    var transition: MangaTransitionSnapshot?
    /// What each loaded chapter's source choice pins, for as long as the chapter is in this window.
    var chapterResolvers: [ExactChapterKey: OfflineChapterSourceResolver] = [:]
    /// Neighbors found to be made for the other reader, with what was already loaded for them.
    var heldPayloads: [ExactChapterKey: ReaderPreparedChapter] = [:]

    private var networkSubscription: AnyCancellable?
    var mainLoadTask: Task<Void, Never>?
    var mainLoadOperationID: UUID?
    // Written by the adjacent-prefetch extension in its own file, so the setters stay internal.
    var adjacentPrefetchTask: Task<Void, Never>?
    var adjacentPrefetchOperationID: UUID?
    var adjacentPrefetchEpoch: NetworkPrefetchEpoch?
    /// The neighbors the last prefetch was started for.
    var adjacentPrefetchKeys: Set<String> = []
    /// A boundary changed while the reader was inactive; `appear()` applies it.
    var offlineChangeWaiting = false
    /// Operations whose end was logged, so an operation ends in the log once however many paths finish it.
    var finalizedLogOperations: Set<UUID> = []
    var appendTask: Task<Void, Never>?
    var appendOperationID: UUID?
    var appendPrefetchEpoch: NetworkPrefetchEpoch?
    var appendBoundary: ChapterToken?
    var appendSession: UUID?
    var appendGeneration: UInt64?
    var prependTask: Task<Void, Never>?
    var prependOperationID: UUID?
    /// A chapter-window trim that waited for the viewport to stop moving.
    var pendingTrim: ContinuousLoadedEnd?
    var effectTasks: [UUID: Task<Void, Never>] = [:]
    var lastSavedPage: (chapterKey: String, page: Int)?
    var settingsWriteTask: Task<Void, Never>?
    private var viewerWriteTask: Task<Void, Never>?
    var flatPageIndexByID: [String: Int] = [:]
    /// Continuous pages on screen; the topmost is the current page.
    var visiblePageIDs: Set<String> = []
    /// Whether the last loaded page is on screen, so the reader is at the loaded chapter's end.
    var readerIsAtLoadedEnd: Bool { flatPages.last.map { visiblePageIDs.contains($0.id) } ?? false }
    var continuousViewportRetention = MangaContinuousViewportRetentionRegistry()
    private var visiblePageOrder: [String] = []
    private var continuousMutationDepth = 0
    private var continuousSnapshotRevision: UInt64 = 0

    nonisolated deinit {}

    init(
        chapterPreparer: any ReaderChapterPreparing,
        routeSession: ReaderRouteSession,
        routeVisitID: UUID,
        presentationMode: ReaderPresentationMode,
        pluginID: String,
        entry: MediaEntry,
        initialChapter: Manga.Chapter,
        dependencies: PreparedMangaReaderDependencies,
        offline: ReaderOfflineContext
    ) {
        self.chapterPreparer = chapterPreparer
        self.routeSession = routeSession
        self.routeVisitID = routeVisitID
        self.presentationMode = presentationMode
        if case .staged(let requestID, _) = presentationMode { arrivalRequestID = requestID }
        self.pluginID = pluginID
        self.entry = entry
        self.offline = offline
        currentChapter = entry.chapters?.first { $0.key == initialChapter.key } ?? initialChapter
        self.dependencies = dependencies
        imagePrefetcher = dependencies.makeImagePrefetcher(pluginID)
        imageSession = imagePrefetcher.imageSession
        preloadImageCount = dependencies.settings.mangaReaderPreloadImageCount
        mediaIdentity = MediaIdentity(pluginId: pluginID, canonicalMediaId: entry.key, mediaKind: entry.kind)
        overrideViewer = dependencies.progress.savedViewer(media: mediaIdentity) ?? .Default
        publishContinuousSnapshot()
        observeOfflineChanges()
        offline.bind(downloadedCopy: self)
        networkSubscription = dependencies.settings.mangaReaderNetworkChanges.sink { @Sendable [weak self] in
            Task { @MainActor in self?.networkPolicyDidChange() }
        }
    }

    /// Stops the running adjacent prefetch; its task ends as stale at its next check.
    func cancelAdjacentChapterPrefetch() {
        adjacentPrefetchOperationID = nil
        adjacentPrefetchTask?.cancel()
        adjacentPrefetchTask = nil
    }

    private func rebuildFlatPages() {
        let currentID = flatPages.indices.contains(continuousPageIndex)
            ? flatPages[continuousPageIndex].id
            : nil
        let (result, indexByID) = Self.flatten(segments)
        flatPages = result
        flatPageIndexByID = indexByID
        visiblePageIDs = visiblePageIDs.filter { indexByID[$0] != nil }
        visiblePageOrder = visiblePageOrder.filter { indexByID[$0] != nil }
        // Keep pointing at the same page when chapters are added or dropped before it.
        if let currentID, let index = indexByID[currentID] {
            continuousPageIndex = index
        } else if let fallbackID = visiblePageOrder.first, let fallbackIndex = indexByID[fallbackID] {
            continuousPageIndex = fallbackIndex
        } else {
            continuousPageIndex = min(max(continuousPageIndex, 0), max(result.count - 1, 0))
        }
        publishContinuousSnapshot()
    }

    private func publishContinuousSnapshot() {
        guard continuousMutationDepth == 0 else { return }
        continuousSnapshotRevision &+= 1
        retainImageRequestsForChapterWindow()
        continuousSnapshot = MangaContinuousReaderSnapshot(
            revision: continuousSnapshotRevision,
            pages: flatPages,
            previousBoundary: previousBoundaryForFirstSegment,
            nextBoundary: nextBoundaryForLastSegment,
            loadingPrevious: loadingPrevChapter,
            loadingNext: loadingNextChapter,
            prependFailed: prependFailed,
            appendFailed: appendFailed,
            isWebtoon: activeViewer == .Webtoon
        )
    }

    func beginContinuousMutation() {
        continuousMutationDepth += 1
    }

    func endContinuousMutation() {
        guard continuousMutationDepth > 0 else { return }
        continuousMutationDepth -= 1
        if continuousMutationDepth == 0 { publishContinuousSnapshot() }
    }

    // MARK: - Presentation lifecycle

    func start() {
        guard isActive, presentationMode.isLive else { return }
        switch loadPhase {
        case .content, .failure:
            return
        case .loading:
            if mainLoadOperationID != nil { return }
        case .idle:
            break
        }
        beginMainLoad(for: currentChapter)
    }

    func appear() {
        viewAppeared = true
        // A destination built behind the visible reader only records that it is mounted.
        guard presentationMode.isLive, !handoffRetired else { return }
        let isResumingCancelledLoad = !isActive && loadPhase == .loading
        if !isActive {
            isActive = true
            sessionID = UUID()
            effectGate = ReaderEffectGate()
        }
        hasPresentedPresence = true
        presentPresence(for: currentChapter, resetTimer: true)
        if isResumingCancelledLoad {
            beginMainLoad(for: currentChapter)
        }
        if offlineChangeWaiting { applyOfflineChange() }
    }

    func disappear() {
        guard presentationMode.isLive else {
            discardPreparedPresentation()
            return
        }
        guard isActive else { return }
        isActive = false
        viewAppeared = false
        hasPresentedPresence = false
        sessionID = UUID()
        groupSwitchConsent = nil
        contentGeneration &+= 1
        cancelContentOperations()
        // Not cancelled: a chapter's local read mark is durable progress and must finish even
        // if the reader closes right after the last page. A tracker step needs the gate open, which a
        // reader that is closed (not one handing off to the other) shuts.
        if !handoffRetired { effectGate.isOpen = false }
        effectTasks.removeAll()
        settingsWriteTask?.cancel()
        settingsWriteTask = nil
        imagePrefetcher.stopPrefetching()
        imageSession.deactivate()
        dependencies.presence.clearMangaReaderPresence()
    }

    /// Puts the chapter a transition was leaving back on screen, where the reader really was: the page it
    /// was on, and for scrolling the same page as a scroll target the view applies without animating.
    func restoreTransition(_ snapshot: MangaTransitionSnapshot) {
        currentChapter = snapshot.chapter
        pagedPages = snapshot.pagedPages
        pagedIndex = snapshot.pagedIndex
        segments = snapshot.segments
        continuousPageIndex = snapshot.continuousPageIndex
        scrollTarget = snapshot.scrollTarget
        loadPhase = snapshot.loadPhase
    }

    /// The route made this reader live, or built it behind the visible one; only the route decides.
    func setPresentationMode(_ mode: ReaderPresentationMode) { presentationMode = mode }

    /// The chapter is made for the other reader and no route can take it.
    func failDivertedLoad() {
        loadPhase = .failure(ReaderRouteError.otherReader.localizedDescription, needsSignIn: false)
    }

    /// Drops a destination that was never shown: its own work and images end, and nothing of the visible
    /// reader (presence included) is touched.
    func discardPreparedPresentation() {
        guard !presentationMode.isLive else { return }
        isActive = false
        invalidateContentOperations()
        imagePrefetcher.stopPrefetching()
        imageSession.deactivate()
    }

    /// Loads the current chapter again after it failed to load.
    func retry() {
        guard isActive, case .failure = loadPhase else { return }
        pagedPages = []
        pagedIndex = 0
        segments = []
        continuousPageIndex = 0
        scrollTarget = nil
        beginMainLoad(for: currentChapter)
    }

    /// A download finishing or the network changing moves a boundary: the prompts follow, and a paged
    /// reader resting on a notice page loads the chapter that just became available.
    private func observeOfflineChanges() {
        offline.observe { [weak self] in
            guard let self else { return }
            objectWillChange.send()
            publishContinuousSnapshot()
            // This runs navigation synchronously inside the download center's publish: nothing on this
            // path may read the center back synchronously.
            applyOfflineChange()
        }
    }

    /// Applies a boundary change to a paged reader. One that arrives while the reader is inactive waits
    /// for `appear()`. A prefetch in flight is left alone unless the neighbors to fetch changed.
    func applyOfflineChange() {
        guard isActive, presentationMode.isLive else { return offlineChangeWaiting = true }
        offlineChangeWaiting = false
        guard isPaged, loadPhase == .content, !pagedPages.isEmpty else { return }
        if pagedIndex < 0 || pagedIndex >= pagedPages.count {
            setPagedIndex(pagedIndex)
        } else if adjacentPrefetchOperationID == nil || adjacentNeighborKeys != adjacentPrefetchKeys {
            beginAdjacentChapterPrefetch()
        }
    }

    /// Opens the failed chapter local-first, as if it had been opened without the online choice.
    func readDownloadedCopy() {
        guard isActive, canReadDownloadedCopy else { return }
        offline.readDownloadedCopy(chapterKey: currentChapter.key)
        retry()
    }

    // MARK: - Viewer and settings

    func setViewerOverride(_ viewer: Manga.Viewer) {
        guard isActive, overrideViewer != viewer else { return }
        // Spacing changes between Vertical and Webtoon too, so the renderer gets one snapshot.
        beginContinuousMutation()
        defer { endContinuousMutation() }
        let wasPaged = isPaged
        overrideViewer = viewer
        saveViewer(viewer)
        let isNowPaged = isPaged
        guard wasPaged != isNowPaged else { return }

        invalidateContentOperations()
        if isNowPaged {
            convertContinuousToPagedOrReload()
        } else {
            convertPagedToContinuousOrReload()
        }
    }

    /// Remembers the reading mode for the series. Writes run in order; failing is harmless.
    private func saveViewer(_ viewer: Manga.Viewer) {
        let progress = dependencies.progress
        let identity = mediaIdentity
        let chapterKey = currentChapter.key
        let preceding = viewerWriteTask
        viewerWriteTask = Task { @MainActor [progress] in
            await preceding?.value
            try? await progress.saveViewer(viewer, media: identity, chapterID: chapterKey)
        }
    }

    func setPreloadImageCount(_ value: Int) {
        guard ImagePreloadCountPreference(rawValue: value) != nil else { return }
        let settings = dependencies.settings
        let session = sessionID
        let preceding = settingsWriteTask
        let task = Task { @MainActor [weak self, settings] in
            await preceding?.value
            guard let self, self.isActive, self.sessionID == session,
                  !Task.isCancelled else { return }
            do {
                try await settings.setMangaReaderPreloadImageCount(value)
            } catch {
                // The existing Reader intentionally has no visible settings-write error.
            }
            guard self.isActive, self.sessionID == session,
                  !Task.isCancelled else { return }
            self.preloadImageCount = settings.mangaReaderPreloadImageCount
        }
        settingsWriteTask = task
    }

    // MARK: - Chapter and page navigation

    func setPagedIndex(_ newIndex: Int) {
        guard isActive, presentationMode.isLive else { return }
        // The other reader's chapter: the pager rests on its notice and the route takes the crossing.
        if newIndex == pagedPages.count, boundaryAfter(currentChapter).isHandoff {
            requestHandoff(direction: .next, position: .start, trigger: .pagedEdge, atLoadedEdge: false)
            return
        }
        if newIndex == -1, boundaryBefore(currentChapter).isHandoff {
            requestHandoff(direction: .previous, position: .end, trigger: .pagedEdge, atLoadedEdge: false)
            return
        }
        // Another group's chapter waits for consent: the pager is not moved onto it.
        if newIndex == pagedPages.count, boundaryAfter(currentChapter).needsGroupConsent {
            requestGroupSwitch(.next)
            return
        }
        if newIndex == -1, boundaryBefore(currentChapter).needsGroupConsent {
            requestGroupSwitch(.previous, opensAtEnd: true)
            return
        }
        if pagedPages.indices.contains(newIndex) { endHandoffCrossing() }
        pagedIndex = newIndex
        if newIndex == pagedPages.count,
           let next = boundaryAfter(currentChapter).chapter {
            pagedGoToChapter(next, direction: .next, trigger: .pagedEdge)
        } else if newIndex == -1,
                  let previous = boundaryBefore(currentChapter).chapter {
            // Swiping back past the first page continues from the end of the previous chapter.
            pagedGoToChapter(previous, opensAtEnd: true, direction: .previous, trigger: .pagedEdge)
        } else if pagedPages.indices.contains(newIndex) {
            pageShown(in: currentChapter, at: newIndex, pageCount: pagedPages.count)
            prefetchPagedImages(around: newIndex)
        }
    }

    func previousPage() {
        guard isActive else { return }
        if isPaged {
            guard pagedIndex > 0 else { return }
            setPagedIndex(pagedIndex - 1)
        } else {
            guard continuousChapterPage.index > 0 else { return }
            continuousPageIndex -= 1
            scrollTarget = MangaScrollRequest(
                pageID: flatPages[continuousPageIndex].id,
                animated: true
            )
        }
    }

    func nextPage() {
        guard isActive else { return }
        if isPaged {
            guard pagedIndex < pagedPages.count - 1 else { return }
            setPagedIndex(pagedIndex + 1)
        } else {
            let chapterPage = continuousChapterPage
            guard chapterPage.index < chapterPage.count - 1 else { return }
            continuousPageIndex += 1
            scrollTarget = MangaScrollRequest(
                pageID: flatPages[continuousPageIndex].id,
                animated: true
            )
        }
    }

    func goToNextChapter() {
        guard isActive, presentationMode.isLive else { return }
        let boundary = boundaryAfter(currentChapter)
        if boundary.isHandoff {
            requestHandoff(direction: .next, position: .resume, trigger: .chapterControl, atLoadedEdge: false)
            return
        }
        if boundary.needsGroupConsent {
            requestGroupSwitch(.next)
            return
        }
        guard let next = boundary.chapter else { return }
        if isPaged {
            pagedGoToChapter(next, direction: .next, trigger: .chapterControl)
        } else {
            continuousGoToChapter(next, direction: .next, trigger: .chapterControl)
        }
    }

    func setGroupSwitchConsent(_ consent: ReaderGroupSwitchConsent<Manga.Chapter>?) { groupSwitchConsent = consent }

    /// Opens the one neighbor the user approved, in the reader's current mode.
    func openApprovedGroupSwitch(
        _ chapter: Manga.Chapter,
        opensAtEnd: Bool,
        direction: ReaderHandoffDirection
    ) {
        if isPaged {
            pagedGoToChapter(chapter, opensAtEnd: opensAtEnd, direction: direction, trigger: .chapterControl, approved: true)
        } else {
            continuousGoToChapter(chapter, direction: direction, trigger: .chapterControl, approved: true)
        }
    }

    func cachePrefetchedChapter(_ pages: [Page], for key: String) { prefetchedChapters[key] = pages }

    func setAskBeforeSwitchingGroups(_ value: Bool) {
        groupSwitchConsent = nil
        let settings = dependencies.settings
        let session = sessionID
        let preceding = settingsWriteTask
        settingsWriteTask = Task { @MainActor [weak self] in
            await preceding?.value
            guard let self, self.isActive, self.sessionID == session, !Task.isCancelled else { return }
            do {
                try await settings.setAskBeforeSwitchingGroups(value)
            } catch {
                self.objectWillChange.send()
                return
            }
            guard self.isActive, self.sessionID == session, !Task.isCancelled else { return }
            self.adjacentPrefetchTask?.cancel()
            self.adjacentPrefetchTask = nil
            self.adjacentPrefetchOperationID = nil
            self.appendTask?.cancel()
            if let operationID = self.appendOperationID {
                self.finishAppend(operationID: operationID, outcome: .cancelled)
            }
            self.prefetchedChapters = self.prefetchedChapters.filter { self.adjacentNeighborKeys.contains($0.key) }
            if value, let index = self.segments.firstIndex(where: { $0.chapter.key == self.currentChapter.key }),
               let boundary = self.segments.indices.dropFirst(index + 1).first(where: {
                   !ReaderContinuationGroup(self.segments[$0 - 1].chapter).matches(ReaderContinuationGroup(self.segments[$0].chapter))
               }) {
                self.segments.removeSubrange(boundary...)
            }
            self.objectWillChange.send()
            self.publishContinuousSnapshot()
            if self.isPaged { self.beginAdjacentChapterPrefetch() }
        }
    }

    func goToPreviousChapter() {
        guard isActive, presentationMode.isLive else { return }
        let boundary = boundaryBefore(currentChapter)
        if boundary.isHandoff {
            requestHandoff(direction: .previous, position: .resume, trigger: .chapterControl, atLoadedEdge: false)
            return
        }
        if boundary.needsGroupConsent {
            requestGroupSwitch(.previous)
            return
        }
        guard let previous = boundary.chapter else { return }
        if isPaged {
            pagedGoToChapter(previous, direction: .previous, trigger: .chapterControl)
        } else {
            continuousGoToChapter(previous, direction: .previous, trigger: .chapterControl)
        }
    }

    func consumeScrollTarget(_ target: MangaScrollRequest) {
        guard scrollTarget == target else { return }
        scrollTarget = nil
    }

    func makeContinuousViewportRetention() -> MangaContinuousViewportRetention { continuousViewportRetention.makeLease() }

    /// Receives page IDs ordered by their actual image-frame position in the continuous viewport.
    func continuousViewportChanged(_ pageIDs: [String], preferredPageID: String? = nil) {
        guard isActive, presentationMode.isLive, !isPaged else { return }
        let validIDs = pageIDs.filter { flatPageIndexByID[$0] != nil }
        guard !validIDs.isEmpty else { return }

        let nextVisibleIDs = Set(validIDs)
        let visibilityChanged = visiblePageIDs != nextVisibleIDs
        let topPageID = preferredPageID.flatMap { validIDs.contains($0) ? $0 : nil } ?? validIDs[0]
        guard let topIndex = flatPageIndexByID[topPageID] else { return }
        visiblePageOrder = validIDs

        visiblePageIDs = nextVisibleIDs

        for pageID in validIDs {
            guard let index = flatPageIndexByID[pageID] else { continue }
            let page = flatPages[index]
            if segments.indices.contains(page.segmentIndex),
               page.chapterPosition == segments[page.segmentIndex].pages.count - 1 {
                markChapterFinished(page.chapter)
            }
        }

        let flatPage = flatPages[topIndex]
        continuousPageIndex = topIndex
        if flatPage.chapter.key != currentChapter.key {
            changeCurrentChapter(to: flatPage.chapter)
            chapterOpened(flatPage.chapter)
        }
        savePage(flatPage.chapterPosition, in: flatPage.chapter)
        if visibilityChanged, let bottomIndex = validIDs.compactMap({ flatPageIndexByID[$0] }).max() {
            // Several short strips can be on screen at once: preload past the last of them.
            prefetchContinuousImages(around: bottomIndex, allPages: flatPages)
        }
        releaseHandoffLatchIfViewportLeftEdge()
    }

    private func pagedGoToChapter(
        _ chapter: Manga.Chapter,
        opensAtEnd: Bool = false,
        direction: ReaderHandoffDirection = .next,
        trigger: ReaderHandoffTrigger = .chapterControl,
        approved: Bool = false
    ) {
        // What the reader holds now, until the chapter proves to be made for this reader.
        if prefetchedChapters[chapter.key] == nil {
            beginTransitionSnapshot(direction: direction, trigger: trigger, approved: approved)
        } else {
            transition = nil
        }
        endHandoffCrossing()
        invalidateContentOperations()
        changeCurrentChapter(to: chapter)
        if let cached = prefetchedChapters[chapter.key] {
            pagedPages = cached
            pagedIndex = opensAtEnd
                ? max(cached.count - 1, 0)
                : startPage(for: chapter, pageCount: cached.count)
            loadPhase = .content
            chapterOpened(chapter)
            if !cached.isEmpty {
                pageShown(in: chapter, at: pagedIndex, pageCount: cached.count)
            }
            prefetchPagedImages(around: pagedIndex)
            beginAdjacentChapterPrefetch()
        } else {
            pagedPages = []
            pagedIndex = 0
            loadPhase = .loading
            beginMainLoad(for: chapter, opensAtEnd: opensAtEnd)
        }
    }

    private func continuousGoToChapter(
        _ chapter: Manga.Chapter,
        direction: ReaderHandoffDirection = .next,
        trigger: ReaderHandoffTrigger = .chapterControl,
        approved: Bool = false
    ) {
        // Already loaded: scroll to it rather than throwing the loaded chapters away.
        if let first = flatPages.first(where: { $0.chapter.key == chapter.key }) {
            scrollTarget = MangaScrollRequest(pageID: first.id, animated: false)
            return
        }
        beginTransitionSnapshot(direction: direction, trigger: trigger, approved: approved)
        endHandoffCrossing()
        invalidateContentOperations()
        changeCurrentChapter(to: chapter)
        segments = []
        continuousPageIndex = 0
        scrollTarget = nil
        loadPhase = .loading
        beginMainLoad(for: chapter)
    }

    private func changeCurrentChapter(to chapter: Manga.Chapter) {
        let changedKey = currentChapter.key != chapter.key
        groupSwitchConsent = nil
        currentChapter = chapter
        if changedKey, isActive, hasPresentedPresence {
            presentPresence(for: chapter, resetTimer: false)
        }
    }

    // MARK: - Main chapter loading

    private func beginMainLoad(for chapter: Manga.Chapter, opensAtEnd: Bool = false) {
        guard isActive, presentationMode.isLive, !chapter.isPaywalled else { return }
        let token = ChapterToken(chapter)
        if loadPhase == .loading,
           mainLoadOperationID != nil,
           token == ChapterToken(currentChapter) {
            return
        }

        mainLoadTask?.cancel()
        let operationID = UUID()
        let session = sessionID
        let generation = contentGeneration
        let expectedPaged = isPaged
        let preparer = chapterPreparer
        let entry = entry
        mainLoadOperationID = operationID
        loadPhase = .loading
        logStarted(kind: .remoteLoad, operationID: operationID)
        let operation = PluginNetworkOperation(purpose: .foregroundReading, operationID: operationID)

        mainLoadTask = Task { @MainActor [weak self, preparer, entry] in
            do {
                let result = try await preparer.prepareChapter(entry: entry, chapter: chapter, operation: operation)
                self?.completeMainLoad(
                    result,
                    chapter: chapter,
                    token: token,
                    expectedPaged: expectedPaged,
                    opensAtEnd: opensAtEnd,
                    operationID: operationID,
                    session: session,
                    generation: generation
                )
            } catch {
                self?.failMainLoad(
                    error,
                    token: token,
                    expectedPaged: expectedPaged,
                    operationID: operationID,
                    session: session,
                    generation: generation
                )
            }
        }
    }

    private func completeMainLoad(
        _ prepared: ReaderPreparedChapter,
        chapter: Manga.Chapter,
        token: ChapterToken,
        expectedPaged: Bool,
        opensAtEnd: Bool,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) {
        guard isCurrentMainLoad(
            token: token,
            expectedPaged: expectedPaged,
            operationID: operationID,
            session: session,
            generation: generation
        ) else {
            logFinished(kind: .remoteLoad, operationID: operationID, outcome: .ignoredStale)
            return
        }

        mainLoadTask = nil
        mainLoadOperationID = nil
        guard prepared.format == .pages else {
            // Made for the other reader: this one is put back as it was and the route takes over.
            logFinished(kind: .remoteLoad, operationID: operationID, outcome: .succeeded)
            if transition != nil {
                divertTransition(prepared, opensAtEnd: opensAtEnd)
            } else {
                divertOpening(prepared, opensAtEnd: opensAtEnd)
            }
            return
        }
        transition = nil
        retain(prepared)
        let start = installMainPages(
            prepared.pages, chapter: chapter, position: opensAtEnd ? .end : .resume, paged: expectedPaged
        )
        logFinished(kind: .remoteLoad, operationID: operationID, outcome: .succeeded)
        chapterOpened(chapter)
        if !prepared.pages.isEmpty {
            pageShown(in: chapter, at: start, pageCount: prepared.pages.count)
        }
        if expectedPaged {
            prefetchPagedImages(around: start)
            beginAdjacentChapterPrefetch()
        }
    }

    /// Publishes a loaded chapter at the native position `position` names, and returns the page it opens on.
    @discardableResult
    func installMainPages(
        _ pages: [Page],
        chapter: Manga.Chapter,
        position: ReaderEntryPosition,
        paged: Bool
    ) -> Int {
        let start: Int
        switch position {
        case .start: start = 0
        case .end: start = max(pages.count - 1, 0)
        case .resume: start = startPage(for: chapter, pageCount: pages.count)
        }
        if paged {
            pagedPages = pages
            pagedIndex = start
        } else {
            segments = [ChapterSegment(chapter: chapter, pages: pages)]
            continuousPageIndex = start
            scrollTarget = start > 0
                ? MangaScrollRequest(
                    pageID: FlatPage.id(chapterKey: chapter.key, position: start),
                    animated: false
                )
                : nil
        }
        loadPhase = .content
        return start
    }

    private func failMainLoad(
        _ error: any Error,
        token: ChapterToken,
        expectedPaged: Bool,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) {
        guard isCurrentMainLoad(
            token: token,
            expectedPaged: expectedPaged,
            operationID: operationID,
            session: session,
            generation: generation
        ) else {
            logFinished(kind: .remoteLoad, operationID: operationID, outcome: .ignoredStale)
            return
        }
        mainLoadTask = nil
        mainLoadOperationID = nil
        transition = nil
        loadPhase = .failure(error.localizedDescription, needsSignIn: (error as? PluginCallError)?.kind == .needsLogin)
        let outcome: PresentationEventOutcome = error is CancellationError
            ? .cancelled
            : .failed(.pluginExecution)
        logFinished(kind: .remoteLoad, operationID: operationID, outcome: outcome)
    }

    private func isCurrentMainLoad(
        token: ChapterToken,
        expectedPaged: Bool,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) -> Bool {
        isActive
            && sessionID == session
            && contentGeneration == generation
            && mainLoadOperationID == operationID
            && ChapterToken(currentChapter) == token
            && isPaged == expectedPaged
            && !Task.isCancelled
    }

    // MARK: - Mode conversion

    private func convertContinuousToPagedOrReload() {
        let allPages = flatPages
        guard let projection = Self.pagedProjection(
            currentChapter: currentChapter,
            segments: segments,
            flatPages: allPages,
            continuousPageIndex: continuousPageIndex
        ) else {
            loadPhase = .loading
            beginMainLoad(for: currentChapter)
            return
        }

        pagedPages = projection.pages
        pagedIndex = projection.index
        loadPhase = .content
    }

    private func convertPagedToContinuousOrReload() {
        guard !pagedPages.isEmpty else {
            loadPhase = .loading
            beginMainLoad(for: currentChapter)
            return
        }

        segments = [ChapterSegment(chapter: currentChapter, pages: pagedPages)]
        let position = min(max(pagedIndex, 0), pagedPages.count - 1)
        continuousPageIndex = position
        scrollTarget = MangaScrollRequest(
            pageID: FlatPage.id(chapterKey: currentChapter.key, position: position),
            animated: false
        )
        loadPhase = .content
    }
}
