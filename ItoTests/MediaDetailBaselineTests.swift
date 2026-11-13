import XCTest
import ito_runner
@testable import Ito

/// When opening a saved series moves its update baseline (the known chapter count) and clears
/// its new-chapter badge.
extension MediaDetailViewModelTests {
    func testBaselineRunsOnlyForSavedLoadedMediaAndDeduplicatesRecomputation() async {
        let unsaved = makeMangaSubject(media: manga(chapters: [chapter("c1", 1)]))
        unsaved.viewModel.start()
        await waitUntil { unsaved.viewModel.detailLoadState == .content }
        XCTAssertTrue(unsaved.baseline.requests.isEmpty)

        let saved = makeMangaSubject(media: manga(chapters: [chapter("c1", 1), chapter("c2", 2)]), saved: true)
        saved.viewModel.start()
        saved.viewModel.start()
        await waitUntil { saved.baseline.requests.count == 1 }
        XCTAssertEqual(saved.baseline.requests.first?.media, saved.viewModel.mediaIdentity)
        XCTAssertEqual(saved.baseline.requests.first?.knownChapterCount, 2)
        saved.viewModel.appear()
        saved.viewModel.appear()
        await Task.yield()
        XCTAssertEqual(saved.baseline.requests.count, 1)
    }

    func testBaselineFailureDoesNotCorruptDetailState() async {
        let subject = makeMangaSubject(media: manga(chapters: [chapter("c1", 1)]), saved: true)
        subject.baseline.error = MediaDetailTestFailure.expected
        subject.viewModel.start()
        await waitUntil { subject.baseline.requests.count == 1 }
        await Task.yield()
        XCTAssertEqual(subject.viewModel.detailLoadState, .content)
        XCTAssertTrue(subject.messages.messages.isEmpty)
    }

    /// The saved chapter list is older than the update check's count; a failed load must not
    /// replace that count with it or clear the badge for chapters the user has not seen.
    func testFailedLoadLeavesTheUpdateBaselineAlone() async {
        let subject = makeMangaSubject(media: manga(chapters: [chapter("c1", 1), chapter("c2", 2)]), saved: true)
        subject.route.loadResponses = [
            .failure,
            .value(manga(chapters: [chapter("c1", 1), chapter("c2", 2), chapter("c3", 3)]))
        ]
        subject.viewModel.start()
        await waitUntil {
            if case .failure = subject.viewModel.detailLoadState { return true }
            return false
        }

        subject.viewModel.retryDetailLoad()
        await waitUntil { !subject.baseline.requests.isEmpty }
        XCTAssertEqual(subject.baseline.requests.map(\.knownChapterCount), [3])
    }

    /// A source can answer a refused request with no chapters; that list is not a new baseline.
    func testEmptyChapterListDoesNotAdvanceTheBaseline() async {
        let subject = makeMangaSubject(media: manga(chapters: [chapter("c1", 1)]), saved: true)
        subject.route.loadResponses = [
            .value(manga(chapters: [])),
            .value(manga(chapters: [chapter("c1", 1), chapter("c2", 2)]))
        ]
        subject.viewModel.start()
        await waitUntil { subject.viewModel.detailLoadState == .content }

        subject.viewModel.retryDetailLoad()
        await waitUntil { !subject.baseline.requests.isEmpty }
        XCTAssertEqual(subject.baseline.requests.map(\.knownChapterCount), [2])
    }

    func testPostRelinkBaselineUsesCurrentIdentityAndCount() async {
        let selected = manga(key: "m2", title: "Selected", chapters: [chapter("c1", 1), chapter("c2", 2)])
        let subject = makeMangaSubject(saved: true)
        subject.route.searchResponses = [.value([selected])]
        subject.route.loadResponses = [.value(selected)]
        subject.library.stateOnRefresh = MediaDetailLibraryState(
            records: [MediaDetailLibraryRecord(itemID: "m2", pluginID: Self.pluginID, mediaKind: .manga)],
            hasCustomCategories: false
        )
        subject.viewModel.openRelink()
        await waitUntil { subject.viewModel.relinkSearchState == .results }
        await subject.viewModel.performRelink(with: selected)
        let relinked = MediaIdentity(pluginId: Self.pluginID, itemId: "m2", mediaKind: .manga)
        await waitUntil { subject.baseline.requests.contains { $0.media == relinked } }

        let current = subject.baseline.requests.last
        XCTAssertEqual(current?.media, relinked)
        XCTAssertEqual(current?.knownChapterCount, 2)
    }

    func testDetailAcknowledgesEveryExactEditionWithEqualNumbers() async {
        let subject = makeMangaSubject(media: manga(chapters: [
            Chapter(key: "a", chapter: 1, scanlator: "A"),
            Chapter(key: "b", chapter: 1, scanlator: "B"),
            Chapter(key: "split", chapter: 1, scanlator: "B"),
            Chapter(key: "split", chapter: 1, scanlator: "B")
        ]), saved: true)
        let acknowledged = expectation(description: "Exact catalog acknowledged")
        subject.baseline.onAdvance = { acknowledged.fulfill() }
        subject.viewModel.start()
        await fulfillment(of: [acknowledged])
        XCTAssertEqual(subject.baseline.requests.map(\.knownChapterCount), [3])
    }

    func testStaleCatalogCannotAcknowledgeEditionsOrClearCurrentLoading() async {
        let subject = makeMangaSubject(saved: true)
        subject.route.loadResponses = [.suspended, .suspended]
        let oldPending = expectation(description: "Old load suspended")
        subject.route.onLoadSuspended = { oldPending.fulfill() }
        let old = Task { await subject.viewModel.refresh() }
        await fulfillment(of: [oldPending])
        let currentPending = expectation(description: "Current load suspended")
        subject.route.onLoadSuspended = { currentPending.fulfill() }
        let current = Task { await subject.viewModel.refresh() }
        await fulfillment(of: [currentPending])

        subject.route.resolveLoad(at: 0, with: .success(manga(chapters: [chapter("old", 1)])))
        await old.value
        XCTAssertTrue(subject.baseline.requests.isEmpty)
        XCTAssertEqual(subject.viewModel.detailLoadState, .loading)
        let acknowledged = expectation(description: "Current load acknowledged")
        subject.baseline.onAdvance = { acknowledged.fulfill() }
        subject.route.resolveLoad(at: 0, with: .success(manga(chapters: [
            chapter("a", 1), chapter("b", 1)
        ])))
        await current.value
        // Manual refresh deliberately does not acknowledge update badges. A current detail
        // retry does; keep that distinction while proving stale loads never acknowledge anything.
        XCTAssertTrue(subject.baseline.requests.isEmpty)
        subject.viewModel.retryDetailLoad()
        await fulfillment(of: [acknowledged])
        XCTAssertEqual(subject.baseline.requests.map(\.knownChapterCount), [2])
    }

    func testDismissedCatalogCannotAcknowledgeEditions() async {
        let subject = makeMangaSubject(saved: true)
        subject.viewModel.appear()
        subject.route.loadResponses = [.suspended]
        let pending = expectation(description: "Load suspended")
        subject.route.onLoadSuspended = { pending.fulfill() }
        let load = Task { await subject.viewModel.refresh() }
        await fulfillment(of: [pending])
        subject.viewModel.disappear()
        subject.route.resolveLoad(at: 0, with: .success(manga(chapters: [chapter("a", 1)])))
        await load.value
        XCTAssertTrue(subject.baseline.requests.isEmpty)
        XCTAssertEqual(subject.viewModel.detailLoadState, .idle)
    }
}
