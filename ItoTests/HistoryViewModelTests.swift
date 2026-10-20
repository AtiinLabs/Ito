import XCTest
@testable import Ito

@MainActor
final class HistoryViewModelTests: XCTestCase {
    func testInitialEmptyAndContentPhasesDeriveClearVisibility() {
        let empty = makeViewModel(history: []).viewModel
        XCTAssertEqual(empty.phase, .empty)
        XCTAssertFalse(empty.isClearVisible)

        let content = makeViewModel(
            history: [pr11bHistoryEntry(id: "one", readAt: 1)]
        ).viewModel
        XCTAssertEqual(content.phase, .content)
        XCTAssertTrue(content.isClearVisible)
    }

    func testAuthoritativePublicationAndExactOrderingArePreserved() {
        let harness = makeViewModel()
        let newest = pr11bHistoryEntry(id: "new", readAt: 3)
        let middle = pr11bHistoryEntry(id: "middle", readAt: 2)
        let oldest = pr11bHistoryEntry(id: "old", readAt: 1)

        harness.service.publish([newest, middle, oldest])

        XCTAssertEqual(harness.viewModel.history.map(\.id), ["new", "middle", "old"])
        XCTAssertEqual(harness.viewModel.phase, .content)
        harness.service.publish([])
        XCTAssertEqual(harness.viewModel.phase, .empty)
    }

    func testDeleteAwaitsPublicationAndRemovesOnlyExactEntry() async {
        let one = pr11bHistoryEntry(id: "one", readAt: 2)
        let two = pr11bHistoryEntry(id: "two", readAt: 1)
        let harness = makeViewModel(history: [one, two])
        harness.service.deleteResponses = [.suspended]

        let task = Task { await harness.viewModel.deleteEntry(id: "one") }
        await waitUntil { harness.service.pendingDeleteCount == 1 }
        XCTAssertEqual(harness.viewModel.history.map(\.id), ["one", "two"])

        harness.service.resolveDelete(at: 0, result: .success(()))
        await task.value

        XCTAssertEqual(harness.service.deleteRequests, ["one"])
        XCTAssertEqual(harness.viewModel.history.map(\.id), ["two"])
        XCTAssertFalse(harness.viewModel.deletingEntryIDs.contains("one"))
        XCTAssertEqual(harness.logger.events.last?.outcome, .succeeded)
    }

    func testDeleteFailureKeepsEntryAndIsRetryable() async {
        let entry = pr11bHistoryEntry(id: "one", readAt: 1)
        let harness = makeViewModel(history: [entry])
        harness.service.deleteResponses = [
            .immediate(.failure(CategoryHistoryTestFailure.expected)),
            .immediate(.success(()))
        ]

        await harness.viewModel.deleteEntry(id: "one")

        XCTAssertEqual(harness.viewModel.history.map(\.id), ["one"])
        XCTAssertEqual(harness.viewModel.failure, .historyDeleteFailed)
        XCTAssertEqual(harness.messages.messages, [.historyDeleteFailed])

        await harness.viewModel.deleteEntry(id: "one")
        XCTAssertTrue(harness.viewModel.history.isEmpty)
    }

    func testDuplicateSameEntryDeleteIsSuppressedWhileOtherEntryCanProceed() async {
        let one = pr11bHistoryEntry(id: "one", readAt: 2)
        let two = pr11bHistoryEntry(id: "two", readAt: 1)
        let harness = makeViewModel(history: [one, two])
        harness.service.deleteResponses = [.suspended, .immediate(.success(()))]

        let first = Task { await harness.viewModel.deleteEntry(id: "one") }
        await waitUntil { harness.service.pendingDeleteCount == 1 }
        await harness.viewModel.deleteEntry(id: "one")
        await harness.viewModel.deleteEntry(id: "two")

        XCTAssertEqual(harness.service.deleteRequests, ["one", "two"])
        XCTAssertEqual(harness.viewModel.history.map(\.id), ["one"])

        harness.service.resolveDelete(at: 0, result: .success(()))
        await first.value
        XCTAssertTrue(harness.viewModel.history.isEmpty)
    }

    func testDeleteCleanupDoesNotOverwriteNewerExternalPublication() async {
        let one = pr11bHistoryEntry(id: "one", readAt: 2)
        let two = pr11bHistoryEntry(id: "two", readAt: 1)
        let newer = pr11bHistoryEntry(id: "newer", readAt: 3)
        let harness = makeViewModel(history: [one, two])
        harness.service.deleteResponses = [.suspended]

        let task = Task { await harness.viewModel.deleteEntry(id: "one") }
        await waitUntil { harness.service.pendingDeleteCount == 1 }
        harness.service.publish([newer, one, two])
        harness.service.resolveDelete(at: 0, result: .success(()))
        await task.value

        XCTAssertEqual(harness.viewModel.history.map(\.id), ["newer", "two"])
    }

