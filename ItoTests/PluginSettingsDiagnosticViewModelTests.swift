import Combine
import XCTest
import ito_runner
@testable import Ito

@MainActor
extension PluginSettingsViewModelTests {
    func testRichFormIssuesFollowVisibilityAndUnsavedSecretActionStaysUnpersisted() async throws {
        let store = PR7BSettingsStoreSpy()
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.inspectResult = PluginSettingsInspection(actions: [], issues: [
            SettingIssue(key: "credential", message: "Credential issue"),
            SettingIssue(key: "unknown", message: "Form issue")
        ])
        let toggle = Control(
            id: "enabled", title: "Enabled", summary: nil, flags: 0, visibleWhen: [],
            kind: .toggle(ToggleControl(defaultValue: false))
        )
        let secret = Control(
            id: "credential", title: "Credential", summary: nil, flags: 0,
            visibleWhen: [ControlCondition(control: "enabled", anyOf: ["true"])],
            kind: .secret(SecretControl(placeholder: nil))
        )
        let viewModel = PluginSettingsViewModel(
            plugin: pr7bPlugin(),
            surface: .form(SettingsForm(sections: [
                ControlSection(id: "rich", title: "Rich", summary: nil, flags: [.page], controls: [toggle, secret])
            ])),
            settingsStore: store, messagePresenter: PR7BMessagePresenterSpy(), diagnostics: diagnostics
        )
        let inspected = expectation(description: "rich form inspected")
        let observation = diagnostics.inspectCountPublisher.filter { $0 >= 1 }
            .flatMap { _ in viewModel.$isInspecting.filter { !$0 } }
            .first().sink { _ in inspected.fulfill() }
        await viewModel.loadIfNeeded()
        await fulfillment(of: [inspected], timeout: 2)
        withExtendedLifetime(observation) {}
        XCTAssertTrue(viewModel.issuesBySettingKey.isEmpty)
        XCTAssertEqual(viewModel.formLevelIssues, ["Credential issue", "Form issue"])
        XCTAssertTrue(viewModel.persistControlValue(.toggle(true), for: toggle))
        XCTAssertEqual(viewModel.issuesBySettingKey["credential"], ["Credential issue"])
        XCTAssertEqual(viewModel.formLevelIssues, ["Form issue"])

        viewModel.updateSecretDraft(key: "credential", value: "unsaved-test-credential")
        let finished = expectation(description: "rich action finished")
        let actionObservation = diagnostics.runCountPublisher.filter { $0 >= 1 }
            .flatMap { _ in viewModel.$runningActionID.filter { $0 == nil } }
            .first().sink { _ in finished.fulfill() }
        viewModel.runAction("check")
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(actionObservation) {}
        XCTAssertEqual(diagnostics.runCalls.first?.secretDrafts["credential"], "unsaved-test-credential")
        XCTAssertNil(store.values["credential"])
        XCTAssertNil(store.secrets["credential"])
        viewModel.cancel()
    }

    func testInspectRunsOnPreparationAndPublishesActionsAndIssues() async throws {
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.inspectResult = PluginSettingsInspection(
            actions: [SettingsAction(id: "ping", title: "Ping Server", summary: "Check latency")],
            issues: [SettingIssue(key: "api_key", message: "API key is required")]
        )
        let schema = try pr7bSettingsSchema(settings: [.secret(id: "api_key", name: "Key", summary: nil)])
        let viewModel = makeViewModel(schema: schema, diagnostics: diagnostics)

        var cancellables = Set<AnyCancellable>()
        let inspected = expectation(description: "inspected")
        diagnostics.inspectCountPublisher
            .filter { $0 >= 1 }
            .flatMap { _ in viewModel.$isInspecting.filter { !$0 } }
            .first()
            .sink { _ in inspected.fulfill() }
            .store(in: &cancellables)

        await viewModel.loadIfNeeded()
        await fulfillment(of: [inspected], timeout: 2.0)

        XCTAssertEqual(diagnostics.inspectCallCount, 1)
        XCTAssertEqual(viewModel.actions.map(\.id), ["ping"])
        XCTAssertEqual(viewModel.issuesBySettingKey["api_key"], ["API key is required"])
        XCTAssertEqual(viewModel.formLevelIssues, [])
        XCTAssertFalse(viewModel.isInspecting)
        XCTAssertNil(viewModel.inspectError)
    }

