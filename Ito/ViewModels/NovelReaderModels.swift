import Foundation
import ito_runner

enum NovelReaderLoadPhase: Equatable {
    case idle
    case loading
    case content
    case failure(String)
}

struct NovelLoadedChapter: Identifiable, Equatable {
    let id: UUID
    let chapter: Novel.Chapter
    let pages: [Page]

    init(id: UUID = UUID(), chapter: Novel.Chapter, pages: [Page]) {
        self.id = id
        self.chapter = chapter
        self.pages = pages
    }

    static func == (lhs: NovelLoadedChapter, rhs: NovelLoadedChapter) -> Bool {
        lhs.id == rhs.id
    }
}

/// A place to reopen a loaded chapter at; `offset` is a `NovelTextOffsets` offset.
struct NovelReadingAnchor: Equatable {
    let chapterID: UUID
    let offset: Int
}

/// A block of a loaded chapter in continuous mode, by index into its pages; the chapter's
/// heading comes before them all.
struct NovelBlockReference: Hashable {
    static let titleIndex = -1
    let chapterID: UUID
    let index: Int
}
struct NovelChapterToken: Equatable {
    let key: String
    let title: String?
    /// Raw runner numbers, not the Float boundary: request identity must stay exact.
    let volume: Double?
    let chapter: Double?
    let dateUpdated: Double?
    let scanlator: String?
    let url: String?
    let language: String?
    let paywalled: Bool?

    init(_ chapter: Novel.Chapter) {
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
}
