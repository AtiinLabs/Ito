import Foundation
import Testing
import ito_runner
@testable import Ito

/// How a listing recovers when the runner behind it crashes: the failed instance is retired by identity, and the
/// retry runs on a freshly acquired context without losing the loaded pages or the listing's operation.
@MainActor
struct ListingRunnerRecoveryTests {
    private static let crash = PluginCallError(kind: .crashed, message: "The source stopped unexpectedly. Try again.")

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aCrashOnTheFirstPageRetiresThatInstanceAndRetryRunsOnANewOne() async {
        let crashed = PR7BSourceRunnerContextSpy()
        crashed.listingResults[1] = .failure(Self.crash)
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.listingResults[1] = .success(page(["fresh"], hasNextPage: false))
        let provider = CachingRunnerProvider(cached: crashed, upcoming: [fresh])
        let viewModel = makeViewModel(context: crashed, provider: provider)

        await viewModel.loadInitialIfNeeded()

        #expect(viewModel.phase == .failure(Self.crash.message))
        #expect(provider.retiredIdentities == [crashed.runnerIdentity])
        #expect(provider.cachedIdentity == nil)
        #expect(provider.acquisitions == 0)

        await viewModel.retry()

        #expect(viewModel.phase == .content)
        #expect(viewModel.entries.map(\.key) == ["fresh"])
        #expect(crashed.listingInvocations.count == 1)
        #expect(fresh.listingInvocations.map(\.page) == [1])
        #expect(fresh.listingInvocations.map(\.operationID) == crashed.listingInvocations.map(\.operationID))
        #expect(viewModel.destination.context.runnerIdentity == fresh.runnerIdentity)
        #expect(provider.acquisitions == 1)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aCrashOnALaterPageKeepsLoadedEntriesAndRetryRequestsTheSamePage() async {
        let crashed = PR7BSourceRunnerContextSpy()
        crashed.listingResults[1] = .success(page(["one"], hasNextPage: true))
        crashed.listingResults[2] = .failure(Self.crash)
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.listingResults[2] = .success(page(["two"], hasNextPage: false))
        let provider = CachingRunnerProvider(cached: crashed, upcoming: [fresh])
        let viewModel = makeViewModel(context: crashed, provider: provider)
        await viewModel.loadInitialIfNeeded()

        await viewModel.loadMore()

        #expect(viewModel.paginationState == .failure(page: 2, reason: Self.crash.message))
        #expect(viewModel.entries.map(\.key) == ["one"])
        #expect(viewModel.nextPage == 2)
        #expect(provider.retiredIdentities == [crashed.runnerIdentity])

        await viewModel.retry()

        #expect(fresh.listingInvocations.map(\.page) == [2])
        #expect(fresh.listingInvocations.first?.operationID == crashed.listingInvocations.first?.operationID)
        #expect(viewModel.entries.map(\.key) == ["one", "two"])
        #expect(viewModel.nextPage == 3)
        #expect(viewModel.paginationState == .exhausted)
        #expect(provider.acquisitions == 1)

        await viewModel.loadMore()

        #expect(fresh.listingInvocations.map(\.page) == [2])
        #expect(viewModel.entries.map(\.key) == ["one", "two"])
    }

