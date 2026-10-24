import Combine
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class DiscoverViewModelTests: XCTestCase {
    func test01ConstructorInjectionProducesUsableViewModel() async {
        let service = DiscoverServiceFake()
        let viewModel = makeViewModel(service: service)
        await viewModel.loadInitialHomeIfNeeded()
        XCTAssertEqual(service.homeRequests.count, 3)
    }

    func test02ConstructorRequiresNoMutableConfigurationStep() throws {
        let source = try sourceFile("Ito/ViewModels/DiscoverViewModel.swift")
        XCTAssertFalse(source.contains("func configure("))
        XCTAssertTrue(source.contains("init(\n        service:"))
    }

    func test03DiscoverRootOwnsOneStableViewModelPerScopeEpoch() {
        let scope = makeScope()
        XCTAssertTrue(scope.rootModels.discoverViewModel === scope.viewFactory.rootModels.discoverViewModel)
    }

    func test04RepeatedRootRecomputationReturnsSameDiscoverViewModel() {
        let scope = makeScope()
        let first = scope.rootModels.discoverViewModel
        _ = scope.viewFactory.makeDiscoverView()
        let second = scope.rootModels.discoverViewModel
        XCTAssertTrue(first === second)
    }

    func test05NewScopeEpochCreatesNewDiscoverViewModel() {
        XCTAssertFalse(makeScope().rootModels.discoverViewModel === makeScope().rootModels.discoverViewModel)
    }

    func test06PreparedDiscoverDependenciesAreNotDuplicated() {
        let service = DiscoverServiceFake()
        let cache = InMemoryDiscoverCache()
        let clock = TestDiscoverClock()
        let scope = makeScope(service: service, cache: cache, clock: clock)
        XCTAssertTrue(scope.dependencies.discoverService === service)
        XCTAssertTrue(scope.dependencies.discoverCache === cache)
        XCTAssertTrue(scope.dependencies.discoverClock === clock)
        XCTAssertTrue(scope.rootModels.discoverViewModel === scope.rootModels.discoverViewModel)
    }

    func test07InitialHomeLoadEntersLoadingState() async {
        let service = DiscoverServiceFake(homeSuspended: true)
        let viewModel = makeViewModel(service: service)
        let task = Task { await viewModel.loadInitialHomeIfNeeded() }
        await waitUntil { service.homeRequests.count == 3 }
        XCTAssertEqual(viewModel.state, .loading)
        service.completeAllHome()
        await task.value
    }

    func test08SuccessfulHomeLoadPublishesContent() async {
        let service = DiscoverServiceFake()
        service.homeResults[.trending] = [.media(1)]
        service.homeResults[.popular] = [.media(2)]
        service.homeResults[.topRated] = [.media(3)]
        let viewModel = makeViewModel(service: service)
        await viewModel.loadInitialHomeIfNeeded()
        XCTAssertEqual(viewModel.state, .home(.init(trending: [.media(1)], seasonal: [], popular: [.media(2)], topRated: [.media(3)])))
    }

    func test09ZeroResultHomeLoadPublishesEmptyState() async {
        let viewModel = makeViewModel()
        await viewModel.loadInitialHomeIfNeeded()
        XCTAssertEqual(viewModel.state, .empty(.home))
    }

    func test10HomeFailurePublishesRecoverableErrorState() async {
        let service = DiscoverServiceFake()
        service.homeErrors[.trending] = TestError.failed
        let viewModel = makeViewModel(service: service)
        await viewModel.loadInitialHomeIfNeeded()
        guard case .error(let failure, retainedResults: []) = viewModel.state else { return XCTFail("Expected home error") }
        XCTAssertEqual(failure.context, .home)
    }

    func test11RetryPerformsOneRequestPerHomeSection() async {
        let service = DiscoverServiceFake()
        service.homeErrors[.trending] = TestError.failed
        let viewModel = makeViewModel(service: service)
        await viewModel.loadInitialHomeIfNeeded()
        service.homeErrors = [:]
        viewModel.retryHome()
        await waitUntil { service.homeRequests.count == 6 }
        XCTAssertEqual(service.homeRequests.count, 6)
    }

    func test12SupersededHomeRequestCannotPublishStaleContent() async {
        let service = DiscoverServiceFake(homeSuspended: true)
        let viewModel = makeViewModel(service: service)
        let first = Task { await viewModel.loadInitialHomeIfNeeded() }
        await waitUntil { service.homeRequests.count == 3 }
        viewModel.selectMediaType(.anime)
        await waitUntil { service.homeRequests.count == 6 }
        service.completeHome(mediaType: .manga, media: [.media(1)])
        await Task.yield()
        XCTAssertEqual(viewModel.selectedType, .anime)
        XCTAssertNotEqual(viewModel.state, .home(.init(trending: [.media(1)], seasonal: [], popular: [.media(1)], topRated: [.media(1)])))
        service.completeHome(mediaType: .anime, media: [.media(2)])
        await waitUntil { service.homeRequests.count == 7 }
        service.completeAllHome()
        await first.value
    }

    func test13FreshCacheAvoidsNetworkRequest() async {
        let clock = TestDiscoverClock(now: Date(timeIntervalSince1970: 1_000))
        let cache = InMemoryDiscoverCache()
        for section in primarySections { cache.storeHomeMedia([.media(section.hashValue)], section: section, mediaType: .manga, at: clock.now) }
        let service = DiscoverServiceFake()
        await makeViewModel(service: service, cache: cache, clock: clock).loadInitialHomeIfNeeded()
        XCTAssertTrue(service.homeRequests.isEmpty)
    }

    func test14ExpiredCacheTriggersRefresh() async {
        let clock = TestDiscoverClock(now: Date(timeIntervalSince1970: 1_000))
        let cache = InMemoryDiscoverCache()
        for section in primarySections { cache.storeHomeMedia([.media(1)], section: section, mediaType: .manga, at: clock.now) }
        clock.advance(seconds: DiscoverViewModel.cacheLifetime + 0.001)
        let service = DiscoverServiceFake()
        await makeViewModel(service: service, cache: cache, clock: clock).loadInitialHomeIfNeeded()
        XCTAssertEqual(service.homeRequests.count, 3)
    }

    func test15CacheFreshnessUsesNoRealSleep() async {
        let clock = TestDiscoverClock()
        let viewModel = makeViewModel(clock: clock)
        await viewModel.loadInitialHomeIfNeeded()
        XCTAssertEqual(clock.sleepRequests, [])
    }

    func test16FailedExpiredCacheRefreshDoesNotPublishStaleCacheAsSuccess() async {
        let clock = TestDiscoverClock(now: Date(timeIntervalSince1970: 1_000))
        let cache = InMemoryDiscoverCache()
        for section in primarySections { cache.storeHomeMedia([.media(99)], section: section, mediaType: .manga, at: clock.now) }
        clock.advance(seconds: DiscoverViewModel.cacheLifetime + 1)
        let service = DiscoverServiceFake(); service.homeErrors[.trending] = TestError.failed
        let viewModel = makeViewModel(service: service, cache: cache, clock: clock)
        await viewModel.loadInitialHomeIfNeeded()
        guard case .error = viewModel.state else { return XCTFail("Expected refresh error") }
    }

    func test17ProductionDebounceIntervalRemainsFourHundredMilliseconds() {
        XCTAssertEqual(DiscoverViewModel.productionDebounceMilliseconds, 400)
    }

    func test18QueryDoesNotExecuteBeforeDeterministicDebounceElapses() async {
        let service = DiscoverServiceFake(); let clock = TestDiscoverClock()
        let viewModel = makeViewModel(service: service, clock: clock, debounce: 400)
        viewModel.searchQuery = "one"
        await waitUntil { clock.sleepRequests == [400] }
        XCTAssertTrue(service.searchRequests.isEmpty)
    }

    func test19QueryExecutesOnceAfterDebounceInterval() async {
        let service = DiscoverServiceFake(); let clock = TestDiscoverClock()
        let viewModel = makeViewModel(service: service, clock: clock, debounce: 400)
        viewModel.searchQuery = "one"
        await waitUntil { clock.sleepRequests.count == 1 }
        clock.advance(milliseconds: 400)
        await waitUntil { service.searchRequests.count == 1 }
        XCTAssertEqual(service.searchRequests.map(\.query), ["one"])
    }

    func test20RapidQueryChangesExecuteOnlyLatestQuery() async {
        let service = DiscoverServiceFake(); let clock = TestDiscoverClock()
        let viewModel = makeViewModel(service: service, clock: clock, debounce: 400)
        viewModel.searchQuery = "one"; await Task.yield(); viewModel.searchQuery = "two"
        await waitUntil { clock.sleepRequests.count == 2 }
        clock.advance(milliseconds: 400)
        await waitUntil { service.searchRequests.count == 1 }
        XCTAssertEqual(service.searchRequests.first?.query, "two")
    }

    func test21ClearingQueryRestoresHomeState() async {
        let service = DiscoverServiceFake(); service.homeResults[.trending] = [.media(1)]
        let viewModel = makeViewModel(service: service, debounce: nil)
        await viewModel.loadInitialHomeIfNeeded()
        viewModel.searchQuery = "query"; await waitUntil { service.searchRequests.count == 1 }
        viewModel.searchQuery = ""
        guard case .home = viewModel.state else { return XCTFail("Expected home") }
    }

    func test22NewerQuerySupersedesPreviousOperation() async {
        let service = DiscoverServiceFake(searchSuspended: true)
        let viewModel = makeViewModel(service: service, debounce: nil)
        viewModel.searchQuery = "old"; await waitUntil { service.searchRequests.count == 1 }
        viewModel.searchQuery = "new"; await waitUntil { service.searchRequests.count == 2 }
        XCTAssertEqual(service.searchRequests.map(\.query), ["old", "new"])
    }

    func test23StaleSearchCannotMutateCurrentQueryState() async {
        let service = DiscoverServiceFake(searchSuspended: true)
        let viewModel = makeViewModel(service: service, debounce: nil)
        viewModel.searchQuery = "old"; await waitUntil { service.searchRequests.count == 1 }
        viewModel.searchQuery = "new"; await waitUntil { service.searchRequests.count == 2 }
        service.completeSearch(query: "old", media: [.media(1)])
        await Task.yield()
        XCTAssertNotEqual(viewModel.searchResults.map(\.id), [1])
        service.completeSearch(query: "new", media: [.media(2)])
        await waitUntil { viewModel.searchResults.map(\.id) == [2] }
    }

    func test24CooperativeSearchCancellationDoesNotSurfaceFailure() async {
        let service = DiscoverServiceFake(searchSuspended: true)
        let viewModel = makeViewModel(service: service, debounce: nil)
        viewModel.searchQuery = "old"; await waitUntil { service.searchRequests.count == 1 }
        viewModel.searchQuery = ""
        service.failSearch(query: "old", error: CancellationError())
        await Task.yield()
        guard case .error = viewModel.state else { return }
        XCTFail("Cancellation must not surface as an error")
    }

    func test25FilterDefaultsArePreserved() {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.activeFilters, DiscoverFilters())
        XCTAssertEqual(viewModel.activeFilters.sort, .popularity)
    }

    func test26FilterOptionsLoadAndExcludeAdultTags() async {
        let service = DiscoverServiceFake(); service.genresResult = .success(["Action"]); service.tagsResult = .success([.tag(1, adult: false), .tag(2, adult: true)])
        let viewModel = makeViewModel(service: service)
        viewModel.loadFilterOptionsIfNeeded()
        await waitUntil { viewModel.filterLoadState != .loading }
        XCTAssertEqual(viewModel.availableGenres, ["Action"])
        XCTAssertEqual(viewModel.availableTags.map(\.id), [1])
    }

    func test27ApplyingFilterIssuesExpectedFirstPageRequest() async {
        let service = DiscoverServiceFake(); let viewModel = makeViewModel(service: service, debounce: nil)
        var filters = DiscoverFilters(); filters.genres = ["Action"]
        viewModel.applyFilters(filters)
        await waitUntil { service.searchRequests.count == 1 }
        XCTAssertEqual(service.searchRequests[0].filters, filters)
        XCTAssertEqual(service.searchRequests[0].page, 1)
    }

    func test28ChangingFilterResetsPaginationToFirstPage() async {
        let service = DiscoverServiceFake(); service.searchResult = .init(media: [.media(1)], hasNextPage: true)
        let viewModel = makeViewModel(service: service, debounce: nil)
        var first = DiscoverFilters(); first.genres = ["A"]; viewModel.applyFilters(first)
        await waitUntil { viewModel.searchResults.count == 1 }; viewModel.loadNextPage(); await waitUntil { service.searchRequests.count == 2 }
        var second = DiscoverFilters(); second.genres = ["B"]; viewModel.applyFilters(second)
        await waitUntil { service.searchRequests.count == 3 }
        XCTAssertEqual(service.searchRequests.last?.page, 1)
    }

    func test29ChangingFilterInvalidatesStaleResponse() async {
        let service = DiscoverServiceFake(searchSuspended: true); let viewModel = makeViewModel(service: service, debounce: nil)
        var first = DiscoverFilters(); first.genres = ["A"]; viewModel.applyFilters(first); await waitUntil { service.searchRequests.count == 1 }
        var second = DiscoverFilters(); second.genres = ["B"]; viewModel.applyFilters(second); await waitUntil { service.searchRequests.count == 2 }
        service.completeSearch(filterGenre: "A", media: [.media(1)]); await Task.yield()
        XCTAssertTrue(viewModel.searchResults.isEmpty)
        service.completeSearch(filterGenre: "B", media: [.media(2)]); await waitUntil { viewModel.searchResults.map(\.id) == [2] }
    }

    func test30ResetFiltersRestoresDefaultHomeBehavior() async {
        let service = DiscoverServiceFake(); service.homeResults[.trending] = [.media(1)]
        let viewModel = makeViewModel(service: service, debounce: nil); await viewModel.loadInitialHomeIfNeeded()
        var filters = DiscoverFilters(); filters.genres = ["A"]; viewModel.applyFilters(filters); await waitUntil { !service.searchRequests.isEmpty }
        viewModel.resetFilters()
        XCTAssertEqual(viewModel.activeFilters, DiscoverFilters())
        XCTAssertTrue(viewModel.isShowingHome)
    }

    func test31FilterLoadFailureIsRecoverableAndPreservesValidState() async {
        let service = DiscoverServiceFake(); service.genresResult = .success(["Action"]); service.tagsResult = .success([.tag(1)])
        let clock = TestDiscoverClock()
        let viewModel = makeViewModel(service: service, clock: clock); viewModel.loadFilterOptionsIfNeeded(); await waitUntil { viewModel.filterLoadState == .loaded }
        clock.advance(seconds: DiscoverViewModel.cacheLifetime + 1)
        service.genresResult = .failure(TestError.failed); service.tagsResult = .failure(TestError.failed); viewModel.retryFilterOptions()
        await waitUntil { viewModel.filterLoadState == .failed }
        XCTAssertEqual(viewModel.availableGenres, ["Action"]); XCTAssertEqual(viewModel.availableTags.map(\.id), [1])
        service.genresResult = .success(["Drama"]); service.tagsResult = .success([.tag(2)])
        viewModel.loadFilterOptionsIfNeeded()
        await waitUntil { viewModel.filterLoadState == .loaded }
        XCTAssertEqual(viewModel.availableGenres, ["Drama"]); XCTAssertEqual(viewModel.availableTags.map(\.id), [2])
        XCTAssertEqual(service.genreRequests, 3); XCTAssertEqual(service.tagRequests, 3)
    }

    func test32InitialSearchUsesExistingFirstPageAndPageSizeSemantics() async {
        let service = DiscoverServiceFake(); let viewModel = makeViewModel(service: service, debounce: nil); viewModel.searchQuery = "q"
        await waitUntil { service.searchRequests.count == 1 }
        XCTAssertEqual(service.searchRequests[0].page, 1); XCTAssertEqual(service.searchRequests[0].perPage, 20)
    }

    func test33LoadMoreRequestsNextPage() async {
        let service = DiscoverServiceFake(); service.searchResult = .init(media: [.media(1)], hasNextPage: true)
        let viewModel = makeViewModel(service: service, debounce: nil); viewModel.searchQuery = "q"; await waitUntil { viewModel.searchResults.count == 1 }
        viewModel.loadNextPage(); await waitUntil { service.searchRequests.count == 2 }
        XCTAssertEqual(service.searchRequests.last?.page, 2)
    }

    func test34SuccessfulLoadMoreAppendsInOrder() async {
        let service = DiscoverServiceFake(); service.searchResponses = [.success(.init(media: [.media(1)], hasNextPage: true)), .success(.init(media: [.media(2), .media(3)], hasNextPage: false))]
        let viewModel = makeViewModel(service: service, debounce: nil); viewModel.searchQuery = "q"; await waitUntil { viewModel.searchResults.count == 1 }
        viewModel.loadNextPage(); await waitUntil { viewModel.searchResults.count == 3 }
        XCTAssertEqual(viewModel.searchResults.map(\.id), [1, 2, 3])
    }

    func test35DuplicateLoadMoreTriggersDoNotOverlap() async {
        let service = DiscoverServiceFake(); service.searchResponses = [.success(.init(media: [.media(1)], hasNextPage: true))]
        let viewModel = makeViewModel(service: service, debounce: nil); viewModel.searchQuery = "q"; await waitUntil { viewModel.searchResults.count == 1 }
        service.searchSuspended = true; viewModel.loadNextPage(); viewModel.loadNextPage(); await waitUntil { service.searchRequests.count == 2 }
        XCTAssertEqual(service.searchRequests.filter { $0.page == 2 }.count, 1)
        service.completeSearch(page: 2, media: [])
    }

    func test36EndOfResultsPreventsAdditionalRequests() async {
        let service = DiscoverServiceFake(); service.searchResult = .init(media: [.media(1)], hasNextPage: false)
        let viewModel = makeViewModel(service: service, debounce: nil); viewModel.searchQuery = "q"; await waitUntil { viewModel.searchResults.count == 1 }
        viewModel.loadNextPage(); await Task.yield(); XCTAssertEqual(service.searchRequests.count, 1)
    }

    func test37PaginationFailurePreservesExistingContent() async {
        let service = DiscoverServiceFake(); service.searchResponses = [.success(.init(media: [.media(1)], hasNextPage: true)), .failure(TestError.failed)]
        let viewModel = makeViewModel(service: service, debounce: nil); viewModel.searchQuery = "q"; await waitUntil { viewModel.searchResults.count == 1 }
        viewModel.loadNextPage(); await waitUntil { if case .results(_, pagination: .failed) = viewModel.state { return true }; return false }
        XCTAssertEqual(viewModel.searchResults.map(\.id), [1])
    }

    func test38NewSearchInvalidatesOldPagination() async {
        let (viewModel, service) = await viewModelWithSuspendedSecondPage()
        viewModel.searchQuery = "new"; await waitUntil { service.searchRequests.count == 3 }
        service.completeSearch(query: "q", page: 2, media: [.media(9)]); await Task.yield()
        XCTAssertFalse(viewModel.searchResults.map(\.id).contains(9))
        service.completeSearch(query: "new", page: 1, media: [.media(2)])
    }

    func test39NewFilterInvalidatesOldPagination() async {
        let (viewModel, service) = await viewModelWithSuspendedSecondPage()
        var filters = DiscoverFilters(); filters.genres = ["A"]; viewModel.applyFilters(filters); await waitUntil { service.searchRequests.count == 3 }
        service.completeSearch(query: "q", page: 2, media: [.media(9)]); await Task.yield()
        XCTAssertFalse(viewModel.searchResults.map(\.id).contains(9))
        service.completeSearch(filterGenre: "A", media: [.media(2)])
    }

    func test40StalePageCannotAppendIntoNewSession() async {
        let (viewModel, service) = await viewModelWithSuspendedSecondPage()
        viewModel.searchQuery = "replacement"; await waitUntil { service.searchRequests.count == 3 }
        service.completeSearch(query: "replacement", page: 1, media: [.media(2)]); await waitUntil { viewModel.searchResults.map(\.id) == [2] }
        service.completeSearch(query: "q", page: 2, media: [.media(99)]); await Task.yield()
        XCTAssertEqual(viewModel.searchResults.map(\.id), [2])
    }

    func test41ViewModelContainsNoForbiddenDirectGlobalsOrConfigureStep() throws {
        let source = try sourceFile("Ito/ViewModels/DiscoverViewModel.swift")
        for forbidden in ["DiscoverManager.shared", "SnackBarManager.shared", "AppLogger", "UserDefaults.standard", "func configure("] { XCTAssertFalse(source.contains(forbidden), "Forbidden: \(forbidden)") }
    }

    func test42MigratedDiscoverHomeAndFilterViewsContainNoManagerSingleton() throws {
        for path in ["Ito/Views/Discover/DiscoverView.swift", "Ito/Views/Discover/DiscoverFilterView.swift"] {
            XCTAssertFalse(try sourceFile(path).contains("DiscoverManager.shared"), path)
        }
    }

    func test43DetailAndSourceResolverUseInjectedScreenBoundary() throws {
        let detail = try sourceFile("Ito/Views/Discover/DiscoverDetailView.swift")
        let resolver = try sourceFile("Ito/ViewModels/Discover/SourceResolverViewModel.swift")
        let detailViewModel = try sourceFile(
            "Ito/ViewModels/Discover/DiscoverDetailViewModel.swift"
        )
        for source in [detail, resolver, detailViewModel] {
            XCTAssertFalse(source.contains("DiscoverManager.shared"))
            XCTAssertFalse(source.contains("ThemeManager.shared"))
            XCTAssertFalse(source.contains("AppDatabase.shared"))
            XCTAssertFalse(source.contains("PluginManager.shared"))
            XCTAssertFalse(source.contains("SnackBarManager.shared"))
        }
        XCTAssertTrue(detail.contains("@StateObject private var viewModel"))
        XCTAssertTrue(detailViewModel.contains("let sourceResolver: SourceResolverViewModel"))
    }

    func test44DiscoverNavigationUsesAppViewFactory() throws {
        let source = try sourceFile("Ito/Views/Discover/DiscoverView.swift")
        XCTAssertTrue(source.contains("viewFactory.makeDiscoverDetailView(media: media)"))
        XCTAssertFalse(source.contains("@EnvironmentObject private var pluginManager"))
        XCTAssertFalse(source.contains("AppRouter"))
    }

    private func viewModelWithSuspendedSecondPage() async -> (DiscoverViewModel, DiscoverServiceFake) {
        let service = DiscoverServiceFake(); service.searchResult = .init(media: [.media(1)], hasNextPage: true)
        let viewModel = makeViewModel(service: service, debounce: nil); viewModel.searchQuery = "q"; await waitUntil { viewModel.searchResults.count == 1 }
        service.searchSuspended = true; viewModel.loadNextPage(); await waitUntil { service.searchRequests.count == 2 }
        return (viewModel, service)
    }
}

