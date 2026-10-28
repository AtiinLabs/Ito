import Combine
import Foundation
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class OptionCatalogModelTests: XCTestCase {
    func testPagesAppendDeduplicatedAndOnlyOneAppendRuns() async {
        let context = CatalogContext()
        context.pageHandler = { request in
            if case .search(_, 0) = request.query { return self.page(["a"], next: 1) }
            return await context.suspendPage()
        }
        let model = makeModel(context)
        model.appear()
        await model.requestTask?.value
        model.loadMore()
        let append = model.requestTask
        model.loadMore()
        model.retry()
        await context.waitForPendingRequest()
        XCTAssertEqual(context.requests.count, 2)
        context.pending?.resume(returning: page(["a", "b"]))
        await append?.value
        assertItems(model, ["a", "b"])
    }

    func testQueryGenerationDropsStalePageResponse() async {
        let context = CatalogContext()
        context.pageHandler = { request in
            if case .search("old", 0) = request.query {
                return await context.suspendPage()
            }
            return self.page(["new"])
        }
        let model = makeModel(context)
        model.textChanged("old")
        await context.waitForPendingRequest()
        let oldTask = model.requestTask
        model.textChanged("new")
        await context.waitForRequests(2)
        await model.requestTask?.value
        context.pending?.resume(returning: page(["old"]))
        await oldTask?.value
        assertItems(model, ["new"])
    }

    func testDisappearDropsNonCooperativePageAndReopensLazily() async {
        let context = CatalogContext()
        context.pageHandler = { _ in await context.suspendPage() }
        let model = makeModel(context)
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(context.requests.isEmpty)
        model.appear()
        await context.waitForPendingRequest()
        let oldTask = model.requestTask
        model.disappear()
        context.pending?.resume(returning: page(["stale"]))
        await oldTask?.value
        XCTAssertEqual(model.state, .idle)
        context.pageHandler = { _ in self.page(["fresh"]) }
        model.appear()
        await model.requestTask?.value
        assertItems(model, ["fresh"])
    }

    func testNilAndThrownPagesFailAndRetryWithoutChangingSelection() async {
        let context = CatalogContext()
        context.pageHandler = { _ in nil }
        let model = makeModel(context)
        model.appear()
        await model.requestTask?.value
        XCTAssertEqual(model.state, .failed("Options could not be loaded."))
        context.pageHandler = { _ in throw CatalogFailure.failed }
        model.retry()
        await model.requestTask?.value
        XCTAssertEqual(model.state, .failed("Options could not be loaded."))
        context.pageHandler = { _ in self.page([]) }
        model.retry()
        await model.requestTask?.value
        XCTAssertEqual(model.state, .empty)
    }

    func testAppendFailureKeepsItemsAndRetriesSameOffset() async {
        let context = CatalogContext()
        context.pageHandler = { request in
            if case .search(_, 0) = request.query { return self.page(["a"], next: 5) }
            throw CatalogFailure.failed
        }
        let model = makeModel(context)
        model.appear()
        await model.requestTask?.value
        model.loadMore()
        await model.requestTask?.value
        if case let .loaded(items, next, _, _, _, loading, error) = model.state {
            XCTAssertEqual(items.map(\.value), ["a"])
            XCTAssertEqual(next, 5)
            XCTAssertFalse(loading)
            XCTAssertNotNil(error)
        } else { XCTFail("Expected retained first page") }
        context.pageHandler = { request in
            XCTAssertEqual(request.query, .search(text: "", offset: 5))
            return self.page(["b"])
        }
        model.retry()
        await model.requestTask?.value
        assertItems(model, ["a", "b"])
    }

    func testRevisionChangeRestartsRatherThanAppending() async {
        let context = CatalogContext()
        var firstPageCount = 0
        context.pageHandler = { request in
            if case .search(_, 0) = request.query {
                firstPageCount += 1
                return self.page([firstPageCount == 1 ? "old" : "fresh"], next: 1, revision: firstPageCount == 1 ? "r1" : "r2")
            }
            return self.page(["moved"], revision: "r2")
        }
        let model = makeModel(context)
        model.appear()
        await model.requestTask?.value
        model.loadMore()
        await context.waitForRequests(3)
        await model.requestTask?.value
        assertItems(model, ["fresh"])
    }

    func testRunnerChangeRestartsAndCachesRemainIdentityScoped() async {
        let first = CatalogContext()
        let second = CatalogContext()
        first.pageHandler = { _ in self.page(["old"], next: 1) }
        second.pageHandler = { request in
            if case .search(_, 0) = request.query { return self.page(["fresh"]) }
            if case .values = request.query { return self.page(["value"]) }
            return self.page(["wrong-append"])
        }
        let provider = CatalogRunnerProvider(context: first)
        let model = makeModel(provider: provider)
        model.appear()
        await model.requestTask?.value
        let oldLabel = await model.resolve(values: ["value"])
        XCTAssertTrue(oldLabel.unavailable.contains(Data("value".utf8)))
        provider.context = second
        model.loadMore()
        await second.waitForRequests(2)
        await model.requestTask?.value
        assertItems(model, ["fresh"])
        let currentLabel = await model.resolve(values: ["value"])
        XCTAssertEqual(currentLabel.labels[Data("value".utf8)], "Label value")
        XCTAssertTrue(currentLabel.unavailable.isEmpty)
    }

    func testTenThousandCapEndsPaging() async {
        let context = CatalogContext()
        context.pageHandler = { _ in self.page((0..<10_001).map(String.init), next: 10_001) }
        let model = makeModel(context)
        model.appear()
        await model.requestTask?.value
        if case let .loaded(items, next, _, _, _, _, _) = model.state {
            XCTAssertEqual(items.count, 10_000)
            XCTAssertNil(next)
        } else { XCTFail("Expected capped list") }
        model.loadMore()
        XCTAssertEqual(context.requests.count, 1)
    }

    func testLabelsOmittedOnlyBySuccessRemainUnavailableInCache() async {
        let context = CatalogContext()
        context.pageHandler = { _ in self.page(["known"]) }
        let model = makeModel(context)
        let first = await model.resolve(values: ["known", "missing"])
        XCTAssertEqual(first.labels[Data("known".utf8)], "Label known")
        XCTAssertEqual(first.unavailable, [Data("missing".utf8)])
        let cached = await model.resolve(values: ["missing", "known"])
        XCTAssertEqual(cached.unavailable, [Data("missing".utf8)])
        XCTAssertEqual(cached.labels, first.labels)
        XCTAssertEqual(context.requests.count, 1)
        XCTAssertEqual(model.state, .idle, "Label resolution must not open the catalog list")
    }

    func testNilAndFailedLabelRequestsReportRetryAndDoNotCacheMissing() async {
        let context = CatalogContext()
        let model = makeModel(context)
        context.pageHandler = { _ in nil }
        let absent = await model.resolve(values: ["selected"])
        XCTAssertNotNil(absent.error)
        XCTAssertTrue(absent.unavailable.isEmpty)
        context.pageHandler = { _ in throw CatalogFailure.failed }
        let failed = await model.resolve(values: ["selected"])
        XCTAssertNotNil(failed.error)
        XCTAssertTrue(failed.unavailable.isEmpty)
        context.pageHandler = { _ in self.page(["selected"]) }
        let retried = await model.resolve(values: ["selected"])
        XCTAssertNil(retried.error)
        XCTAssertEqual(retried.labels[Data("selected".utf8)], "Label selected")
        XCTAssertEqual(context.requests.count, 3)
    }

    func testStaleLabelResponseCannotPoisonCache() async {
        let context = CatalogContext()
        context.pageHandler = { _ in await context.suspendPage() }
        let model = makeModel(context)
        let old = Task { await model.resolve(values: ["value"]) }
        await context.waitForPendingRequest()
        context.pageHandler = { _ in self.page(["value"]) }
        let fresh = await model.resolve(values: ["value"])
        XCTAssertEqual(fresh.labels[Data("value".utf8)], "Label value")
        context.pending?.resume(returning: page([]))
        let stale = await old.value
        XCTAssertTrue(stale.labels.isEmpty)
        XCTAssertTrue(stale.unavailable.isEmpty)
        let cached = await model.resolve(values: ["value"])
        XCTAssertEqual(cached.labels[Data("value".utf8)], "Label value")
        XCTAssertTrue(cached.unavailable.isEmpty)
        XCTAssertEqual(context.requests.count, 2)
    }

    func testDisappearedLabelResponseCannotMutateCache() async {
        let context = CatalogContext()
        context.pageHandler = { _ in await context.suspendPage() }
        let model = makeModel(context)
        let task = Task { await model.resolve(values: ["value"]) }
        await context.waitForPendingRequest()
        model.disappear()
        context.pending?.resume(returning: page([]))
        let stale = await task.value
        XCTAssertTrue(stale.unavailable.isEmpty)
        context.pageHandler = { _ in self.page(["value"]) }
        let fresh = await model.resolve(values: ["value"])
        XCTAssertEqual(fresh.labels[Data("value".utf8)], "Label value")
        XCTAssertEqual(context.requests.count, 2)
    }

    func testLabelRequestsBatchInSelectionOrder() async {
        let context = CatalogContext()
        context.pageHandler = { request in
            guard case .values(let values) = request.query else { return nil }
            XCTAssertEqual(request.limit, UInt32(values.count))
            return self.page(values)
        }
        let values = (0..<205).map(String.init)
        let result = await makeModel(context).resolve(values: values)
        XCTAssertEqual(result.labels.count, 205)
        XCTAssertEqual(context.requests.map(\.limit), [100, 100, 5])
        let batches = context.requests.flatMap { request -> [String] in
            if case .values(let values) = request.query { return values }; return []
        }
        XCTAssertEqual(batches, values)
    }

    func testSummaryAndPickerLabelConsumersDoNotSupersedeOneAnother() async {
        let context = CatalogContext()
        context.pageHandler = { _ in await context.suspendPage() }
        let model = makeModel(context)
        let summary = UUID()
        let picker = UUID()
        let pending = Task { await model.resolve(values: ["summary"], consumer: summary) }
        await context.waitForPendingRequest()
        context.pageHandler = { _ in self.page(["picker"]) }
        let pickerResult = await model.resolve(values: ["picker"], consumer: picker)
        context.pending?.resume(returning: page(["summary"]))
        let summaryResult = await pending.value
        XCTAssertEqual(summaryResult.labels[Data("summary".utf8)], "Label summary")
        XCTAssertEqual(pickerResult.labels[Data("picker".utf8)], "Label picker")
    }

    func testPagesPreserveByteDistinctUnicodeOptionsAndDeduplicateExactRepeats() async {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let context = CatalogContext()
        context.pageHandler = { request in
            if case .search(_, 0) = request.query {
                return self.page([composed, composed], next: 2)
            }
            return self.page([composed, decomposed, decomposed])
        }
        let model = makeModel(context)
        model.appear()
        await model.requestTask?.value
        assertItems(model, [composed])
        model.loadMore()
        await model.requestTask?.value
        assertItems(model, [composed, decomposed])
    }

    func testUnicodeLabelsAndCachesUseExactOptionBytes() async {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let context = CatalogContext()
        context.pageHandler = { _ in
            OptionPage(options: [
                ChoiceOption(value: composed, label: "Composed", group: nil),
                ChoiceOption(value: decomposed, label: "Decomposed", group: nil)
            ], nextOffset: nil, total: nil, revision: nil)
        }
        let model = makeModel(context)
        let result = await model.resolve(values: [composed, decomposed])
        XCTAssertEqual(result.labels, [
            Data(composed.utf8): "Composed",
            Data(decomposed.utf8): "Decomposed"
        ])
        XCTAssertTrue(result.unavailable.isEmpty)
        let cached = await model.resolve(values: [decomposed, composed])
        XCTAssertEqual(cached, result)
        XCTAssertEqual(context.requests.count, 1)
    }

    func testWrongUnicodeFormCannotResolveOrPoisonAnotherValuesCache() async {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let context = CatalogContext()
        context.pageHandler = { _ in self.page([decomposed]) }
        let model = makeModel(context)
        let wrongForm = await model.resolve(values: [composed])
        XCTAssertTrue(wrongForm.labels.isEmpty)
        XCTAssertEqual(wrongForm.unavailable, [Data(composed.utf8)])
        let exactForm = await model.resolve(values: [decomposed])
        XCTAssertEqual(exactForm.labels[Data(decomposed.utf8)], "Label \(decomposed)")
        XCTAssertTrue(exactForm.unavailable.isEmpty)
        let cached = await model.resolve(values: [composed, decomposed])
        XCTAssertEqual(cached.labels, exactForm.labels)
        XCTAssertEqual(cached.unavailable, [Data(composed.utf8)])
        XCTAssertEqual(context.requests.count, 2)
    }

    private func page(_ values: [String], next: UInt32? = nil, revision: String? = "r1") -> OptionPage {
        OptionPage(options: values.map { ChoiceOption(value: $0, label: "Label \($0)", group: nil) }, nextOffset: next, total: nil, revision: revision)
    }
    private func assertItems(_ model: OptionCatalogModel, _ values: [String], file: StaticString = #filePath, line: UInt = #line) {
        if case let .loaded(items, _, _, _, _, _, _) = model.state {
            XCTAssertEqual(items.map(\.identity), values.map { Data($0.utf8) }, file: file, line: line)
        }
        else { XCTFail("Expected loaded list", file: file, line: line) }
    }
    private func makeModel(_ context: CatalogContext) -> OptionCatalogModel { makeModel(provider: CatalogRunnerProvider(context: context)) }
    private func makeModel(provider: CatalogRunnerProvider) -> OptionCatalogModel {
        OptionCatalogModel(catalog: OptionCatalog(id: "catalog", flags: []), runnerProvider: provider, pluginID: "plugin", debounceNanoseconds: 0)
    }
}

