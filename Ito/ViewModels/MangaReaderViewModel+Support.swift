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

    func cancelSpeculativeAppendIfNeeded() {
        guard !speculativeAppendAdmitted, let operationID = appendOperationID else { return }
        let task = appendTask
        finishAppend(operationID: operationID, outcome: .ignoredStale)
        task?.cancel()
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

    func logFinished(
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
