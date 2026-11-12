import Foundation
import ito_runner

extension MangaReaderViewModel {
    /// The next chapter, if it is pages too: the reader stops where the series switches to text,
    /// which opens in the text reader instead.
    func chapterAfter(_ chapter: Manga.Chapter) -> Manga.Chapter? {
        let askBeforeSwitching = dependencies.settings.askBeforeSwitchingGroups
        return ReaderChapterOrdering.boundary(
            after: chapter,
            in: entry.chapters,
            preferredScanlator: currentChapter.scanlator,
            preferredScanlatorID: askBeforeSwitching ? currentChapter.scanlatorID : nil
        ).requiringGroupConsent(from: chapter, enabled: askBeforeSwitching)
            .chapter.flatMap(pagesChapter)
    }

    func chapterBefore(_ chapter: Manga.Chapter) -> Manga.Chapter? {
        let askBeforeSwitching = dependencies.settings.askBeforeSwitchingGroups
        return ReaderChapterOrdering.boundary(
            before: chapter,
            in: entry.chapters,
            preferredScanlator: currentChapter.scanlator,
            preferredScanlatorID: askBeforeSwitching ? currentChapter.scanlatorID : nil
        ).requiringGroupConsent(from: chapter, enabled: askBeforeSwitching)
            .chapter.flatMap(pagesChapter)
    }

    /// What follows `chapter` for this reader: a chapter it can open, or why it stops. With the
    /// continuation setting on, another group's upload is a consent boundary, not an open chapter.
    func boundaryAfter(_ chapter: Manga.Chapter) -> ReaderChapterBoundary<Manga.Chapter> {
        let askBeforeSwitching = dependencies.settings.askBeforeSwitchingGroups
        return offline.resolving(
            ReaderChapterOrdering.boundary(
                after: chapter,
                in: entry.chapters,
                preferredScanlator: currentChapter.scanlator,
                preferredScanlatorID: askBeforeSwitching ? currentChapter.scanlatorID : nil
            ),
            opensHere: { pagesChapter($0) != nil }
        ).requiringGroupConsent(from: chapter, enabled: askBeforeSwitching)
    }

    func boundaryBefore(_ chapter: Manga.Chapter) -> ReaderChapterBoundary<Manga.Chapter> {
        let askBeforeSwitching = dependencies.settings.askBeforeSwitchingGroups
        return offline.resolving(
            ReaderChapterOrdering.boundary(
                before: chapter,
                in: entry.chapters,
                preferredScanlator: currentChapter.scanlator,
                preferredScanlatorID: askBeforeSwitching ? currentChapter.scanlatorID : nil
            ),
            opensHere: { pagesChapter($0) != nil }
        ).requiringGroupConsent(from: chapter, enabled: askBeforeSwitching)
    }

    /// The keys of the neighbors this reader can open, which a paged reader prefetches.
    var adjacentNeighborKeys: Set<String> {
        Set([boundaryAfter(currentChapter).chapter, boundaryBefore(currentChapter).chapter].compactMap { $0?.key })
    }

    /// The page the footer shows in paged mode. The pager rests one past either end on a chapter's
    /// loading or notice page; the footer keeps to the chapter's own pages.
    var pagedDisplayIndex: Int {
        min(max(pagedIndex, 0), max(pagedPages.count - 1, 0))
    }

    /// Whether the chapter that failed was opened to read online this time and has a downloaded copy to
    /// read instead.
    var canReadDownloadedCopy: Bool {
        guard case .failure = loadPhase else { return false }
        return offline.canReadDownloadedCopy(chapterKey: currentChapter.key)
    }

    private func pagesChapter(_ chapter: Manga.Chapter) -> Manga.Chapter? {
        entry.contentKind(of: chapter) == .images ? chapter : nil
    }
}
