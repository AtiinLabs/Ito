import Foundation
import ito_runner

/// Whether a tracker step an effect task already owns may still run. A reader that is closed shuts it; a
/// reader that hands off to the other one leaves it open, because the route goes on.
@MainActor
final class ReaderEffectGate {
    var isOpen = true
}

/// What opening, reading and finishing a chapter record, kept out of the main file. History, completion
/// claims and position writes belong to the route's session, so a renderer swap cannot repeat or reorder
/// them. A reader that is not live yet records nothing.
extension MangaReaderViewModel {
    /// Records the chapter in history once per route; crossing back and forth over a chapter
    /// boundary, or between readers, does not add a row each time.
    func chapterOpened(_ chapter: Manga.Chapter) {
        guard presentationMode.isLive, routeSession.claimHistory(chapter) else { return }
        dependencies.history.recordChapter(
            of: entry,
            chapter: HistoryChapter(chapter, format: .pages),
            pluginID: pluginID
        )
    }

    /// Saves where the reader is, and marks the chapter read once its last page is shown.
    func pageShown(in chapter: Manga.Chapter, at page: Int, pageCount: Int) {
        savePage(page, in: chapter)
        if page == pageCount - 1 {
            markChapterFinished(chapter)
        }
    }

    func savePage(_ page: Int, in chapter: Manga.Chapter) {
        guard presentationMode.isLive else { return }
        if let lastSavedPage, lastSavedPage.chapterKey == chapter.key, lastSavedPage.page == page {
            return
        }
        lastSavedPage = (chapter.key, page)
        let progress = dependencies.progress
        let identity = mediaIdentity
        routeSession.enqueuePositionWrite {
            // Saving the position is best effort; reading carries on if it fails.
            try? await progress.savePage(page, media: identity, chapterID: chapter.key)
        }
    }

    func markChapterFinished(_ chapter: Manga.Chapter) {
        guard presentationMode.isLive else { return }
        let plan = ReaderSessionEffectPlan.chapterFinished(
            chapterNumber: chapter.chapterNumber,
            titleOrKey: chapter.title ?? chapter.key,
            alreadyMarked: routeSession.hasClaimedCompletion(chapter.key)
        )
        guard !plan.effects.isEmpty, routeSession.claimCompletion(chapter) else { return }
        let operationID = UUID()
        let routeSession = routeSession
        let gate = effectGate
        let progress = dependencies.progress
        let tracker = dependencies.tracker
        let context = completionContext
        logStarted(kind: .chapterEffects, operationID: operationID)

        let task = Task { @MainActor [weak self, progress, tracker] in
            do {
                for effect in plan.effects {
                    switch effect {
                    case .markLocalProgress:
                        try await progress.markChapterRead(context: context, chapterID: chapter.key, chapterNumber: chapter.chapterNumber)
                    case .updateTracker(let progressValue):
                        // Needs this reader open and the route's source scope unchanged, not this reader's
                        // own survival: a renderer swap retires the reader that started the step.
                        guard gate.isOpen,
                              routeSession.allowsTracker(context: context),
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

    // MARK: - Operation invalidation

    func invalidateContentOperations() {
        contentGeneration &+= 1
        cancelContentOperations()
    }

    func cancelContentOperations() {
        mainLoadTask?.cancel()
        mainLoadTask = nil
        mainLoadOperationID = nil
        adjacentPrefetchTask?.cancel()
        adjacentPrefetchTask = nil
        adjacentPrefetchOperationID = nil
        appendTask?.cancel()
        appendTask = nil
        appendOperationID = nil
        appendPrefetchEpoch = nil
        appendBoundary = nil
        appendSession = nil
        appendGeneration = nil
        prependTask?.cancel()
        prependTask = nil
        prependOperationID = nil
        loadingNextChapter = false
        loadingPrevChapter = false
        appendFailed = false
        prependFailed = false
    }

#if DEBUG
    var appendTaskForTesting: Task<Void, Never>? { appendTask }
    func waitForTestingOperations() async {
        await settingsWriteTask?.value
        await mainLoadTask?.value
        await adjacentPrefetchTask?.value
        await appendTask?.value
        await prependTask?.value
        await routeSession.waitForPositionWritesForTesting()
    }
#endif
}
