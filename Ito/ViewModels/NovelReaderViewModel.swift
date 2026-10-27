import Combine
import Foundation
import ito_runner

enum NovelReaderLoadPhase: Equatable {
    case idle
    case loading
    case content
    case failure(String)
}

struct NovelLoadedChapter: Identifiable, Equatable {
    let id: UUID
    let chapter: Novel.Chapter
    let pages: [Page]

    init(id: UUID = UUID(), chapter: Novel.Chapter, pages: [Page]) {
        self.id = id
        self.chapter = chapter
        self.pages = pages
    }

    static func == (lhs: NovelLoadedChapter, rhs: NovelLoadedChapter) -> Bool {
        lhs.id == rhs.id
    }
}

/// A place to reopen a loaded chapter at; `offset` is a `NovelTextOffsets` offset.
struct NovelReadingAnchor: Equatable {
    let chapterID: UUID
    let offset: Int
}

/// A block of a loaded chapter in continuous mode, by index into its pages; the chapter's
/// heading comes before them all.
struct NovelBlockReference: Hashable {
    static let titleIndex = -1
    let chapterID: UUID
    let index: Int
}

@MainActor
final class NovelReaderViewModel: ObservableObject {
    let pluginID: String
    /// The series being read: a novel, or a manga whose chapter is text.
    let entry: MediaEntry
    let imageSession = ReaderPageImageSession()
    let chapterLoader: any NovelChapterLoading

    @Published private(set) var currentChapter: Novel.Chapter
    @Published private(set) var loadedChapters: [NovelLoadedChapter] = [] {
        didSet {
            let ids = Set(loadedChapters.map(\.id))
            visibleBlocks = visibleBlocks.filter { ids.contains($0.chapterID) }
            visibleChapterEnds.formIntersection(ids)
        }
    }
    @Published private(set) var loadPhase: NovelReaderLoadPhase = .idle
    @Published private(set) var isLoadingNext = false
    /// The last next-chapter load failed; it waits for `retryNextChapter` instead of being
    /// started again by scrolling or page turns.
    @Published private(set) var appendFailed = false
    /// Where the reader should open the loaded chapter; the view applies it once and consumes it.
    @Published private(set) var restoreAnchor: NovelReadingAnchor?

    @Published private(set) var fontSize: Double
    @Published private(set) var lineSpacing: Double
    @Published private(set) var fontFamily: NovelFont
    @Published private(set) var theme: NovelTheme
    @Published private(set) var isPaging: Bool
    @Published private(set) var prefetchChapters: Bool

    private let dependencies: PreparedNovelReaderDependencies
    private let mediaIdentity: MediaIdentity
    /// Captured once per reader session; every chapter in the session shares it.
    private let completionContext: PluginCompletionContext

    private var isActive = true
    private var hasPresentedPresence = false
    private var sessionID = UUID()
    private var contentGeneration: UInt64 = 0

    private var mainLoadTask: Task<Void, Never>?
    private var mainLoadOperationID: UUID?
    private var appendTask: Task<Void, Never>?
    private var appendOperationID: UUID?
    private var effectTasks: [UUID: Task<Void, Never>] = [:]
    private var finishedChapterKeys: Set<String> = []
    /// Continuous-mode blocks on screen; the topmost one is where the reader is.
    private var visibleBlocks: Set<NovelBlockReference> = []
    /// The last place reported in either mode, reopened after switching between them.
    private var lastPosition: NovelReadingAnchor?
    /// Chapters whose end marker is on screen: the reader is at their end.
    private var visibleChapterEnds: Set<UUID> = []
    private var historyChapterKeys: Set<String> = []
    /// Offset writes run one after another so an older write cannot land after a newer one.
    private var offsetWriteTask: Task<Void, Never>?
    private var lastSavedOffset: (chapterKey: String, offset: Int)?
    private var settingsWriteTasks: [UUID: Task<Void, Never>] = [:]
    private var settingsWriteTailTasks: [NovelReaderSettingKind: Task<Void, Never>] = [:]
    private var settingsWriteOperationIDs: [NovelReaderSettingKind: UUID] = [:]
    private var settingsWriteGenerations: [NovelReaderSettingKind: UInt64] = [:]
    private var settingsCancellable: AnyCancellable?
    private var finalizedLogOperations: Set<UUID> = []
#if DEBUG
    private var testingOperationTasks: [UUID: Task<Void, Never>] = [:]
#endif

