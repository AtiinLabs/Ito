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

    private let settingsStore: any PluginSettingsPersisting
    private let messagePresenter: any SourceMessagePresenting
    private var loadOperationID: UUID?
    private var reloadOperationID: UUID?
    private var reloadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        plugin: InstalledPlugin,
        schema: SettingsSchema,
        settingsStore: any PluginSettingsPersisting,
        messagePresenter: any SourceMessagePresenting
    ) {
        self.plugin = plugin
        self.schema = schema
        self.settingsStore = settingsStore
        self.messagePresenter = messagePresenter

        settingsStore.settingsRevisionPublisher
            .sink { @MainActor [weak self] revision in
                self?.bindingRevision = revision
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

    func ensureDefault(key: String, value: String) {
        guard storedValue(key: key) == nil else { return }
        persistValue(key: key, value: value)
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
