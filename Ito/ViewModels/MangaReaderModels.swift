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

/// The end of the continuous chapter window that last grew.
enum ContinuousLoadedEnd {
    case top
    case bottom
}

/// The renderer's latest physical viewport, independent of persisted reading progress.
@MainActor
final class MangaContinuousViewportRetention {
    private(set) var pageIDs: [String]?
    private(set) var isValid = true
    /// A finger or momentum is moving the viewport. Dropping chapters above it then needs a
    /// scroll-position correction in the middle of native motion, which interferes with it.
    private(set) var isMoving = false

    func update(_ pageIDs: [String]) {
        guard isValid, self.pageIDs != pageIDs else { return }
        self.pageIDs = pageIDs
    }

    func setMoving(_ moving: Bool) {
        guard isValid else { return }
        isMoving = moving
    }

    func invalidate() {
        isValid = false
        isMoving = false
        pageIDs = nil
    }
}

/// Only the newest attached renderer can protect the chapter window.
@MainActor
struct MangaContinuousViewportRetentionRegistry {
    private weak var latest: MangaContinuousViewportRetention?

    mutating func makeLease() -> MangaContinuousViewportRetention {
        let lease = MangaContinuousViewportRetention()
        latest = lease
        return lease
    }

    func protectionIDs(fallback: Set<String>, validPages: [String: Int]) -> Set<String>? {
        guard let latest, latest.isValid else { return fallback }
        guard let pageIDs = latest.pageIDs, !latest.isMoving else { return nil }
        let mapped = Set(pageIDs.filter { validPages[$0] != nil })
        return mapped.isEmpty ? nil : mapped
    }
}

/// A request for the continuous reader to scroll to a page, by `FlatPage.id`.
struct MangaScrollRequest: Equatable {
    /// Distinguishes requests with the same payload, so a lifecycle check never mistakes a new
    /// request for an earlier one.
    let id = UUID()
    let pageID: String
    /// Footer page buttons animate; position restores jump.
    let animated: Bool
}

/// Everything the continuous renderer draws, published as one value once a change (an append
/// or prepend together with its trimming) is complete, so the renderer never lays out a
/// half-applied chapter window.
struct MangaContinuousReaderSnapshot {
    /// Increases with every publication; the renderer skips a revision it already applied.
    let revision: UInt64
    let pages: [FlatPage]
    let previousBoundary: ReaderChapterBoundary<Manga.Chapter>
    let nextBoundary: ReaderChapterBoundary<Manga.Chapter>
    let loadingPrevious: Bool
    let loadingNext: Bool
    let prependFailed: Bool
    let appendFailed: Bool
    let isWebtoon: Bool

    /// The chapter the next row loads, when the reader can open it.
    var nextChapter: Manga.Chapter? { nextBoundary.chapter }
    var previousChapter: Manga.Chapter? { previousBoundary.chapter }

    static let empty = MangaContinuousReaderSnapshot(
        revision: 0,
        pages: [],
        previousBoundary: .end,
        nextBoundary: .end,
        loadingPrevious: false,
        loadingNext: false,
        prependFailed: false,
        appendFailed: false,
        isWebtoon: false
    )
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

    /// The pages to preload after `index`: up to `count` items ahead, keeping only pages with
    /// a valid image URL, in reading order.
    static func pagesToPreload<Item>(
        after index: Int,
        count: Int,
        in items: [Item],
        page: (Item) -> Page
    ) -> [Page] {
        let start = index + 1
        let end = min(index + count, items.count - 1)
        guard count > 0, start >= 0, start <= end else { return [] }
        return items[start...end].map(page).filter { page in
            guard case .url(let urlString) = page.content else { return false }
            return URL(string: urlString) != nil
        }
    }

    static func presence(
        entry: MediaEntry,
        chapter: Chapter,
        anilistID: String?,
        pluginName: String?,
        resetTimer: Bool
    ) -> MangaReaderPresence {
        MangaReaderPresence(
            details: entry.title,
            state: String(localized: "Reading \(ReaderChapterTitle.text(title: chapter.title, number: chapter.chapterNumber))", comment: "Discord status: the chapter being read"),
            activityType: 3,
            detailsURL: anilistID.map { "https://anilist.co/manga/\($0)" },
            largeImageText: String(
                localized: "Reading from \(chapter.scanlator ?? String(localized: "Official", comment: "Discord status: chapter from the official release")) at \(pluginName ?? String(localized: "Unknown Plugin"))",
                comment: "Discord status: scanlation group, then source name"
            ),
            imageURL: entry.cover,
            resetTimer: resetTimer
        )
    }
}

/// Everything that identifies a chapter request; a load result applies only if it still matches.
struct ChapterToken: Equatable {
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
