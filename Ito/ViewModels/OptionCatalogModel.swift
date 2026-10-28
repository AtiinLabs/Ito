import Combine
import Foundation
import ito_runner

@MainActor
final class OptionCatalogModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(
            items: [ChoiceOption],
            nextOffset: UInt32?,
            total: UInt32?,
            revision: String?,
            runnerID: ObjectIdentifier,
            loadingMore: Bool,
            moreError: String?
        )
        case failed(String)
        case empty
    }

    struct LabelResolution: Equatable {
        let labels: [Data: String]
        let unavailable: Set<Data>
        let error: String?
    }

    @Published private(set) var query = ""
    @Published private(set) var state: State = .idle
    private let catalog: OptionCatalog

    private let loader: OptionCatalogLoading
    private let debounceNanoseconds: UInt64
    private var generation: UInt64 = 0
    private var expectedOffset: UInt32 = 0
    private var failedOffset: UInt32 = 0
    private(set) var requestTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    // Retain every cache identity's owner so ObjectIdentifier cannot be reused.
    private var contextsByRunner: [ObjectIdentifier: any SourceRunnerContext] = [:]
    private var labelsByRunner: [ObjectIdentifier: [Data: String]] = [:]
    private var unavailableValuesByRunner: [ObjectIdentifier: Set<Data>] = [:]
    private var resolutionGeneration: UInt64 = 0
    private var resolutionRequests: [UUID?: UInt64] = [:]

    init(
        catalog: OptionCatalog,
        runnerProvider: any SourceRunnerProviding,
        pluginID: String,
        debounceNanoseconds: UInt64 = 250_000_000
    ) {
        self.catalog = catalog
        self.loader = OptionCatalogLoading(pluginID: pluginID, runnerProvider: runnerProvider)
        self.debounceNanoseconds = debounceNanoseconds
    }

    func appear() {
        guard case .idle = state else { return }
        start(query: query, offset: 0)
    }

    func textChanged(_ text: String) {
        guard query != text else { return }
        query = text
        generation &+= 1
        requestTask?.cancel()
        debounceTask?.cancel()
        state = .loading
        let expectedGeneration = generation
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            start(query: text, offset: 0, incrementGeneration: false)
        }
    }

    func loadMore() {
        guard case let .loaded(items, nextOffset, total, revision, runnerID, loadingMore, _) = state,
              let nextOffset, !loadingMore, items.count < 10_000 else { return }
        state = .loaded(
            items: items,
            nextOffset: nextOffset,
            total: total,
            revision: revision,
            runnerID: runnerID,
            loadingMore: true,
            moreError: nil
        )
        start(query: query, offset: nextOffset, incrementGeneration: false)
    }

    func retry() {
        switch state {
        case .failed:
            start(query: query, offset: 0)
        case let .loaded(_, _, _, _, _, loadingMore, moreError) where !loadingMore && moreError != nil:
            start(query: query, offset: failedOffset)
        default:
            break
        }
    }

    func disappear() {
        generation &+= 1
        resolutionGeneration &+= 1
        resolutionRequests.removeAll()
        requestTask?.cancel()
        requestTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        state = .idle
    }

    func resolve(values: [String], consumer: UUID? = nil) async -> LabelResolution {
        resolutionRequests[consumer, default: 0] &+= 1
        let requestGeneration = resolutionRequests[consumer]
        let currentGeneration = resolutionGeneration
        var labels: [Data: String] = [:]
        var unavailable = Set<Data>()
        func isCurrent() -> Bool {
            resolutionGeneration == currentGeneration &&
                resolutionRequests[consumer] == requestGeneration && !Task.isCancelled
        }
        do {
            let context = try await loader.sourceContext()
            guard isCurrent() else { return LabelResolution(labels: [:], unavailable: [], error: nil) }
            let runnerID = context.runnerIdentity
            contextsByRunner[runnerID] = context
            for batchStart in stride(from: 0, to: values.count, by: 100) {
                guard isCurrent() else { return LabelResolution(labels: [:], unavailable: [], error: nil) }
                let batch = Array(values[batchStart..<min(batchStart + 100, values.count)])
                let cached = labelsByRunner[runnerID] ?? [:]
                let cachedUnavailable = unavailableValuesByRunner[runnerID] ?? []
                for value in batch {
                    let identity = Data(value.utf8)
                    if let label = cached[identity] { labels[identity] = label }
                    if cachedUnavailable.contains(identity) { unavailable.insert(identity) }
                }
                let missing = batch.filter {
                    let identity = Data($0.utf8)
                    return cached[identity] == nil && !cachedUnavailable.contains(identity)
                }
                guard !missing.isEmpty else { continue }
                let response = try await context.loadOptionPage(
                    OptionRequest(catalog: catalog.id, query: .values(missing), limit: UInt32(missing.count))
                )
                guard isCurrent() else { return LabelResolution(labels: [:], unavailable: [], error: nil) }
                guard let page = response else { throw CatalogUnavailableError.unavailable }
                let requested = Set(missing.map { Data($0.utf8) })
                var found: [Data: String] = [:]
                for option in page.options where requested.contains(option.identity) && found[option.identity] == nil {
                    found[option.identity] = option.label
                }
                let omitted = requested.subtracting(found.keys)
                labelsByRunner[runnerID, default: [:]].merge(found) { _, new in new }
                unavailableValuesByRunner[runnerID, default: []].formUnion(omitted)
                unavailableValuesByRunner[runnerID, default: []].subtract(found.keys)
                for value in omitted { labelsByRunner[runnerID]?.removeValue(forKey: value) }
                labels.merge(found) { _, new in new }
                unavailable.formUnion(omitted)
            }
            return LabelResolution(labels: labels, unavailable: unavailable, error: nil)
        } catch {
            guard isCurrent() else { return LabelResolution(labels: [:], unavailable: [], error: nil) }
            return LabelResolution(labels: labels, unavailable: unavailable, error: "Labels unavailable.")
        }
    }

    private func start(query: String, offset: UInt32, incrementGeneration: Bool = true) {
        if incrementGeneration { generation &+= 1 }
        let requestGeneration = generation
        failedOffset = offset
        requestTask?.cancel()
        state = offset == 0 ? .loading : currentLoadedState(loadingMore: true)
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let request = OptionRequest(
                    catalog: catalog.id,
                    query: .search(text: query, offset: offset),
                    limit: 50
                )
                let result = try await loader.load(request)
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                guard let page = result.options else { throw CatalogUnavailableError.unavailable }
                contextsByRunner[result.runnerIdentity] = result.context
                apply(page, offset: offset, runnerID: result.runnerIdentity)
            } catch {
                guard generation == requestGeneration, !Task.isCancelled else { return }
                if offset == 0 {
                    state = .failed("Options could not be loaded.")
                } else if case let .loaded(items, next, total, revision, runnerID, _, _) = state {
                    state = .loaded(
                        items: items,
                        nextOffset: next,
                        total: total,
                        revision: revision,
                        runnerID: runnerID,
                        loadingMore: false,
                        moreError: "More options could not be loaded."
                    )
                }
            }
        }
    }

    private func currentLoadedState(loadingMore: Bool) -> State {
        guard case let .loaded(items, next, total, revision, runnerID, _, _) = state else { return .loading }
        return .loaded(
            items: items,
            nextOffset: next,
            total: total,
            revision: revision,
            runnerID: runnerID,
            loadingMore: loadingMore,
            moreError: nil
        )
    }

    private func apply(
        _ page: OptionPage,
        offset: UInt32,
        runnerID: ObjectIdentifier
    ) {
        var options: [ChoiceOption]
        if offset == 0 {
            options = []
            expectedOffset = 0
        } else {
            guard case let .loaded(existing, _, _, revision, oldRunnerID, _, _) = state,
                  oldRunnerID == runnerID, revision == page.revision, offset == expectedOffset else {
                generation &+= 1
                start(query: query, offset: 0, incrementGeneration: false)
                return
            }
            options = existing
        }
        var seen = Set(options.map(\.identity))
        for option in page.options where seen.insert(option.identity).inserted && options.count < 10_000 {
            options.append(option)
        }
        // A malformed/non-advancing cursor must never create an endless page loop.
        let nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
        expectedOffset = nextOffset ?? UInt32(options.count)
        if options.count >= 10_000 {
            state = .loaded(
                items: options,
                nextOffset: nil,
                total: page.total,
                revision: page.revision,
                runnerID: runnerID,
                loadingMore: false,
                moreError: nil
            )
        } else {
            state = .loaded(
                items: options,
                nextOffset: nextOffset,
                total: page.total,
                revision: page.revision,
                runnerID: runnerID,
                loadingMore: false,
                moreError: nil
            )
            if options.isEmpty && nextOffset == nil { state = .empty }
        }
    }

    private enum CatalogUnavailableError: Error { case unavailable }
}
