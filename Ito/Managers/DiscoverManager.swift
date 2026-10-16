import Foundation
import Combine

@MainActor
public class DiscoverManager: ObservableObject {
    public static let shared = DiscoverManager()

    private let service = DiscoverService.shared

    private init() {}

    // MARK: - Search

    public func search(
        query: String,
        type: DiscoverMediaType,
        filters: DiscoverFilters = DiscoverFilters(),
        page: Int = 1,
        perPage: Int = 20
    ) async throws -> (media: [DiscoverMedia], hasNextPage: Bool) {
        let sort: DiscoverSort = query.isEmpty ? filters.sort : .searchMatch
        return try await service.queryMediaPaginated(
            type: type, sort: sort,
            season: filters.season,
            seasonYear: filters.year,
            search: query.isEmpty ? nil : query,
            genres: filters.genres.isEmpty ? nil : filters.genres,
            excludedGenres: filters.excludedGenres.isEmpty ? nil : filters.excludedGenres,
            tags: filters.tags.isEmpty ? nil : filters.tags,
            excludedTags: filters.excludedTags.isEmpty ? nil : filters.excludedTags,
            format: filters.format, status: filters.status,
            countryOfOrigin: filters.countryOfOrigin,
            page: page, perPage: perPage
        )
    }

    func loadUncachedHomeSection(
        _ request: DiscoverHomeSectionRequest
    ) async throws -> [DiscoverMedia] {
        switch request.section {
        case .trending:
            return try await service.queryMedia(
                type: request.mediaType,
                sort: .trending,
                perPage: request.perPage
            )
        case .popular:
            return try await service.queryMedia(
                type: request.mediaType,
                sort: .popularity,
                perPage: request.perPage
            )
        case .topRated:
            return try await service.queryMedia(
                type: request.mediaType,
                sort: .score,
                perPage: request.perPage
            )
        case .seasonal:
            return try await service.queryMedia(
                type: request.mediaType,
                sort: .popularity,
                season: request.season,
                seasonYear: request.seasonYear,
                perPage: request.perPage
            )
        }
    }

    // MARK: - Genre & Tag Collections

    func loadUncachedGenres() async throws -> [String] {
        try await service.fetchGenres()
    }

    func loadUncachedTags() async throws -> [DiscoverTag] {
        try await service.fetchTags()
    }

    // MARK: - Single Media Detail

    public func fetchMediaDetails(id: Int) async throws -> DiscoverMedia? {
        return try await service.fetchMediaDetails(id: id)
    }
}
