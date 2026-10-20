import Foundation
import ito_runner

enum MangaReaderLoadPhase: Equatable {
    case idle
    case loading
    case content
    case failure(String)
}

struct ChapterSegment: Identifiable, Equatable {
    let id = UUID()
    let chapter: Manga.Chapter
    let pages: [Page]

    static func == (lhs: ChapterSegment, rhs: ChapterSegment) -> Bool {
        lhs.id == rhs.id
    }
}

struct FlatPage: Identifiable {
    let id: String
    let segmentIndex: Int
    let chapter: Manga.Chapter
    let page: Page
    let globalIndex: Int
    /// Position of the page inside its chapter (array position, not `Page.index`).
    var chapterPosition = 0

    static func id(chapterKey: String, position: Int) -> String {
        "\(chapterKey)#\(position)"
    }
}

/// A request for the continuous reader to scroll to a page, by `FlatPage.id`.
struct MangaScrollRequest: Equatable {
    let pageID: String
    /// Footer page buttons animate; position restores and corrections jump.
    let animated: Bool
}

extension MangaReaderViewModel {
    struct PagedProjection {
        let pages: [Page]
        let index: Int
    }

    /// Pages and position for paged mode, taken from the continuous position. Positions are
    /// array positions; `Page.index` is plugin-supplied and need not start at 0 or be contiguous.
    static func pagedProjection(
        currentChapter: Manga.Chapter,
        segments: [ChapterSegment],
        flatPages: [FlatPage],
        continuousPageIndex: Int
    ) -> PagedProjection? {
        guard let segmentIndex = segments.firstIndex(where: {
            $0.chapter.key == currentChapter.key
        }) else { return nil }
        let segment = segments[segmentIndex]

        guard flatPages.indices.contains(continuousPageIndex),
              flatPages[continuousPageIndex].segmentIndex == segmentIndex else {
            return PagedProjection(pages: segment.pages, index: 0)
        }
        let segmentStart = segments[..<segmentIndex].reduce(0) { $0 + $1.pages.count }
        let index = flatPages[continuousPageIndex].globalIndex - segmentStart
        return PagedProjection(
            pages: segment.pages,
            index: segment.pages.indices.contains(index) ? index : 0
        )
    }
}

/// Everything that identifies a chapter request; a load result applies only if it still matches.
struct ChapterToken: Equatable {
    let key: String
    let title: String?
    let volume: Float32?
    let chapter: Float32?
    let dateUpdated: Double?
    let scanlator: String?
    let url: String?
    let language: String?
    let paywalled: Bool?

    init(_ chapter: Manga.Chapter) {
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

    init(_ segment: ChapterSegment) {
        self.init(segment.chapter)
    }
}
