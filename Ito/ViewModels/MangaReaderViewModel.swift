import Combine
import Foundation
import ito_runner

@MainActor
final class MangaReaderViewModel: ObservableObject {
    let pluginID: String
    let entry: MediaEntry
    let pageLoader: any MangaPageLoading

    @Published private(set) var currentChapter: Manga.Chapter
    @Published private(set) var loadPhase: MangaReaderLoadPhase = .idle
    @Published private(set) var overrideViewer: Manga.Viewer = .Default
    @Published private(set) var preloadImageCount: Int

    @Published private(set) var pagedPages: [Page] = [] {
        didSet { retainImageRequestsForChapterWindow() }
    }
    @Published private(set) var pagedIndex = 0
    @Published private(set) var prefetchedChapters: [String: [Page]] = [:] {
        didSet { retainImageRequestsForChapterWindow() }
    }

    @Published private(set) var segments: [ChapterSegment] = [] {
        didSet { rebuildFlatPages() }
    }
    /// Every page of `segments` in reading order; rebuilt only when `segments` changes.
    @Published private(set) var flatPages: [FlatPage] = []
    @Published private(set) var continuousPageIndex = 0
    @Published private(set) var continuousSnapshot = MangaContinuousReaderSnapshot.empty
    @Published private(set) var scrollTarget: MangaScrollRequest?
    @Published private(set) var loadingNextChapter = false {
        didSet { publishContinuousSnapshot() }
    }
    @Published private(set) var loadingPrevChapter = false {
        didSet { publishContinuousSnapshot() }
    }
    @Published private(set) var appendFailed = false {
        didSet { publishContinuousSnapshot() }
    }
    @Published private(set) var prependFailed = false {
        didSet { publishContinuousSnapshot() }
    }

    private(set) var markedChapterKeys: Set<String> = []

    private let dependencies: PreparedMangaReaderDependencies
    private let imagePrefetcher: any MangaReaderImagePrefetching
    let imageSession: ReaderPageImageSession
    private let mediaIdentity: MediaIdentity
    /// Captured once per reader session; every chapter in the session shares it.
    private let completionContext: PluginCompletionContext

    private var isActive = true
    private var hasPresentedPresence = false
    private var sessionID = UUID()
    private var contentGeneration: UInt64 = 0

    private var mainLoadTask: Task<Void, Never>?
    private var mainLoadOperationID: UUID?
    private var adjacentPrefetchTask: Task<Void, Never>?
    private var adjacentPrefetchOperationID: UUID?
    private var appendTask: Task<Void, Never>?
    private var appendOperationID: UUID?
    private var prependTask: Task<Void, Never>?
    private var prependOperationID: UUID?
    private var effectTasks: [UUID: Task<Void, Never>] = [:]
    /// Page writes run one after another so an older write cannot land after a newer one.
    private var pageWriteTask: Task<Void, Never>?
    private var lastSavedPage: (chapterKey: String, page: Int)?
    private var settingsWriteTask: Task<Void, Never>?
    private var viewerWriteTask: Task<Void, Never>?
    private var historyChapterKeys: Set<String> = []
    private var flatPageIndexByID: [String: Int] = [:]
    /// Continuous pages on screen; the topmost is the current page.
    private var visiblePageIDs: Set<String> = []
    private var visiblePageOrder: [String] = []
    private var continuousMutationDepth = 0
    private var continuousSnapshotRevision: UInt64 = 0

    nonisolated deinit {}

