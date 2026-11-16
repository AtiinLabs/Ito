import Foundation
import ito_runner

/// What opening, reading and finishing a chapter record, kept out of the main file. History, completion
/// claims and position writes belong to the route's session, so a renderer swap cannot repeat or reorder
/// them. A reader that is not live yet records nothing.
extension NovelReaderViewModel {
    /// Records the chapter in history once per route; crossing back and forth over a chapter
    /// boundary, or between readers, does not add a row each time.
    func chapterOpened(_ chapter: Novel.Chapter) {
        guard isActive,
              presentationMode.isLive,
              let loaded = loadedChapters.first(where: { $0.chapter.key == chapter.key }),
              routeSession.claimHistory(chapter) else { return }
        dependencies.history.recordChapter(
            of: entry,
            chapter: HistoryChapter(
                chapter,
                format: .text,
                textLength: NovelTextOffsets.bodyLength(loaded.pages)
            ),
            pluginID: pluginID
        )
    }

    func saveOffset(_ offset: Int, in chapter: Novel.Chapter) {
        guard presentationMode.isLive else { return }
        if let lastSavedOffset,
           lastSavedOffset.chapterKey == chapter.key,
           lastSavedOffset.offset == offset {
            return
        }
        lastSavedOffset = (chapter.key, offset)
        let operationID = UUID()
        let progress = dependencies.progress
        let identity = mediaIdentity
        let task = routeSession.enqueuePositionWrite { [weak self, progress] in
            defer { self?.finishTestingOperation(operationID) }
            // Saving the position is best effort; reading carries on if it fails.
            try? await progress.saveNovelOffset(offset, media: identity, chapterID: chapter.key)
        }
        retainTestingOperation(task, operationID: operationID)
    }

    func markChapterFinished(_ chapter: Novel.Chapter) {
        guard isActive, presentationMode.isLive else { return }
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
                            chapterNumber: chapter.chapterNumber
                        )
                    case .updateTracker(let progressValue):
                        // Needs this reader open and the route's source scope unchanged, not this reader's
                        // own survival: a renderer swap retires the reader that started the step.
                        guard gate.isOpen,
                              routeSession.allowsTracker(context: context),
                              !Task.isCancelled else { return }
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

    private func finishEffect(operationID: UUID, outcome: PresentationEventOutcome) {
        guard effectTasks.removeValue(forKey: operationID) != nil else { return }
        logFinishedOnce(kind: .chapterEffects, operationID: operationID, outcome: outcome)
    }
}
