import Foundation
import ito_runner

/// Helpers of the reader that read only its published state and dependencies, kept out of the main file.
extension MangaReaderViewModel {
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
