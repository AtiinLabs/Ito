import XCTest
import ito_runner
@testable import Ito

@MainActor
final class SourceViewModelCancellationTests: XCTestCase {
    func testCallerCancellationEndingInCancelledHostErrorLeavesHomeCancelled() async {
        let context = PR7BSourceRunnerContextSpy()
        context.suspendsHome = true
        defer { context.completeHome(with: .failure(CancellationError())) }
        let suspended = expectation(description: "Home request is suspended")
        context.onHomeSuspended = { suspended.fulfill() }
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(
            provider: PR7BSourceRunnerProviderSpy(contexts: [context]),
            messages: messages
        )

        let task = Task { await viewModel.loadIfNeeded() }
        await fulfillment(of: [suspended], timeout: 2)
        task.cancel()
        context.completeHome(with: .failure(URLError(.cancelled)))
        await task.value

        XCTAssertEqual(viewModel.phase, .cancelled)
        XCTAssertNil(viewModel.homeLayout)
        XCTAssertTrue(messages.messages.isEmpty)
    }

    func testSupersededHomeCancellationErrorDoesNotPublishFailure() async {
        let stale = PR7BSourceRunnerContextSpy()
        stale.suspendsHome = true
        defer { stale.completeHome(with: .failure(CancellationError())) }
        let suspended = expectation(description: "Old home request is suspended")
        stale.onHomeSuspended = { suspended.fulfill() }
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.homeResult = .success(pr7bHome(ids: ["fresh"]))
        let messages = PR7BMessagePresenterSpy()
        let provider = PR7BSourceRunnerProviderSpy(contexts: [stale, fresh])
        let viewModel = makeViewModel(provider: provider, messages: messages)

        let oldTask = Task { await viewModel.loadIfNeeded() }
        await fulfillment(of: [suspended], timeout: 2)
        await viewModel.retry()
        stale.completeHome(with: .failure(URLError(.cancelled)))
        await oldTask.value

        XCTAssertEqual(viewModel.phase, .content)
        XCTAssertEqual(viewModel.homeLayout?.components.first?.title, "fresh")
        XCTAssertTrue(messages.messages.isEmpty)
    }

    func testCancelledLoadThatCrashesEvictsItsRunnerWithoutPublishingFailure() async {
        let context = PR7BSourceRunnerContextSpy()
        context.suspendsHome = true
        defer { context.completeHome(with: .failure(CancellationError())) }
        let suspended = expectation(description: "Home request is suspended")
        context.onHomeSuspended = { suspended.fulfill() }
        let provider = PR7BSourceRunnerProviderSpy(contexts: [context])
        let messages = PR7BMessagePresenterSpy()
        let viewModel = makeViewModel(provider: provider, messages: messages)

        let task = Task { await viewModel.loadIfNeeded() }
        await fulfillment(of: [suspended], timeout: 2)
        task.cancel()
        context.completeHome(with: .failure(PluginCallError(kind: .crashed, message: "x")))
        await task.value

        XCTAssertEqual(provider.retiredRunners, [.init(pluginID: viewModel.plugin.id, runnerIdentity: context.runnerIdentity)])
        XCTAssertTrue(provider.evictedPluginIDs.isEmpty)
        XCTAssertEqual(viewModel.phase, .cancelled)
        XCTAssertTrue(messages.messages.isEmpty)
    }

    private func makeViewModel(
        plugin: InstalledPlugin = pr7bPlugin(),
        provider: PR7BSourceRunnerProviderSpy = PR7BSourceRunnerProviderSpy(),
        publisher: PR7BPluginStatePublisherSpy = PR7BPluginStatePublisherSpy(),
        files: PR7BFileDeletionSpy = PR7BFileDeletionSpy(),
        messages: PR7BMessagePresenterSpy = PR7BMessagePresenterSpy(),
        debounce: UInt64? = nil
    ) -> SourceViewModel {
        publisher.currentPlugins[plugin.id] = plugin
        return SourceViewModel(
            plugin: plugin,
            runnerProvider: provider,
            pluginStatePublisher: publisher,
            fileDeletion: files,
            messagePresenter: messages,
            searchDebounceNanoseconds: debounce
        )
    }
}
