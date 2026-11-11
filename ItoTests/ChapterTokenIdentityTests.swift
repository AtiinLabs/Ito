import ito_runner
import Testing
@testable import Ito

/// Request identity is exact. Two chapters whose numbers collapse to one `Float` read as one number to the legacy
/// readers, but a stale load result must never apply to the other chapter, so their tokens differ.
@MainActor
struct ChapterTokenIdentityTests {
    @Test func mangaTokensTellApartChapterNumbersThatRoundToOneFloat() {
        let first = Manga.Chapter(key: "same", chapter: 1.0)
        let second = Manga.Chapter(key: "same", chapter: 1.0 + 1e-9)

        #expect(first.chapterNumber == second.chapterNumber)
        #expect(ChapterToken(first) != ChapterToken(second))
    }

    @Test func mangaTokensTellApartVolumesThatRoundToOneFloat() {
        let first = Manga.Chapter(key: "same", volume: 1.0, chapter: 2)
        let second = Manga.Chapter(key: "same", volume: 1.0 + 1e-9, chapter: 2)

        #expect(first.volumeNumber == second.volumeNumber)
        #expect(ChapterToken(first) != ChapterToken(second))
    }

    @Test func novelTokensTellApartChapterNumbersThatRoundToOneFloat() {
        let first = Novel.Chapter(key: "same", chapter: 1.0)
        let second = Novel.Chapter(key: "same", chapter: 1.0 + 1e-9)

        #expect(first.chapterNumber == second.chapterNumber)
        #expect(NovelChapterToken(first) != NovelChapterToken(second))
    }

    @Test func novelTokensTellApartVolumesThatRoundToOneFloat() {
        let first = Novel.Chapter(key: "same", volume: 1.0, chapter: 2)
        let second = Novel.Chapter(key: "same", volume: 1.0 + 1e-9, chapter: 2)

        #expect(first.volumeNumber == second.volumeNumber)
        #expect(NovelChapterToken(first) != NovelChapterToken(second))
    }
}
