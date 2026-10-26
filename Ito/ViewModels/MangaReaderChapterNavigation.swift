import Foundation
import ito_runner

extension MangaReaderViewModel {
    static func isPagedViewer(_ viewer: Manga.Viewer) -> Bool {
        switch viewer {
        case .Ltr, .Rtl, .Default:
            return true
        case .Vertical, .Webtoon:
            return false
        }
    }

    /// The next chapter, if it is pages too: the reader stops where the series switches to text,
    /// which opens in the text reader instead.
    func chapterAfter(_ chapter: Manga.Chapter) -> Manga.Chapter? {
        ReaderChapterOrdering.mangaChapter(
            after: chapter,
            in: entry.chapters,
            preferredScanlator: currentChapter.scanlator
        ).flatMap(pagesChapter)
    }

    func chapterBefore(_ chapter: Manga.Chapter) -> Manga.Chapter? {
        ReaderChapterOrdering.mangaChapter(
            before: chapter,
            in: entry.chapters,
            preferredScanlator: currentChapter.scanlator
        ).flatMap(pagesChapter)
    }

    private func pagesChapter(_ chapter: Manga.Chapter) -> Manga.Chapter? {
        entry.contentKind(of: chapter) == .images ? chapter : nil
    }
}