    nonisolated deinit {}

    init(
        chapterLoader: any NovelChapterLoading,
        pluginID: String,
        entry: MediaEntry,
        initialChapter: Novel.Chapter,
        dependencies: PreparedNovelReaderDependencies
    ) {
        self.chapterLoader = chapterLoader
        self.pluginID = pluginID
        self.entry = entry
        currentChapter = entry.chapters?.first { $0.key == initialChapter.key } ?? initialChapter
        self.dependencies = dependencies
        mediaIdentity = MediaIdentity(pluginId: pluginID, canonicalMediaId: entry.key, mediaKind: entry.kind)
        completionContext = dependencies.progress.captureCompletionContext(
            media: mediaIdentity,
            mediaKey: entry.key
        )

        let settings = dependencies.settings.novelReaderSettings
        fontSize = settings.fontSize
        lineSpacing = settings.lineSpacing
        fontFamily = NovelFont(rawValue: settings.fontFamily.rawValue) ?? .system
        theme = NovelTheme(rawValue: settings.theme.rawValue) ?? .system
        isPaging = settings.isPaging
        prefetchChapters = settings.prefetchChapters

        settingsCancellable = dependencies.settings.novelReaderSettingsUpdates
            .sink { [weak self] settings in
                guard let self, self.isActive else { return }
                self.applySettings(settings)
            }
    }

    var nextChapter: Novel.Chapter? {
        chapterAfter(currentChapter)
    }

    var previousChapter: Novel.Chapter? {
        chapterBefore(currentChapter)
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
        let shouldRestartLoad = !isActive && loadPhase == .loading
        if !isActive {
            isActive = true
            sessionID = UUID()
            applySettings(dependencies.settings.novelReaderSettings)
        }
        hasPresentedPresence = true
        presentPresence(for: currentChapter, resetTimer: true)
        if shouldRestartLoad {
            beginMainLoad(for: currentChapter)
        }
    }

    func disappear() {
        guard isActive else { return }
        isActive = false
        imageSession.deactivate()
        hasPresentedPresence = false
        sessionID = UUID()
        contentGeneration &+= 1
        cancelContentOperations(finishingAs: .cancelled)

        // The local read mark is durable progress and must finish even if the reader closes
        // right after the end, so effect tasks are not cancelled; their tracker step checks
        // that this presentation is still current.
        for operationID in effectTasks.keys {
            logFinishedOnce(
                kind: .chapterEffects,
                operationID: operationID,
                outcome: .cancelled
            )
        }
        effectTasks.removeAll()
        for (operationID, task) in settingsWriteTasks {
            task.cancel()
            logFinishedOnce(
                kind: .preferenceWrite,
                operationID: operationID,
                outcome: .cancelled
            )
        }
        settingsWriteTasks.removeAll()
        settingsWriteTailTasks.removeAll()
        settingsWriteOperationIDs.removeAll()
        dependencies.presence.clearNovelReaderPresence()
    }

    // MARK: - Chapter navigation

    /// Stop at the immediate neighbor when it uses the other reader.
    func chapterAfter(_ chapter: Novel.Chapter) -> Novel.Chapter? {
        ReaderChapterOrdering.novelChapter(after: chapter, in: entry.chapters).flatMap(textChapter)
    }

    func chapterBefore(_ chapter: Novel.Chapter) -> Novel.Chapter? {
        ReaderChapterOrdering.novelChapter(before: chapter, in: entry.chapters).flatMap(textChapter)
    }

    private func textChapter(_ chapter: Novel.Chapter) -> Novel.Chapter? {
        entry.contentKind(of: chapter) == .text ? chapter : nil
    }

    func goToNextChapter() {
        guard let nextChapter else { return }
        goToChapter(nextChapter)
    }

    func goToPreviousChapter() {
        guard let previousChapter else { return }
        goToChapter(previousChapter)
    }

