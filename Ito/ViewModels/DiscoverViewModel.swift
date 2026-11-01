import Combine
import Foundation

struct DiscoverHomeContent: Equatable {
    var trending: [DiscoverMedia]
    var seasonal: [DiscoverMedia]
    var popular: [DiscoverMedia]
    var topRated: [DiscoverMedia]

    static let empty = DiscoverHomeContent(
        trending: [],
        seasonal: [],
        popular: [],
        topRated: []
    )

    var primarySectionsAreEmpty: Bool {
        trending.isEmpty && popular.isEmpty && topRated.isEmpty
    }
}

enum DiscoverEmptyContext: Equatable {
    case home
    case search
    case filters
}

enum DiscoverErrorContext: Equatable {
    case home
    case search
}

struct DiscoverPresentationFailure: Equatable {
    let context: DiscoverErrorContext
    let message: String?

    var isAniListOutage: Bool {
        guard let message else { return false }
        return message.contains("disabled")
            || message.contains("stability issues")
            || message.contains("403")
    }
}

enum DiscoverPaginationState: Equatable {
    case idle
    case loadingAdditional
    case failed
    case exhausted
}

enum DiscoverPresentationState: Equatable {
    case idle
    case loading
    case home(DiscoverHomeContent)
    case searchLoading(existing: [DiscoverMedia])
    case results([DiscoverMedia], pagination: DiscoverPaginationState)
    case empty(DiscoverEmptyContext)
    case error(DiscoverPresentationFailure, retainedResults: [DiscoverMedia])
}

enum DiscoverFilterLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

@MainActor
final class DiscoverViewModel: ObservableObject {
    static let productionDebounceMilliseconds = 400
    static let cacheLifetime: TimeInterval = 300
    static let pageSize = 20

