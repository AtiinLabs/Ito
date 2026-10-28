import Combine
import Foundation
import ito_runner

@MainActor
final class PluginSettingsViewModel: ObservableObject {
    let plugin: InstalledPlugin
    let surface: SettingsSurface
    let presentation: PluginSettingsPresentation

    @Published private(set) var isPrepared = false
    @Published private(set) var isLoading = false
    @Published private(set) var isReloading = false
    @Published private(set) var loadError: String?
    @Published private(set) var reloadError: String?
    @Published private(set) var persistenceError: String?
    @Published private(set) var bindingRevision = 0
    @Published private(set) var completionSummary: PluginCompletionSummary?
    @Published private(set) var completionRecoveryError: String?
    @Published private(set) var isRecoveringCompletion = false
    @Published private(set) var completionRecoveryRequest: CompletionRecoveryAction?

    // Diagnostics: actions and validation
    @Published private(set) var actions: [SettingsAction] = []
    @Published private var inspectionIssues: [SettingIssue] = []

    var issuesBySettingKey: [String: [String]] {
        let visible = Set(visibleSections.flatMap(\.controls).map(\.id))
        return inspectionIssues.reduce(into: [:]) { result, issue in
            if !issue.key.isEmpty && visible.contains(issue.key) {
                result[issue.key, default: []].append(issue.message)
            }
        }
    }

    var formLevelIssues: [String] {
        let visible = Set(visibleSections.flatMap(\.controls).map(\.id))
        return inspectionIssues.filter { $0.key.isEmpty || !visible.contains($0.key) }.map(\.message)
    }
    @Published private(set) var isInspecting = false
    @Published private(set) var inspectError: String?
    @Published private(set) var runningActionID: String?
    @Published private(set) var actionSuccessMessage: String?
    @Published private(set) var actionErrorMessage: String?

    private let settingsStore: any PluginSettingsPersisting
    private let messagePresenter: any SourceMessagePresenting
    private let completionRecovery: (any PluginCompletionRecovering)?
    private let diagnostics: (any PluginSettingsDiagnosing)?
    private let runnerProvider: (any SourceRunnerProviding)?

    private var secretDrafts: [String: String] = [:]
    private var optionCatalogModels: [String: OptionCatalogModel] = [:]
    private var isActive = true
    private var inputRevision: UInt64 = 0
    private var loadOperationID: UUID?
    private var reloadOperationID: UUID?
    private var reloadTask: Task<Void, Never>?

    private var inspectTask: Task<Void, Never>?
    private var currentInspectFlightID: UUID?
    private var inspectResultGeneration: UInt64 = 0
    private var needsInspectionAfterCurrent = false

    private var actionTask: Task<Void, Never>?
    private var currentActionFlightID: UUID?
    private var actionResultGeneration: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()
    init(
        plugin: InstalledPlugin,
        surface: SettingsSurface,
        runnerProvider: (any SourceRunnerProviding)? = nil,
        settingsStore: any PluginSettingsPersisting,
        messagePresenter: any SourceMessagePresenting,
        completionRecovery: (any PluginCompletionRecovering)? = nil,
        diagnostics: (any PluginSettingsDiagnosing)? = nil
    ) {
        self.plugin = plugin
        self.surface = surface
        self.presentation = PluginSettingsPresentation(surface: surface)
        self.runnerProvider = runnerProvider
        self.settingsStore = settingsStore
        self.messagePresenter = messagePresenter
        self.completionRecovery = completionRecovery
        self.diagnostics = diagnostics

        settingsStore.settingsRevisionPublisher
            .sink { @MainActor [weak self] revision in
                guard let self else { return }
                self.bindingRevision = revision
                self.handleInputChanged()
            }
            .store(in: &cancellables)
        completionRecovery?.completionSummariesPublisher
            .sink { @MainActor [weak self] summaries in
                guard let self else { return }
                self.completionSummary = summaries.first { $0.pluginID == self.plugin.id }
            }
            .store(in: &cancellables)
    }

    deinit {
        reloadTask?.cancel()
        inspectTask?.cancel()
        actionTask?.cancel()
    }

    func loadIfNeeded() async {
        isActive = true
        guard !isLoading else { return }
        if !isPrepared {
            await load()
        } else {
            triggerInspection()
        }
    }

