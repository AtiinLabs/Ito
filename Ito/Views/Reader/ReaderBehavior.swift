import Foundation
import ito_runner

nonisolated enum ReaderChapterTitle {
    /// The chapter's title, else "Chapter 12.5" from its number (whole numbers without ".0"),
    /// else "Unknown Chapter".
    static func text(title: String?, number: Float32?) -> String {
        if let title, !title.isEmpty { return title }
        if let number { return String(localized: "Chapter \(number.formatted())") }
        return String(localized: "Unknown Chapter")
    }
}

/// What lies past a chapter in reading order. `locked` is a candidate the account cannot open;
/// `otherReader` and `notAvailableOffline` are decided by the reader that asks, since they depend
/// on the chapter's format and on what is stored.
nonisolated enum ReaderChapterBoundary<C> {
    case chapter(C)
    case end
    case locked(C)
    case otherReader(C)
    case notAvailableOffline(C)

    /// The neighbor to open, when the reader can open it.
    var chapter: C? {
        guard case .chapter(let chapter) = self else { return nil }
        return chapter
    }

    /// The neighbor in reading order, whether or not the reader can open it; nil at the end.
    var candidate: C? {
        switch self {
        case .chapter(let chapter), .locked(let chapter), .otherReader(let chapter), .notAvailableOffline(let chapter):
            chapter
        case .end:
            nil
        }
    }

    var isEnd: Bool {
        guard case .end = self else { return false }
        return true
    }
}

nonisolated extension ReaderChapterBoundary: Equatable where C: Equatable {}