    @Published private(set) var state: DiscoverPresentationState = .idle
    @Published private(set) var selectedType: DiscoverMediaType = .manga
    @Published var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            scheduleCurrentResultsSession()
        }
    }
    @Published private(set) var activeFilters = DiscoverFilters()
    @Published private(set) var availableGenres: [String] = []
    @Published private(set) var availableTags: [DiscoverTag] = []
    @Published private(set) var filterLoadState: DiscoverFilterLoadState = .idle

    private let service: any DiscoverHomeFilterServing
    private let cache: any DiscoverCaching
    private let clock: any DiscoverClock
    private let debounceMilliseconds: Int?
    private let calendar: Calendar

    private var homeContents: [DiscoverMediaType: DiscoverHomeContent] = [:]
    private var homeGeneration = 0
    private var resultsGeneration = 0
    private var filterGeneration = 0
    private var currentPage = 1
    private var hasNextPage = false

    private var homeTask: Task<Void, Never>?
    private var homeTaskMediaType: DiscoverMediaType?
    private var searchTask: Task<Void, Never>?
    private var paginationTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?

    init(
        service: any DiscoverHomeFilterServing,
        cache: any DiscoverCaching,
        clock: any DiscoverClock,
        debounceMilliseconds: Int? = DiscoverViewModel.productionDebounceMilliseconds,
        calendar: Calendar = .current
    ) {
        self.service = service
        self.cache = cache
        self.clock = clock
        self.debounceMilliseconds = debounceMilliseconds
        self.calendar = calendar
    }

    deinit {
        homeTask?.cancel()
        searchTask?.cancel()
        paginationTask?.cancel()
        filterTask?.cancel()
    }

    var isFilterActive: Bool {
        !activeFilters.isEmpty
    }

    var isShowingHome: Bool {
        searchQuery.isEmpty && !isFilterActive
    }

    var currentHomeContent: DiscoverHomeContent {
        homeContents[selectedType] ?? .empty
    }

    var searchResults: [DiscoverMedia] {
        switch state {
        case .searchLoading(let existing):
            return existing
        case .results(let results, _):
            return results
        case .error(let failure, let retainedResults) where failure.context == .search:
            return retainedResults
        default:
            return []
        }
    }

    var isLoadingResults: Bool {
        switch state {
        case .searchLoading:
            return true
        case .results(_, pagination: .loadingAdditional):
            return true
        default:
            return false
        }
    }

    var currentYear: Int {
        calendar.component(.year, from: clock.now)
    }

    func selectMediaType(_ mediaType: DiscoverMediaType) {
        guard selectedType != mediaType else { return }
        selectedType = mediaType
        guard isShowingHome else { return }

        let content = homeContents[mediaType] ?? .empty
        if content.trending.isEmpty {
            _ = startHomeLoad(for: mediaType, forceRefresh: false)
        } else {
            state = .home(content)
        }
    }

    func loadInitialHomeIfNeeded() async {
        guard isShowingHome else { return }
        if let homeTask, homeTaskMediaType == selectedType {
            await homeTask.value
            return
        }
        let content = currentHomeContent
        guard content.trending.isEmpty else {
            state = .home(content)
            return
        }
        await startHomeLoad(for: selectedType, forceRefresh: false).value
    }

    func refreshHome() async {
        await startHomeLoad(for: selectedType, forceRefresh: true).value
    }

    func retryHome() {
        _ = startHomeLoad(for: selectedType, forceRefresh: true)
    }

    func applyFilters(_ filters: DiscoverFilters) {
        activeFilters = filters
        scheduleCurrentResultsSession()
    }

    func resetFilters() {
        activeFilters = DiscoverFilters()
        scheduleCurrentResultsSession()
    }

    func removeIncludedGenre(_ genre: String) {
        var filters = activeFilters
        filters.genres.removeAll { $0 == genre }
        applyFilters(filters)
    }

    func removeExcludedGenre(_ genre: String) {
        var filters = activeFilters
        filters.excludedGenres.removeAll { $0 == genre }
        applyFilters(filters)
    }

    func removeIncludedTag(_ tag: String) {
        var filters = activeFilters
        filters.tags.removeAll { $0 == tag }
        applyFilters(filters)
    }

    func removeExcludedTag(_ tag: String) {
        var filters = activeFilters
        filters.excludedTags.removeAll { $0 == tag }
        applyFilters(filters)
    }

    func removeFormat() {
        var filters = activeFilters
        filters.format = nil
        applyFilters(filters)
    }

    func removeStatus() {
        var filters = activeFilters
        filters.status = nil
        applyFilters(filters)
    }

    func removeYearAndSeason() {
        var filters = activeFilters
        filters.year = nil
        filters.season = nil
        applyFilters(filters)
    }

    func loadFilterOptionsIfNeeded() {
        guard filterTask == nil else { return }
        switch filterLoadState {
        case .idle, .failed:
            break
        case .loading, .loaded:
            return
        }
        startFilterLoad()
    }

    func retryFilterOptions() {
        guard filterTask == nil else { return }
        startFilterLoad()
    }

    func loadMoreIfNeeded(after media: DiscoverMedia) {
        guard media.id == searchResults.last?.id else { return }
        loadNextPage()
    }

    func loadNextPage() {
        guard paginationTask == nil,
              searchTask == nil,
              hasNextPage,
              case .results(let existingResults, let pagination) = state,
              pagination != .loadingAdditional else {
            return
        }

        let generation = resultsGeneration
        let nextPage = currentPage + 1
        let request = DiscoverSearchRequest(
            query: searchQuery,
            mediaType: selectedType,
            filters: activeFilters,
            page: nextPage,
            perPage: Self.pageSize
        )
        let service = service
        state = .results(existingResults, pagination: .loadingAdditional)

        let task = Task { @MainActor [weak self, service] in
            do {
                let page = try await service.search(request)
                try Task.checkCancellation()
                guard let self,
                      self.resultsGeneration == generation else {
                    return
                }
                self.currentPage = nextPage
                self.hasNextPage = page.hasNextPage
                self.paginationTask = nil
                self.state = .results(
                    existingResults + page.media,
                    pagination: page.hasNextPage ? .idle : .exhausted
                )
            } catch is CancellationError {
                guard let self,
                      self.resultsGeneration == generation else {
                    return
                }
                self.paginationTask = nil
                self.state = .results(
                    existingResults,
                    pagination: self.hasNextPage ? .idle : .exhausted
                )
            } catch {
                guard let self,
                      self.resultsGeneration == generation else {
                    return
                }
                self.paginationTask = nil
                self.state = .results(existingResults, pagination: .failed)
            }
        }
        paginationTask = task
    }

    private func startHomeLoad(
        for mediaType: DiscoverMediaType,
        forceRefresh: Bool
    ) -> Task<Void, Never> {
        if !forceRefresh,
           let homeTask,
           homeTaskMediaType == mediaType {
            return homeTask
        }
        homeTask?.cancel()
        homeGeneration &+= 1
        let generation = homeGeneration
        let service = service
        let cache = cache
        let clock = clock
        let calendar = calendar

        if forceRefresh {
            cache.removeHomeMedia(for: mediaType)
        }

        let existing = homeContents[mediaType] ?? .empty
        if isShowingHome && selectedType == mediaType {
            state = existing.trending.isEmpty ? .loading : .home(existing)
        }

        let task = Task { @MainActor [weak self, service, cache, clock] in
            guard let result = await Self.loadHomeContent(
                mediaType: mediaType,
                service: service,
                cache: cache,
                clock: clock,
                calendar: calendar
            ) else {
                return
            }
            guard let self,
                  self.homeGeneration == generation else {
                return
            }

            self.homeTask = nil
            self.homeTaskMediaType = nil
            self.homeContents[mediaType] = result.content
            guard self.isShowingHome,
                  self.selectedType == mediaType else {
                return
            }

            if result.content.primarySectionsAreEmpty {
                if let failure = result.failure {
                    self.state = .error(failure, retainedResults: [])
                } else {
                    self.state = .empty(.home)
                }
            } else {
                self.state = .home(result.content)
            }
        }
        homeTask = task
        homeTaskMediaType = mediaType
        return task
    }

    private func scheduleCurrentResultsSession() {
        invalidateResultsSession()

        guard !searchQuery.isEmpty || isFilterActive else {
            state = homeState(for: currentHomeContent)
            if currentHomeContent.trending.isEmpty {
                _ = startHomeLoad(for: selectedType, forceRefresh: false)
            }
            return
        }

        cancelHomeLoad()
        let generation = resultsGeneration
        let request = DiscoverSearchRequest(
            query: searchQuery,
            mediaType: selectedType,
            filters: activeFilters,
            page: 1,
            perPage: Self.pageSize
        )
        let retainedResults = searchResults
        let service = service
        let clock = clock
        let debounceMilliseconds = debounceMilliseconds

        let task = Task { @MainActor [weak self, service, clock] in
            do {
                if let debounceMilliseconds {
                    try await clock.sleep(milliseconds: debounceMilliseconds)
                }
                try Task.checkCancellation()
                guard self?.resultsGeneration == generation else { return }

                self?.currentPage = 1
                self?.hasNextPage = false
                self?.state = .searchLoading(existing: retainedResults)

                let page = try await service.search(request)
                try Task.checkCancellation()
                guard let self,
                      self.resultsGeneration == generation else {
                    return
                }

                self.searchTask = nil
                self.currentPage = 1
                self.hasNextPage = page.hasNextPage
                if page.media.isEmpty {
                    self.state = .empty(
                        request.query.isEmpty ? .filters : .search
                    )
                } else {
                    self.state = .results(
                        page.media,
                        pagination: page.hasNextPage ? .idle : .exhausted
                    )
                }
            } catch is CancellationError {
                guard let self,
                      self.resultsGeneration == generation else {
                    return
                }
                self.searchTask = nil
                self.state = retainedResults.isEmpty
                    ? .empty(request.query.isEmpty ? .filters : .search)
                    : .results(retainedResults, pagination: .exhausted)
            } catch {
                guard let self,
                      self.resultsGeneration == generation else {
                    return
                }
                self.searchTask = nil
                self.state = .error(
                    DiscoverPresentationFailure(
                        context: .search,
                        message: error.localizedDescription
                    ),
                    retainedResults: retainedResults
                )
            }
        }
        searchTask = task
    }

    private func invalidateResultsSession() {
        searchTask?.cancel()
        paginationTask?.cancel()
        searchTask = nil
        paginationTask = nil
        resultsGeneration &+= 1
        currentPage = 1
        hasNextPage = false
    }

    private func cancelHomeLoad() {
        homeTask?.cancel()
        homeTask = nil
        homeTaskMediaType = nil
        homeGeneration &+= 1
    }

    private func homeState(
        for content: DiscoverHomeContent
    ) -> DiscoverPresentationState {
        if content.primarySectionsAreEmpty {
            return .idle
        }
        return .home(content)
    }

    private func startFilterLoad() {
        filterTask?.cancel()
        filterGeneration &+= 1
        let generation = filterGeneration
        let service = service
        let cache = cache
        let clock = clock
        filterLoadState = .loading

        let task = Task { @MainActor [weak self, service, cache, clock] in
            let result = await Self.loadFilterOptions(
                service: service,
                cache: cache,
                clock: clock
            )
            guard let self,
                  self.filterGeneration == generation else {
                return
            }
            self.filterTask = nil
            if let genres = result.genres {
                self.availableGenres = genres
            }
            if let tags = result.tags {
                self.availableTags = tags.filter { $0.isAdult != true }
            }
            self.filterLoadState = result.failed ? .failed : .loaded
        }
        filterTask = task
    }
}

