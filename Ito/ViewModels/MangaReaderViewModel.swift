import Combine
import Foundation
import ito_runner

@MainActor
final class MangaReaderViewModel: ObservableObject {
    let pluginID: String
    let manga: Manga
    let pageLoader: any MangaPageLoading

    @Published private(set) var currentChapter: Manga.Chapter
    @Published private(set) var loadPhase: MangaReaderLoadPhase = .idle
    @Published private(set) var overrideViewer: Manga.Viewer = .Default
    @Published private(set) var preloadImageCount: Int

    @Published private(set) var pagedPages: [Page] = []
    @Published private(set) var pagedIndex = 0
    @Published private(set) var prefetchedChapters: [String: [Page]] = [:]

    @Published private(set) var segments: [ChapterSegment] = [] {
        didSet { rebuildFlatPages() }
    }
    /// Every page of `segments` in reading order; rebuilt only when `segments` changes.
    @Published private(set) var flatPages: [FlatPage] = []
    @Published private(set) var continuousPageIndex = 0
    @Published private(set) var scrollTarget: MangaScrollRequest?
    @Published private(set) var loadingNextChapter = false
    @Published private(set) var loadingPrevChapter = false
    /// The last automatic append failed; it waits for `retryAppendNextChapter` instead of
    /// running again each time the end of the list comes into view.
    @Published private(set) var appendFailed = false
    @Published private(set) var prependFailed = false

    private(set) var markedChapterKeys: Set<String> = []

    private let dependencies: PreparedMangaReaderDependencies
    private let imagePrefetcher: any MangaReaderImagePrefetching
    private let mediaIdentity: MediaIdentity

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
    private var flatPageIndexByID: [String: Int] = [:]
    /// Continuous pages on screen; the topmost is the current page.
    private var visiblePageIDs: Set<String> = []

    nonisolated deinit {}

    init(
        pageLoader: any MangaPageLoading,
        pluginID: String,
        manga: Manga,
        initialChapter: Manga.Chapter,
        dependencies: PreparedMangaReaderDependencies
    ) {
        self.pageLoader = pageLoader
        self.pluginID = pluginID
        self.manga = manga
        currentChapter = initialChapter
        self.dependencies = dependencies
        imagePrefetcher = dependencies.makeImagePrefetcher()
        preloadImageCount = dependencies.settings.mangaReaderPreloadImageCount
        mediaIdentity = MediaIdentity(pluginId: pluginID, itemId: manga.key)
        overrideViewer = dependencies.progress.savedViewer(media: mediaIdentity) ?? .Default
    }

    var activeViewer: Manga.Viewer {
        if overrideViewer != .Default { return overrideViewer }
        if manga.viewer != .Default { return manga.viewer }
        return .Rtl
    }

    var isPaged: Bool {
        Self.isPagedViewer(activeViewer)
    }

    /// Most chapters kept loaded in continuous mode; chapters far from the reader are dropped.
    static let maximumLoadedSegments = 4

    private func rebuildFlatPages() {
        let currentID = flatPages.indices.contains(continuousPageIndex)
            ? flatPages[continuousPageIndex].id
            : nil
        var result: [FlatPage] = []
        var indexByID: [String: Int] = [:]
        for (segmentIndex, segment) in segments.enumerated() {
            for (position, page) in segment.pages.enumerated() {
                let id = FlatPage.id(chapterKey: segment.chapter.key, position: position)
                indexByID[id] = result.count
                result.append(
                    FlatPage(
                        id: id,
                        segmentIndex: segmentIndex,
                        chapter: segment.chapter,
                        page: page,
                        globalIndex: result.count,
                        chapterPosition: position
                    )
                )
            }
        }
        flatPages = result
        flatPageIndexByID = indexByID
        visiblePageIDs = visiblePageIDs.filter { indexByID[$0] != nil }
        // Keep pointing at the same page when chapters are added or dropped before it.
        if let currentID, let index = indexByID[currentID] {
            continuousPageIndex = index
        }
    }

    var nextChapterForLastSegment: Manga.Chapter? {
        guard let last = segments.last else { return nil }
        return chapterAfter(last.chapter)
    }

    var previousChapterForFirstSegment: Manga.Chapter? {
        guard let first = segments.first else { return nil }
        return chapterBefore(first.chapter)
    }