    func testActionUsesUnsavedSecretDraftsWithoutPersisting() async throws {
        let store = PR7BSettingsStoreSpy()
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.runResult = "Latency: 42ms"
        let schema = try pr7bSettingsSchema(settings: [.secret(id: "api_key", name: "Key", summary: nil)])
        let viewModel = makeViewModel(schema: schema, store: store, diagnostics: diagnostics)
        await viewModel.loadIfNeeded()

        viewModel.updateSecretDraft(key: "api_key", value: "unsaved_draft_value")
        XCTAssertEqual(viewModel.secretDraft(key: "api_key"), "unsaved_draft_value")
        XCTAssertFalse(viewModel.hasSecret(key: "api_key"))
        XCTAssertTrue(store.writes.isEmpty)

        var cancellables = Set<AnyCancellable>()
        let actionFinished = expectation(description: "actionFinished")
        diagnostics.runCountPublisher
            .filter { $0 >= 1 }
            .flatMap { _ in viewModel.$runningActionID.filter { $0 == nil } }
            .first()
            .sink { _ in actionFinished.fulfill() }
            .store(in: &cancellables)

        viewModel.runAction("ping")
        await fulfillment(of: [actionFinished], timeout: 2.0)

        XCTAssertEqual(diagnostics.runCallCount, 1)
        XCTAssertEqual(diagnostics.runCalls[0].actionID, "ping")
        XCTAssertEqual(diagnostics.runCalls[0].secretDrafts["api_key"], "unsaved_draft_value")
        XCTAssertNotNil(viewModel.actionSuccessMessage)
        XCTAssertNil(viewModel.actionErrorMessage)

        // Prove no persistence occurred from running the action with drafts
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertFalse(viewModel.hasSecret(key: "api_key"))
    }

    func testPersistingSecretClearsOnlyThatSecretDraftOnSuccess() async throws {
        let store = PR7BSettingsStoreSpy()
        let schema = try pr7bSettingsSchema(settings: [
            .secret(id: "sec1", name: "Secret 1", summary: nil),
            .secret(id: "sec2", name: "Secret 2", summary: nil)
        ])
        let viewModel = makeViewModel(schema: schema, store: store)
        await viewModel.loadIfNeeded()

        viewModel.updateSecretDraft(key: "sec1", value: "draft1")
        viewModel.updateSecretDraft(key: "sec2", value: "draft2")

        XCTAssertTrue(viewModel.persistSecret(key: "sec1", value: "draft1"))
        XCTAssertEqual(viewModel.secretDraft(key: "sec1"), "")
        XCTAssertEqual(viewModel.secretDraft(key: "sec2"), "draft2")

        // Clear secret also clears its draft
        XCTAssertTrue(viewModel.clearSecret(key: "sec2"))
        XCTAssertEqual(viewModel.secretDraft(key: "sec2"), "")
    }

    func testSavingIsNonBlockingAndSavesUnaffectedByValidation() async throws {
        let store = PR7BSettingsStoreSpy()
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.suspendsInspect = true
        let schema = try pr7bSettingsSchema(settings: [.text(id: "name", name: "Name", summary: nil, defaultValue: "")])
        let viewModel = makeViewModel(schema: schema, store: store, diagnostics: diagnostics)

        var cancellables = Set<AnyCancellable>()
        let inspectStarted = expectation(description: "inspectStarted")
        diagnostics.inspectCountPublisher
            .filter { $0 >= 1 }
            .first()
            .sink { _ in inspectStarted.fulfill() }
            .store(in: &cancellables)

        await viewModel.loadIfNeeded()
        await fulfillment(of: [inspectStarted], timeout: 2.0)
        XCTAssertTrue(viewModel.isInspecting)

        // Save occurs immediately despite validation in-flight
        XCTAssertTrue(viewModel.persistValue(key: "name", value: "new_value"))
        XCTAssertEqual(store.writes.map(\.value), ["new_value"])
        XCTAssertNil(viewModel.persistenceError)

        diagnostics.resumeInspect()
    }

