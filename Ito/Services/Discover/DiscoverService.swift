import Foundation
import anilist

public actor DiscoverService {
    public static let shared = DiscoverService()

    /// Attempts per request when AniList rate-limits (HTTP 429).
    private static let maxAttempts = 3
    /// Upper bound on a single rate-limit wait, whatever `Retry-After` says.
    private static let maxRetryDelaySeconds = 10

    private let client = AniListClient()

    private init() {}

    // MARK: - Genres & Tags

    public func fetchGenres() async throws -> [String] {
        let genres = try await execute(AniListQueries.GenreCollectionQuery()).genreCollection ?? []
        return genres.filter { $0 != "Hentai" }
    }

    public func fetchTags() async throws -> [DiscoverTag] {
        let tags = try await execute(AniListQueries.MediaTagCollectionQuery()).mediaTagCollection ?? []
        return tags.map {
            DiscoverTag(id: $0.id, name: $0.name, description: $0.description, category: $0.category, isAdult: $0.isAdult)
        }
    }

    // MARK: - Single Media Detail

    public func fetchMediaDetails(id: Int) async throws -> DiscoverMedia? {
        try await execute(AniListQueries.MediaQuery(id: id)).media.map(DiscoverMedia.init(aniList:))
    }

    // MARK: - Core Query

    public func queryMedia(type: DiscoverMediaType, sort: DiscoverSort, season: String? = nil, seasonYear: Int? = nil, search: String? = nil, genres: [String]? = nil, excludedGenres: [String]? = nil, tags: [String]? = nil, excludedTags: [String]? = nil, format: String? = nil, status: String? = nil, countryOfOrigin: String? = nil, page: Int = 1, perPage: Int = 20) async throws -> [DiscoverMedia] {
        let (media, _) = try await queryMediaPaginated(type: type, sort: sort, season: season, seasonYear: seasonYear, search: search, genres: genres, excludedGenres: excludedGenres, tags: tags, excludedTags: excludedTags, format: format, status: status, countryOfOrigin: countryOfOrigin, page: page, perPage: perPage)
        return media
    }

    public func queryMediaPaginated(type: DiscoverMediaType, sort: DiscoverSort, season: String? = nil, seasonYear: Int? = nil, search: String? = nil, genres: [String]? = nil, excludedGenres: [String]? = nil, tags: [String]? = nil, excludedTags: [String]? = nil, format: String? = nil, status: String? = nil, countryOfOrigin: String? = nil, page: Int = 1, perPage: Int = 20) async throws -> (media: [DiscoverMedia], hasNextPage: Bool) {
        let query = AniListQueries.SearchQuery(
            page: page,
            perPage: perPage,
            search: search,
            type: MediaType(rawValue: type.rawValue),
            sort: MediaSort(rawValue: sort.rawValue).map { [$0] },
            season: season.flatMap(MediaSeason.init(rawValue:)),
            seasonYear: seasonYear,
            genreIn: genres,
            genreNotIn: excludedGenres,
            tagIn: tags,
            tagNotIn: excludedTags,
            formatIn: format.flatMap(MediaFormat.init(rawValue:)).map { [$0] },
            status: status.flatMap(MediaStatus.init(rawValue:)),
            countryOfOrigin: countryOfOrigin
        )

        let page = try await execute(query).page
        let media = (page?.media ?? []).map(DiscoverMedia.init(aniList:))
        return (media, page?.pageInfo?.hasNextPage ?? false)
    }

    // MARK: - Networking

    private func execute<R: GraphQLRequest>(_ request: R) async throws -> R.Response {
        var attempt = 1
        while true {
            do {
                return try await client.execute(request)
            } catch AniListError.rateLimitExceeded(let retryAfter) where attempt < Self.maxAttempts {
                attempt += 1
                let delay = min(max(retryAfter ?? 2, 1), Self.maxRetryDelaySeconds)
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            } catch let error as AniListError {
                throw Self.presentableError(error)
            }
        }
    }

    /// Keeps the "AniList Error <status>: <message>" text Discover shows and
    /// `DiscoverPresentationFailure.isAniListOutage` matches on.
    private static func presentableError(_ error: AniListError) -> Error {
        let status: Int?
        switch error {
        case .graphqlErrors(let errors):
            status = errors.lazy.compactMap(\.status).first
        case .httpError(let statusCode):
            status = statusCode
        case .rateLimitExceeded:
            status = 429
        case .networkError(let urlError):
            return urlError
        case .decodingError:
            status = nil
        }

        let message = error.localizedDescription
        guard let status else {
            return NSError(domain: "DiscoverService", code: 0, userInfo: [NSLocalizedDescriptionKey: "AniList Error: \(message)"])
        }
        return NSError(domain: "DiscoverService", code: status, userInfo: [NSLocalizedDescriptionKey: "AniList Error \(status): \(message)"])
    }
}

extension DiscoverMedia {
    nonisolated init(aniList media: Media) {
        let english = media.title?.english
        let romaji = media.title?.romaji
        let native = media.title?.native
        let description = media.description

        self.init(
            id: media.id,
            title: english ?? romaji ?? native ?? "Unknown",
            titleEnglish: english,
            titleRomaji: romaji,
            titleNative: native,
            synonyms: media.synonyms ?? [],
            coverImage: media.coverImage?.extraLarge ?? media.coverImage?.large,
            bannerImage: media.bannerImage,
            format: media.format?.rawValue,
            status: media.status?.rawValue,
            description: description,
            cleanDescription: (description ?? "").strippingHTML(),
            genres: media.genres,
            averageScore: media.averageScore,
            episodes: media.episodes,
            chapters: media.chapters,
            season: media.season?.rawValue,
            seasonYear: media.seasonYear,
            type: media.type?.rawValue ?? "ANIME",
            recommendations: media.recommendations.map { connection in
                (connection.nodes ?? []).compactMap(\.mediaRecommendation).map(DiscoverMedia.init(aniList:))
            }
        )
    }
}