private extension DiscoverViewModel {
    struct HomeLoadResult {
        let content: DiscoverHomeContent
        let failure: DiscoverPresentationFailure?
    }

    enum SectionLoadResult {
        case value([DiscoverMedia])
        case failure(String)
        case cancelled
    }

    struct FilterLoadResult {
        let genres: [String]?
        let tags: [DiscoverTag]?
        let failed: Bool
    }

    enum ValueLoadResult<Value> {
        case value(Value)
        case failure
        case cancelled
    }

    static func loadHomeContent(
        mediaType: DiscoverMediaType,
        service: any DiscoverHomeFilterServing,
        cache: any DiscoverCaching,
        clock: any DiscoverClock,
        calendar: Calendar
    ) async -> HomeLoadResult? {
        async let trending = loadHomeSection(
            .trending,
            mediaType: mediaType,
            service: service,
            cache: cache,
            clock: clock,
            season: nil,
            seasonYear: nil
        )
        async let popular = loadHomeSection(
            .popular,
            mediaType: mediaType,
            service: service,
            cache: cache,
            clock: clock,
            season: nil,
            seasonYear: nil
        )
        async let topRated = loadHomeSection(
            .topRated,
            mediaType: mediaType,
            service: service,
            cache: cache,
            clock: clock,
            season: nil,
            seasonYear: nil
        )

        let primary = await (trending, popular, topRated)
        let primaryResults = [primary.0, primary.1, primary.2]
        guard !primaryResults.contains(where: { result in
            if case .cancelled = result { return true }
            return false
        }) else {
            return nil
        }

        let seasonal: SectionLoadResult
        if mediaType == .anime {
            let now = clock.now
            seasonal = await loadHomeSection(
                .seasonal,
                mediaType: mediaType,
                service: service,
                cache: cache,
                clock: clock,
                season: season(for: now, calendar: calendar),
                seasonYear: calendar.component(.year, from: now)
            )
            if case .cancelled = seasonal { return nil }
        } else {
            seasonal = .value([])
        }

        let allResults = [primary.0, primary.1, primary.2, seasonal]
        let failureMessage = allResults.compactMap { result -> String? in
            if case .failure(let message) = result { return message }
            return nil
        }.last

        return HomeLoadResult(
            content: DiscoverHomeContent(
                trending: primary.0.media,
                seasonal: seasonal.media,
                popular: primary.1.media,
                topRated: primary.2.media
            ),
            failure: failureMessage.map {
                DiscoverPresentationFailure(context: .home, message: $0)
            }
        )
    }

