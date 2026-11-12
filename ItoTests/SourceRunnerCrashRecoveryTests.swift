import Foundation
import Testing
import ito_runner
@testable import Ito

/// How the source screens treat a runner crash: the instance that crashed is retired, whether or not the
/// operation that saw it is still current, and nothing a stale operation produced is published.
@MainActor
struct SourceRunnerCrashRecoveryTests {
    private static let crash = PluginCallError(kind: .crashed, message: "The source stopped unexpectedly. Try again.")

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aCapabilityCrashDuringLoadRetiresTheInstanceAndNeverLoadsTheHomeOnIt() async {
        let crashed = PR7BSourceRunnerContextSpy()
        crashed.capabilitiesResult = .failure(Self.crash)
        crashed.homeResult = .success(pr7bHome(ids: ["crashed"]))
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.homeResult = .success(pr7bHome(ids: ["fresh"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [crashed, fresh])
        let viewModel = makeViewModel(provider: provider)

        await viewModel.loadIfNeeded()

        #expect(crashed.homeLoadCount == 0)
        #expect(provider.retiredRunners == [retirement(of: crashed)])
        #expect(viewModel.phase == .failure(Self.crash.message))

        await viewModel.retry()

        #expect(viewModel.homeLayout?.components.first?.title == "fresh")
        #expect(crashed.homeLoadCount == 0)
        #expect(provider.requestedPluginIDs.count == 2)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aSuggestionCrashRetiresTheInstanceAndDropsItsContextWithoutTouchingTheSearch() async {
        let crashed = PR7BSourceRunnerContextSpy()
        crashed.homeResult = .success(pr7bHome(ids: ["crashed"]))
        crashed.capabilitiesResult = .success(.init(flags: [.suggestions], sections: []))
        crashed.suggestionsHandler = { _, _ in throw Self.crash }
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.homeResult = .success(pr7bHome(ids: ["fresh"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [crashed, fresh])
        let retired = TestGate()
        let viewModel = makeViewModel(provider: provider)
        await viewModel.loadIfNeeded()
        provider.onRetire = { retired.open() }
        viewModel.searchQuery = "query"

        viewModel.performSearch(query: "query")
        await retired.wait()
        await awaitValue(of: viewModel.$phase) { $0 == .content }

        #expect(provider.retiredRunners == [retirement(of: crashed)])
        #expect(viewModel.searchPhase == .empty)
        #expect(viewModel.searchSuggestions.isEmpty)
        // The dead context was dropped, so the screen loaded again on the provider's next runner.
        #expect(provider.requestedPluginIDs.count == 2)
        #expect(viewModel.homeLayout?.components.first?.title == "fresh")
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aSupersededSearchCrashRetiresOnlyItsOwnInstanceAndKeepsTheNewerContext() async {
        let old = PR7BSourceRunnerContextSpy()
        old.homeResult = .success(pr7bHome(ids: ["old"]))
        old.suspendsSearch = true
        let suspended = TestGate()
        old.onSearchSuspended = { suspended.open() }
        let newer = PR7BSourceRunnerContextSpy()
        newer.homeResult = .success(pr7bHome(ids: ["newer"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [old, newer])
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(provider: provider, messages: messages)
        await viewModel.loadIfNeeded()

        viewModel.performSearch(query: "one")
        await suspended.wait()
        await viewModel.retry()
        viewModel.performSearch(query: "two")
        await awaitValue(of: viewModel.$searchPhase) { $0 == .empty }

        let retired = TestGate()
        provider.onRetire = { retired.open() }
        old.completeSearch(query: "one", with: .failure(Self.crash))
        await retired.wait()

        #expect(provider.retiredRunners == [retirement(of: old)])
        #expect(viewModel.phase == .content)
        #expect(viewModel.homeLayout?.components.first?.title == "newer")
        #expect(viewModel.searchPhase == .empty)
        #expect(provider.requestedPluginIDs.count == 2)
        #expect(newer.searchInvocations.map(\.query) == ["two"])
        #expect(messages.messages.isEmpty)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aSupersededSearchCrashOnTheCurrentContextDropsItAndLoadsAgain() async {
        let old = PR7BSourceRunnerContextSpy()
        old.homeResult = .success(pr7bHome(ids: ["old"]))
        old.suspendsSearch = true
        let suspended = TestGate()
        old.onSearchSuspended = { suspended.open() }
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.homeResult = .success(pr7bHome(ids: ["fresh"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [old, fresh])
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(provider: provider, messages: messages)
        await viewModel.loadIfNeeded()

        viewModel.performSearch(query: "one")
        await suspended.wait()
        viewModel.returnToHome()
        let retired = TestGate()
        provider.onRetire = { retired.open() }
        old.completeSearch(query: "one", with: .failure(Self.crash))
        await retired.wait()
        await awaitValue(of: viewModel.$phase) { $0 == .content }

        #expect(provider.retiredRunners == [retirement(of: old)])
        #expect(viewModel.searchPhase == .idle)
        #expect(viewModel.homeLayout?.components.first?.title == "fresh")
        #expect(messages.messages.isEmpty)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aSupersededLoadThatCrashesRetiresItsInstanceAndPublishesNothing() async {
        let stale = PR7BSourceRunnerContextSpy()
        stale.suspendsHome = true
        let suspended = TestGate()
        stale.onHomeSuspended = { suspended.open() }
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.homeResult = .success(pr7bHome(ids: ["fresh"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [stale, fresh])
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(provider: provider, messages: messages)

        let older = Task { await viewModel.loadIfNeeded() }
        await suspended.wait()
        await viewModel.retry()
        let retired = TestGate()
        provider.onRetire = { retired.open() }
        stale.completeHome(with: .failure(Self.crash))
        await retired.wait()
        await older.value

        #expect(provider.retiredRunners == [retirement(of: stale)])
        #expect(viewModel.phase == .content)
        #expect(viewModel.homeLayout?.components.first?.title == "fresh")
        #expect(messages.messages.isEmpty)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aSettingsLoadCancelledBeforeItsRunnerCrashedStillRetiresItAndShowsNoFailure() async {
        let crashed = PR7BSourceRunnerContextSpy()
        let suspended = TestGate()
        var resume: CheckedContinuation<Void, Never>?
        crashed.settingsHandler = {
            await withCheckedContinuation { continuation in
                resume = continuation
                suspended.open()
            }
            throw Self.crash
        }
        let provider = PR7BSourceRunnerProviderSpy(contexts: [crashed])
        let model = PluginSettingsLoaderViewModel(plugin: pr7bPlugin(), runnerProvider: provider)

        let task = Task { await model.load() }
        await suspended.wait()
        task.cancel()
        resume?.resume()
        await task.value

        #expect(provider.retiredRunners == [retirement(of: crashed)])
        #expect(model.failure == nil)
        #expect(model.destination == nil)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aCapabilityCrashOnAKindSwitchStillRunsTheNewKindsSearchOnTheFreshRunner() async {
        let crashed = PR7BSourceRunnerContextSpy()
        crashed.homeResult = .success(pr7bHome(ids: ["crashed"]))
        crashed.searchResult = .success(MediaPageResult(entries: [.manga(Manga(key: "old", title: "Old"))], hasNextPage: false))
        crashed.capabilitiesHandler = { kind in
            if kind == .manga { throw Self.crash }
            return nil
        }
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.homeResult = .success(pr7bHome(ids: ["fresh"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [crashed, fresh])
        let viewModel = makeViewModel(provider: provider, plugin: pr7bPlugin(kinds: [.manga, .novel]))
        await viewModel.loadIfNeeded()
        viewModel.searchQuery = "query"
        viewModel.performSearch(query: "query")
        await awaitValue(of: viewModel.$searchPhase) { $0 == .content }
        #expect(viewModel.searchEntries.map(\.key) == ["old"])

        viewModel.selectedKind = .manga
        await awaitValue(of: viewModel.$searchPhase) { $0 == .empty }

        #expect(provider.retiredRunners == [retirement(of: crashed)])
        #expect(provider.requestedPluginIDs.count == 2)
        #expect(fresh.searchInvocations.map(\.query) == ["query"])
        #expect(fresh.searchInvocations.map(\.pluginType) == [.manga])
        #expect(viewModel.searchEntries.isEmpty)
        #expect(viewModel.phase == .content)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aLoadWhoseRunnerWasRetiredWhileItsHomeLoadedRunsAgainInsteadOfPublishingTheRetiredRunner() async {
        let shared = PR7BSourceRunnerContextSpy()
        shared.homeResult = .success(pr7bHome(ids: ["shared"]))
        shared.suspendsSearch = true
        let searchSuspended = TestGate()
        shared.onSearchSuspended = { searchSuspended.open() }
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.homeResult = .success(pr7bHome(ids: ["fresh"]))
        // The cached runner serves the first load and the reload; the third acquisition is a new runner.
        let provider = PR7BSourceRunnerProviderSpy(contexts: [shared, shared, fresh])
        let viewModel = makeViewModel(provider: provider)
        await viewModel.loadIfNeeded()
        viewModel.performSearch(query: "one")
        await searchSuspended.wait()

        shared.suspendsHome = true
        let homeSuspended = TestGate()
        shared.onHomeSuspended = { homeSuspended.open() }
        let reload = Task { await viewModel.retry() }
        await homeSuspended.wait()
        let retired = TestGate()
        provider.onRetire = { retired.open() }
        // The earlier search's crash retires the runner the reload is still using.
        shared.completeSearch(query: "one", with: .failure(Self.crash))
        await retired.wait()
        shared.completeHome(with: .success(pr7bHome(ids: ["shared-again"])))
        await reload.value
        await awaitValue(of: viewModel.$phase) { $0 == .content }

        #expect(provider.retiredRunners == [retirement(of: shared)])
        #expect(provider.requestedPluginIDs.count == 3)
        #expect(viewModel.homeLayout?.components.first?.title == "fresh")
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aSearchWaitingOnALoadWhoseRunnerWasRetiredRunsOnTheFreshRunnerWithoutAFailure() async {
        let shared = PR7BSourceRunnerContextSpy()
        shared.homeResult = .success(pr7bHome(ids: ["shared"]))
        shared.suspendsSearch = true
        let searchSuspended = TestGate()
        shared.onSearchSuspended = { searchSuspended.open() }
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.homeResult = .success(pr7bHome(ids: ["fresh"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [shared, shared, fresh])
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(provider: provider, messages: messages)
        await viewModel.loadIfNeeded()
        viewModel.performSearch(query: "one")
        await searchSuspended.wait()

        shared.suspendsHome = true
        let homeSuspended = TestGate()
        shared.onHomeSuspended = { homeSuspended.open() }
        let reload = Task { await viewModel.retry() }
        await homeSuspended.wait()
        // This search waits for the reload; an earlier search then crashes the runner the reload is using.
        viewModel.performSearch(query: "two")
        let retired = TestGate()
        provider.onRetire = { retired.open() }
        shared.completeSearch(query: "one", with: .failure(Self.crash))
        await retired.wait()
        shared.completeHome(with: .success(pr7bHome(ids: ["shared-again"])))
        await awaitValue(of: viewModel.$searchPhase) { $0 == .empty }
        await reload.value

        #expect(provider.retiredRunners == [retirement(of: shared)])
        #expect(provider.requestedPluginIDs.count == 3)
        #expect(fresh.searchInvocations.map(\.query) == ["two"])
        #expect(viewModel.phase == .content)
        #expect(viewModel.homeLayout?.components.first?.title == "fresh")
        #expect(messages.messages.isEmpty)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aKindSwitchSearchWhoseCapabilitiesAreInFlightSurvivesALoadRerun() async {
        let shared = PR7BSourceRunnerContextSpy()
        shared.homeResult = .success(pr7bHome(ids: ["shared"]))
        shared.suspendsSearch = true
        let searchSuspended = TestGate()
        shared.onSearchSuspended = { searchSuspended.open() }
        let capabilitiesSuspended = TestGate()
        var capabilitiesResume: CheckedContinuation<Void, Never>?
        shared.capabilitiesHandler = { kind in
            guard kind == .manga else { return nil }
            await withCheckedContinuation { continuation in
                capabilitiesResume = continuation
                capabilitiesSuspended.open()
            }
            return nil
        }
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.homeResult = .success(pr7bHome(ids: ["fresh"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [shared, shared, fresh])
        let viewModel = makeViewModel(provider: provider, plugin: pr7bPlugin(kinds: [.manga, .novel]))
        await viewModel.loadIfNeeded()
        viewModel.searchQuery = "query"
        viewModel.performSearch(query: "query")
        await searchSuspended.wait()
        shared.suspendsHome = true
        let homeSuspended = TestGate()
        shared.onHomeSuspended = { homeSuspended.open() }
        let reload = Task { await viewModel.retry() }
        await homeSuspended.wait()

        viewModel.selectedKind = .manga
        await capabilitiesSuspended.wait()
        let retired = TestGate()
        provider.onRetire = { retired.open() }
        shared.completeSearch(query: "query", with: .failure(Self.crash))
        await retired.wait()
        shared.completeHome(with: .success(pr7bHome(ids: ["shared-again"])))
        await reload.value
        capabilitiesResume?.resume()
        await awaitValue(of: viewModel.$searchPhase) { $0 == .empty }

        #expect(provider.requestedPluginIDs.count == 3)
        #expect(fresh.searchInvocations.map(\.query) == ["query"])
        #expect(fresh.searchInvocations.map(\.pluginType) == [.manga])
        #expect(viewModel.homeLayout?.components.first?.title == "fresh")
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aCrashReportedWhileTheScreenIsHiddenRetiresTheRunnerAndOnlyReloadsOnAppearing() async {
        let shared = PR7BSourceRunnerContextSpy()
        shared.homeResult = .success(pr7bHome(ids: ["shared"]))
        shared.suspendsSearch = true
        let suspended = TestGate()
        shared.onSearchSuspended = { suspended.open() }
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.homeResult = .success(pr7bHome(ids: ["fresh"]))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [shared, fresh])
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(provider: provider, messages: messages)
        await viewModel.loadIfNeeded()
        viewModel.performSearch(query: "one")
        await suspended.wait()

        viewModel.cancelActiveOperations()
        let retired = TestGate()
        provider.onRetire = { retired.open() }
        shared.completeSearch(query: "one", with: .failure(Self.crash))
        await retired.wait()

        #expect(provider.retiredRunners == [retirement(of: shared)])
        #expect(provider.requestedPluginIDs.count == 1)
        #expect(messages.messages.isEmpty)
        #expect(viewModel.phase == .cancelled)

        await viewModel.loadIfNeeded()

        #expect(provider.requestedPluginIDs.count == 2)
        #expect(viewModel.phase == .content)
        #expect(viewModel.homeLayout?.components.first?.title == "fresh")
        #expect(provider.retiredRunners == [retirement(of: shared)])
        #expect(messages.messages.isEmpty)
    }

    private func retirement(of context: PR7BSourceRunnerContextSpy) -> PR7BSourceRunnerProviderSpy.Retirement {
        .init(pluginID: "plugin.manga", runnerIdentity: context.runnerIdentity)
    }

    private func makeViewModel(
        provider: PR7BSourceRunnerProviderSpy,
        plugin: InstalledPlugin = pr7bPlugin(),
        messages: PR7BMessagePresenterSpy = PR7BMessagePresenterSpy()
    ) -> SourceViewModel {
        let publisher = PR7BPluginStatePublisherSpy()
        publisher.currentPlugins[plugin.id] = plugin
        return SourceViewModel(
            plugin: plugin,
            runnerProvider: provider,
            pluginStatePublisher: publisher,
            fileDeletion: PR7BFileDeletionSpy(),
            messagePresenter: messages,
            searchDebounceNanoseconds: nil
        )
    }
}
