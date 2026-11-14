import Foundation
import ito_runner

/// Helpers of the reader that read only its published state and dependencies, kept out of the main file.
extension MangaReaderViewModel {
    enum ChapterAppendTrigger: Equatable {
        case reader
        case speculative
    }

    func isCurrentAppend(
        boundary: ChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) -> Bool {
        isActive
            && speculativeAppendAdmitted
            && !isPaged
            && sessionID == session
            && contentGeneration == generation
            && appendOperationID == operationID
            && segments.last.map(ChapterToken.init) == boundary
            && !Task.isCancelled
    }

    var speculativeAppendAdmitted: Bool {
        guard let appendPrefetchEpoch else { return true }
        return dependencies.settings.mangaReaderAdjacentPrefetchCount > 0
            && appendPrefetchEpoch == dependencies.settings.mangaReaderPrefetchEpoch
    }

    /// Retires an invalid speculative append exactly once. If its session, content boundary and visible loaded end
    /// still match, transfer continuation to a fresh reader-intent operation before cancelling the old task.
    func retireStaleSpeculativeAppend(
        operationID: UUID,
        boundary: ChapterToken,
        session: UUID,
        generation: UInt64
    ) -> Bool {
        guard appendOperationID == operationID,
              appendPrefetchEpoch != nil,
              !speculativeAppendAdmitted else { return false }
        let mayContinue = isActive
            && !isPaged
            && sessionID == session
            && contentGeneration == generation
            && segments.last.map(ChapterToken.init) == boundary
            && readerIsAtLoadedEnd
        let task = appendTask
        finishAppend(operationID: operationID, outcome: .ignoredStale)
        task?.cancel()
        if mayContinue {
            appendNextChapter(trigger: .reader)
        }
        return true
    }

    /// A settings/path notification retires using the append's captured scope. The old task's cancellation state
    /// never decides whether an interactive continuation may start.
    func cancelSpeculativeAppendIfNeeded() {
        guard !speculativeAppendAdmitted,
              let operationID = appendOperationID,
              let boundary = appendBoundary,
              let session = appendSession,
              let generation = appendGeneration else { return }
        _ = retireStaleSpeculativeAppend(
            operationID: operationID, boundary: boundary, session: session, generation: generation
        )
    }

    /// A network policy or setting change. A running adjacent prefetch is cancelled only when it is no longer
    /// allowed, or was admitted under an epoch that has moved; a change that leaves it allowed, such as a batch's
    /// consent expiring, does not touch it. When prefetching is allowed and none is running, it starts again for
    /// the neighbours still missing.
    func networkPolicyDidChange() {
        guard isActive else { return }
        let settings = dependencies.settings
        if settings.mangaReaderEffectivePreloadImageCount == 0 {
            imagePrefetcher.stopPrefetching()
        }
        let admitted = settings.mangaReaderAdjacentPrefetchCount > 0
        if adjacentPrefetchOperationID != nil, !admitted || adjacentPrefetchEpoch != settings.mangaReaderPrefetchEpoch {
            cancelAdjacentChapterPrefetch()
        }
        if admitted, adjacentPrefetchOperationID == nil {
            applyOfflineChange()
        }
        cancelSpeculativeAppendIfNeeded()
    }

    /// The neighbouring chapters to prefetch. One means the following chapter only; two adds the preceding one. A
    /// missing following chapter never lets the preceding one stand in for it.
    func adjacentPrefetchCandidates(for reference: Manga.Chapter) -> [Manga.Chapter] {
        let count = dependencies.settings.mangaReaderAdjacentPrefetchCount
        return [
            count >= 1 ? boundaryAfter(reference).chapter : nil,
            count >= 2 ? boundaryBefore(reference).chapter : nil
        ].compactMap { $0 }
    }

    func finishAppendFailure(
        operationID: UUID,
        boundary: ChapterToken,
        session: UUID,
        generation: UInt64
    ) {
        guard isActive,
              speculativeAppendAdmitted,
              sessionID == session,
              contentGeneration == generation,
              appendOperationID == operationID else {
            logFinished(kind: .chapterAppend, operationID: operationID, outcome: .ignoredStale)
            if !retireStaleSpeculativeAppend(
                operationID: operationID, boundary: boundary, session: session, generation: generation
            ) {
                finishAppend(operationID: operationID, outcome: .ignoredStale)
            }
            return
        }
        finishAppend(operationID: operationID, outcome: .failed(.pluginExecution))
    }
    /// The page to open `chapter` at: where the reader stopped last time, unless that was the
    /// last page, which means the chapter was finished and starts over.
    func startPage(for chapter: Manga.Chapter, pageCount: Int) -> Int {
        guard let saved = dependencies.progress.savedPage(
            media: mediaIdentity,
            chapterID: chapter.key
        ), saved > 0, saved < pageCount - 1 else { return 0 }
        return saved
    }

    /// Lets the image session forget requests of pages no longer loaded; their failures with them.
    func retainImageRequestsForChapterWindow() {
        var pages = segments.flatMap(\.pages)
        if isPaged {
            pages += pagedPages
            for chapter in [boundaryBefore(currentChapter).candidate, boundaryAfter(currentChapter).candidate].compactMap({ $0 }) {
                pages += prefetchedChapters[chapter.key] ?? []
            }
        }
        imageSession.retainRequests(Self.imageKeys(of: pages))
    }

    // MARK: - Image prefetch

    /// Starts at the page being shown: turning to a page still downloading must not drop its
    /// prefetch, which would cancel the download just before the page's view asks for it.
    func prefetchPagedImages(around index: Int) {
        let count = dependencies.settings.mangaReaderEffectivePreloadImageCount
        preload(Self.pagesToPreload(after: index - 1, count: count > 0 ? count + 1 : 0, in: pagedPages) { $0 })
    }

    func prefetchContinuousImages(around index: Int, allPages: [FlatPage]) {
        preload(Self.pagesToPreload(after: index, count: dependencies.settings.mangaReaderEffectivePreloadImageCount, in: allPages) { $0.page })
    }

    func preload(_ pages: [Page]) {
        guard !pages.isEmpty else { return }
        guard dependencies.settings.mangaReaderEffectivePreloadImageCount > 0 else {
            imagePrefetcher.stopPrefetching()
            return
        }
        imagePrefetcher.prefetch(pages)
    }

    // MARK: - Discord presence

    func presentPresence(for chapter: Manga.Chapter, resetTimer: Bool) {
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

    func logStarted(kind: PresentationEventKind, operationID: UUID) {
        dependencies.presentationLogger.log(
            .started(feature: .mangaReader, kind: kind, operationID: operationID)
        )
    }

    /// Logs the end of an operation once; a later finish of the same operation is not logged again.
    func logFinished(
        kind: PresentationEventKind,
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        guard finalizedLogOperations.insert(operationID).inserted else { return }
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