    static func loadHomeSection(
        _ section: DiscoverHomeSection,
        mediaType: DiscoverMediaType,
        service: any DiscoverHomeFilterServing,
        cache: any DiscoverCaching,
        clock: any DiscoverClock,
        season: String?,
        seasonYear: Int?
    ) async -> SectionLoadResult {
        if let cached = cache.homeMedia(
            section: section,
            mediaType: mediaType,
            now: clock.now,
            lifetime: cacheLifetime
        ) {
            return .value(cached)
        }

        do {
            let media = try await service.loadHomeSection(
                DiscoverHomeSectionRequest(
                    section: section,
                    mediaType: mediaType,
                    season: season,
                    seasonYear: seasonYear,
                    perPage: pageSize
                )
            )
            try Task.checkCancellation()
            cache.storeHomeMedia(
                media,
                section: section,
                mediaType: mediaType,
                at: clock.now
            )
            return .value(media)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(homeFailureMessage(for: section, error: error))
        }
    }

    static func loadFilterOptions(
        service: any DiscoverHomeFilterServing,
        cache: any DiscoverCaching,
        clock: any DiscoverClock
    ) async -> FilterLoadResult {
        async let genres = loadGenres(service: service, cache: cache, clock: clock)
        async let tags = loadTags(service: service, cache: cache, clock: clock)
        let results = await (genres, tags)

        let wasCancelled = results.0.isCancelled || results.1.isCancelled
        return FilterLoadResult(
            genres: results.0.value,
            tags: results.1.value,
            failed: wasCancelled || results.0.didFail || results.1.didFail
        )
    }

