import Foundation
@preconcurrency import ito_runner

public protocol ChapterDisplayable: Identifiable {
    var key: String { get }
    var title: String? { get }
    var chapterNumber: Float? { get }
    var scanlator: String? { get }
    var dateUpload: String? { get }
    var isPaywalled: Bool { get }
}

extension ChapterDisplayable {
    public var isPaywalled: Bool { false }
}

extension Sequence where Element: ChapterDisplayable {
    /// The number of distinct chapters, which update checks and their baselines compare. Several
    /// scanlations or languages of one numbered chapter count once; unnumbered chapters count by key.
    var distinctChapterCount: Int {
        var numbers = Set<Float>()
        var unnumberedKeys = Set<String>()
        for chapter in self {
            if let number = chapter.chapterNumber, number.isFinite {
                numbers.insert(number)
            } else {
                unnumberedKeys.insert(chapter.key)
            }
        }
        return numbers.count + unnumberedKeys.count
    }
}

nonisolated extension Manga.Chapter: ChapterDisplayable {
    public var chapterNumber: Float? { chapter }
    public var dateUpload: String? {
        guard let ts = dateUpdated else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .omitted)
    }
    public var isPaywalled: Bool { paywalled ?? false }
}

nonisolated extension Anime.Episode: ChapterDisplayable {
    public var chapterNumber: Float? { episode }
    public var scanlator: String? { lang?.uppercased() }
    public var dateUpload: String? {
        guard let ts = dateUpdated else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .omitted)
    }
    public var isPaywalled: Bool { paywalled ?? false }
}

nonisolated extension Novel.Chapter: ChapterDisplayable {
    public var chapterNumber: Float? { chapter }
    public var dateUpload: String? {
        guard let ts = dateUpdated else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .omitted)
    }
    public var isPaywalled: Bool { paywalled ?? false }
}