    func testInspectionCoalescesWhileInFlightAndLatestWins() async throws {
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.suspendsInspect = true
        let schema = try pr7bSettingsSchema(settings: [.secret(id: "key", name: "Key", summary: nil)])
        let viewModel = makeViewModel(schema: schema, diagnostics: diagnostics)

        var cancellables = Set<AnyCancellable>()
        let firstInspectStarted = expectation(description: "firstInspectStarted")
        diagnostics.inspectCountPublisher
            .filter { $0 >= 1 }
            .first()
            .sink { _ in firstInspectStarted.fulfill() }
            .store(in: &cancellables)

        await viewModel.loadIfNeeded()
        await fulfillment(of: [firstInspectStarted], timeout: 2.0)
        XCTAssertTrue(viewModel.isInspecting)

        // Make multiple draft changes while first inspect is in flight
        viewModel.updateSecretDraft(key: "key", value: "intermediate1")
        viewModel.updateSecretDraft(key: "key", value: "latest_draft")

        // Verify only 1 call happened so far (coalescing)
        XCTAssertEqual(diagnostics.inspectCallCount, 1)

        let secondInspectStarted = expectation(description: "secondInspectStarted")
        diagnostics.inspectCountPublisher
            .filter { $0 >= 2 }
            .first()
            .sink { _ in secondInspectStarted.fulfill() }
            .store(in: &cancellables)

        // Resume the first inspect with stale issues
        diagnostics.inspectResult = PluginSettingsInspection(actions: [], issues: [SettingIssue(key: "key", message: "stale issue")])
        diagnostics.resumeInspect()

        // A second inspect task begins with the latest drafts
        await fulfillment(of: [secondInspectStarted], timeout: 2.0)
        XCTAssertEqual(diagnostics.inspectCalls[1].secretDrafts["key"], "latest_draft")

        let secondInspectFinished = expectation(description: "secondInspectFinished")
        viewModel.$isInspecting
            .filter { !$0 }
            .first()
            .sink { _ in secondInspectFinished.fulfill() }
            .store(in: &cancellables)

        diagnostics.inspectResult = PluginSettingsInspection(actions: [], issues: [SettingIssue(key: "key", message: "latest issue")])
        diagnostics.resumeInspect()

        await fulfillment(of: [secondInspectFinished], timeout: 2.0)
        XCTAssertEqual(viewModel.issuesBySettingKey["key"], ["latest issue"])
    }