    func load() async {
        let operationID = UUID()
        loadOperationID = operationID
        isLoading = true
        loadError = nil
        do {
            try settingsStore.prepareSettings(pluginID: plugin.id)
            guard loadOperationID == operationID else { return }
            isPrepared = true
            isLoading = false
            loadOperationID = nil
            await reload()
        } catch {
            guard loadOperationID == operationID else { return }
            let reason = error.localizedDescription
            isPrepared = false
            isLoading = false
            loadError = reason
            loadOperationID = nil
            messagePresenter.present(
                .settingsLoadFailed(pluginName: plugin.info.name, reason: reason)
            )
        }
    }

    func reload() async {
        let task = startReload()
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult
    private func startReload() -> Task<Void, Never> {
        reloadTask?.cancel()
        let operationID = UUID()
        reloadOperationID = operationID
        isReloading = true
        reloadError = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await settingsStore.reloadPersistedSettings()
                try Task.checkCancellation()
                guard reloadOperationID == operationID else { return }
                isReloading = false
                reloadError = nil
                finishReload(operationID)
            } catch is CancellationError {
                guard reloadOperationID == operationID else { return }
                isReloading = false
                finishReload(operationID)
            } catch {
                guard reloadOperationID == operationID, !Task.isCancelled else { return }
                let reason = error.localizedDescription
                isReloading = false
                reloadError = reason
                messagePresenter.present(
                    .settingsReloadFailed(pluginName: plugin.info.name, reason: reason)
                )
                finishReload(operationID)
            }
        }
        reloadTask = task
        return task
    }

    func storedValue(key: String) -> String? {
        _ = bindingRevision
        return settingsStore.storedValue(pluginID: plugin.id, key: key)
    }

    @discardableResult
    func persistValue(key: String, value: String) -> Bool {
        let succeeded = finishPersistence(settingsStore.persistValue(pluginID: plugin.id, key: key, value: value))
        if succeeded {
            handleInputChanged()
        }
        return succeeded
    }
    func effectiveValue(for control: Control) -> ControlValue? {
        control.effectiveValue(stored: storedValue(key: control.id)).value
    }

    func persistControlValue(_ value: ControlValue, for control: Control) -> Bool {
        guard control.kind.accepts(value) else { return false }
        return persistValue(key: control.id, value: ControlValueCodec.canonical(value))
    }

    @discardableResult
    func resetControl(_ control: Control) -> Bool {
        let succeeded = settingsStore.removeValue(pluginID: plugin.id, key: control.id)
        let saved = finishPersistence(succeeded)
        if saved { handleInputChanged() }
        return saved
    }

    func optionCatalog(for control: Control, debounceNanoseconds: UInt64 = 250_000_000) -> OptionCatalogModel? {
        let source: OptionSource?
        switch control.kind {
        case .select(let spec): source = spec.options
        case .multiSelect(let spec): source = spec.options
        default: source = nil
        }
        guard case let .catalog(catalog)? = source,
              let runnerProvider else { return nil }
        if let existing = optionCatalogModels[control.id] { return existing }
        let model = OptionCatalogModel(
            catalog: catalog,
            runnerProvider: runnerProvider,
            pluginID: plugin.id,
            debounceNanoseconds: debounceNanoseconds
        )
        optionCatalogModels[control.id] = model
        return model
    }

    var visibleSections: [PluginSettingsPresentation.Section] {
        let visible = presentation.visibleControlIDs { control in
            effectiveValue(for: control)
        }
        return presentation.sections.compactMap { section in
            let controls = section.controls.filter { visible.contains($0.id) }
            guard !controls.isEmpty else { return nil }
            return PluginSettingsPresentation.Section(
                id: section.id,
                title: section.title,
                summary: section.summary,
                isPage: section.isPage,
                controls: controls
            )
        }
    }

    var completionPresentation: CompletionPresentation? {
        guard let summary = completionSummary,
              summary.pendingCount > 0 || summary.pausedCount > 0 else { return nil }
        let reasons = PluginCompletionPauseReason.allCases
            .filter { summary.pauseReasons.contains($0) }
            .map(\.recoveryDescription)
        return CompletionPresentation(
            pendingCount: summary.pendingCount,
            pausedCount: summary.pausedCount,
            pauseReasons: summary.pausedCount > 0 ? reasons : []
        )
    }

    /// Asks for confirmation. Nothing is sent or deleted until `confirmCompletionRecovery()`.
    func requestCompletionRecovery(_ action: CompletionRecoveryAction) {
        guard completionRecovery != nil, !isRecoveringCompletion,
              (completionSummary?.pausedCount ?? 0) > 0 else { return }
        completionRecoveryError = nil
        completionRecoveryRequest = action
    }

    func cancelCompletionRecoveryRequest() {
        completionRecoveryRequest = nil
    }

    /// Captures the confirmed action synchronously (the confirmation UI dismisses and clears the
    /// request right after the button fires) and runs it to completion even if settings close.
    @discardableResult
    func confirmCompletionRecovery() -> Task<Void, Never>? {
        guard let action = completionRecoveryRequest, let recovery = completionRecovery,
              !isRecoveringCompletion else { return nil }
        completionRecoveryRequest = nil
        guard (completionSummary?.pausedCount ?? 0) > 0 else { return nil }
        isRecoveringCompletion = true
        completionRecoveryError = nil
        let pluginID = plugin.id
        return Task { @MainActor [weak self] in
            var failed = false
            do {
                switch action {
                case .reauthorize:
                    try await recovery.reauthorize(pluginID: pluginID)
                case .discard:
                    try await recovery.discard(pluginID: pluginID)
                }
            } catch is CancellationError {
                // Cancelled before any change; nothing to report.
            } catch {
                failed = true
            }
            guard let self else { return }
            isRecoveringCompletion = false
            if failed {
                completionRecoveryError = "The queued progress could not be updated. Try again."
            }
        }
    }

    func hasSecret(key: String) -> Bool {
        _ = bindingRevision
        return settingsStore.hasSecret(pluginID: plugin.id, key: key)
    }

    func secretDraft(key: String) -> String {
        secretDrafts[key] ?? ""
    }

    func updateSecretDraft(key: String, value: String) {
        if value.isEmpty {
            secretDrafts.removeValue(forKey: key)
        } else {
            secretDrafts[key] = value
        }
        handleInputChanged()
    }

    /// Saves a secret setting. Surrounding whitespace is dropped; an empty value saves nothing.
    @discardableResult
    func persistSecret(key: String, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let succeeded = finishPersistence(settingsStore.persistSecret(pluginID: plugin.id, key: key, value: trimmed))
        if succeeded {
            secretDrafts.removeValue(forKey: key)
            handleInputChanged()
        }
        return succeeded
    }

    @discardableResult
    func clearSecret(key: String) -> Bool {
        let succeeded = finishPersistence(settingsStore.clearSecret(pluginID: plugin.id, key: key))
        if succeeded {
            secretDrafts.removeValue(forKey: key)
            handleInputChanged()
        }
        return succeeded
    }

    private func finishPersistence(_ succeeded: Bool) -> Bool {
        guard succeeded else {
            persistenceError = "The setting could not be saved."
            messagePresenter.present(.settingsPersistenceFailed(pluginName: plugin.info.name))
            return false
        }
        persistenceError = nil
        scheduleReload()
        return true
    }
    func cancel() {
        isActive = false
        completionRecoveryRequest = nil
        loadOperationID = nil
        isLoading = false
        reloadOperationID = nil
        reloadTask?.cancel()
        reloadTask = nil
        isReloading = false

        inspectResultGeneration &+= 1
        inspectTask?.cancel()
        needsInspectionAfterCurrent = false

        actionResultGeneration &+= 1
        actionTask?.cancel()
        for model in optionCatalogModels.values { model.disappear() }
        optionCatalogModels.removeAll()
    }

    private func handleInputChanged() {
        inputRevision &+= 1
        actionSuccessMessage = nil
        actionErrorMessage = nil
        triggerInspection()
    }

    // MARK: - Diagnostics & Inspection

    func retryInspection() {
        inspectError = nil
        triggerInspection()
    }

    private func triggerInspection() {
        guard isActive, isPrepared, let diagnostics else { return }
        inspectResultGeneration &+= 1
        let expectedResultGen = inspectResultGeneration

        if isInspecting || currentInspectFlightID != nil {
            needsInspectionAfterCurrent = true
            return
        }

        startInspectionTask(resultGeneration: expectedResultGen, diagnostics: diagnostics)
    }

    private func startInspectionTask(resultGeneration: UInt64, diagnostics: any PluginSettingsDiagnosing) {
        let flightID = UUID()
        currentInspectFlightID = flightID
        isInspecting = true
        let capturedDrafts = secretDrafts
        let pluginID = plugin.id
        let surface = self.surface

        inspectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var inspectionResult: PluginSettingsInspection?
            var capturedError: (any Error)?

            do {
                try Task.checkCancellation()
                inspectionResult = try await diagnostics.inspect(
                    pluginID: pluginID,
                    surface: surface,
                    secretDrafts: capturedDrafts
                )
                try Task.checkCancellation()
            } catch is CancellationError {
                // Cancelled
            } catch {
                capturedError = error
            }

            // Check that this flight is still the active flight
            guard self.currentInspectFlightID == flightID else { return }

            // Only apply results if this task is not cancelled, active, and matching expected result generation
            if self.isActive, self.inspectResultGeneration == resultGeneration, !Task.isCancelled {
                if let inspectionResult {
                    self.inspectError = nil
                    self.applyInspection(inspectionResult)
                } else if let capturedError {
                    self.inspectError = Self.diagnosticErrorMessage(for: capturedError)
                }
            }

            self.finishInspectionCycle(flightID: flightID)
        }
    }

    private func finishInspectionCycle(flightID: UUID) {
        guard currentInspectFlightID == flightID else { return }
        currentInspectFlightID = nil
        isInspecting = false
        inspectTask = nil

        if needsInspectionAfterCurrent {
            needsInspectionAfterCurrent = false
            if isActive, isPrepared, let diagnostics {
                inspectResultGeneration &+= 1
                startInspectionTask(resultGeneration: inspectResultGeneration, diagnostics: diagnostics)
            }
        }
    }

    private func applyInspection(_ inspection: PluginSettingsInspection) {
        self.actions = deduplicateActions(inspection.actions)
        self.inspectionIssues = inspection.issues ?? []
    }

    private func deduplicateActions(_ rawActions: [SettingsAction]) -> [SettingsAction] {
        var seenIDs = Set<String>()
        var deduplicated: [SettingsAction] = []
        for action in rawActions {
            if seenIDs.insert(action.id).inserted {
                deduplicated.append(action)
            }
        }
        return deduplicated
    }

    // MARK: - Diagnostic Actions

    func runAction(_ actionID: String) {
        // Physical flight slot check: do not permit a second run until the in-flight slot unwinds
        guard isActive, runningActionID == nil, currentActionFlightID == nil, let diagnostics else { return }
        actionResultGeneration &+= 1
        let expectedResultGen = actionResultGeneration

        let flightID = UUID()
        currentActionFlightID = flightID
        runningActionID = actionID
        actionSuccessMessage = nil
        actionErrorMessage = nil

        let capturedDrafts = secretDrafts
        let capturedInputRev = inputRevision
        let pluginID = plugin.id
        let surface = self.surface

        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var result: String?
            var capturedError: (any Error)?

            do {
                try Task.checkCancellation()
                result = try await diagnostics.run(
                    pluginID: pluginID,
                    surface: surface,
                    secretDrafts: capturedDrafts,
                    actionID: actionID
                )
                try Task.checkCancellation()
            } catch is CancellationError {
                // Cancelled
            } catch {
                capturedError = error
            }

            // Verify that this is still the active flight
            guard self.currentActionFlightID == flightID else { return }

            if self.isActive,
               self.actionResultGeneration == expectedResultGen,
               self.inputRevision == capturedInputRev,
               !Task.isCancelled {
                if let capturedError {
                    self.actionErrorMessage = Self.diagnosticErrorMessage(for: capturedError)
                } else if let result {
                    // nil indicates unsupported / absent action in runner; non-nil is result string
                    self.actionSuccessMessage = result.isEmpty ? "Action completed successfully." : result
                } else {
                    self.actionErrorMessage = "This action is unsupported by the source."
                }
            }

            self.finishActionCycle(flightID: flightID)
        }
    }

    func cancelRunningAction() {
        actionResultGeneration &+= 1
        actionTask?.cancel()
        // Keep physical flight slot (currentActionFlightID and runningActionID) until task unwinds
    }

    private func finishActionCycle(flightID: UUID) {
        guard currentActionFlightID == flightID else { return }
        currentActionFlightID = nil
        runningActionID = nil
        actionTask = nil
    }

    static func diagnosticErrorMessage(for error: any Error) -> String {
        let wrapped = PluginCallError.wrapping(error)
        if let pluginCall = wrapped as? PluginCallError {
            return pluginCall.localizedDescription
        }
        return "An unknown error occurred while running the diagnostic."
    }

    private func scheduleReload() {
        startReload()
    }

    private func finishReload(_ operationID: UUID) {
        guard reloadOperationID == operationID else { return }
        reloadOperationID = nil
        reloadTask = nil
        handleInputChanged()
    }
}

nonisolated enum CompletionRecoveryAction: Equatable, Sendable {
    /// Send paused progress to the server and account configured now.
    case reauthorize
    /// Delete paused progress without sending it.
    case discard
}

/// Source-scoped queued-progress state. Counts and fixed reason text only.
nonisolated struct CompletionPresentation: Equatable, Sendable {
    let pendingCount: Int
    let pausedCount: Int
    let pauseReasons: [String]
}