@MainActor
private let primarySections: [DiscoverHomeSection] = [.trending, .popular, .topRated]

@MainActor
private func makeViewModel(service: DiscoverServiceFake = DiscoverServiceFake(), cache: any DiscoverCaching = InMemoryDiscoverCache(), clock: TestDiscoverClock = TestDiscoverClock(), debounce: Int? = nil) -> DiscoverViewModel {
    DiscoverViewModel(service: service, cache: cache, clock: clock, debounceMilliseconds: debounce, calendar: Calendar(identifier: .gregorian))
}

@MainActor
private final class DiscoverServiceFake: DiscoverHomeFilterServing {
    var homeRequests: [DiscoverHomeSectionRequest] = []
    var searchRequests: [DiscoverSearchRequest] = []
    var homeResults: [DiscoverHomeSection: [DiscoverMedia]] = [:]
    var homeErrors: [DiscoverHomeSection: Error] = [:]
    var searchResult = DiscoverPageResult(media: [], hasNextPage: false)
    var searchResponses: [Result<DiscoverPageResult, Error>] = []
    var genresResult: Result<[String], Error> = .success([])
    var tagsResult: Result<[DiscoverTag], Error> = .success([])
    private(set) var genreRequests = 0
    private(set) var tagRequests = 0
    var homeSuspended: Bool
    var searchSuspended: Bool
    private var homeContinuations: [(DiscoverHomeSectionRequest, CheckedContinuation<[DiscoverMedia], Error>)] = []
    private var searchContinuations: [(DiscoverSearchRequest, CheckedContinuation<DiscoverPageResult, Error>)] = []