    /// Covers the window after the runner already returned `.crashed` to a request its caller cancelled. A cancel
    /// that arrives before the runner call starts surfaces as `CancellationError` from the runner instead, which
    /// carries no crash evidence (ito-runner #33), so nothing here claims to detect that case.
    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aCancelledRequestWhoseRunnerCrashedRetiresItButPublishesNothing() async {
        let crashed = PR7BSourceRunnerContextSpy()
        crashed.suspendedListingPages = [1]
        let suspended = TestGate()
        crashed.onListingSuspended = { _ in suspended.open() }
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.listingResults[1] = .success(page(["fresh"], hasNextPage: false))
        let provider = CachingRunnerProvider(cached: crashed, upcoming: [fresh])
        let viewModel = makeViewModel(context: crashed, provider: provider)

        let task = Task { await viewModel.loadInitialIfNeeded() }
        await suspended.wait()
        viewModel.cancel()
        crashed.completeListing(page: 1, with: .failure(Self.crash))
        await task.value

        #expect(provider.retiredIdentities == [crashed.runnerIdentity])
        #expect(viewModel.phase == .cancelled)
        #expect(viewModel.entries.isEmpty)
        #expect(viewModel.nextPage == 1)

        await viewModel.loadInitialIfNeeded()

        #expect(viewModel.entries.map(\.key) == ["fresh"])
        #expect(crashed.listingInvocations.count == 1)
        #expect(provider.acquisitions == 1)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func anOldCrashArrivingAfterANewerRunnerLoadedNeverEvictsTheNewerRunner() async {
        let old = PR7BSourceRunnerContextSpy()
        old.suspendedListingPages = [1]
        let suspended = TestGate()
        old.onListingSuspended = { _ in suspended.open() }
        let newer = PR7BSourceRunnerContextSpy()
        newer.listingResults[1] = .success(page(["newer-one"], hasNextPage: true))
        newer.listingResults[2] = .success(page(["newer-two"], hasNextPage: false))
        let provider = CachingRunnerProvider(cached: old, upcoming: [newer])
        let viewModel = makeViewModel(context: old, provider: provider)

        // Request A is cancelled while its runner call is still out; request B on the same runner then crashes.
        let first = Task { await viewModel.loadInitialIfNeeded() }
        await suspended.wait(for: 1)
        viewModel.cancel()
        let second = Task { await viewModel.loadInitialIfNeeded() }
        await suspended.wait(for: 2)
        old.completeListing(call: 2, with: .failure(Self.crash))
        await second.value

        #expect(viewModel.phase == .failure(Self.crash.message))
        #expect(provider.retiredIdentities == [old.runnerIdentity])
        #expect(provider.cachedIdentity == nil)

        // The retry reacquires the newer runner, which the provider now caches.
        await viewModel.retry()

        #expect(viewModel.entries.map(\.key) == ["newer-one"])
        #expect(provider.cachedIdentity == newer.runnerIdentity)
        #expect(provider.acquisitions == 1)

        // Request A's crash arrives late and must retire only its own instance.
        old.completeListing(call: 1, with: .failure(Self.crash))
        await first.value

        #expect(provider.retiredIdentities == [old.runnerIdentity, old.runnerIdentity])
        #expect(provider.cachedIdentity == newer.runnerIdentity)
        #expect(viewModel.destination.context.runnerIdentity == newer.runnerIdentity)
        #expect(viewModel.phase == .content)
        #expect(viewModel.entries.map(\.key) == ["newer-one"])

        await viewModel.loadMore()

        #expect(newer.listingInvocations.map(\.page) == [1, 2])
        #expect(provider.acquisitions == 1)
        #expect(viewModel.entries.map(\.key) == ["newer-one", "newer-two"])
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func anOrdinaryNetworkErrorRetriesOnTheSameRunnerWithoutRetiringIt() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults[1] = .success(page(["one"], hasNextPage: true))
        context.listingResults[2] = .failure(URLError(.notConnectedToInternet))
        let provider = CachingRunnerProvider(cached: context, upcoming: [])
        let viewModel = makeViewModel(context: context, provider: provider)
        await viewModel.loadInitialIfNeeded()

        await viewModel.loadMore()

        #expect(viewModel.paginationState == .failure(
            page: 2,
            reason: URLError(.notConnectedToInternet).localizedDescription
        ))
        context.listingResults[2] = .success(page(["two"], hasNextPage: false))

        await viewModel.retry()

        #expect(provider.retiredIdentities.isEmpty)
        #expect(provider.cachedIdentity == context.runnerIdentity)
        #expect(provider.acquisitions == 0)
        #expect(context.listingInvocations.map(\.page) == [1, 2, 2])
        #expect(viewModel.entries.map(\.key) == ["one", "two"])
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aRestartedListingNeverPublishesTheOlderRequestsLateFirstPage() async {
        let context = PR7BSourceRunnerContextSpy()
        context.suspendedListingPages = [1]
        let suspended = TestGate()
        context.onListingSuspended = { _ in suspended.open() }
        let viewModel = makeViewModel(context: context, provider: CachingRunnerProvider(cached: context, upcoming: []))

        let older = Task { await viewModel.loadInitialIfNeeded() }
        await suspended.wait(for: 1)
        let newer = Task { await viewModel.loadInitial() }
        await suspended.wait(for: 2)
        context.completeListing(call: 2, with: .success(page(["fresh"], hasNextPage: false)))
        await newer.value
        context.completeListing(call: 1, with: .success(page(["stale"], hasNextPage: true)))
        await older.value

        #expect(viewModel.entries.map(\.key) == ["fresh"])
        #expect(viewModel.nextPage == 2)
        #expect(viewModel.paginationState == .exhausted)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aRestartedListingNeverAppendsTheOlderRequestsLatePage() async {
        let context = PR7BSourceRunnerContextSpy()
        context.listingResults[1] = .success(page(["one"], hasNextPage: true))
        context.suspendedListingPages = [2]
        let suspended = TestGate()
        context.onListingSuspended = { _ in suspended.open() }
        let viewModel = makeViewModel(context: context, provider: CachingRunnerProvider(cached: context, upcoming: []))
        await viewModel.loadInitialIfNeeded()

        let olderPage = Task { await viewModel.loadMore() }
        await suspended.wait()
        await viewModel.loadInitial()
        context.completeListing(call: 2, with: .success(page(["stale-two"], hasNextPage: false)))
        await olderPage.value

        #expect(viewModel.entries.map(\.key) == ["one"])
        #expect(viewModel.nextPage == 2)
        #expect(viewModel.paginationState == .idle)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aSupersededRequestEndingInACancelledHostErrorKeepsTheNewerContent() async {
        let context = PR7BSourceRunnerContextSpy()
        context.suspendedListingPages = [1]
        let suspended = TestGate()
        context.onListingSuspended = { _ in suspended.open() }
        let viewModel = makeViewModel(context: context, provider: CachingRunnerProvider(cached: context, upcoming: []))

        let older = Task { await viewModel.loadInitialIfNeeded() }
        await suspended.wait(for: 1)
        let newer = Task { await viewModel.loadInitial() }
        await suspended.wait(for: 2)
        context.completeListing(call: 2, with: .success(page(["fresh"], hasNextPage: false)))
        await newer.value
        context.completeListing(call: 1, with: .failure(URLError(.cancelled)))
        await older.value

        #expect(viewModel.phase == .content)
        #expect(viewModel.entries.map(\.key) == ["fresh"])
        #expect(viewModel.paginationState == .exhausted)
    }

    @Test func aLateRetirementFromAnOlderInstanceKeepsTheNewerCachedRunner() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter()),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: { _, _, _ in ItoRunner() }
        )
        let plugin = InstalledPlugin(
            url: URL(fileURLWithPath: "/test/plugin.test.ito"),
            info: PluginInfo(
                id: "plugin.test", name: "Test Plugin", version: "1.0.0", minAppVersion: "1.0", type: .manga
            ),
            iconData: nil,
            binary: makeRunnableBinary()
        )
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])

        let first = try await manager.getRunner(for: plugin.id)
        manager.retireRunner(for: plugin.id, matching: first)
        let second = try await manager.getRunner(for: plugin.id)
        #expect(second !== first)

        manager.retireRunner(for: plugin.id, matching: first)
        let stillSecond = try await manager.getRunner(for: plugin.id)
        #expect(stillSecond === second)

        manager.retireRunner(for: plugin.id, matching: second)
        let third = try await manager.getRunner(for: plugin.id)
        #expect(third !== second)
    }

    private func page(_ keys: [String], hasNextPage: Bool) -> MediaPageResult {
        MediaPageResult(
            entries: keys.map { .manga(Manga(key: $0, title: $0)) },
            hasNextPage: hasNextPage
        )
    }

    private func makeViewModel(
        context: PR7BSourceRunnerContextSpy,
        provider: CachingRunnerProvider
    ) -> ListingViewModel {
        ListingViewModel(destination: makeDestination(context: context), runnerProvider: provider)
    }

    private func makeDestination(
        context: PR7BSourceRunnerContextSpy,
        listingID: String = "popular",
        title: String = "Popular"
    ) -> SourceListingDestination {
        SourceListingDestination(
            plugin: pr7bPlugin(),
            context: context,
            listing: Listing(id: listingID, name: title, kind: 1),
            title: title,
            operationID: UUID()
        )
    }
}

/// A provider that caches one runner context the way the plugin manager does: a retirement removes the cached
/// context only when it is the instance named, and the next acquisition takes the next prepared context.
@MainActor
private final class CachingRunnerProvider: SourceRunnerProviding {
    private var cached: (any SourceRunnerContext)?
    private var upcoming: [any SourceRunnerContext]
    private(set) var acquisitions = 0
    private(set) var retiredIdentities: [ObjectIdentifier] = []

    var cachedIdentity: ObjectIdentifier? { cached?.runnerIdentity }

    init(cached: (any SourceRunnerContext)?, upcoming: [any SourceRunnerContext]) {
        self.cached = cached
        self.upcoming = upcoming
    }

    func sourceRunnerContext(for pluginID: String) async throws -> any SourceRunnerContext {
        acquisitions += 1
        if let cached { return cached }
        let next = upcoming.removeFirst()
        cached = next
        return next
    }

    func evictSourceRunner(for pluginID: String) {
        cached = nil
    }

    func retireSourceRunner(for pluginID: String, matching context: any SourceRunnerContext) {
        retiredIdentities.append(context.runnerIdentity)
        if cachedIdentity == context.runnerIdentity { cached = nil }
    }
}
