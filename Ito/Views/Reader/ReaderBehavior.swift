import Foundation
import ito_runner

nonisolated enum ReaderChapterOrdering {
    static let chapterNumberEpsilon: Float32 = 0.0001
    private static let missingChapterNumber: Float32 = -10000

    static func mangaChapter(
        after chapter: Manga.Chapter,
        in chapters: [Manga.Chapter]?,
        preferredScanlator: String?
    ) -> Manga.Chapter? {
        guard let chapters else { return nil }
        let currentNumber = chapter.chapter ?? missingChapterNumber
        let candidates = chapters.filter {
            ($0.chapter ?? missingChapterNumber) > currentNumber + chapterNumberEpsilon
        }
        guard let nextNumber = candidates.map({
            $0.chapter ?? missingChapterNumber
        }).min() else {
            return nil
        }
        return preferredMangaSource(
            for: nextNumber,
            in: chapters,
            preferredScanlator: preferredScanlator
        )
    }

    static func mangaChapter(
        before chapter: Manga.Chapter,
        in chapters: [Manga.Chapter]?,
        preferredScanlator: String?
    ) -> Manga.Chapter? {
        guard let chapters else { return nil }
        let currentNumber = chapter.chapter ?? missingChapterNumber
        let candidates = chapters.filter {
            ($0.chapter ?? missingChapterNumber) < currentNumber - chapterNumberEpsilon
        }
        guard let previousNumber = candidates.map({
            $0.chapter ?? missingChapterNumber
        }).max() else {
            return nil
        }
        return preferredMangaSource(
            for: previousNumber,
            in: chapters,
            preferredScanlator: preferredScanlator
        )
    }

    static func novelChapter(
        after chapter: Novel.Chapter,
        in chapters: [Novel.Chapter]?
    ) -> Novel.Chapter? {
        guard let chapters else { return nil }

        if let currentNumber = chapter.chapter {
            let candidates = chapters.filter {
                ($0.chapter ?? missingChapterNumber) > currentNumber + chapterNumberEpsilon
            }
            if let next = candidates.min(by: {
                ($0.chapter ?? missingChapterNumber) < ($1.chapter ?? missingChapterNumber)
            }) {
                return next
            }
        }

        guard let currentIndex = chapters.firstIndex(where: {
            $0.key == chapter.key
        }) else {
            return nil
        }
        if currentIndex - 1 >= 0 {
            return chapters[currentIndex - 1]
        }
        if currentIndex + 1 < chapters.count {
            return chapters[currentIndex + 1]
        }
        return nil
    }

    static func novelChapter(
        before chapter: Novel.Chapter,
        in chapters: [Novel.Chapter]?
    ) -> Novel.Chapter? {
        guard let chapters else { return nil }

        if let currentNumber = chapter.chapter {
            let candidates = chapters.filter {
                ($0.chapter ?? missingChapterNumber) < currentNumber - chapterNumberEpsilon
            }
            if let previous = candidates.max(by: {
                ($0.chapter ?? missingChapterNumber) < ($1.chapter ?? missingChapterNumber)
            }) {
                return previous
            }
        }

        guard let currentIndex = chapters.firstIndex(where: {
            $0.key == chapter.key
        }) else {
            return nil
        }
        if currentIndex + 1 < chapters.count {
            return chapters[currentIndex + 1]
        }
        if currentIndex - 1 >= 0 {
            return chapters[currentIndex - 1]
        }
        return nil
    }

    private static func preferredMangaSource(
        for chapterNumber: Float32,
        in chapters: [Manga.Chapter],
        preferredScanlator: String?
    ) -> Manga.Chapter? {
        let sources = chapters.filter {
            abs(($0.chapter ?? missingChapterNumber) - chapterNumber) < chapterNumberEpsilon
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

nonisolated struct ReaderSessionEffectPlan: Equatable, Sendable {
    enum Effect: Equatable, Sendable {
        case recordHistory
        case markLocalProgress
        case updateTracker(progress: Int)
    }

    let synchronousEffects: [Effect]
    let asynchronousEffects: [Effect]

    static func chapterRead(
        chapterNumber: Float32?,
        titleOrKey: String,
        alreadyMarked: Bool
    ) -> ReaderSessionEffectPlan {
        guard !alreadyMarked else {
            return ReaderSessionEffectPlan(
                synchronousEffects: [.recordHistory],
                asynchronousEffects: []
            )
        }

        var asynchronousEffects: [Effect] = [.markLocalProgress]
        if let progress = trackerProgress(
            chapterNumber: chapterNumber,
            titleOrKey: titleOrKey
        ) {
            asynchronousEffects.append(.updateTracker(progress: progress))
        }
        return ReaderSessionEffectPlan(
            synchronousEffects: [.recordHistory],
            asynchronousEffects: asynchronousEffects
        )
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