private enum CatalogFailure: Error { case failed }

@MainActor
private final class CatalogRunnerProvider: SourceRunnerProviding {
    var context: CatalogContext
    init(context: CatalogContext) { self.context = context }
    func sourceRunnerContext(for pluginID: String) async throws -> any SourceRunnerContext { context }
    func evictSourceRunner(for pluginID: String) {}
    func pendingTrust(for pluginID: String) -> PendingTrust? { nil }
    func clearPendingTrust(for pluginID: String) {}
}

@MainActor
private final class CatalogContext: @MainActor SourceRunnerContext {
    let runner = ItoRunner()
    var runnerIdentity: ObjectIdentifier { ObjectIdentifier(self) }
    var pageHandler: ((OptionRequest) async throws -> OptionPage?)?
    private(set) var requests: [OptionRequest] = []
    var pending: CheckedContinuation<OptionPage?, Never>?
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendPage() async -> OptionPage? {
        await withCheckedContinuation { continuation in
            pending = continuation
            let waiters = pendingWaiters
            pendingWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitForPendingRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { pendingWaiters.append($0) }
    }

    func loadOptionPage(_ request: OptionRequest) async throws -> OptionPage? {
        requests.append(request)
        let ready = requestWaiters.filter { requests.count >= $0.0 }
        requestWaiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        return try await pageHandler?(request)
    }
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }
    func loadHome() async throws -> HomeLayout { throw CancellationError() }
    func loadSettingsSurface() async throws -> SettingsSurface? { nil }
    func loadSearchCapabilities(kind: MediaKind?) async throws -> SearchCapabilities? { nil }
    func loadSearchSuggestions(query: String, kind: MediaKind?) async throws -> [SearchSuggestion]? { nil }
    func search(kind: MediaKind?, query: String, page: Int32, filterValues: [String: ControlValue]) async throws -> MediaPageResult { MediaPageResult(entries: [], hasNextPage: false) }
    func loadListing(listing: Listing, page: Int32) async throws -> MediaPageResult { MediaPageResult(entries: [], hasNextPage: false) }
    func loadManga(_ manga: Manga) async throws -> Manga { throw CancellationError() }
    func loadAnime(_ anime: Anime) async throws -> Anime { throw CancellationError() }
    func loadNovel(_ novel: Novel) async throws -> Novel { throw CancellationError() }
}