nonisolated enum ReaderChapterOrdering {
    static let chapterNumberEpsilon: Float32 = 0.0001

    /// The closest higher-numbered chapter, or the list neighbor for an unnumbered chapter
    /// (newest first). A known lock on that candidate is a boundary, never skipped.
    static func mangaChapter(
        after chapter: Manga.Chapter,
        in chapters: [Manga.Chapter]?,
        preferredScanlator: String?
    ) -> Manga.Chapter? {
        boundary(after: chapter, in: chapters, preferredScanlator: preferredScanlator).chapter
    }

    /// The previous chapter, mirroring `mangaChapter(after:)`.
    static func mangaChapter(
        before chapter: Manga.Chapter,
        in chapters: [Manga.Chapter]?,
        preferredScanlator: String?
    ) -> Manga.Chapter? {
        boundary(before: chapter, in: chapters, preferredScanlator: preferredScanlator).chapter
    }

    /// What follows `chapter`: the candidate before the lock check, so a locked one is reported
    /// instead of skipped.
    static func boundary(
        after chapter: Manga.Chapter,
        in chapters: [Manga.Chapter]?,
        preferredScanlator: String?
    ) -> ReaderChapterBoundary<Manga.Chapter> {
        guard let chapters else { return .end }
        guard let currentNumber = chapter.chapter else {
            return gated(listNeighbor(of: chapter.key, in: chapters, offset: -1, key: \.key))
        }
        // Unnumbered chapters are left out: their place among numbered ones is unknown.
        guard let nextNumber = chapters.compactMap(\.chapter).filter({
            $0 > currentNumber + chapterNumberEpsilon
        }).min() else {
            return .end
        }
        return gated(preferredMangaSource(
            for: nextNumber,
            in: chapters,
            preferredScanlator: preferredScanlator
        ))
    }

    /// What precedes `chapter`, mirroring `boundary(after:in:preferredScanlator:)`.
    static func boundary(
        before chapter: Manga.Chapter,
        in chapters: [Manga.Chapter]?,
        preferredScanlator: String?
    ) -> ReaderChapterBoundary<Manga.Chapter> {
        guard let chapters else { return .end }
        guard let currentNumber = chapter.chapter else {
            return gated(listNeighbor(of: chapter.key, in: chapters, offset: 1, key: \.key))
        }
        guard let previousNumber = chapters.compactMap(\.chapter).filter({
            $0 < currentNumber - chapterNumberEpsilon
        }).max() else {
            return .end
        }
        return gated(preferredMangaSource(
            for: previousNumber,
            in: chapters,
            preferredScanlator: preferredScanlator
        ))
    }

    /// The chapter `offset` places from `key` in the list, or nil past either end.
    private static func listNeighbor<Chapter>(
        of key: String,
        in chapters: [Chapter],
        offset: Int,
        key chapterKey: (Chapter) -> String
    ) -> Chapter? {
        guard let index = chapters.firstIndex(where: { chapterKey($0) == key }) else { return nil }
        let neighbor = index + offset
        return chapters.indices.contains(neighbor) ? chapters[neighbor] : nil
    }

    /// The closest higher-numbered chapter, or the list neighbor for an unnumbered chapter.
    /// A known lock stops navigation; it never selects a farther chapter instead.
    static func novelChapter(
        after chapter: Novel.Chapter,
        in chapters: [Novel.Chapter]?
    ) -> Novel.Chapter? {
        boundary(after: chapter, in: chapters).chapter
    }

    /// The previous chapter, mirroring `novelChapter(after:)`.
    static func novelChapter(
        before chapter: Novel.Chapter,
        in chapters: [Novel.Chapter]?
    ) -> Novel.Chapter? {
        boundary(before: chapter, in: chapters).chapter
    }

    /// What follows `chapter`, before the lock check.
    static func boundary(
        after chapter: Novel.Chapter,
        in chapters: [Novel.Chapter]?
    ) -> ReaderChapterBoundary<Novel.Chapter> {
        guard let chapters else { return .end }
        guard let currentNumber = chapter.chapter else {
            return gated(listNeighbor(of: chapter.key, in: chapters, offset: -1, key: \.key))
        }
        let candidate = numbered(chapters)
            .filter { $0.number > currentNumber + chapterNumberEpsilon }
            .min { $0.number < $1.number }?
            .chapter
        return gated(candidate)
    }

    /// What precedes `chapter`, mirroring `boundary(after:in:)`.
    static func boundary(
        before chapter: Novel.Chapter,
        in chapters: [Novel.Chapter]?
    ) -> ReaderChapterBoundary<Novel.Chapter> {
        guard let chapters else { return .end }
        guard let currentNumber = chapter.chapter else {
            return gated(listNeighbor(of: chapter.key, in: chapters, offset: 1, key: \.key))
        }
        let candidate = numbered(chapters)
            .filter { $0.number < currentNumber - chapterNumberEpsilon }
            .max { $0.number < $1.number }?
            .chapter
        return gated(candidate)
    }

    /// Select first, then check access: filtering the list would skip a locked boundary.
    private static func gated(_ chapter: Chapter?) -> ReaderChapterBoundary<Chapter> {
        guard let chapter else { return .end }
        return chapter.paywalled == true ? .locked(chapter) : .chapter(chapter)
    }

    private static func numbered(
        _ chapters: [Novel.Chapter]
    ) -> [(chapter: Novel.Chapter, number: Float32)] {
        chapters.compactMap { chapter in chapter.chapter.map { (chapter, $0) } }
    }

    private static func preferredMangaSource(
        for chapterNumber: Float32,
        in chapters: [Manga.Chapter],
        preferredScanlator: String?
    ) -> Manga.Chapter? {
        let sources = chapters.filter {
            $0.chapter.map { abs($0 - chapterNumber) < chapterNumberEpsilon } ?? false
        }
        if let match = sources.first(where: {
            $0.scanlator == preferredScanlator
        }) {
            return match
        }
        return sources.first
    }
}

