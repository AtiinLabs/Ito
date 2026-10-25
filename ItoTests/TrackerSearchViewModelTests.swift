import XCTest
import ito_runner
@testable import Ito

@MainActor
final class TrackerSearchViewModelTests: XCTestCase {
    func testInitialSearchRunsOnceWithExactProviderMediaTypeAndQuery() async {
        let service = TrackerSearchServiceFake()
        service.suspendsSearches = true
        let viewModel = makeViewModel(title: "Initial", isAnime: true, service: service)

        XCTAssertEqual(viewModel.searchQuery, "Initial")
        XCTAssertEqual(viewModel.state, .idle)
        viewModel.start()
        viewModel.start()
        await trackingWaitUntil { service.pendingCount == 1 }

        XCTAssertEqual(
            service.invocations,
            [.init(providerID: "anilist", title: "Initial", isAnime: true)]
        )
        XCTAssertEqual(viewModel.state, .loading)
        service.complete(with: .success([]))
        await trackingWaitUntil { viewModel.state == .empty }
    }

    func testManualSearchSuccessExactSelectionAndEmptyQueryNoOp() async {
        let exact = trackerTestMedia(id: "exact", title: "New Query")
        let other = trackerTestMedia(id: "other", title: "Other")
        let service = TrackerSearchServiceFake()
        service.queuedResults = [.success([exact, other])]
        let viewModel = makeViewModel(service: service)
        viewModel.searchQuery = "New Query"

        viewModel.performSearch()
        await trackingWaitUntil { viewModel.state == .content }

        XCTAssertEqual(viewModel.results, [exact, other])
        XCTAssertEqual(viewModel.selectedMedia, exact)
        XCTAssertEqual(service.invocations.last?.title, "New Query")

        viewModel.searchQuery = ""
        viewModel.performSearch()
        XCTAssertEqual(service.invocations.count, 1)
        XCTAssertEqual(viewModel.state, .content)
        XCTAssertEqual(viewModel.results, [exact, other])
        XCTAssertEqual(viewModel.selectedMedia, exact)
    }

    func testFailureIsVisibleAndRetryableWithoutStaleSelection() async {
        let service = TrackerSearchServiceFake()
        service.queuedResults = [
            .failure(TrackingTestError.failure),
            .success([trackerTestMedia(title: "Query")])
        ]
        let viewModel = makeViewModel(title: "Query", service: service)

        viewModel.performSearch()
        await trackingWaitUntil { viewModel.state == .failure }
        XCTAssertEqual(viewModel.errorMessage, "Search failed. Please try again.")
        XCTAssertNil(viewModel.selectedMedia)

        viewModel.retry()
        await trackingWaitUntil { viewModel.state == .content }
        XCTAssertEqual(viewModel.selectedMedia?.title, "Query")
        XCTAssertEqual(service.invocations.count, 2)
    }

    func testNonExactResultNeedsExplicitSelectionAndProducesTypedDestination() async {
        let first = trackerTestMedia(id: "one", title: "Different")
        let second = trackerTestMedia(id: "two", title: "Another")
        let service = TrackerSearchServiceFake()
        service.queuedResults = [.success([first, second])]
        let viewModel = makeViewModel(title: "Requested", service: service)

        viewModel.performSearch()
        await trackingWaitUntil { viewModel.state == .content }
        XCTAssertNil(viewModel.selectedMedia)
        XCTAssertNil(viewModel.destination)

        viewModel.select(mediaID: second.id)
        viewModel.presentSelectedDetails()

        XCTAssertEqual(viewModel.selectedMedia, second)
        XCTAssertEqual(
            viewModel.destination,
            TrackerDetailsDestination(
                providerID: "anilist",
                providerName: "AniList",
                mediaIdentity: mediaIdentity,
                media: second,
                showCancelButton: false,
                isLocallyLinked: false
            )
        )
        XCTAssertTrue(viewModel.isPresentingDetails)

        viewModel.navigationBindingDidSet(false)
        XCTAssertNil(viewModel.destination)
        viewModel.select(mediaID: first.id)
        viewModel.presentSelectedDetails()
        XCTAssertEqual(viewModel.destination?.media.id, first.id)
    }

    func testNewerQuerySuppressesOlderSuccessAndCannotLoseNewLoadingState() async {
        let service = TrackerSearchServiceFake()
        service.suspendsSearches = true
        let viewModel = makeViewModel(title: "Old", service: service)

        viewModel.performSearch()
        await trackingWaitUntil { service.pendingCount == 1 }
        viewModel.searchQuery = "New"
        viewModel.performSearch()
        await trackingWaitUntil { service.pendingCount == 2 }

        service.complete(at: 0, with: .success([trackerTestMedia(id: "old", title: "Old")]))
        await Task.yield()
        XCTAssertEqual(viewModel.state, .loading)
        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertNil(viewModel.selectedMedia)

        let newest = trackerTestMedia(id: "new", title: "New")
        service.complete(with: .success([newest]))
        await trackingWaitUntil { viewModel.state == .content }
        XCTAssertEqual(viewModel.results, [newest])
        XCTAssertEqual(viewModel.selectedMedia, newest)
    }

