import Combine
import Foundation
import ito_runner

@MainActor
final class PluginSettingsViewModel: ObservableObject {
    let plugin: InstalledPlugin
    let schema: SettingsSchema

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

    private let settingsStore: any PluginSettingsPersisting
    private let messagePresenter: any SourceMessagePresenting
    private let completionRecovery: (any PluginCompletionRecovering)?
    private var loadOperationID: UUID?
    private var reloadOperationID: UUID?
    private var reloadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        plugin: InstalledPlugin,
        schema: SettingsSchema,
        settingsStore: any PluginSettingsPersisting,
        messagePresenter: any SourceMessagePresenting,
        completionRecovery: (any PluginCompletionRecovering)? = nil
    ) {
        self.plugin = plugin
        self.schema = schema
        self.settingsStore = settingsStore
        self.messagePresenter = messagePresenter
        self.completionRecovery = completionRecovery

        settingsStore.settingsRevisionPublisher
            .sink { @MainActor [weak self] revision in
                self?.bindingRevision = revision
            }
            .store(in: &cancellables)

        completionRecovery?.completionSummariesPublisher
            .sink { @MainActor [weak self] summaries in
                guard let self else { return }
                completionSummary = summaries.first { $0.pluginID == self.plugin.id }
            }
            .store(in: &cancellables)
    }

    deinit {
        reloadTask?.cancel()
    }

    func loadIfNeeded() async {
        guard !isPrepared, !isLoading else { return }
        await load()
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
        finishPersistence(settingsStore.persistValue(pluginID: plugin.id, key: key, value: value))
    }

    /// Queued read progress for this source, or nil when nothing is queued.
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

    /// Saves a secret setting. Surrounding whitespace is dropped; an empty value saves nothing.
    @discardableResult
    func persistSecret(key: String, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return finishPersistence(settingsStore.persistSecret(pluginID: plugin.id, key: key, value: trimmed))
    }

    @discardableResult
    func clearSecret(key: String) -> Bool {
        finishPersistence(settingsStore.clearSecret(pluginID: plugin.id, key: key))
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
        completionRecoveryRequest = nil
        loadOperationID = nil
        isLoading = false
        reloadOperationID = nil
        reloadTask?.cancel()
        reloadTask = nil
        isReloading = false
    }

    private func scheduleReload() {
        startReload()
    }

    private func finishReload(_ operationID: UUID) {
        guard reloadOperationID == operationID else { return }
        reloadOperationID = nil
        reloadTask = nil
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
