import Foundation
import Testing
import ito_runner
@testable import Ito

@MainActor
struct ChapterUploadLanguageTests {
    private static let english = Locale(identifier: "en_US")

    private static func upload(
        _ key: String,
        _ number: Float?,
        _ language: String?,
        title: String? = nil
    ) -> Upload {
        Upload(key: key, title: title, chapterNumber: number, uploadLanguage: language)
    }

    private static func chapter(_ key: String, _ number: Double, _ language: String) -> Chapter {
        var chapter = Chapter(key: key, chapter: number, scanlator: nil, scanlatorID: nil)
        chapter.lang = language
        return chapter
    }

    @Test func sameNumberWithDifferentLanguagesShowsEachLanguage() {
        let labels = ChapterUploadLanguage.labels(
            for: [Self.upload("a", 38, "en"), Self.upload("b", 38, "fr")],
            locale: Self.english
        )

        #expect(labels == ["English", "French"])
    }

    @Test func duplicatesInOneLanguageShowNothing() {
        let labels = ChapterUploadLanguage.labels(
            for: [Self.upload("a", 38, "en"), Self.upload("b", 38, "en")],
            locale: Self.english
        )

        #expect(labels == [nil, nil])
    }

    @Test func chaptersWithoutADuplicateShowNothing() {
        let labels = ChapterUploadLanguage.labels(
            for: [Self.upload("a", 1, "en"), Self.upload("b", 2, "fr")],
            locale: Self.english
        )

        #expect(labels == [nil, nil])
    }

    @Test func languagesCompareIgnoringCaseAndSurroundingSpace() {
        let labels = ChapterUploadLanguage.labels(
            for: [Self.upload("a", 38, "en"), Self.upload("b", 38, " EN ")],
            locale: Self.english
        )

        #expect(labels == [nil, nil])
    }

    @Test func missingOrBlankLanguagesNeverCountAsADifferentLanguage() {
        let labels = ChapterUploadLanguage.labels(
            for: [Self.upload("a", 38, "en"), Self.upload("b", 38, nil), Self.upload("c", 38, "  ")],
            locale: Self.english
        )

        #expect(labels == [nil, nil, nil])
    }

    @Test func aSameLanguagePairIsLabeledWhenAThirdUploadHasAnotherLanguage() {
        let labels = ChapterUploadLanguage.labels(
            for: [Self.upload("a", 38, "en"), Self.upload("b", 38, "en"), Self.upload("c", 38, "fr")],
            locale: Self.english
        )

        #expect(labels == ["English", "English", "French"])
    }

    @Test func titlesStandInForMissingNumbers() {
        let labels = ChapterUploadLanguage.labels(
            for: [
                Self.upload("a", nil, "en", title: "Extra"),
                Self.upload("b", nil, "fr", title: "Extra"),
                Self.upload("c", nil, "fr", title: "Other")
            ],
            locale: Self.english
        )

        #expect(labels == ["English", "French", nil])
    }

    @Test func numbersTakePrecedenceOverTitles() {
        let labels = ChapterUploadLanguage.labels(
            for: [Self.upload("a", 1, "en", title: "Extra"), Self.upload("b", 2, "fr", title: "Extra")],
            locale: Self.english
        )

        #expect(labels == [nil, nil])
    }

    @Test func aNonFiniteNumberIsTreatedAsMissing() {
        let labels = ChapterUploadLanguage.labels(
            for: [Self.upload("a", .nan, "en", title: "Extra"), Self.upload("b", .nan, "fr", title: "Extra")],
            locale: Self.english
        )

        #expect(labels == ["English", "French"])
    }

    @Test func aLanguageWithoutASystemNameIsShownUppercased() {
        #expect(ChapterUploadLanguage.name(forCode: "zzz", locale: Self.english) == "ZZZ")
        #expect(ChapterUploadLanguage.name(forCode: "fr", locale: Self.english) == "French")
    }

    @Test func readerRowsCarryTheLanguageThatTellsDuplicatesApart() {
        let english = Self.chapter("en", 38, "en")
        let french = Self.chapter("fr", 38, "fr")
        let other = Self.chapter("other", 39, "en")
        let rows = ReaderChapterList.rows(
            chapters: [english, french, other],
            current: other,
            isRead: { _ in false },
            boundary: { .chapter($0) }
        )

        #expect(rows.map(\.chapter.key) == ["other", "en", "fr"])
        #expect(rows.map(\.uploadLanguage) == [
            nil,
            ChapterUploadLanguage.name(forCode: "en", locale: .current),
            ChapterUploadLanguage.name(forCode: "fr", locale: .current)
        ])
    }
}

/// A minimal upload, so the language rule is tested without the runner's model.
private nonisolated struct Upload: ChapterDisplayable {
    let key: String
    let title: String?
    let chapterNumber: Float?
    let uploadLanguage: String?

    var id: String { key }
    var scanlator: String? { nil }
    var dateUpload: String? { nil }
}