    func testRapidDuplicateSearchesPublishOnlyLatestOperation() async {
        let service = TrackerSearchServiceFake()
        service.suspendsSearches = true
        let viewModel = makeViewModel(title: "Same", service: service)

        viewModel.performSearch()
        await trackingWaitUntil { service.pendingCount == 1 }
        viewModel.performSearch()
        await trackingWaitUntil { service.pendingCount == 2 }

        let stale = trackerTestMedia(id: "stale", title: "Same")
        let current = trackerTestMedia(id: "current", title: "Same")
        service.complete(at: 0, with: .success([stale]))
        await Task.yield()
        XCTAssertEqual(viewModel.state, .loading)
        XCTAssertTrue(viewModel.results.isEmpty)

        service.complete(with: .success([current]))
        await trackingWaitUntil { viewModel.state == .content }
        XCTAssertEqual(viewModel.results, [current])
        XCTAssertEqual(viewModel.selectedMedia, current)
    }

    func testNewSearchImmediatelyInvalidatesPriorRowsAndNavigation() async {
        let old = trackerTestMedia(id: "old", title: "Old")
        let service = TrackerSearchServiceFake()
        service.queuedResults = [.success([old])]
        let viewModel = makeViewModel(title: "Old", service: service)

        viewModel.performSearch()
        await trackingWaitUntil { viewModel.state == .content }
        XCTAssertEqual(viewModel.selectedMedia, old)

        service.suspendsSearches = true
        viewModel.searchQuery = "New"
        viewModel.performSearch()
        await trackingWaitUntil { service.pendingCount == 1 }

        XCTAssertEqual(viewModel.state, .loading)
        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertNil(viewModel.selectedMedia)
        viewModel.select(mediaID: old.id)
        viewModel.presentSelectedDetails()
        XCTAssertNil(viewModel.destination)
        XCTAssertFalse(viewModel.isPresentingDetails)

        service.complete(with: .failure(TrackingTestError.failure))
        await trackingWaitUntil { viewModel.state == .failure }
        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertNil(viewModel.destination)
    }

    func testStaleFailureCannotReplaceNewerSuccessfulContent() async {
        let service = TrackerSearchServiceFake()
        service.suspendsSearches = true
        let viewModel = makeViewModel(title: "Old", service: service)

        viewModel.performSearch()
        await trackingWaitUntil { service.pendingCount == 1 }
        viewModel.searchQuery = "New"
        viewModel.performSearch()
        await trackingWaitUntil { service.pendingCount == 2 }

        let newest = trackerTestMedia(id: "new", title: "New")
        service.complete(at: 1, with: .success([newest]))
        await trackingWaitUntil { viewModel.state == .content }
        service.complete(with: .failure(TrackingTestError.failure))
        await Task.yield()

        XCTAssertEqual(viewModel.state, .content)
        XCTAssertEqual(viewModel.results, [newest])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCancellationInvalidatesNonCooperativeCompletion() async {
        let service = TrackerSearchServiceFake()
        service.suspendsSearches = true
        let viewModel = makeViewModel(service: service)

        viewModel.performSearch()
        await trackingWaitUntil { service.pendingCount == 1 }
        viewModel.cancelOwnedWork()
        XCTAssertEqual(viewModel.state, .idle)

        service.complete(with: .success([trackerTestMedia()]))
        await Task.yield()
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertNil(viewModel.destination)
    }

    func testPresentationLogsContainNoRawQueryOrResultPayload() async {
        let service = TrackerSearchServiceFake()
        service.queuedResults = [.failure(TrackingTestError.secret("provider-payload-secret"))]
        let logger = PresentationEventCaptureSpy()
        let viewModel = makeViewModel(title: "private-search-title", service: service, logger: logger)

        viewModel.performSearch()
        await trackingWaitUntil { viewModel.state == .failure }
        let output = logger.formattedMessages.joined(separator: "\n")

        XCTAssertFalse(output.contains("private-search-title"))
        XCTAssertFalse(output.contains("provider-payload-secret"))
        XCTAssertFalse(output.contains("anilist"))
    }

    private var mediaIdentity: MediaIdentity {
        MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "media.test", mediaKind: .manga)
    }

    private func makeViewModel(
        title: String = "Initial",
        isAnime: Bool = false,
        service: TrackerSearchServiceFake = TrackerSearchServiceFake(),
        logger: PresentationEventCaptureSpy = PresentationEventCaptureSpy(),
        providerID: String = "anilist",
        providerName: String = "AniList"
    ) -> TrackerSearchViewModel {
        TrackerSearchViewModel(
            providerID: providerID,
            providerName: providerName,
            mediaIdentity: mediaIdentity,
            title: title,
            isAnime: isAnime,
            searchService: service,
            presentationLogger: logger
        )
    }

    func testMyAnimeListShortQueryShowsHintAndNeverSearches() async {
        let service = TrackerSearchServiceFake()
        let viewModel = makeViewModel(title: "86", service: service, providerID: "myanimelist", providerName: "MyAnimeList")

        viewModel.start()
        XCTAssertEqual(viewModel.queryHint, "Enter at least 3 characters to search MyAnimeList.")
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertTrue(service.invocations.isEmpty)

        viewModel.searchQuery = "86 eighty"
        XCTAssertNil(viewModel.queryHint)
        viewModel.performSearch()
        await trackingWaitUntil { service.invocations.count == 1 }
        XCTAssertEqual(service.invocations, [.init(providerID: "myanimelist", title: "86 eighty", isAnime: false)])
    }
}