    static func isPagedViewer(_ viewer: Manga.Viewer) -> Bool {
        switch viewer {
        case .Ltr, .Rtl, .Default:
            return true
        case .Vertical, .Webtoon:
            return false
        }
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
        for task in effectTasks.values { task.cancel() }
        effectTasks.removeAll()
        settingsWriteTask?.cancel()
        settingsWriteTask = nil
        imagePrefetcher.stopPrefetching()
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

    func chapterAfter(_ chapter: Manga.Chapter) -> Manga.Chapter? {
        ReaderChapterOrdering.mangaChapter(
            after: chapter,
            in: manga.chapters,
            preferredScanlator: currentChapter.scanlator
        )
    }

    func chapterBefore(_ chapter: Manga.Chapter) -> Manga.Chapter? {
        ReaderChapterOrdering.mangaChapter(
            before: chapter,
            in: manga.chapters,
            preferredScanlator: currentChapter.scanlator
        )
    }

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

    /// The current page within its chapter and that chapter's page count, as paged mode counts.
    var continuousChapterPage: (index: Int, count: Int) {
        guard flatPages.indices.contains(continuousPageIndex) else { return (0, 0) }
        let page = flatPages[continuousPageIndex]
        let count = segments.indices.contains(page.segmentIndex)
            ? segments[page.segmentIndex].pages.count
            : 0
        return (page.chapterPosition, count)
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

    func continuousPageAppeared(_ appeared: FlatPage) {
        // Look the page up by id: positions shift when chapters are added or dropped above it.
        guard isActive, let index = flatPageIndexByID[appeared.id] else { return }
        visiblePageIDs.insert(appeared.id)
        let flatPage = flatPages[index]
        // The last page of the list may never reach the top, so finishing counts once it shows.
        if segments.indices.contains(flatPage.segmentIndex),
           flatPage.chapterPosition == segments[flatPage.segmentIndex].pages.count - 1 {
            markChapterFinished(flatPage.chapter)
        }
        updateCurrentContinuousPage()
        prefetchContinuousImages(around: index, allPages: flatPages)
    }

    func continuousPageDisappeared(_ disappeared: FlatPage) {
        guard isActive, visiblePageIDs.remove(disappeared.id) != nil else { return }
        updateCurrentContinuousPage()
    }

    /// Makes the topmost visible page current, and saves it as the place to come back to.
    private func updateCurrentContinuousPage() {
        guard let index = visiblePageIDs.compactMap({ flatPageIndexByID[$0] }).min() else {
            return
        }
        let flatPage = flatPages[index]
        continuousPageIndex = index
        if flatPage.chapter.key != currentChapter.key {
            changeCurrentChapter(to: flatPage.chapter)
            chapterOpened(flatPage.chapter)
        }
        savePage(flatPage.chapterPosition, in: flatPage.chapter)
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
        guard isActive else { return }
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
        let manga = manga
        mainLoadOperationID = operationID
        loadPhase = .loading
        logStarted(kind: .remoteLoad, operationID: operationID)

        mainLoadTask = Task { @MainActor [weak self, loader, manga] in
            do {
                let result = try await loader.pages(for: manga, chapter: chapter)
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
        let manga = manga
        adjacentPrefetchOperationID = operationID
        logStarted(kind: .chapterPrefetch, operationID: operationID)

        adjacentPrefetchTask = Task { @MainActor [weak self, loader, manga] in
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
                    let pages = try await loader.pages(for: manga, chapter: chapter)
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
        let manga = manga
        appendOperationID = operationID
        logStarted(kind: .chapterAppend, operationID: operationID)

        appendTask = Task { @MainActor [weak self, loader, manga] in
            do {
                let pages = try await loader.pages(for: manga, chapter: chapter)
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
        segments.append(
            ChapterSegment(chapter: chapter, pages: ReaderPageOrdering.ascending(pages))
        )
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
        let manga = manga
        prependOperationID = operationID
        logStarted(kind: .chapterPrepend, operationID: operationID)

        prependTask = Task { @MainActor [weak self, loader, manga] in
            do {
                let pages = try await loader.pages(for: manga, chapter: chapter)
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
        segments.insert(ChapterSegment(chapter: chapter, pages: sorted), at: 0)
        // Content added above the reader pushes it down; jump back to the same page.
        if flatPages.indices.contains(continuousPageIndex) {
            scrollTarget = MangaScrollRequest(
                pageID: flatPages[continuousPageIndex].id,
                animated: false
            )
        }
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
            let removable = current.segmentIndex - 1
            guard prependOperationID == nil, removable > 0 else { return }
            segments.removeFirst(min(excess, removable))
            // Removing content above the reader moves it up; jump back to the same page.
            scrollTarget = MangaScrollRequest(pageID: current.id, animated: false)
        case .top:
            let removable = segments.count - 1 - (current.segmentIndex + 1)
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

    private func chapterOpened(_ chapter: Manga.Chapter) {
        dependencies.history.recordManga(
            manga,
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
        let identity = mediaIdentity
        logStarted(kind: .chapterEffects, operationID: operationID)

        let task = Task { @MainActor [weak self, progress, tracker] in
            do {
                for effect in plan.effects {
                    guard let self,
                          self.isActive,
                          self.sessionID == session,
                          !Task.isCancelled else { return }
                    switch effect {
                    case .markLocalProgress:
                        try await progress.markChapterRead(
                            media: identity,
                            chapterID: chapter.key,
                            chapterNumber: chapter.chapter
                        )
                    case .updateTracker(let progressValue):
                        guard self.isActive,
                              self.sessionID == session,
                              !Task.isCancelled else { return }
                        await tracker.updateMangaProgress(
                            media: identity,
                            progress: progressValue
                        )
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
                manga: manga,
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
}
