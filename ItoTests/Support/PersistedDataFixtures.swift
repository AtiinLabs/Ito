import Foundation
import ito_runner
import Testing
@testable import Ito

/// Golden blobs under `Fixtures/PersistedData/`, captured from what the app's own writers produced:
/// the Library's `rawPayload`, the offline store's queue and inventory snapshots, and a backup file.
/// Their bytes are frozen. A change of the runner's models must keep every one of them readable, with
/// the values asserted here.
enum PersistedDataFixtures {
    static func url(_ fileName: String) throws -> URL {
        let bundle = Bundle(for: PersistedFixtureBundleToken.self)
        let name = fileName as NSString
        let base = name.deletingPathExtension
        let ext = name.pathExtension
        guard let url = bundle.url(forResource: base, withExtension: ext)
            ?? bundle.url(forResource: base, withExtension: ext, subdirectory: "Fixtures/PersistedData") else {
            throw PersistedFixtureError.missing(fileName)
        }
        return url
    }

    static func data(_ fileName: String) throws -> Data {
        try Data(contentsOf: url(fileName))
    }
}

enum PersistedFixtureError: Error {
    case missing(String)
}

private final class PersistedFixtureBundleToken {}

// MARK: - Library payloads

/// A series saved by the Library: which kind it is, and whether it was saved before chapters carried a
/// content kind (ABI 1 era) or after (ABI 2 era).
enum PersistedLibraryFixture: String, CaseIterable, Sendable {
    case mangaABI1 = "manga-abi1"
    case mangaABI2 = "manga-abi2"
    case novelABI1 = "novel-abi1"
    case novelABI2 = "novel-abi2"
    case animeABI1 = "anime-abi1"
    case animeABI2 = "anime-abi2"

    static let pluginId = "com.example.fixture"

    /// The Library row's id: the series key.
    var id: String { rawValue }
    var fileName: String { "persisted-library-\(rawValue).json" }

    var kind: MediaKind {
        switch self {
        case .mangaABI1, .mangaABI2: return .manga
        case .novelABI1, .novelABI2: return .novel
        case .animeABI1, .animeABI2: return .anime
        }
    }

    /// The content kind its chapters were stored with; nil before chapters carried one.
    var chapterKind: ContentKind? {
        switch self {
        case .mangaABI1, .novelABI1, .animeABI1, .animeABI2: return nil
        case .mangaABI2: return .images
        case .novelABI2: return .text
        }
    }

    var title: String {
        switch self {
        case .mangaABI1: return "Tower of Dawn 夜明けの塔"
        case .mangaABI2: return "Tower of Dusk"
        case .novelABI1: return "The Quiet Archive"
        case .novelABI2: return "The Loud Archive"
        case .animeABI1: return "Skyward"
        case .animeABI2: return "Skyward Returns"
        }
    }

    var coverURL: String { "https://cdn.example.test/covers/\(rawValue).jpg" }
    var seriesURL: String {
        switch kind {
        case .manga: return "https://example.test/series/\(rawValue)"
        case .novel: return "https://example.test/novel/\(rawValue)"
        case .anime: return "https://example.test/anime/\(rawValue)"
        }
    }

    func payload() throws -> Data {
        try PersistedDataFixtures.data(fileName)
    }

    /// The Library row as the app stores it. Without the type column it is a row from before kinds were stored.
    func libraryItem(withTypeColumn: Bool = true) throws -> Ito.LibraryItem {
        Ito.LibraryItem(
            id: id, title: title, coverUrl: coverURL, pluginId: Self.pluginId, isAnime: kind == .anime,
            pluginType: withTypeColumn ? kind : nil, rawPayload: try payload(), anilistId: nil
        )
    }
}

// MARK: - Expected values

/// Whether a stored number is the decimal `expected`, compared in the model's own type. The literal is
/// converted to that type, never the stored value to a wider one, so a `Float` model passes for `1.1` and a
/// `Double` model passes only if it holds exactly `1.1`: a stored `1.100000023841858` read back as a
/// `Double` fails, as it would mark a different chapter number.
func sameNumber<Number: BinaryFloatingPoint>(_ actual: Number?, _ expected: Double?) -> Bool {
    actual == expected.map { Number($0) }
}

/// A number as the legacy `Float` readers (read marks, history) see it, whatever width the model stores.
func legacyFloat<Number: BinaryFloatingPoint>(_ value: Number?) -> Float? {
    value.map { Float($0) }
}

