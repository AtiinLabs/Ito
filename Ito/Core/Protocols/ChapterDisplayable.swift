import Foundation
@preconcurrency import ito_runner

public protocol ChapterDisplayable: Identifiable {
    var key: String { get }
    var title: String? { get }
    var chapterNumber: Float? { get }
    var scanlator: String? { get }
    /// The volume, for series whose chapter numbers restart each volume.
    var volumeNumber: Float? { get }
    var dateUpload: String? { get }
    var isPaywalled: Bool { get }
    /// The source's identifier of the group, when it has one.
    var scanlatorID: String? { get }
    /// Shared by every upload the source declares to be one reading position.
    var logicalUnitID: String? { get }
    /// The source's reading position, meaningful only within the response it came from.
    var readingOrder: Int64? { get }
}

extension ChapterDisplayable {
    public var isPaywalled: Bool { false }
    public var volumeNumber: Float? { nil }
    public var scanlatorID: String? { nil }
    public var logicalUnitID: String? { nil }
    public var readingOrder: Int64? { nil }
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

    /// The text chapters, when the list also has page chapters; empty otherwise, so an all-text
    /// novel or an all-pages manga marks nothing.
    func textChapterKeysInMixedSeries(defaultKind: ContentKind) -> Set<String> {
        var text = Set<String>()
        var hasPages = false
        for chapter in self {
            guard let chapter = chapter as? Chapter else { continue }
            if (chapter.kind ?? defaultKind) == .text {
                text.insert(chapter.key)
            } else {
                hasPages = true
            }
        }
        return hasPages ? text : []
    }
}

/// Manga and novel chapters (`Manga.Chapter`, `Novel.Chapter`). Readers take numbers from
/// `chapterNumber` and `volumeNumber`, never from the runner's `chapter` or `volume`.
nonisolated extension Chapter: ChapterDisplayable {
    public nonisolated var chapterNumber: Float? { chapter.map { Float($0) } }
    public nonisolated var volumeNumber: Float? { volume.map { Float($0) } }
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