    static func loadGenres(
        service: any DiscoverHomeFilterServing,
        cache: any DiscoverCaching,
        clock: any DiscoverClock
    ) async -> ValueLoadResult<[String]> {
        if let cached = cache.genres(now: clock.now, lifetime: cacheLifetime) {
            return .value(cached)
        }
        do {
            let genres = try await service.loadGenres()
            try Task.checkCancellation()
            cache.storeGenres(genres, at: clock.now)
            return .value(genres)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure
        }
    }

    static func loadTags(
        service: any DiscoverHomeFilterServing,
        cache: any DiscoverCaching,
        clock: any DiscoverClock
    ) async -> ValueLoadResult<[DiscoverTag]> {
        if let cached = cache.tags(now: clock.now, lifetime: cacheLifetime) {
            return .value(cached)
        }
        do {
            let tags = try await service.loadTags()
            try Task.checkCancellation()
            cache.storeTags(tags, at: clock.now)
            return .value(tags)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure
        }
    }

    static func season(for date: Date, calendar: Calendar) -> String {
        switch calendar.component(.month, from: date) {
        case 1...3:
            return "WINTER"
        case 4...6:
            return "SPRING"
        case 7...9:
            return "SUMMER"
        default:
            return "FALL"
        }
    }

    static func homeFailureMessage(for section: DiscoverHomeSection, error: any Error) -> String {
        switch section {
        case .trending:
            return String(localized: "Couldn't load trending titles: \(error.localizedDescription)")
        case .popular:
            return String(localized: "Couldn't load popular titles: \(error.localizedDescription)")
        case .topRated:
            return String(localized: "Couldn't load top-rated titles: \(error.localizedDescription)")
        case .seasonal:
            return String(localized: "Couldn't load this season's anime: \(error.localizedDescription)")
        }
    }
}

private extension DiscoverViewModel.SectionLoadResult {
    var media: [DiscoverMedia] {
        if case .value(let media) = self { return media }
        return []
    }
}

private extension DiscoverViewModel.ValueLoadResult {
    var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }

    var didFail: Bool {
        if case .failure = self { return true }
        return false
    }

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