    func goToChapter(_ chapter: Novel.Chapter) {
        let chapter = entry.chapters?.first { $0.key == chapter.key } ?? chapter
        guard isActive, !chapter.isPaywalled else { return }
        changeCurrentChapter(to: chapter)
        loadedChapters = []
        restoreAnchor = nil
        loadPhase = .loading
        invalidateContentOperations()
        beginMainLoad(for: chapter)
    }

    func retry() {
        guard isActive, case .failure = loadPhase else { return }
        loadedChapters = []
        restoreAnchor = nil
        loadPhase = .loading
        invalidateContentOperations()
        beginMainLoad(for: currentChapter)
    }

    func continuousChapterTitleAppeared(_ loadedChapter: NovelLoadedChapter) {
        guard isActive, !isPaging,
              loadedChapters.contains(where: {
                  $0.id == loadedChapter.id
                      && NovelChapterToken($0.chapter) == NovelChapterToken(loadedChapter.chapter)
              }) else { return }
        visibleBlocks.insert(
            NovelBlockReference(chapterID: loadedChapter.id, index: NovelBlockReference.titleIndex)
        )
        updateContinuousPosition()
    }

    func continuousChapterTitleDisappeared(_ loadedChapter: NovelLoadedChapter) {
        guard isActive, !isPaging,
              visibleBlocks.remove(
                  NovelBlockReference(chapterID: loadedChapter.id, index: NovelBlockReference.titleIndex)
              ) != nil
        else { return }
        updateContinuousPosition()
    }

    /// Makes the chapter of the topmost visible block current and saves that place. Scrolling
    /// up into an earlier chapter moves back to it, not only reaching a chapter's title.
    private func updateContinuousPosition() {
        let ranked = visibleBlocks.compactMap { block -> (rank: Int, block: NovelBlockReference)? in
            guard let position = loadedChapters.firstIndex(where: { $0.id == block.chapterID }) else {
                return nil
            }
            return (position, block)
        }
        guard let top = ranked.min(by: {
            ($0.rank, $0.block.index) < ($1.rank, $1.block.index)
        }) else { return }
        let loaded = loadedChapters[top.rank]
        if loaded.chapter.key != currentChapter.key {
            changeCurrentChapter(to: loaded.chapter)
            chapterOpened(loaded.chapter)
        }
        // While the chapter's end is still on screen the reader is at its end, even once the
        // paragraph above has scrolled off the top; saving that paragraph would undo "finished".
        let reachedEnd = visibleChapterEnds.contains(loaded.id)
        let offset = top.block.index == NovelBlockReference.titleIndex
            ? 0
            : NovelTextOffsets.blockStarts(loaded.pages)[top.block.index]
        readingPositionChanged(chapterID: loaded.id, offset: offset, reachedEnd: reachedEnd)
    }

    func pagedChapterChanged(_ chapter: Novel.Chapter) {
        guard isActive,
              loadedChapters.contains(where: {
                  NovelChapterToken($0.chapter) == NovelChapterToken(chapter)
              }),
              currentChapter.key != chapter.key else { return }
        changeCurrentChapter(to: chapter)
        chapterOpened(chapter)
    }

    /// The reader moved to `offset` in a loaded chapter. Saves it, and marks the chapter read
    /// when the end was reached.
    func readingPositionChanged(chapterID: UUID, offset: Int, reachedEnd: Bool) {
        guard isActive,
              let loaded = loadedChapters.first(where: { $0.id == chapterID }) else { return }
        let bodyLength = NovelTextOffsets.bodyLength(loaded.pages)
        let position = reachedEnd ? bodyLength : min(offset, bodyLength)
        lastPosition = NovelReadingAnchor(chapterID: chapterID, offset: position)
        saveOffset(position, in: loaded.chapter)
        if reachedEnd {
            markChapterFinished(loaded.chapter)
        }
    }

    func consumeRestoreAnchor(_ anchor: NovelReadingAnchor) {
        guard restoreAnchor == anchor else { return }
        restoreAnchor = nil
    }

    private func changeCurrentChapter(to chapter: Novel.Chapter) {
        let changedKey = currentChapter.key != chapter.key
        currentChapter = chapter
        if changedKey, isActive, hasPresentedPresence {
            presentPresence(for: chapter, resetTimer: false)
        }
    }