/// What a reader says where it stops instead of opening the neighboring chapter. The user returns to
/// the details and opens that chapter there; a reader never switches by itself.
nonisolated struct ReaderBoundaryNotice: Equatable {
    let text: String
    let systemImage: String

    /// The page reader's notice before or after its chapters; nil when the neighbor opens there or
    /// there is none.
    static func pages<C>(for boundary: ReaderChapterBoundary<C>, isNext: Bool) -> ReaderBoundaryNotice? {
        switch boundary {
        case .chapter, .end:
            return nil
        case .locked:
            return locked(isNext: isNext)
        case .otherReader:
            return ReaderBoundaryNotice(
                text: isNext
                    ? String(localized: "Next chapter opens in the text reader", comment: "Reader: the next chapter is text; go back to the series to open it")
                    : String(localized: "Previous chapter opens in the text reader", comment: "Reader: the previous chapter is text; go back to the series to open it"),
                systemImage: "text.alignleft"
            )
        case .notAvailableOffline:
            return notDownloaded(isNext: isNext)
        }
    }

    /// The text reader's notice after its last loaded chapter. It shows nothing before the first one.
    static func textAfterLast<C>(for boundary: ReaderChapterBoundary<C>) -> ReaderBoundaryNotice? {
        switch boundary {
        case .chapter, .end:
            return nil
        case .locked:
            return locked(isNext: true)
        case .otherReader:
            return ReaderBoundaryNotice(
                text: String(localized: "Next chapter opens in the page reader", comment: "Reader: the next chapter is made of pages; go back to the series to open it"),
                systemImage: "photo.on.rectangle"
            )
        case .notAvailableOffline:
            return notDownloaded(isNext: true)
        }
    }

    private static func locked(isNext: Bool) -> ReaderBoundaryNotice {
        ReaderBoundaryNotice(
            text: isNext
                ? String(localized: "Next chapter is locked", comment: "Reader: shown after the last page when the next chapter needs an unlock")
                : String(localized: "Previous chapter is locked", comment: "Reader: shown before the first page when the previous chapter needs an unlock"),
            systemImage: "lock.fill"
        )
    }

    private static func notDownloaded(isNext: Bool) -> ReaderBoundaryNotice {
        ReaderBoundaryNotice(
            text: isNext
                ? String(localized: "Next chapter isn't downloaded", comment: "Reader: the next chapter has no saved copy and the source cannot be reached")
                : String(localized: "Previous chapter isn't downloaded", comment: "Reader: the previous chapter has no saved copy and the source cannot be reached"),
            systemImage: "arrow.down.circle"
        )
    }
}

nonisolated enum ReaderPageOrdering {
    static func ascending(_ pages: [Page]) -> [Page] {
        pages.sorted(by: { $0.index < $1.index })
    }
}

/// What finishing a chapter does: mark it read locally, then update trackers. Opening a
/// chapter only records history; the reader does that itself.
nonisolated struct ReaderSessionEffectPlan: Equatable, Sendable {
    enum Effect: Equatable, Sendable {
        case markLocalProgress
        case updateTracker(progress: Int)
    }

    let effects: [Effect]

    static func chapterFinished(
        chapterNumber: Float32?,
        titleOrKey: String,
        alreadyMarked: Bool
    ) -> ReaderSessionEffectPlan {
        guard !alreadyMarked else {
            return ReaderSessionEffectPlan(effects: [])
        }

        var effects: [Effect] = [.markLocalProgress]
        if let progress = trackerProgress(
            chapterNumber: chapterNumber,
            titleOrKey: titleOrKey
        ) {
            effects.append(.updateTracker(progress: progress))
        }
        return ReaderSessionEffectPlan(effects: effects)
    }

    private static func trackerProgress(
        chapterNumber: Float32?,
        titleOrKey: String
    ) -> Int? {
        if let chapterNumber {
            return Int(chapterNumber)
        }
        return TrackerProgressParser.number(inTitle: titleOrKey)
    }
}

/// Positions inside a novel chapter, as UTF-16 offsets into its body text: each text block
/// followed by the two-character separator the paginator puts between blocks, and one unit
/// for each image. The same offsets work in the paged and continuous readers and survive
/// repagination.
nonisolated enum NovelTextOffsets {
    static let blockSeparator = "\n\n"

    static func blockStarts(_ pages: [Page]) -> [Int] {
        var starts: [Int] = []
        starts.reserveCapacity(pages.count)
        var offset = 0
        for page in pages {
            starts.append(offset)
            offset += length(of: page)
        }
        return starts
    }

    static func bodyLength(_ pages: [Page]) -> Int {
        pages.reduce(0) { $0 + length(of: $1) }
    }

    /// The block that contains `offset`, or the last block before it.
    static func blockIndex(containing offset: Int, in pages: [Page]) -> Int {
        let starts = blockStarts(pages)
        return starts.lastIndex { $0 <= offset } ?? 0
    }

    private static func length(of page: Page) -> Int {
        // An image takes one unit, so a position can point at it rather than the text after it.
        guard case .text(let text) = page.content else { return 1 }
        return (text as NSString).length + (blockSeparator as NSString).length
    }
}