/// What a stored chapter must decode to. Numbers are the decimal literals the series were built from, and
/// include ones with no exact `Float` form (`1.1`, `10.3`, `0.1`).
struct ExpectedChapter {
    var key: String
    var title: String?
    var volume: Double?
    var chapter: Double?
    var dateUpdated: Double?
    var scanlator: String?
    var url: String?
    var lang: String?
    var paywalled: Bool?
    var kind: ContentKind?

    func withoutPageListingFields() -> ExpectedChapter {
        var copy = self
        copy.url = nil
        copy.paywalled = nil
        return copy
    }

    func check(_ actual: Chapter, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.key == key, sourceLocation: sourceLocation)
        #expect(actual.title == title, sourceLocation: sourceLocation)
        #expect(sameNumber(actual.volume, volume), "volume of \(key): \(String(describing: actual.volume))", sourceLocation: sourceLocation)
        #expect(sameNumber(actual.chapter, chapter), "number of \(key): \(String(describing: actual.chapter))", sourceLocation: sourceLocation)
        #expect(actual.dateUpdated == dateUpdated, sourceLocation: sourceLocation)
        #expect(actual.scanlator == scanlator, sourceLocation: sourceLocation)
        #expect(actual.url == url, sourceLocation: sourceLocation)
        #expect(actual.lang == lang, sourceLocation: sourceLocation)
        #expect(actual.paywalled == paywalled, sourceLocation: sourceLocation)
        #expect(actual.kind == kind, sourceLocation: sourceLocation)
        // ABI 3 fields are absent from every fixture captured before ABI 3.
        #expect(actual.scanlatorID == nil, sourceLocation: sourceLocation)
        #expect(actual.logicalUnitID == nil, sourceLocation: sourceLocation)
        #expect(actual.readingOrder == nil, sourceLocation: sourceLocation)
        #expect(actual.revision == nil, sourceLocation: sourceLocation)
    }

    static func check(
        _ actual: [Chapter]?,
        _ expected: [ExpectedChapter],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let actual else {
            Issue.record("The stored series has no chapter list", sourceLocation: sourceLocation)
            return
        }
        #expect(actual.map(\.key) == expected.map(\.key), sourceLocation: sourceLocation)
        for (chapter, expectation) in zip(actual, expected) {
            expectation.check(chapter, sourceLocation: sourceLocation)
        }
    }
}

/// The values the golden series were built from.
enum PersistedExpectations {
    /// The manga chapters: a numbered and volumed one, a half-numbered locked one, an unnumbered bonus, and
    /// two whose numbers (`1.1`, `10.3`) and volume (`0.1`) have no exact `Float` form.
    static func mangaChapters(seriesKey _: String, kind: ContentKind?) -> [ExpectedChapter] {
        [
            ExpectedChapter(
                key: "ch-001", title: "Prologue", volume: 1, chapter: 1, dateUpdated: 1_700_000_000,
                scanlator: "Group One", url: "https://example.test/read/ch-001?token=abc", lang: "en",
                paywalled: false, kind: kind
            ),
            ExpectedChapter(
                key: "ch-002", title: nil, volume: nil, chapter: 2.5, dateUpdated: 1_700_086_400,
                scanlator: "Group Two", url: "https://example.test/read/ch-002", lang: "en",
                paywalled: true, kind: kind
            ),
            ExpectedChapter(
                key: "ch-003-bonus", title: "Bonus ✨", volume: 2, chapter: nil, dateUpdated: nil,
                scanlator: nil, url: nil, lang: nil, paywalled: nil, kind: kind
            ),
            ExpectedChapter(
                key: "ch-004-decimal", title: "Decimal", volume: 0.1, chapter: 1.1, dateUpdated: 1_700_172_800,
                scanlator: "Group One", url: "https://example.test/read/ch-004-decimal", lang: "en",
                paywalled: false, kind: kind
            ),
            ExpectedChapter(
                key: "ch-005-decimal", title: nil, volume: nil, chapter: 10.3, dateUpdated: nil,
                scanlator: "Group Two", url: "https://example.test/read/ch-005-decimal", lang: "en",
                paywalled: false, kind: kind
            )
        ]
    }

