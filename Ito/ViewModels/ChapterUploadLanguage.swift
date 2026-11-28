import Foundation

/// Tells apart the uploads of one chapter by language, for a list where nothing else does.
///
/// A chapter shows its language only when another chapter in the same list has the same number (or, without a
/// number, the same title) and a different non-empty language. A chapter with no duplicate, or whose duplicates
/// all share its language, shows none, so a list never guesses.
@MainActor
enum ChapterUploadLanguage {
    /// Identifies the chapters that can be duplicates of one another.
    private enum Group: Hashable {
        case number(Float)
        case title(String)
    }

    /// The label each chapter shows, parallel to `chapters`: the system's name for its language, or nil.
    static func labels<C: ChapterDisplayable>(for chapters: [C], locale: Locale = .current) -> [String?] {
        let uploads = chapters.map { (group: group(of: $0), code: code(of: $0)) }

        // A group with two or more distinct languages is one where the languages tell its uploads apart.
        var languagesByGroup: [Group: Set<String>] = [:]
        for upload in uploads {
            guard let group = upload.group, let code = upload.code else { continue }
            languagesByGroup[group, default: []].insert(code.lowercased())
        }

        return uploads.map { upload in
            guard let group = upload.group, let code = upload.code,
                  languagesByGroup[group, default: []].count > 1
            else { return nil }
            return name(forCode: code, locale: locale)
        }
    }

    /// The system's localized name for a language code, or the code in uppercase when the system has no name for it.
    static func name(forCode code: String, locale: Locale) -> String {
        locale.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    private static func group<C: ChapterDisplayable>(of chapter: C) -> Group? {
        if let number = chapter.chapterNumber, number.isFinite {
            return .number(number)
        }
        guard let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        return .title(title)
    }

    private static func code<C: ChapterDisplayable>(of chapter: C) -> String? {
        guard let code = chapter.uploadLanguage?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            return nil
        }
        return code
    }
}
