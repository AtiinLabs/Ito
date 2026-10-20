import Foundation
import ito_runner

nonisolated enum ReaderChapterOrdering {
    static let chapterNumberEpsilon: Float32 = 0.0001

    /// The next chapter: the closest higher-numbered one, or for an unnumbered chapter the one
    /// listed above it (lists are newest first). Nil at the end.
    static func mangaChapter(
        after chapter: Manga.Chapter,
        in chapters: [Manga.Chapter]?,
        preferredScanlator: String?
    ) -> Manga.Chapter? {
        guard let chapters else { return nil }
        guard let currentNumber = chapter.chapter else {
            return listNeighbor(of: chapter.key, in: chapters, offset: -1, key: \.key)
        }
        // Unnumbered chapters are left out: their place among numbered ones is unknown.
        guard let nextNumber = chapters.compactMap(\.chapter).filter({
            $0 > currentNumber + chapterNumberEpsilon
        }).min() else {
            return nil
        }
        return preferredMangaSource(
            for: nextNumber,
            in: chapters,
            preferredScanlator: preferredScanlator
        )
    }

    /// The previous chapter, mirroring `mangaChapter(after:)`.
    static func mangaChapter(
        before chapter: Manga.Chapter,
        in chapters: [Manga.Chapter]?,
        preferredScanlator: String?
    ) -> Manga.Chapter? {
        guard let chapters else { return nil }
        guard let currentNumber = chapter.chapter else {
            return listNeighbor(of: chapter.key, in: chapters, offset: 1, key: \.key)
        }
        guard let previousNumber = chapters.compactMap(\.chapter).filter({
            $0 < currentNumber - chapterNumberEpsilon
        }).max() else {
            return nil
        }
        return preferredMangaSource(
            for: previousNumber,
            in: chapters,
            preferredScanlator: preferredScanlator
        )
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

    /// The next chapter: the closest higher-numbered one, or for an unnumbered chapter the one
    /// listed above it (lists are newest first). Nil at the end, never the chapter before.
    static func novelChapter(
        after chapter: Novel.Chapter,
        in chapters: [Novel.Chapter]?
    ) -> Novel.Chapter? {
        guard let chapters else { return nil }
        guard let currentNumber = chapter.chapter else {
            return listNeighbor(of: chapter.key, in: chapters, offset: -1, key: \.key)
        }
        return numbered(chapters)
            .filter { $0.number > currentNumber + chapterNumberEpsilon }
            .min { $0.number < $1.number }?
            .chapter
    }

    /// The previous chapter, mirroring `novelChapter(after:)`.
    static func novelChapter(
        before chapter: Novel.Chapter,
        in chapters: [Novel.Chapter]?
    ) -> Novel.Chapter? {
        guard let chapters else { return nil }
        guard let currentNumber = chapter.chapter else {
            return listNeighbor(of: chapter.key, in: chapters, offset: 1, key: \.key)
        }
        return numbered(chapters)
            .filter { $0.number < currentNumber - chapterNumberEpsilon }
            .max { $0.number < $1.number }?
            .chapter
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
/// followed by the two-character separator the paginator puts between blocks. The same offsets
/// work in the paged and continuous readers and survive repagination.
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
        guard case .text(let text) = page.content else { return 0 }
        return (text as NSString).length + (blockSeparator as NSString).length
    }
}