    init(homeSuspended: Bool = false, searchSuspended: Bool = false) { self.homeSuspended = homeSuspended; self.searchSuspended = searchSuspended }

    func loadHomeSection(_ request: DiscoverHomeSectionRequest) async throws -> [DiscoverMedia] {
        homeRequests.append(request)
        if homeSuspended { return try await withCheckedThrowingContinuation { homeContinuations.append((request, $0)) } }
        if let error = homeErrors[request.section] { throw error }
        return homeResults[request.section] ?? []
    }

    func search(_ request: DiscoverSearchRequest) async throws -> DiscoverPageResult {
        searchRequests.append(request)
        if searchSuspended { return try await withCheckedThrowingContinuation { searchContinuations.append((request, $0)) } }
        if !searchResponses.isEmpty { return try searchResponses.removeFirst().get() }
        return searchResult
    }

    func loadGenres() async throws -> [String] { genreRequests += 1; return try genresResult.get() }
    func loadTags() async throws -> [DiscoverTag] { tagRequests += 1; return try tagsResult.get() }

    func completeAllHome() { let pending = homeContinuations; homeContinuations.removeAll(); pending.forEach { $0.1.resume(returning: homeResults[$0.0.section] ?? []) } }
    func completeHome(mediaType: DiscoverMediaType, media: [DiscoverMedia]) { resumeHome { $0.mediaType == mediaType } result: { _ in media } }
    private func resumeHome(where predicate: (DiscoverHomeSectionRequest) -> Bool, result: (DiscoverHomeSectionRequest) -> [DiscoverMedia]) { let matching = homeContinuations.filter { predicate($0.0) }; homeContinuations.removeAll { predicate($0.0) }; matching.forEach { $0.1.resume(returning: result($0.0)) } }
    func completeSearch(query: String? = nil, filterGenre: String? = nil, page: Int? = nil, media: [DiscoverMedia], hasNextPage: Bool = false) { resumeSearch(query: query, filterGenre: filterGenre, page: page, result: .success(.init(media: media, hasNextPage: hasNextPage))) }
    func failSearch(query: String, error: Error) { resumeSearch(query: query, result: .failure(error)) }
    private func resumeSearch(query: String? = nil, filterGenre: String? = nil, page: Int? = nil, result: Result<DiscoverPageResult, Error>) {
        guard let index = searchContinuations.firstIndex(where: { item in (query == nil || item.0.query == query) && (filterGenre == nil || item.0.filters.genres.contains(filterGenre!)) && (page == nil || item.0.page == page) }) else { return }
        let continuation = searchContinuations.remove(at: index).1
        continuation.resume(with: result)
    }
}