    func testClearAwaitsPublicationThenTransitionsToEmpty() async {
        let harness = makeViewModel(
            history: [
                pr11bHistoryEntry(id: "one", readAt: 2),
                pr11bHistoryEntry(id: "two", readAt: 1)
            ]
        )
        harness.service.clearResponses = [.suspended]

        let task = Task { await harness.viewModel.clearHistory() }
        await waitUntil { harness.service.pendingClearCount == 1 }
        XCTAssertEqual(harness.viewModel.phase, .content)

        harness.service.resolveClear(at: 0, result: .success(()))
        await task.value

        XCTAssertEqual(harness.service.clearRequestCount, 1)
        XCTAssertEqual(harness.viewModel.phase, .empty)
        XCTAssertFalse(harness.viewModel.isClearVisible)
    }

    func testClearRequiresConfirmationBeforeWriting() async {
        let harness = makeViewModel(history: [pr11bHistoryEntry(id: "one", readAt: 1)])

        harness.viewModel.requestClear()
        XCTAssertTrue(harness.viewModel.isClearConfirmationPresented)
        XCTAssertEqual(harness.service.clearRequestCount, 0)

        harness.viewModel.cancelClear()
        XCTAssertFalse(harness.viewModel.isClearConfirmationPresented)
        XCTAssertEqual(harness.service.clearRequestCount, 0)
        XCTAssertEqual(harness.viewModel.phase, .content)

        harness.viewModel.requestClear()
        await harness.viewModel.confirmClear()

        XCTAssertFalse(harness.viewModel.isClearConfirmationPresented)
        XCTAssertEqual(harness.service.clearRequestCount, 1)
        XCTAssertEqual(harness.viewModel.phase, .empty)
    }

    func testRequestClearIsIgnoredWithoutHistory() {
        let harness = makeViewModel()

        harness.viewModel.requestClear()

        XCTAssertFalse(harness.viewModel.isClearConfirmationPresented)
    }

    func testClearFailureRetainsHistoryIsRetryableAndSuppressesDuplicate() async {
        let entry = pr11bHistoryEntry(id: "one", readAt: 1)
        let harness = makeViewModel(history: [entry])
        harness.service.clearResponses = [.suspended, .immediate(.success(()))]

        let first = Task { await harness.viewModel.clearHistory() }
        await waitUntil { harness.service.pendingClearCount == 1 }
        await harness.viewModel.clearHistory()
        XCTAssertEqual(harness.service.clearRequestCount, 1)

        harness.service.resolveClear(
            at: 0,
            result: .failure(CategoryHistoryTestFailure.expected)
        )
        await first.value

        XCTAssertEqual(harness.viewModel.history.map(\.id), ["one"])
        XCTAssertEqual(harness.viewModel.failure, .historyClearFailed)
        XCTAssertEqual(harness.messages.messages, [.historyClearFailed])
        XCTAssertFalse(harness.viewModel.isClearing)

        await harness.viewModel.clearHistory()
        XCTAssertTrue(harness.viewModel.history.isEmpty)
    }

    func testFailedOperationCleanupDoesNotOverwriteExternalHistory() async {
        let original = pr11bHistoryEntry(id: "original", readAt: 1)
        let external = pr11bHistoryEntry(id: "external", readAt: 2)
        let harness = makeViewModel(history: [original])
        harness.service.deleteResponses = [.suspended]

        let task = Task { await harness.viewModel.deleteEntry(id: "original") }
        await waitUntil { harness.service.pendingDeleteCount == 1 }
        harness.service.publish([external, original])
        harness.service.resolveDelete(
            at: 0,
            result: .failure(CategoryHistoryTestFailure.expected)
        )
        await task.value

        XCTAssertEqual(harness.viewModel.history.map(\.id), ["external", "original"])
        XCTAssertEqual(harness.viewModel.failure, .historyDeleteFailed)
    }

    func testUnknownDeleteAndEmptyClearPerformNoWrites() async {
        let harness = makeViewModel()

        await harness.viewModel.deleteEntry(id: "missing")
        await harness.viewModel.clearHistory()

        XCTAssertTrue(harness.service.deleteRequests.isEmpty)
        XCTAssertEqual(harness.service.clearRequestCount, 0)
    }

    private func makeViewModel(history: [HistoryEntry] = []) -> (
        viewModel: HistoryViewModel,
        service: HistoryServiceFake,
        messages: CategoryHistoryMessageSpy,
        logger: CategoryHistoryPresentationLogSpy
    ) {
        let service = HistoryServiceFake(history: history)
        let messages = CategoryHistoryMessageSpy()
        let logger = CategoryHistoryPresentationLogSpy()
        return (
            HistoryViewModel(
                historyService: service,
                messagePresenter: messages,
                presentationLogger: logger
            ),
            service,
            messages,
            logger
        )
    }
}
