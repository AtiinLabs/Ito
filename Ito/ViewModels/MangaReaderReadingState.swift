import Foundation
import ito_runner

/// Values the reader derives from its published state, and pure helpers that build that state.
extension MangaReaderViewModel {
    /// Most chapters kept loaded in continuous mode; chapters far from the reader are dropped.
    static let maximumLoadedSegments = 4

    var defaultViewer: Manga.Viewer { entry.manga?.viewer ?? .Default }

    var activeViewer: Manga.Viewer {
        if overrideViewer != .Default { return overrideViewer }
        if defaultViewer != .Default { return defaultViewer }
        return .Rtl
    }

    var isPaged: Bool {
        Self.isPagedViewer(activeViewer)
    }

    var nextChapterForLastSegment: Manga.Chapter? {
        guard let last = segments.last else { return nil }
        return chapterAfter(last.chapter)
    }

    var previousChapterForFirstSegment: Manga.Chapter? {
        guard let first = segments.first else { return nil }
        return chapterBefore(first.chapter)
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

    static func isPagedViewer(_ viewer: Manga.Viewer) -> Bool {
        switch viewer {
        case .Ltr, .Rtl, .Default:
            return true
        case .Vertical, .Webtoon:
            return false
        }
    }

    /// Every page of `segments` in reading order, with each page's index by ID.
    static func flatten(_ segments: [ChapterSegment]) -> (pages: [FlatPage], indexByID: [String: Int]) {
        var pages: [FlatPage] = []
        var indexByID: [String: Int] = [:]
        for (segmentIndex, segment) in segments.enumerated() {
            for (position, page) in segment.pages.enumerated() {
                let id = FlatPage.id(chapterKey: segment.chapter.key, position: position)
                indexByID[id] = pages.count
                pages.append(
                    FlatPage(
                        id: id,
                        segmentIndex: segmentIndex,
                        chapter: segment.chapter,
                        page: page,
                        globalIndex: pages.count,
                        chapterPosition: position
                    )
                )
            }
        }
        return (pages, indexByID)
    }

    /// The image requests of `pages`, as the image session identifies them.
    static func imageKeys(of pages: [Page]) -> Set<ReaderPageImageKey> {
        Set(pages.compactMap { page in
            guard case .url(let value) = page.content, let url = URL(string: value) else { return nil }
            return ReaderPageImageKey(
                request: NukeMangaReaderImagePrefetcher.urlRequest(url: url, headers: page.headers)
            )
        })
    }
}