    init(
        pageLoader: any MangaPageLoading,
        pluginID: String,
        entry: MediaEntry,
        initialChapter: Manga.Chapter,
        dependencies: PreparedMangaReaderDependencies
    ) {
        self.pageLoader = pageLoader
        self.pluginID = pluginID
        self.entry = entry
        currentChapter = entry.chapters?.first { $0.key == initialChapter.key } ?? initialChapter
        self.dependencies = dependencies
        imagePrefetcher = dependencies.makeImagePrefetcher()
        imageSession = imagePrefetcher.imageSession
        preloadImageCount = dependencies.settings.mangaReaderPreloadImageCount
        mediaIdentity = MediaIdentity(pluginId: pluginID, canonicalMediaId: entry.key, mediaKind: entry.kind)
        completionContext = dependencies.progress.captureCompletionContext(media: mediaIdentity, mediaKey: entry.key)
        overrideViewer = dependencies.progress.savedViewer(media: mediaIdentity) ?? .Default
        publishContinuousSnapshot()
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
            previousChapter: previousChapterForFirstSegment,
            nextChapter: nextChapterForLastSegment,
            loadingPrevious: loadingPrevChapter,
            loadingNext: loadingNextChapter,
            prependFailed: prependFailed,
            appendFailed: appendFailed,
            isWebtoon: activeViewer == .Webtoon
        )
    }

    /// Lets the image session forget requests of pages no longer loaded; their failures with them.
    private func retainImageRequestsForChapterWindow() {
        var pages = segments.flatMap(\.pages)
        if isPaged {
            pages += pagedPages
            for chapter in [chapterBefore(currentChapter), chapterAfter(currentChapter)].compactMap({ $0 }) {
                pages += prefetchedChapters[chapter.key] ?? []
            }
        }
        imageSession.retainRequests(Self.imageKeys(of: pages))
    }

    private func beginContinuousMutation() {
        continuousMutationDepth += 1
    }

    private func endContinuousMutation() {
        guard continuousMutationDepth > 0 else { return }
        continuousMutationDepth -= 1
        if continuousMutationDepth == 0 { publishContinuousSnapshot() }
    }

    // MARK: - Presentation lifecycle

    func start() {
        guard isActive else { return }
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
        let isResumingCancelledLoad = !isActive && loadPhase == .loading
        if !isActive {
            isActive = true
            sessionID = UUID()
        }
        hasPresentedPresence = true
        presentPresence(for: currentChapter, resetTimer: true)
        if isResumingCancelledLoad {
            beginMainLoad(for: currentChapter)
        }
    }

    func disappear() {
        guard isActive else { return }
        isActive = false
        hasPresentedPresence = false
        sessionID = UUID()
        contentGeneration &+= 1
        cancelContentOperations()
        // Not cancelled: a chapter's local read mark is durable progress and must finish even
        // if the reader closes right after the last page. The tracker step checks `isActive`.
        effectTasks.removeAll()
        settingsWriteTask?.cancel()
        settingsWriteTask = nil
        imagePrefetcher.stopPrefetching()
        imageSession.deactivate()
        dependencies.presence.clearMangaReaderPresence()
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
        guard isActive else { return }
        pagedIndex = newIndex
        if newIndex == pagedPages.count,
           let next = chapterAfter(currentChapter) {
            pagedGoToChapter(next)
        } else if newIndex == -1,
           let previous = chapterBefore(currentChapter) {
            // Swiping back past the first page continues from the end of the previous chapter.
            pagedGoToChapter(previous, opensAtEnd: true)
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
        guard isActive else { return }
        guard let next = chapterAfter(currentChapter) else { return }
        if isPaged {
            pagedGoToChapter(next)
        } else {
            continuousGoToChapter(next)
        }
    }

    func goToPreviousChapter() {
        guard isActive else { return }
        guard let previous = chapterBefore(currentChapter) else { return }
        if isPaged {
            pagedGoToChapter(previous)
        } else {
            continuousGoToChapter(previous)
        }
    }

    func consumeScrollTarget(_ target: MangaScrollRequest) {
        guard scrollTarget == target else { return }
        scrollTarget = nil
    }

    /// Receives page IDs ordered by their actual image-frame position in the continuous viewport.
    func continuousViewportChanged(_ pageIDs: [String], preferredPageID: String? = nil) {
        guard isActive, !isPaged else { return }
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
    }

    private func pagedGoToChapter(_ chapter: Manga.Chapter, opensAtEnd: Bool = false) {
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

    private func continuousGoToChapter(_ chapter: Manga.Chapter) {
        // Already loaded: scroll to it rather than throwing the loaded chapters away.
        if let first = flatPages.first(where: { $0.chapter.key == chapter.key }) {
            scrollTarget = MangaScrollRequest(pageID: first.id, animated: false)
            return
        }
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
        currentChapter = chapter
        if changedKey, isActive, hasPresentedPresence {
            presentPresence(for: chapter, resetTimer: false)
        }
    }

    // MARK: - Main chapter loading

    private func beginMainLoad(for chapter: Manga.Chapter, opensAtEnd: Bool = false) {
        guard isActive, !chapter.isPaywalled else { return }
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
        let loader = pageLoader
        let entry = entry
        mainLoadOperationID = operationID
        loadPhase = .loading
        logStarted(kind: .remoteLoad, operationID: operationID)

        mainLoadTask = Task { @MainActor [weak self, loader, entry] in
            do {
                let result = try await loader.pages(for: entry, chapter: chapter)
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
        _ pages: [Page],
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

        let sorted = ReaderPageOrdering.ascending(pages)
        let start = opensAtEnd
            ? max(sorted.count - 1, 0)
            : startPage(for: chapter, pageCount: sorted.count)
        if expectedPaged {
            pagedPages = sorted
            pagedIndex = start
        } else {
            segments = [ChapterSegment(chapter: chapter, pages: sorted)]
            continuousPageIndex = start
            scrollTarget = start > 0
                ? MangaScrollRequest(
                    pageID: FlatPage.id(chapterKey: chapter.key, position: start),
                    animated: false
                )
                : nil
        }
        loadPhase = .content
        mainLoadTask = nil
        mainLoadOperationID = nil
        logFinished(kind: .remoteLoad, operationID: operationID, outcome: .succeeded)
        chapterOpened(chapter)
        if !sorted.isEmpty {
            pageShown(in: chapter, at: start, pageCount: sorted.count)
        }
        if expectedPaged {
            prefetchPagedImages(around: start)
            beginAdjacentChapterPrefetch()
        }
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
        loadPhase = .failure(error.localizedDescription)
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

    // MARK: - Adjacent chapter page prefetch

    private func beginAdjacentChapterPrefetch() {
        adjacentPrefetchTask?.cancel()
        let reference = currentChapter
        let referenceToken = ChapterToken(reference)
        let candidates = [chapterAfter(reference), chapterBefore(reference)].compactMap { $0 }
        let missing = candidates.filter { prefetchedChapters[$0.key] == nil }
        guard !missing.isEmpty, isActive, isPaged else {
            adjacentPrefetchTask = nil
            adjacentPrefetchOperationID = nil
            return
        }

        let operationID = UUID()
        let session = sessionID
        let generation = contentGeneration
        let loader = pageLoader
        let entry = entry
        adjacentPrefetchOperationID = operationID
        logStarted(kind: .chapterPrefetch, operationID: operationID)

        adjacentPrefetchTask = Task { @MainActor [weak self, loader, entry] in
            var hadFailure = false
            for chapter in missing {
                guard self?.isCurrentAdjacentPrefetch(
                    reference: referenceToken,
                    operationID: operationID,
                    session: session,
                    generation: generation
                ) == true else {
                    self?.logFinished(
                        kind: .chapterPrefetch,
                        operationID: operationID,
                        outcome: .ignoredStale
                    )
                    return
                }
                do {
                    let pages = try await loader.pages(for: entry, chapter: chapter)
                    guard self?.isCurrentAdjacentPrefetch(
                        reference: referenceToken,
                        operationID: operationID,
                        session: session,
                        generation: generation
                    ) == true else {
                        self?.logFinished(
                            kind: .chapterPrefetch,
                            operationID: operationID,
                            outcome: .ignoredStale
                        )
                        return
                    }
                    self?.prefetchedChapters[chapter.key] = ReaderPageOrdering.ascending(pages)
                } catch {
                    hadFailure = true
                }
            }
            self?.finishAdjacentPrefetch(operationID: operationID, hadFailure: hadFailure)
        }
    }

    private func isCurrentAdjacentPrefetch(
        reference: ChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) -> Bool {
        isActive
            && isPaged
            && sessionID == session
            && contentGeneration == generation
            && adjacentPrefetchOperationID == operationID
            && ChapterToken(currentChapter) == reference
            && !Task.isCancelled
    }

    private func finishAdjacentPrefetch(operationID: UUID, hadFailure: Bool) {
        guard adjacentPrefetchOperationID == operationID else { return }
        adjacentPrefetchTask = nil
        adjacentPrefetchOperationID = nil
        logFinished(
            kind: .chapterPrefetch,
            operationID: operationID,
            outcome: hadFailure ? .partiallySucceeded(.pluginExecution) : .succeeded
        )
    }

    // MARK: - Continuous chapter loading

    /// Retries the next-chapter append after `appendFailed`.
    func retryAppendNextChapter() {
        guard appendFailed else { return }
        appendFailed = false
        appendNextChapter()
    }

    func appendNextChapter() {
        guard isActive,
              !loadingNextChapter,
              !appendFailed,
              appendOperationID == nil,
              !isPaged,
              let last = segments.last,
              let chapter = chapterAfter(last.chapter) else { return }

        loadingNextChapter = true
        let boundary = ChapterToken(last.chapter)
        let operationID = UUID()
        let session = sessionID
        let generation = contentGeneration
        let loader = pageLoader
        let entry = entry
        appendOperationID = operationID
        logStarted(kind: .chapterAppend, operationID: operationID)

        appendTask = Task { @MainActor [weak self, loader, entry] in
            do {
                let pages = try await loader.pages(for: entry, chapter: chapter)
                self?.completeAppend(
                    pages,
                    chapter: chapter,
                    boundary: boundary,
                    operationID: operationID,
                    session: session,
                    generation: generation
                )
            } catch {
                self?.finishAppendFailure(
                    operationID: operationID,
                    session: session,
                    generation: generation
                )
            }
        }
    }

    private func completeAppend(
        _ pages: [Page],
        chapter: Manga.Chapter,
        boundary: ChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) {
        guard isCurrentAppend(
            boundary: boundary,
            operationID: operationID,
            session: session,
            generation: generation
        ) else {
            logFinished(kind: .chapterAppend, operationID: operationID, outcome: .ignoredStale)
            return
        }
        let sorted = ReaderPageOrdering.ascending(pages)
        beginContinuousMutation()
        defer { endContinuousMutation() }
        // An empty chapter is a failure: appending it would make the next one due at once.
        guard !sorted.isEmpty else {
            appendFailed = true
            finishAppend(operationID: operationID, outcome: .failed(.pluginExecution))
            return
        }
        segments.append(ChapterSegment(chapter: chapter, pages: sorted))
        finishAppend(operationID: operationID, outcome: .succeeded)
        trimLoadedSegments(awayFrom: .bottom)
    }

    private func finishAppendFailure(
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) {
        guard isActive,
              sessionID == session,
              contentGeneration == generation,
              appendOperationID == operationID else {
            logFinished(kind: .chapterAppend, operationID: operationID, outcome: .ignoredStale)
            return
        }
        appendFailed = true
        finishAppend(operationID: operationID, outcome: .failed(.pluginExecution))
    }

    private func finishAppend(operationID: UUID, outcome: PresentationEventOutcome) {
        guard appendOperationID == operationID else { return }
        appendTask = nil
        appendOperationID = nil
        loadingNextChapter = false
        logFinished(kind: .chapterAppend, operationID: operationID, outcome: outcome)
    }

    private func isCurrentAppend(
        boundary: ChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) -> Bool {
        isActive
            && !isPaged
            && sessionID == session
            && contentGeneration == generation
            && appendOperationID == operationID
            && segments.last.map(ChapterToken.init) == boundary
            && !Task.isCancelled
    }

    func prependPreviousChapter() {
        guard isActive,
              !loadingPrevChapter,
              prependOperationID == nil,
              !isPaged,
              let first = segments.first,
              let chapter = chapterBefore(first.chapter) else { return }

        loadingPrevChapter = true
        prependFailed = false
        let boundary = ChapterToken(first.chapter)
        let operationID = UUID()
        let session = sessionID
        let generation = contentGeneration
        let loader = pageLoader
        let entry = entry
        prependOperationID = operationID
        logStarted(kind: .chapterPrepend, operationID: operationID)

        prependTask = Task { @MainActor [weak self, loader, entry] in
            do {
                let pages = try await loader.pages(for: entry, chapter: chapter)
                self?.completePrepend(
                    pages,
                    chapter: chapter,
                    boundary: boundary,
                    operationID: operationID,
                    session: session,
                    generation: generation
                )
            } catch {
                self?.finishPrependFailure(
                    operationID: operationID,
                    session: session,
                    generation: generation
                )
            }
        }
    }

    private func completePrepend(
        _ pages: [Page],
        chapter: Manga.Chapter,
        boundary: ChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) {
        guard isCurrentPrepend(
            boundary: boundary,
            operationID: operationID,
            session: session,
            generation: generation
        ) else {
            logFinished(kind: .chapterPrepend, operationID: operationID, outcome: .ignoredStale)
            return
        }

        let sorted = ReaderPageOrdering.ascending(pages)
        beginContinuousMutation()
        defer { endContinuousMutation() }
        guard !sorted.isEmpty else {
            prependFailed = true
            finishPrepend(operationID: operationID, outcome: .failed(.pluginExecution))
            return
        }
        segments.insert(ChapterSegment(chapter: chapter, pages: sorted), at: 0)
        finishPrepend(operationID: operationID, outcome: .succeeded)
        trimLoadedSegments(awayFrom: .top)
    }

    /// Drops loaded chapters beyond `maximumLoadedSegments` from the end away from the one
    /// that just grew, keeping one chapter past the current one. Skips an end that is still
    /// loading, whose result is matched against that end.
    private func trimLoadedSegments(awayFrom grownEnd: LoadedEnd) {
        guard segments.count > Self.maximumLoadedSegments,
              flatPages.indices.contains(continuousPageIndex) else { return }
        let current = flatPages[continuousPageIndex]
        let excess = segments.count - Self.maximumLoadedSegments

        switch grownEnd {
        case .bottom:
            let firstVisible = visiblePageIDs.compactMap { flatPageIndexByID[$0] }
                .map { flatPages[$0].segmentIndex }.min()
            let removable = min(current.segmentIndex - 1, firstVisible ?? Int.max)
            guard prependOperationID == nil, removable > 0 else { return }
            segments.removeFirst(min(excess, removable))
        case .top:
            let lastVisible = visiblePageIDs.compactMap { flatPageIndexByID[$0] }
                .map { flatPages[$0].segmentIndex }.max()
            let removable = min(
                segments.count - 1 - (current.segmentIndex + 1),
                lastVisible.map { segments.count - 1 - $0 } ?? Int.max
            )
            guard appendOperationID == nil, removable > 0 else { return }
            segments.removeLast(min(excess, removable))
        }
    }

    private enum LoadedEnd {
        case top
        case bottom
    }

    private func finishPrependFailure(
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) {
        guard isActive,
              sessionID == session,
              contentGeneration == generation,
              prependOperationID == operationID else {
            logFinished(kind: .chapterPrepend, operationID: operationID, outcome: .ignoredStale)
            return
        }
        prependFailed = true
        finishPrepend(operationID: operationID, outcome: .failed(.pluginExecution))
    }

    private func finishPrepend(operationID: UUID, outcome: PresentationEventOutcome) {
        guard prependOperationID == operationID else { return }
        prependTask = nil
        prependOperationID = nil
        loadingPrevChapter = false
        logFinished(kind: .chapterPrepend, operationID: operationID, outcome: outcome)
    }

    private func isCurrentPrepend(
        boundary: ChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) -> Bool {
        isActive
            && !isPaged
            && sessionID == session
            && contentGeneration == generation
            && prependOperationID == operationID
            && segments.first.map(ChapterToken.init) == boundary
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
        let position = pagedPages.indices.contains(pagedIndex) ? pagedIndex : 0
        continuousPageIndex = position
        scrollTarget = MangaScrollRequest(
            pageID: FlatPage.id(chapterKey: currentChapter.key, position: position),
            animated: false
        )
        loadPhase = .content
    }

    // MARK: - Chapter effects

    /// The page to open `chapter` at: where the reader stopped last time, unless that was the
    /// last page, which means the chapter was finished and starts over.
    private func startPage(for chapter: Manga.Chapter, pageCount: Int) -> Int {
        guard let saved = dependencies.progress.savedPage(
            media: mediaIdentity,
            chapterID: chapter.key
        ), saved > 0, saved < pageCount - 1 else { return 0 }
        return saved
    }

    /// Records the chapter in history once per reader session; crossing back and forth over a
    /// chapter boundary does not add a row each time.
    private func chapterOpened(_ chapter: Manga.Chapter) {
        guard historyChapterKeys.insert(chapter.key).inserted else { return }
        dependencies.history.recordChapter(
            of: entry,
            chapterKey: chapter.key,
            chapterTitle: chapter.title ?? chapter.key,
            pluginID: pluginID
        )
    }

    /// Saves where the reader is, and marks the chapter read once its last page is shown.
    private func pageShown(in chapter: Manga.Chapter, at page: Int, pageCount: Int) {
        savePage(page, in: chapter)
        if page == pageCount - 1 {
            markChapterFinished(chapter)
        }
    }

    private func savePage(_ page: Int, in chapter: Manga.Chapter) {
        if let lastSavedPage, lastSavedPage.chapterKey == chapter.key, lastSavedPage.page == page {
            return
        }
        lastSavedPage = (chapter.key, page)
        let progress = dependencies.progress
        let identity = mediaIdentity
        let preceding = pageWriteTask
        pageWriteTask = Task { @MainActor [progress] in
            await preceding?.value
            // Saving the position is best effort; reading carries on if it fails.
            try? await progress.savePage(page, media: identity, chapterID: chapter.key)
        }
    }

    func markChapterFinished(_ chapter: Manga.Chapter) {
        let plan = ReaderSessionEffectPlan.chapterFinished(
            chapterNumber: chapter.chapter,
            titleOrKey: chapter.title ?? chapter.key,
            alreadyMarked: markedChapterKeys.contains(chapter.key)
        )
        guard !plan.effects.isEmpty else { return }
        markedChapterKeys.insert(chapter.key)
        let operationID = UUID()
        let session = sessionID
        let progress = dependencies.progress
        let tracker = dependencies.tracker
        let context = completionContext
        logStarted(kind: .chapterEffects, operationID: operationID)

        let task = Task { @MainActor [weak self, progress, tracker] in
            do {
                for effect in plan.effects {
                    switch effect {
                    case .markLocalProgress:
                        try await progress.markChapterRead(context: context, chapterID: chapter.key, chapterNumber: chapter.chapter)
                    case .updateTracker(let progressValue):
                        guard let self,
                              self.isActive,
                              self.sessionID == session,
                              !Task.isCancelled else { return }
                        await tracker.updateMangaProgress(media: context.media, progress: progressValue)
                    }
                }
                self?.finishEffect(operationID: operationID, outcome: .succeeded)
            } catch {
                self?.finishEffect(
                    operationID: operationID,
                    outcome: .failed(.persistence)
                )
            }
        }
        effectTasks[operationID] = task
    }

    private func finishEffect(operationID: UUID, outcome: PresentationEventOutcome) {
        guard effectTasks.removeValue(forKey: operationID) != nil else { return }
        logFinished(kind: .chapterEffects, operationID: operationID, outcome: outcome)
    }

    // MARK: - Image prefetch

    private func prefetchPagedImages(around index: Int) {
        preload(Self.pagesToPreload(after: index, count: preloadImageCount, in: pagedPages) { $0 })
    }

    private func prefetchContinuousImages(around index: Int, allPages: [FlatPage]) {
        preload(Self.pagesToPreload(after: index, count: preloadImageCount, in: allPages) { $0.page })
    }

    private func preload(_ pages: [Page]) {
        guard !pages.isEmpty else { return }
        imagePrefetcher.prefetch(pages)
    }

    // MARK: - Discord presence

    private func presentPresence(for chapter: Manga.Chapter, resetTimer: Bool) {
        guard isActive else { return }
        dependencies.presence.presentMangaReaderPresence(
            Self.presence(
                entry: entry,
                chapter: chapter,
                anilistID: dependencies.tracker.anilistID(for: mediaIdentity),
                pluginName: dependencies.pluginMetadata.displayName(for: pluginID),
                resetTimer: resetTimer
            )
        )
    }

    // MARK: - Operation invalidation and logging

    private func invalidateContentOperations() {
        contentGeneration &+= 1
        cancelContentOperations()
    }

    private func cancelContentOperations() {
        mainLoadTask?.cancel()
        mainLoadTask = nil
        mainLoadOperationID = nil
        adjacentPrefetchTask?.cancel()
        adjacentPrefetchTask = nil
        adjacentPrefetchOperationID = nil
        appendTask?.cancel()
        appendTask = nil
        appendOperationID = nil
        prependTask?.cancel()
        prependTask = nil
        prependOperationID = nil
        loadingNextChapter = false
        loadingPrevChapter = false
        appendFailed = false
        prependFailed = false
    }

    private func logStarted(kind: PresentationEventKind, operationID: UUID) {
        dependencies.presentationLogger.log(
            .started(feature: .mangaReader, kind: kind, operationID: operationID)
        )
    }

    private func logFinished(
        kind: PresentationEventKind,
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        dependencies.presentationLogger.log(
            .finished(
                feature: .mangaReader,
                kind: kind,
                operationID: operationID,
                outcome: outcome
            )
        )
    }

#if DEBUG
    func waitForTestingOperations() async {
        await mainLoadTask?.value
        await adjacentPrefetchTask?.value
        await appendTask?.value
        await prependTask?.value
    }
#endif
}
