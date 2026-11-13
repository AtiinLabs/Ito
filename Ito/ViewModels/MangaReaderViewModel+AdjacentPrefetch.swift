import Foundation
import ito_runner

/// Adjacent chapter page prefetch of the paged reader, kept out of the main file. It only ever
/// prefetches a neighbor the reader can open: another group's chapter waiting for consent,
/// a locked one and one that opens in the other reader are never fetched ahead.
extension MangaReaderViewModel {
    func beginAdjacentChapterPrefetch() {
        adjacentPrefetchTask?.cancel()
        let reference = currentChapter
        let referenceToken = ChapterToken(reference)
        let candidates = [boundaryAfter(reference).chapter, boundaryBefore(reference).chapter].compactMap { $0 }
        adjacentPrefetchKeys = Set(candidates.map(\.key))
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
        let operation = PluginNetworkOperation(purpose: .prefetch, operationID: operationID)

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
                    let pages = try await loader.pages(for: entry, chapter: chapter, operation: operation)
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
                    self?.cachePrefetchedChapter(ReaderPageOrdering.ascending(pages), for: chapter.key)
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
}
