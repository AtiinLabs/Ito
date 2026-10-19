import Foundation

public struct DiscoverMedia: Identifiable, Codable, Hashable, Sendable {
    public let id: Int
    public nonisolated let title: String
    public nonisolated let titleEnglish: String?
    public nonisolated let titleRomaji: String?
    public nonisolated let titleNative: String?
    public nonisolated let synonyms: [String]
    public let coverImage: String?
    public let bannerImage: String?
    public let format: String?
    public let status: String?
    public let description: String?
    public let cleanDescription: String?
    public let genres: [String]?
    public let averageScore: Int?
    public let episodes: Int?
    public let chapters: Int?
    public let season: String?
    public let seasonYear: Int?
    public let type: String
    public nonisolated let recommendations: [DiscoverMedia]?
}

public struct DiscoverTag: Identifiable, Codable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let description: String?
    public let category: String?
    public let isAdult: Bool?
}

public enum DiscoverMediaType: String, CaseIterable, Sendable {
    case anime = "ANIME"
    case manga = "MANGA"
}

public enum DiscoverSort: String, CaseIterable, Sendable {
    case trending = "TRENDING_DESC"
    case popularity = "POPULARITY_DESC"
    case score = "SCORE_DESC"
    case newest = "START_DATE_DESC"
    case searchMatch = "SEARCH_MATCH"

    public var displayName: String {
        switch self {
        case .trending: return "Trending"
        case .popularity: return "Popular"
        case .score: return "Top Rated"
        case .newest: return "Newest"
        case .searchMatch: return "Best Match"
        }
    }
}

public struct DiscoverFilters: Equatable, Sendable {
    public var genres: [String] = []
    public var excludedGenres: [String] = []
    public var tags: [String] = []
    public var excludedTags: [String] = []
    public var format: String?
    public var status: String?
    public var countryOfOrigin: String?
    public var sort: DiscoverSort = .popularity
    public var year: Int?
    public var season: String?
    // swiftlint:disable:next todo
    // TODO: Wire `onList: Boolean` filter when AniList tracker auth is integrated

    public var isEmpty: Bool {
        genres.isEmpty && excludedGenres.isEmpty && tags.isEmpty && excludedTags.isEmpty
            && format == nil && status == nil && countryOfOrigin == nil
            && year == nil && season == nil
    }

    public init() {}
}