@MainActor
private final class TestDiscoverClock: DiscoverClock {
    var now: Date
    private(set) var sleepRequests: [Int] = []
    private struct Sleeper { let deadline: Date; let continuation: CheckedContinuation<Void, Error> }
    private var sleepers: [UUID: Sleeper] = [:]
    init(now: Date = Date(timeIntervalSince1970: 1_000)) { self.now = now }
    func sleep(milliseconds: Int) async throws {
        sleepRequests.append(milliseconds)
        let id = UUID(); let deadline = now.addingTimeInterval(Double(milliseconds) / 1_000)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { sleepers[id] = Sleeper(deadline: deadline, continuation: $0) }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel(id) } })
    }
    func advance(milliseconds: Int) { advance(seconds: Double(milliseconds) / 1_000) }
    func advance(seconds: TimeInterval) { now.addTimeInterval(seconds); let ready = sleepers.filter { $0.value.deadline <= now }; ready.keys.forEach { sleepers.removeValue(forKey: $0)?.continuation.resume() } }
    private func cancel(_ id: UUID) { sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
}

private enum TestError: LocalizedError { case failed; var errorDescription: String? { "test failure" } }

private extension DiscoverMedia {
    static func media(_ id: Int) -> DiscoverMedia { DiscoverMedia(id: id, title: "Media \(id)", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [], coverImage: nil, bannerImage: nil, format: nil, status: nil, description: nil, cleanDescription: nil, genres: nil, averageScore: nil, episodes: nil, chapters: nil, season: nil, seasonYear: nil, type: "MANGA", recommendations: nil) }
}