    static func novelChapters(seriesKey: String, kind: ContentKind?) -> [ExpectedChapter] {
        [
            ExpectedChapter(
                key: "nc-001", title: "Chapter One", volume: 1, chapter: 1, dateUpdated: 1_690_000_000,
                scanlator: "Translator E", url: "https://example.test/novel/\(seriesKey)/1", lang: "en",
                paywalled: false, kind: kind
            ),
            ExpectedChapter(
                key: "nc-002", title: "Chapter Two", volume: 1, chapter: 2, dateUpdated: 1_690_086_400,
                scanlator: "Translator E", url: "https://example.test/novel/\(seriesKey)/2", lang: "en",
                paywalled: false, kind: kind
            ),
            ExpectedChapter(
                key: "nc-003", title: "Chapter Three", volume: 0.1, chapter: 1.1, dateUpdated: 1_690_172_800,
                scanlator: "Translator E", url: "https://example.test/novel/\(seriesKey)/3", lang: "en",
                paywalled: false, kind: kind
            ),
            ExpectedChapter(
                key: "nc-004", title: "Chapter Four", volume: nil, chapter: 10.3, dateUpdated: nil,
                scanlator: "Translator E", url: "https://example.test/novel/\(seriesKey)/4", lang: "en",
                paywalled: false, kind: kind
            )
        ]
    }

    static func chapters(of fixture: PersistedLibraryFixture) -> [ExpectedChapter] {
        switch fixture.kind {
        case .manga: return mangaChapters(seriesKey: fixture.id, kind: fixture.chapterKind)
        case .novel: return novelChapters(seriesKey: fixture.id, kind: fixture.chapterKind)
        case .anime: return []
        }
    }

    static let mangaDescription = "A tale with \"quotes\", ünïcode and a newline.\nSecond line."

    /// Checks every field of a decoded Library payload against what it was captured from.
    static func check(
        _ media: DeferredPluginMedia,
        _ fixture: PersistedLibraryFixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch (media, fixture.kind) {
        case (.manga(let manga), .manga):
            #expect(manga.key == fixture.id, sourceLocation: sourceLocation)
            #expect(manga.title == fixture.title, sourceLocation: sourceLocation)
            #expect(manga.authors == ["Writer A", "Writer B"], sourceLocation: sourceLocation)
            #expect(manga.artist == "Artist C", sourceLocation: sourceLocation)
            #expect(manga.description == mangaDescription, sourceLocation: sourceLocation)
            #expect(manga.tags == ["fantasy", "adventure"], sourceLocation: sourceLocation)
            #expect(manga.cover == fixture.coverURL, sourceLocation: sourceLocation)
            #expect(manga.url == fixture.seriesURL, sourceLocation: sourceLocation)
            #expect(manga.status == .Ongoing, sourceLocation: sourceLocation)
            #expect(manga.contentRating == .Suggestive, sourceLocation: sourceLocation)
            #expect(manga.nsfw == 0, sourceLocation: sourceLocation)
            #expect(manga.viewer == (fixture == .mangaABI1 ? .Rtl : .Webtoon), sourceLocation: sourceLocation)
            ExpectedChapter.check(manga.chapters, chapters(of: fixture), sourceLocation: sourceLocation)
            #expect(manga.catalog == nil, sourceLocation: sourceLocation)
        case (.novel(let novel), .novel):
            #expect(novel.key == fixture.id, sourceLocation: sourceLocation)
            #expect(novel.title == fixture.title, sourceLocation: sourceLocation)
            #expect(novel.authors == ["Novelist D"], sourceLocation: sourceLocation)
            #expect(novel.artist == nil, sourceLocation: sourceLocation)
            #expect(novel.description == "Light novel synopsis.", sourceLocation: sourceLocation)
            #expect(novel.tags == ["isekai"], sourceLocation: sourceLocation)
            #expect(novel.cover == fixture.coverURL, sourceLocation: sourceLocation)
            #expect(novel.url == fixture.seriesURL, sourceLocation: sourceLocation)
            #expect(novel.status == .Completed, sourceLocation: sourceLocation)
            #expect(novel.contentRating == .Safe, sourceLocation: sourceLocation)
            #expect(novel.nsfw == 0, sourceLocation: sourceLocation)
            ExpectedChapter.check(novel.chapters, chapters(of: fixture), sourceLocation: sourceLocation)
            #expect(novel.catalog == nil, sourceLocation: sourceLocation)
        case (.anime(let anime), .anime):
            #expect(anime.key == fixture.id, sourceLocation: sourceLocation)
            #expect(anime.title == fixture.title, sourceLocation: sourceLocation)
            #expect(anime.studios == ["Studio Q"], sourceLocation: sourceLocation)
            #expect(anime.description == "Anime synopsis.", sourceLocation: sourceLocation)
            #expect(anime.tags == ["action"], sourceLocation: sourceLocation)
            #expect(anime.cover == fixture.coverURL, sourceLocation: sourceLocation)
            #expect(anime.url == fixture.seriesURL, sourceLocation: sourceLocation)
            #expect(anime.status == .Ongoing, sourceLocation: sourceLocation)
            #expect(anime.contentRating == .Safe, sourceLocation: sourceLocation)
            #expect(anime.nsfw == 0, sourceLocation: sourceLocation)
            checkEpisodes(anime, sourceLocation: sourceLocation)
        default:
            Issue.record("Decoded the wrong kind for \(fixture.rawValue)", sourceLocation: sourceLocation)
        }
    }