    // MARK: - Main chapter load

    private func beginMainLoad(for chapter: Novel.Chapter) {
        guard isActive, !chapter.isPaywalled else { return }
        let token = NovelChapterToken(chapter)
        if mainLoadOperationID != nil,
           token == NovelChapterToken(currentChapter) {
            return
        }

        let operationID = UUID()
        let session = sessionID
        let generation = contentGeneration
        let loader = chapterLoader
        let entry = entry
        mainLoadOperationID = operationID
        loadPhase = .loading
        logStarted(kind: .remoteLoad, operationID: operationID)

        let task = Task { @MainActor [weak self, loader, entry] in
            defer { self?.finishTestingOperation(operationID) }
            do {
                let pages = try await loader.content(for: entry, chapter: chapter)
                self?.completeMainLoad(
                    pages,
                    chapter: chapter,
                    token: token,
                    operationID: operationID,
                    session: session,
                    generation: generation
                )
            } catch {
                self?.failMainLoad(
                    error,
                    token: token,
                    operationID: operationID,
                    session: session,
                    generation: generation
                )
            }
        }
        mainLoadTask = task
        retainTestingOperation(task, operationID: operationID)
    }

    private func completeMainLoad(
        _ pages: [Page],
        chapter: Novel.Chapter,
        token: NovelChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) {
        guard isCurrentMainLoad(
            token: token,
            operationID: operationID,
            session: session,
            generation: generation
        ) else {
            logFinishedOnce(
                kind: .remoteLoad,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }

        let loaded = NovelLoadedChapter(
            chapter: chapter,
            pages: ReaderPageOrdering.ascending(pages)
        )
        loadedChapters = [loaded]
        restoreAnchor = savedAnchor(for: loaded)
        loadPhase = .content
        mainLoadTask = nil
        mainLoadOperationID = nil
        logFinishedOnce(kind: .remoteLoad, operationID: operationID, outcome: .succeeded)
        chapterOpened(chapter)
    }

    /// Where the reader stopped in `loaded` last time, unless it was finished.
    private func savedAnchor(for loaded: NovelLoadedChapter) -> NovelReadingAnchor? {
        guard let saved = dependencies.progress.savedNovelOffset(
            media: mediaIdentity,
            chapterID: loaded.chapter.key
        ), saved > 0, saved < NovelTextOffsets.bodyLength(loaded.pages) else { return nil }
        return NovelReadingAnchor(chapterID: loaded.id, offset: saved)
    }

    private func failMainLoad(
        _ error: any Error,
        token: NovelChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) {
        guard isCurrentMainLoad(
            token: token,
            operationID: operationID,
            session: session,
            generation: generation
        ) else {
            logFinishedOnce(
                kind: .remoteLoad,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }
        mainLoadTask = nil
        mainLoadOperationID = nil
        loadPhase = .failure(error.localizedDescription)
        let outcome: PresentationEventOutcome = error is CancellationError
            ? .cancelled
            : .failed(.pluginExecution)
        logFinishedOnce(kind: .remoteLoad, operationID: operationID, outcome: outcome)
    }

    private func isCurrentMainLoad(
        token: NovelChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) -> Bool {
        isActive
            && sessionID == session
            && contentGeneration == generation
            && mainLoadOperationID == operationID
            && NovelChapterToken(currentChapter) == token
            && !Task.isCancelled
    }

    // MARK: - Next-chapter append and automatic prefetch

    func continuousPageAppeared(chapterID: UUID, pageIndex: Int) {
        guard isActive, !isPaging,
              let loaded = loadedChapters.first(where: { $0.id == chapterID }),
              loaded.pages.indices.contains(pageIndex) else { return }
        visibleBlocks.insert(NovelBlockReference(chapterID: chapterID, index: pageIndex))
        updateContinuousPosition()
        guard prefetchChapters,
              let last = loadedChapters.last,
              last.id == chapterID,
              pageIndex >= last.pages.count - 5 else { return }
        loadNextChapter()
    }

    func continuousPageDisappeared(chapterID: UUID, pageIndex: Int) {
        guard isActive, !isPaging,
              visibleBlocks.remove(NovelBlockReference(chapterID: chapterID, index: pageIndex)) != nil
        else { return }
        updateContinuousPosition()
    }

    /// The marker after a chapter's last block scrolled into view: the chapter was read to the end.
    func continuousChapterEndAppeared(chapterID: UUID) {
        guard !isPaging else { return }
        visibleChapterEnds.insert(chapterID)
        readingPositionChanged(chapterID: chapterID, offset: .max, reachedEnd: true)
    }

    func continuousChapterEndDisappeared(chapterID: UUID) {
        visibleChapterEnds.remove(chapterID)
    }

    /// Loads the next chapter again after `appendFailed`.
    func retryNextChapter() {
        guard appendFailed else { return }
        appendFailed = false
        loadNextChapter()
    }

    func loadNextChapter() {
        guard isActive,
              appendOperationID == nil,
              !isLoadingNext,
              !appendFailed,
              let last = loadedChapters.last,
              let next = chapterAfter(last.chapter),
              !next.isPaywalled,
              // Never append a chapter twice; ordering must not loop back to a loaded one.
              !loadedChapters.contains(where: { $0.chapter.key == next.key }) else { return }

        let operationID = UUID()
        let session = sessionID
        let generation = contentGeneration
        let boundaryID = last.id
        let boundaryToken = NovelChapterToken(last.chapter)
        let loader = chapterLoader
        let entry = entry
        appendOperationID = operationID
        isLoadingNext = true
        logStarted(kind: .chapterAppend, operationID: operationID)

        let task = Task { @MainActor [weak self, loader, entry] in
            defer { self?.finishTestingOperation(operationID) }
            do {
                let pages = try await loader.content(for: entry, chapter: next)
                self?.completeAppend(
                    pages,
                    chapter: next,
                    boundaryID: boundaryID,
                    boundaryToken: boundaryToken,
                    operationID: operationID,
                    session: session,
                    generation: generation
                )
            } catch {
                self?.failAppend(
                    operationID: operationID,
                    session: session,
                    generation: generation
                )
            }
        }
        appendTask = task
        retainTestingOperation(task, operationID: operationID)
    }

    private func completeAppend(
        _ pages: [Page],
        chapter: Novel.Chapter,
        boundaryID: UUID,
        boundaryToken: NovelChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) {
        guard isCurrentAppend(
            boundaryID: boundaryID,
            boundaryToken: boundaryToken,
            operationID: operationID,
            session: session,
            generation: generation
        ) else {
            logFinishedOnce(
                kind: .chapterAppend,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }
        loadedChapters.append(
            NovelLoadedChapter(
                chapter: chapter,
                pages: ReaderPageOrdering.ascending(pages)
            )
        )
        finishAppend(operationID: operationID, outcome: .succeeded)
    }

    private func failAppend(
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) {
        guard isActive,
              sessionID == session,
              contentGeneration == generation,
              appendOperationID == operationID,
              !Task.isCancelled else {
            logFinishedOnce(
                kind: .chapterAppend,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }
        appendFailed = true
        finishAppend(operationID: operationID, outcome: .failed(.pluginExecution))
    }

    private func finishAppend(
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        guard appendOperationID == operationID else { return }
        appendTask = nil
        appendOperationID = nil
        isLoadingNext = false
        logFinishedOnce(kind: .chapterAppend, operationID: operationID, outcome: outcome)
    }

    private func isCurrentAppend(
        boundaryID: UUID,
        boundaryToken: NovelChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) -> Bool {
        isActive
            && sessionID == session
            && contentGeneration == generation
            && appendOperationID == operationID
            && loadedChapters.last?.id == boundaryID
            && loadedChapters.last.map { NovelChapterToken($0.chapter) } == boundaryToken
            && !Task.isCancelled
    }

    // MARK: - Chapter effects

    /// Records the chapter in history once per reader session; crossing back and forth over a
    /// chapter boundary does not add a row each time.
    private func chapterOpened(_ chapter: Novel.Chapter) {
        guard isActive, historyChapterKeys.insert(chapter.key).inserted else { return }
        dependencies.history.recordChapter(
            of: entry,
            chapterKey: chapter.key,
            chapterTitle: chapter.title ?? chapter.key,
            pluginID: pluginID
        )
    }

    private func saveOffset(_ offset: Int, in chapter: Novel.Chapter) {
        if let lastSavedOffset,
           lastSavedOffset.chapterKey == chapter.key,
           lastSavedOffset.offset == offset {
            return
        }
        lastSavedOffset = (chapter.key, offset)
        let operationID = UUID()
        let progress = dependencies.progress
        let identity = mediaIdentity
        let preceding = offsetWriteTask
        let task = Task { @MainActor [weak self, progress] in
            defer { self?.finishTestingOperation(operationID) }
            await preceding?.value
            // Saving the position is best effort; reading carries on if it fails.
            try? await progress.saveNovelOffset(offset, media: identity, chapterID: chapter.key)
        }
        offsetWriteTask = task
        retainTestingOperation(task, operationID: operationID)
    }

    func markChapterFinished(_ chapter: Novel.Chapter) {
        guard isActive else { return }
        let plan = ReaderSessionEffectPlan.chapterFinished(
            chapterNumber: chapter.chapter,
            titleOrKey: chapter.title ?? chapter.key,
            alreadyMarked: finishedChapterKeys.contains(chapter.key)
        )

        guard !plan.effects.isEmpty else { return }
        finishedChapterKeys.insert(chapter.key)
        let operationID = UUID()
        let session = sessionID
        let progress = dependencies.progress
        let tracker = dependencies.tracker
        let identity = mediaIdentity
        let context = completionContext
        logStarted(kind: .chapterEffects, operationID: operationID)

        let task = Task { @MainActor [weak self, progress, tracker] in
            defer { self?.finishTestingOperation(operationID) }
            do {
                for effect in plan.effects {
                    switch effect {
                    case .markLocalProgress:
                        try await progress.markNovelChapterRead(
                            context: context,
                            chapterID: chapter.key,
                            chapterNumber: chapter.chapter
                        )
                    case .updateTracker(let progressValue):
                        guard let self,
                              self.isCurrentEffect(operationID: operationID, session: session)
                        else { return }
                        await tracker.updateNovelProgress(
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
        retainTestingOperation(task, operationID: operationID)
    }

    private func isCurrentEffect(operationID: UUID, session: UUID) -> Bool {
        isActive
            && sessionID == session
            && effectTasks[operationID] != nil
            && !Task.isCancelled
    }

    private func finishEffect(operationID: UUID, outcome: PresentationEventOutcome) {
        guard effectTasks.removeValue(forKey: operationID) != nil else { return }
        logFinishedOnce(kind: .chapterEffects, operationID: operationID, outcome: outcome)
    }

    // MARK: - Settings

    /// Font sizes the reader offers.
    static let fontSizeRange: ClosedRange<Double> = 10...40
    /// Line spacings the reader offers; the stored preference accepts the same range.
    static let lineSpacingRange: ClosedRange<Double> = 0...40

    // Each setter shows the choice at once, then saves it; a failed save puts back the saved
    // value. Showing it at once also means quick repeated taps build on each other.

    func setFontSize(_ value: Double) {
        guard isActive else { return }
        let clamped = min(max(value, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        fontSize = clamped
        enqueueSettingsWrite(kind: .fontSize) {
            try await $0.setNovelFontSize(clamped)
        }
    }

    func setLineSpacing(_ value: Double) {
        guard isActive else { return }
        let clamped = min(max(value, Self.lineSpacingRange.lowerBound), Self.lineSpacingRange.upperBound)
        lineSpacing = clamped
        enqueueSettingsWrite(kind: .lineSpacing) {
            try await $0.setNovelLineSpacing(clamped)
        }
    }

    func setFontFamily(_ value: NovelFont) {
        guard isActive, let preference = NovelFontPreference(rawValue: value.rawValue) else { return }
        fontFamily = value
        enqueueSettingsWrite(kind: .fontFamily) {
            try await $0.setNovelFontFamily(preference)
        }
    }

    func setTheme(_ value: NovelTheme) {
        guard isActive, let preference = NovelThemePreference(rawValue: value.rawValue) else { return }
        theme = value
        enqueueSettingsWrite(kind: .theme) {
            try await $0.setNovelTheme(preference)
        }
    }

    func setIsPaging(_ value: Bool) {
        guard isActive else { return }
        // The other mode opens where this one was; the continuous view leaving the screen
        // must not move that place, so its callbacks are ignored while paging.
        if value != isPaging, loadPhase == .content, let lastPosition {
            restoreAnchor = lastPosition
        }
        isPaging = value
        enqueueSettingsWrite(kind: .isPaging) {
            try await $0.setNovelIsPaging(value)
        }
    }

    func setPrefetchChapters(_ value: Bool) {
        guard isActive else { return }
        prefetchChapters = value
        enqueueSettingsWrite(kind: .prefetchChapters) {
            try await $0.setNovelPrefetchChapters(value)
        }
    }

    private func enqueueSettingsWrite(
        kind: NovelReaderSettingKind,
        operation: @escaping @MainActor (
            any NovelReaderSettingsAccessing
        ) async throws -> Void
    ) {
        guard isActive else { return }
        let preceding = settingsWriteTailTasks[kind]
        let generation = (settingsWriteGenerations[kind] ?? 0) &+ 1
        settingsWriteGenerations[kind] = generation
        let operationID = UUID()
        let session = sessionID
        let settings = dependencies.settings
        settingsWriteOperationIDs[kind] = operationID
        logStarted(kind: .preferenceWrite, operationID: operationID)

        let task = Task { @MainActor [weak self, settings] in
            defer { self?.finishTestingOperation(operationID) }
            await preceding?.value
            guard let self,
                  self.isActive,
                  self.sessionID == session,
                  !Task.isCancelled else {
                self?.finishSettingsWrite(
                    kind: kind,
                    generation: generation,
                    operationID: operationID,
                    outcome: .cancelled
                )
                return
            }
            do {
                try await operation(settings)
            } catch {
                // Put back the saved value, unless a newer choice is still being saved.
                if self.settingsWriteGenerations[kind] == generation {
                    self.applySetting(kind, from: settings.novelReaderSettings)
                }
                self.finishSettingsWrite(
                    kind: kind,
                    generation: generation,
                    operationID: operationID,
                    outcome: .failed(.persistence)
                )
                return
            }
            guard self.isActive,
                  self.sessionID == session,
                  !Task.isCancelled else {
                self.finishSettingsWrite(
                    kind: kind,
                    generation: generation,
                    operationID: operationID,
                    outcome: .cancelled
                )
                return
            }
            let outcome: PresentationEventOutcome
            if self.settingsWriteGenerations[kind] == generation {
                self.applySetting(kind, from: settings.novelReaderSettings)
                outcome = .succeeded
            } else {
                outcome = .ignoredStale
            }
            self.finishSettingsWrite(
                kind: kind,
                generation: generation,
                operationID: operationID,
                outcome: outcome
            )
        }
        settingsWriteTasks[operationID] = task
        settingsWriteTailTasks[kind] = task
        retainTestingOperation(task, operationID: operationID)
    }

    private func finishSettingsWrite(
        kind: NovelReaderSettingKind,
        generation: UInt64,
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        logFinishedOnce(kind: .preferenceWrite, operationID: operationID, outcome: outcome)
        settingsWriteTasks[operationID] = nil
        guard settingsWriteGenerations[kind] == generation,
              settingsWriteOperationIDs[kind] == operationID else { return }
        settingsWriteTailTasks[kind] = nil
        settingsWriteOperationIDs[kind] = nil
    }

    /// Takes saved settings, except those with a newer choice still being saved.
    private func applySettings(_ settings: NovelReaderSettingsSnapshot) {
        for kind in NovelReaderSettingKind.allCases where settingsWriteOperationIDs[kind] == nil {
            applySetting(kind, from: settings)
        }
    }

    private func applySetting(_ kind: NovelReaderSettingKind, from settings: NovelReaderSettingsSnapshot) {
        switch kind {
        case .fontSize: fontSize = settings.fontSize
        case .lineSpacing: lineSpacing = settings.lineSpacing
        case .fontFamily: fontFamily = NovelFont(rawValue: settings.fontFamily.rawValue) ?? .system
        case .theme: theme = NovelTheme(rawValue: settings.theme.rawValue) ?? .system
        case .isPaging: isPaging = settings.isPaging
        case .prefetchChapters: prefetchChapters = settings.prefetchChapters
        }
    }

    // MARK: - Discord presence

    private func presentPresence(for chapter: Novel.Chapter, resetTimer: Bool) {
        guard isActive else { return }
        let anilistID = dependencies.tracker.novelReaderAnilistID(for: mediaIdentity)
        let detailsURL = anilistID.map { "https://anilist.co/manga/\($0)" }
        let pluginName = dependencies.pluginMetadata.novelReaderPluginDisplayName(for: pluginID)
            ?? "Unknown Plugin"
        let scanlator = chapter.scanlator ?? "Official"
        dependencies.presence.presentNovelReaderPresence(
            NovelReaderPresence(
                details: entry.title,
                state: "Reading \(ReaderChapterTitle.text(title: chapter.title, number: chapter.chapter))",
                activityType: 3,
                detailsURL: detailsURL,
                largeImageText: "Reading from \(scanlator) at \(pluginName)",
                imageURL: entry.cover,
                resetTimer: resetTimer
            )
        )
    }

    // MARK: - Operation invalidation and logging

    private func invalidateContentOperations() {
        contentGeneration &+= 1
        cancelContentOperations(finishingAs: nil)
    }

    private func cancelContentOperations(finishingAs outcome: PresentationEventOutcome?) {
        if let outcome, let operationID = mainLoadOperationID {
            logFinishedOnce(kind: .remoteLoad, operationID: operationID, outcome: outcome)
        }
        mainLoadTask?.cancel()
        mainLoadTask = nil
        mainLoadOperationID = nil

        if let outcome, let operationID = appendOperationID {
            logFinishedOnce(kind: .chapterAppend, operationID: operationID, outcome: outcome)
        }
        appendTask?.cancel()
        appendTask = nil
        appendOperationID = nil
        isLoadingNext = false
        appendFailed = false
    }

    private func logStarted(kind: PresentationEventKind, operationID: UUID) {
        dependencies.presentationLogger.log(
            .started(feature: .novelReader, kind: kind, operationID: operationID)
        )
    }

    private func logFinishedOnce(
        kind: PresentationEventKind,
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        guard finalizedLogOperations.insert(operationID).inserted else { return }
        dependencies.presentationLogger.log(
            .finished(
                feature: .novelReader,
                kind: kind,
                operationID: operationID,
                outcome: outcome
            )
        )
    }

    // Exact task joins keep async tests deterministic without timing heuristics.
#if DEBUG
    func waitForCurrentMainLoadForTesting() async {
        await mainLoadTask?.value
    }

    func waitForAllOperationsForTesting() async {
        while !testingOperationTasks.isEmpty {
            let tasks = Array(testingOperationTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

    private func retainTestingOperation(
        _ task: Task<Void, Never>,
        operationID: UUID
    ) {
        testingOperationTasks[operationID] = task
    }

    private func finishTestingOperation(_ operationID: UUID) {
        testingOperationTasks[operationID] = nil
    }
#else
    private func retainTestingOperation(
        _: Task<Void, Never>,
        operationID _: UUID
    ) {}

    private func finishTestingOperation(_: UUID) {}
#endif
}

private enum NovelReaderSettingKind: Hashable, CaseIterable {
    case fontSize
    case lineSpacing
    case fontFamily
    case theme
    case isPaging
    case prefetchChapters
}

private struct NovelChapterToken: Equatable {
    let key: String
    let title: String?
    let volume: Float32?
    let chapter: Float32?
    let dateUpdated: Double?
    let scanlator: String?
    let url: String?
    let language: String?
    let paywalled: Bool?

    init(_ chapter: Novel.Chapter) {
        key = chapter.key
        title = chapter.title
        volume = chapter.volume
        self.chapter = chapter.chapter
        dateUpdated = chapter.dateUpdated
        scanlator = chapter.scanlator
        url = chapter.url
        language = chapter.lang
        paywalled = chapter.paywalled
    }
}