private extension DiscoverTag {
    static func tag(_ id: Int, adult: Bool? = nil) -> DiscoverTag { DiscoverTag(id: id, name: "Tag \(id)", description: nil, category: nil, isAdult: adult) }
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<2_000 { if condition() { return }; await Task.yield() }
    XCTFail("Condition was not met", file: file, line: line)
}

private func sourceFile(_ relativePath: String) throws -> String { try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8) }
private func repositoryRoot() -> URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
@MainActor
private func makeScope(service: DiscoverServiceFake = DiscoverServiceFake(), cache: any DiscoverCaching = InMemoryDiscoverCache(), clock: TestDiscoverClock = TestDiscoverClock()) -> AppScope {
    AppScope(preparedDependencies: PreparedApplicationDependencies(settings: makeTestPreparedSettingsDependencies(), searchExecutor: DiscoverTestSearchExecutor(), recentSearchStore: DiscoverTestRecentStore(), searchDebounceMilliseconds: nil, presentationLogger: DiscoverTestLogger(), browseRepositoryManager: DiscoverTestRepositoryManager(), repositoryManagement: makeTestRepositoryManagementDependencies(), browsePluginManager: DiscoverTestPluginManager(), browseFileOperations: DiscoverTestFileOperations(), discoverService: service, discoverCache: cache, discoverClock: clock, discoverDebounceMilliseconds: nil))
}