    func testSingleFlightActionPreventsConcurrentRuns() async throws {
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.suspendsRun = true
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), diagnostics: diagnostics)
        await viewModel.loadIfNeeded()

        var cancellables = Set<AnyCancellable>()
        let actionStarted = expectation(description: "actionStarted")
        diagnostics.runCountPublisher
            .filter { $0 >= 1 }
            .first()
            .sink { _ in actionStarted.fulfill() }
            .store(in: &cancellables)

        viewModel.runAction("action1")
        await fulfillment(of: [actionStarted], timeout: 2.0)
        XCTAssertEqual(viewModel.runningActionID, "action1")

        // Attempt second action while first is running
        viewModel.runAction("action2")
        XCTAssertEqual(diagnostics.runCallCount, 1)
        XCTAssertEqual(viewModel.runningActionID, "action1")

        let actionFinished = expectation(description: "actionFinished")
        viewModel.$runningActionID
            .filter { $0 == nil }
            .first()
            .sink { _ in actionFinished.fulfill() }
            .store(in: &cancellables)

        diagnostics.resumeRun()
        await fulfillment(of: [actionFinished], timeout: 2.0)
    }

    func testCancelSuppressesLateActionAndInspectionResults() async throws {
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.suspendsInspect = true
        diagnostics.suspendsRun = true
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), diagnostics: diagnostics)

        var cancellables = Set<AnyCancellable>()
        let inspectStarted = expectation(description: "inspectStarted")
        diagnostics.inspectCountPublisher
            .filter { $0 >= 1 }
            .first()
            .sink { _ in inspectStarted.fulfill() }
            .store(in: &cancellables)

        await viewModel.loadIfNeeded()
        await fulfillment(of: [inspectStarted], timeout: 2.0)

        let runStarted = expectation(description: "runStarted")
        diagnostics.runCountPublisher
            .filter { $0 >= 1 }
            .first()
            .sink { _ in runStarted.fulfill() }
            .store(in: &cancellables)

        viewModel.runAction("action1")
        await fulfillment(of: [runStarted], timeout: 2.0)

        // Dismissal / cancel
        viewModel.cancel()

        // Resuming late results does not pollute view model
        diagnostics.inspectResult = PluginSettingsInspection(actions: [SettingsAction(id: "late", title: "Late")], issues: [])
        diagnostics.runResult = "Late result"

        let actionUnwound = expectation(description: "actionUnwound")
        viewModel.$runningActionID
            .filter { $0 == nil }
            .first()
            .sink { _ in actionUnwound.fulfill() }
            .store(in: &cancellables)

        diagnostics.resumeInspect()
        diagnostics.resumeRun()
        await fulfillment(of: [actionUnwound], timeout: 2.0)

        XCTAssertTrue(viewModel.actions.isEmpty)
        XCTAssertNil(viewModel.actionSuccessMessage)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    func testInlineAndFormLevelIssuesHandlingWithUnknownAndDuplicateKeys() async throws {
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.inspectResult = PluginSettingsInspection(
            actions: [
                SettingsAction(id: "act1", title: "Action 1"),
                SettingsAction(id: "act1", title: "Action 1 Duplicate")
            ],
            issues: [
                SettingIssue(key: "username", message: "Username error 1"),
                SettingIssue(key: "username", message: "Username error 2"),
                SettingIssue(key: "", message: "Global error 1"),
                SettingIssue(key: "   ", message: "Global error 2"),
                SettingIssue(key: "non_existent_field", message: "Unknown field error")
            ]
        )
        let schema = try pr7bSettingsSchema(settings: [.text(id: "username", name: "User", summary: nil, defaultValue: "")])
        let viewModel = makeViewModel(schema: schema, diagnostics: diagnostics)

        var cancellables = Set<AnyCancellable>()
        let inspected = expectation(description: "inspected")
        diagnostics.inspectCountPublisher
            .filter { $0 >= 1 }
            .flatMap { _ in viewModel.$isInspecting.filter { !$0 } }
            .first()
            .sink { _ in inspected.fulfill() }
            .store(in: &cancellables)

        await viewModel.loadIfNeeded()
        await fulfillment(of: [inspected], timeout: 2.0)

        // Deduplication of actions by id
        XCTAssertEqual(viewModel.actions.count, 1)
        XCTAssertEqual(viewModel.actions[0].id, "act1")

        // Inline issues grouped by key without duplicate-key trap
        XCTAssertEqual(viewModel.issuesBySettingKey["username"], ["Username error 1", "Username error 2"])

        // Empty, whitespace, or unknown keys collected into form-level issues
        XCTAssertEqual(
            viewModel.formLevelIssues,
            ["Global error 1", "Global error 2", "Unknown field error"]
        )
    }

    func testActionAndInspectErrorMappingProvidesSafeAndUsefulErrors() async throws {
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.runError = ItoError.wasmTrap("trap")
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), diagnostics: diagnostics)
        await viewModel.loadIfNeeded()

        var cancellables = Set<AnyCancellable>()
        let actionFinished = expectation(description: "actionFinished")
        diagnostics.runCountPublisher
            .filter { $0 >= 1 }
            .flatMap { _ in viewModel.$runningActionID.filter { $0 == nil } }
            .first()
            .sink { _ in actionFinished.fulfill() }
            .store(in: &cancellables)

        viewModel.runAction("failing_action")
        await fulfillment(of: [actionFinished], timeout: 2.0)

        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.actionSuccessMessage)
    }

    func testActionReturnsNilTreatedAsUnsupportedError() async throws {
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.runResult = nil // runner returns nil when action is unsupported/absent
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), diagnostics: diagnostics)
        await viewModel.loadIfNeeded()

        var cancellables = Set<AnyCancellable>()
        let actionFinished = expectation(description: "actionFinished")
        diagnostics.runCountPublisher
            .filter { $0 >= 1 }
            .flatMap { _ in viewModel.$runningActionID.filter { $0 == nil } }
            .first()
            .sink { _ in actionFinished.fulfill() }
            .store(in: &cancellables)

        viewModel.runAction("unsupported_action")
        await fulfillment(of: [actionFinished], timeout: 2.0)

        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.actionSuccessMessage)
    }

    func testActionReturnsEmptyStringUsesGenericSuccessFallback() async throws {
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.runResult = ""
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), diagnostics: diagnostics)
        await viewModel.loadIfNeeded()

        var cancellables = Set<AnyCancellable>()
        let actionFinished = expectation(description: "actionFinished")
        diagnostics.runCountPublisher
            .filter { $0 >= 1 }
            .flatMap { _ in viewModel.$runningActionID.filter { $0 == nil } }
            .first()
            .sink { _ in actionFinished.fulfill() }
            .store(in: &cancellables)

        viewModel.runAction("empty_action")
        await fulfillment(of: [actionFinished], timeout: 2.0)

        XCTAssertNotNil(viewModel.actionSuccessMessage)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    func testEditDuringActionSuppressesOldActionResultAndClearsPreviousMessages() async throws {
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.suspendsRun = true
        let schema = try pr7bSettingsSchema(settings: [.secret(id: "key", name: "Key", summary: nil)])
        let viewModel = makeViewModel(schema: schema, diagnostics: diagnostics)
        await viewModel.loadIfNeeded()

        var cancellables = Set<AnyCancellable>()
        let runStarted = expectation(description: "runStarted")
        diagnostics.runCountPublisher
            .filter { $0 >= 1 }
            .first()
            .sink { _ in runStarted.fulfill() }
            .store(in: &cancellables)

        viewModel.runAction("action1")
        await fulfillment(of: [runStarted], timeout: 2.0)

        // User edits secret draft while action is running
        viewModel.updateSecretDraft(key: "key", value: "new_secret")

        let actionFinished = expectation(description: "actionFinished")
        viewModel.$runningActionID
            .filter { $0 == nil }
            .first()
            .sink { _ in actionFinished.fulfill() }
            .store(in: &cancellables)

        diagnostics.runResult = "Stale Success"
        diagnostics.resumeRun()
        await fulfillment(of: [actionFinished], timeout: 2.0)

        // Result suppressed because input revision changed during action flight
        XCTAssertNil(viewModel.actionSuccessMessage)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    func testCancelRunningActionKeepsFlightSlotUntilUnwoundPreventingPrematureSecondRun() async throws {
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.suspendsRun = true
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), diagnostics: diagnostics)
        await viewModel.loadIfNeeded()

        var cancellables = Set<AnyCancellable>()
        let runStarted = expectation(description: "runStarted")
        diagnostics.runCountPublisher
            .filter { $0 >= 1 }
            .first()
            .sink { _ in runStarted.fulfill() }
            .store(in: &cancellables)

        viewModel.runAction("action1")
        await fulfillment(of: [runStarted], timeout: 2.0)
        XCTAssertEqual(viewModel.runningActionID, "action1")

        // Cancel action while noncooperative run is suspended
        viewModel.cancelRunningAction()

        // Second action attempt rejected because first action slot is still in-flight
        viewModel.runAction("action2")
        XCTAssertEqual(diagnostics.runCallCount, 1)
        XCTAssertEqual(viewModel.runningActionID, "action1")

        let firstRunFinished = expectation(description: "firstRunFinished")
        viewModel.$runningActionID
            .filter { $0 == nil }
            .first()
            .sink { _ in firstRunFinished.fulfill() }
            .store(in: &cancellables)

        // Now unwind the first run
        diagnostics.resumeRun()
        await fulfillment(of: [firstRunFinished], timeout: 2.0)

        let secondRunStarted = expectation(description: "secondRunStarted")
        diagnostics.runCountPublisher
            .filter { $0 >= 2 }
            .first()
            .sink { _ in secondRunStarted.fulfill() }
            .store(in: &cancellables)

        // Now a new action can run
        viewModel.runAction("action2")
        await fulfillment(of: [secondRunStarted], timeout: 2.0)
        diagnostics.resumeRun()
    }

    func testDismissalSuppressesStoreRevisionInspectionTrigger() async throws {
        let store = PR7BSettingsStoreSpy()
        let diagnostics = PR7BDiagnosticsSpy()
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), store: store, diagnostics: diagnostics)

        var cancellables = Set<AnyCancellable>()
        let initialInspectFinished = expectation(description: "initialInspectFinished")
        diagnostics.inspectCountPublisher
            .filter { $0 >= 1 }
            .flatMap { _ in viewModel.$isInspecting.filter { !$0 } }
            .first()
            .sink { _ in initialInspectFinished.fulfill() }
            .store(in: &cancellables)

        await viewModel.loadIfNeeded()
        await fulfillment(of: [initialInspectFinished], timeout: 2.0)

        // View dismissed
        viewModel.cancel()

        // Background store revision published after dismissal
        store.revision += 1

        // Verify no second inspection is triggered
        let invertedExpectation = expectation(description: "noSecondInspect")
        invertedExpectation.isInverted = true
        diagnostics.inspectCountPublisher
            .filter { $0 > 1 }
            .sink { _ in invertedExpectation.fulfill() }
            .store(in: &cancellables)

        await fulfillment(of: [invertedExpectation], timeout: 0.1)
        XCTAssertEqual(diagnostics.inspectCallCount, 1)
    }

    func testReappearanceOldFinishDoesNotClobberNewFlight() async throws {
        let diagnostics = PR7BDiagnosticsSpy()
        diagnostics.suspendsInspect = true
        let viewModel = makeViewModel(schema: try pr7bSettingsSchema(), diagnostics: diagnostics)

        var cancellables = Set<AnyCancellable>()
        let firstInspectStarted = expectation(description: "firstInspectStarted")
        diagnostics.inspectCountPublisher
            .filter { $0 >= 1 }
            .first()
            .sink { _ in firstInspectStarted.fulfill() }
            .store(in: &cancellables)

        await viewModel.loadIfNeeded()
        await fulfillment(of: [firstInspectStarted], timeout: 2.0)

        // Dismiss screen while first inspect is suspended
        viewModel.cancel()

        // Reappear
        diagnostics.inspectResult = PluginSettingsInspection(
            actions: [SettingsAction(id: "new_act", title: "New Action")],
            issues: []
        )

        let secondInspectStarted = expectation(description: "secondInspectStarted")
        diagnostics.inspectCountPublisher
            .filter { $0 >= 2 }
            .first()
            .sink { _ in secondInspectStarted.fulfill() }
            .store(in: &cancellables)

        let secondLoad = Task { await viewModel.loadIfNeeded() }

        // Resume old inspect callback
        diagnostics.resumeInspect()

        // New inspect completes
        await fulfillment(of: [secondInspectStarted], timeout: 2.0)

        let secondInspectFinished = expectation(description: "secondInspectFinished")
        viewModel.$isInspecting
            .filter { !$0 }
            .first()
            .sink { _ in secondInspectFinished.fulfill() }
            .store(in: &cancellables)

        diagnostics.resumeInspect()
        await secondLoad.value
        await fulfillment(of: [secondInspectFinished], timeout: 2.0)

        // Proves new flight state remains authoritative and wasn't clobbered by old callback
        XCTAssertEqual(viewModel.actions.map(\.id), ["new_act"])
    }

}

