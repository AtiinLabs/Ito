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

/// String's canonical Unicode equality must not merge distinct source keys.
private nonisolated struct ChapterCountKey: Hashable {
    let value: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }

    func hash(into hasher: inout Hasher) {
        for byte in value.utf8 { hasher.combine(byte) }
    }
}

extension Sequence where Element: ChapterDisplayable {
    /// Manga/novel uploads count by byte-exact key, independently of display numbers or metadata.
    /// Anime retains its existing numbered-episode/language aggregation.
    var distinctChapterCount: Int {
        if Element.self == Anime.Episode.self {
            var numbers = Set<Float>()
            var unnumberedKeys = Set<String>()
            for episode in self {
                if let number = episode.chapterNumber, number.isFinite {
                    numbers.insert(number)
                } else {
                    unnumberedKeys.insert(episode.key)
                }
            }
            return numbers.count + unnumberedKeys.count
        }
        var keys = Set<ChapterCountKey>()
        for chapter in self {
            keys.insert(ChapterCountKey(value: chapter.key))
        }
        return keys.count
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