@MainActor private final class DiscoverTestSearchExecutor: SearchPluginExecuting { var plugins: [SearchPluginDescriptor] = []; func search(plugin: SearchPluginDescriptor, query: String, limit: Int) async throws -> [PluginSearchResult] { [] }; func evictRunner(for pluginID: String) {} }
@MainActor private struct DiscoverTestRecentStore: RecentSearchPersisting { func load() -> [String] { [] }; func save(_ searches: [String]) {}; func clear() {} }
private final class DiscoverTestLogger: PresentationEventLogging { func log(_ event: PresentationLogEvent) {} }
@MainActor private final class DiscoverTestPluginManager: BrowsePluginManaging { var installedPlugins: [String: InstalledPlugin] = [:]; var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> { Just([:]).eraseToAnyPublisher() }; func reloadInstalledPlugins() async {}; func holdCompletionDelivery(for pluginID: String) async throws {}; func purgeCompletionDelivery(for pluginID: String) async {}; func removeSecrets(for pluginID: String) {} }
@MainActor private final class DiscoverTestRepositoryManager: BrowseRepositoryManaging {
    var repositories: [Repository] = []
    var repositoriesPublisher: AnyPublisher<[Repository], Never> {
        Just([]).eraseToAnyPublisher()
    }
    func addRepository(url: String) async throws -> RepositoryAdditionResult {
        _ = url
        return .alreadyPresent
    }
    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws {
        _ = package
        _ = repositoryURL
    }
    func refreshAll() async {}
}
@MainActor private final class DiscoverTestFileOperations: BrowsePluginFileOperating { func supportsPluginFile(at url: URL) -> Bool { false }; func installPluginFile(from url: URL) throws {}; func deletePluginFile(at url: URL) throws {} }