@MainActor
private final class PR7BDiagnosticsSpy: PluginSettingsDiagnosing {
    struct InspectCall: Sendable {
        let pluginID: String
        let surface: SettingsSurface
        let secretDrafts: [String: String]
    }

    struct RunCall: Sendable {
        let pluginID: String
        let surface: SettingsSurface
        let secretDrafts: [String: String]
        let actionID: String
    }

    private(set) var inspectCalls: [InspectCall] = []
    private(set) var runCalls: [RunCall] = []
    private let inspectSubject = CurrentValueSubject<Int, Never>(0)
    private let runSubject = CurrentValueSubject<Int, Never>(0)

    var inspectCountPublisher: AnyPublisher<Int, Never> {
        inspectSubject.eraseToAnyPublisher()
    }

    var runCountPublisher: AnyPublisher<Int, Never> {
        runSubject.eraseToAnyPublisher()
    }

    var inspectResult = PluginSettingsInspection(actions: [], issues: nil)
    var inspectError: (any Error)?
    var suspendsInspect = false
    private var inspectContinuation: CheckedContinuation<Void, Never>?

    var runResult: String?
    var runError: (any Error)?
    var suspendsRun = false
    private var runContinuation: CheckedContinuation<Void, Never>?

    var inspectCallCount: Int { inspectCalls.count }
    var runCallCount: Int { runCalls.count }

    func inspect(
        pluginID: String,
        surface: SettingsSurface,
        secretDrafts: [String: String]
    ) async throws -> PluginSettingsInspection {
        inspectCalls.append(InspectCall(pluginID: pluginID, surface: surface, secretDrafts: secretDrafts))
        inspectSubject.send(inspectCalls.count)
        if suspendsInspect {
            await withCheckedContinuation { inspectContinuation = $0 }
        }
        if let inspectError { throw inspectError }
        return inspectResult
    }

    func run(
        pluginID: String,
        surface: SettingsSurface,
        secretDrafts: [String: String],
        actionID: String
    ) async throws -> String? {
        runCalls.append(RunCall(pluginID: pluginID, surface: surface, secretDrafts: secretDrafts, actionID: actionID))
        runSubject.send(runCalls.count)
        if suspendsRun {
            await withCheckedContinuation { runContinuation = $0 }
        }
        if let runError { throw runError }
        return runResult
    }

    func resumeInspect() {
        inspectContinuation?.resume()
        inspectContinuation = nil
    }

    func resumeRun() {
        runContinuation?.resume()
        runContinuation = nil
    }
}