    private static func checkEpisodes(_ anime: Anime, sourceLocation: SourceLocation) {
        let episodes = anime.episodes ?? []
        #expect(episodes.map(\.key) == ["ep-1", "ep-2", "ep-3"], sourceLocation: sourceLocation)
        guard episodes.count == 3 else { return }
        #expect(episodes[0].title == "Pilot", sourceLocation: sourceLocation)
        #expect(sameNumber(episodes[0].episode, 1), sourceLocation: sourceLocation)
        #expect(episodes[0].dateUpdated == 1_680_000_000, sourceLocation: sourceLocation)
        #expect(episodes[0].url == "https://example.test/anime/\(anime.key)/1", sourceLocation: sourceLocation)
        #expect(episodes[0].lang == "ja", sourceLocation: sourceLocation)
        #expect(episodes[0].paywalled == false, sourceLocation: sourceLocation)
        #expect(episodes[1].title == nil, sourceLocation: sourceLocation)
        #expect(sameNumber(episodes[1].episode, 2.5), sourceLocation: sourceLocation)
        #expect(episodes[1].dateUpdated == nil, sourceLocation: sourceLocation)
        #expect(episodes[1].url == nil, sourceLocation: sourceLocation)
        #expect(episodes[1].lang == nil, sourceLocation: sourceLocation)
        #expect(episodes[1].paywalled == nil, sourceLocation: sourceLocation)
        #expect(episodes[2].title == "Special", sourceLocation: sourceLocation)
        #expect(sameNumber(episodes[2].episode, 1.1), sourceLocation: sourceLocation)
        #expect(episodes[2].dateUpdated == 1_680_086_400, sourceLocation: sourceLocation)
        #expect(episodes[2].url == "https://example.test/anime/\(anime.key)/3", sourceLocation: sourceLocation)
        #expect(episodes[2].lang == "ja", sourceLocation: sourceLocation)
        #expect(episodes[2].paywalled == false, sourceLocation: sourceLocation)
        let seasons = anime.seasons ?? []
        #expect(seasons.map(\.key) == ["s1"], sourceLocation: sourceLocation)
        #expect(seasons.map(\.title) == ["Season 1"], sourceLocation: sourceLocation)
        #expect(seasons.map(\.isCurrent) == [true], sourceLocation: sourceLocation)
    }
}

// MARK: - Offline snapshots

/// A series frozen on a download batch, and its queued chapters, as the offline store wrote them.
enum PersistedOfflineFixture: String, CaseIterable, Sendable {
    case mangaABI1 = "manga-abi1"
    case mangaABI2 = "manga-abi2"
    case novelABI2 = "novel-abi2"

    /// The series key and canonical media id the rows were written under.
    var seriesKey: String {
        switch self {
        case .mangaABI1: return "m-abi1"
        case .mangaABI2: return "m-abi2"
        case .novelABI2: return "n-abi2"
        }
    }

    var kind: MediaKind { self == .novelABI2 ? .novel : .manga }

    var chapterKind: ContentKind? {
        switch self {
        case .mangaABI1: return nil
        case .mangaABI2: return .images
        case .novelABI2: return .text
        }
    }

    var title: String {
        switch self {
        case .mangaABI1: return "Tower of Dawn 夜明けの塔"
        case .mangaABI2: return "Tower of Dusk"
        case .novelABI2: return "The Loud Archive"
        }
    }

    /// The chapters of the frozen entry, as the source listed them.
    var listedChapters: [ExpectedChapter] {
        kind == .novel
            ? PersistedExpectations.novelChapters(seriesKey: seriesKey, kind: chapterKind)
            : PersistedExpectations.mangaChapters(seriesKey: seriesKey, kind: chapterKind)
    }

    /// The chapters that were queued, in reading order: every listed chapter except the locked one.
    var queuedChapters: [ExpectedChapter] {
        listedChapters.filter { $0.key != "ch-002" }
    }

    var entryFileName: String { "persisted-offline-entry-\(rawValue).json" }

    func jobFileName(chapterKey: String) -> String {
        "persisted-offline-job-\(rawValue)-\(chapterKey).json"
    }

    /// A queued chapter's inventory copy, written when it was published.
    func inventoryFileName(chapterKey: String) -> String {
        "persisted-offline-inventory-\(rawValue)-\(chapterKey).json"
    }
}
