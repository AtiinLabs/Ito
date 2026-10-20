import Combine

@MainActor
final class LibrarySettingsViewModel: ObservableObject {
    @Published private(set) var alwaysShowCategoryPicker: Bool
    @Published private(set) var backgroundUpdatesEnabled: Bool
    @Published private(set) var updateNotifications: Bool
    @Published private(set) var updateInterval: UpdateIntervalPreference
    @Published private(set) var skipCompleted: Bool
    @Published private(set) var alert: SettingsAlert?

    let updateIntervals = UpdateIntervalPreference.allCases

    var showsUpdateOptions: Bool {
        backgroundUpdatesEnabled
    }

    private let settingsStore: AppSettingsStore
    private let notificationAuthorization: any NotificationAuthorizationRequesting
    private let applicationSettingsOpener: any ApplicationSettingsOpening
    private var notificationMutationTail: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        settingsStore: AppSettingsStore,
        notificationAuthorization: any NotificationAuthorizationRequesting,
        applicationSettingsOpener: any ApplicationSettingsOpening
    ) {
        self.settingsStore = settingsStore
        self.notificationAuthorization = notificationAuthorization
        self.applicationSettingsOpener = applicationSettingsOpener
        alwaysShowCategoryPicker = settingsStore.alwaysShowCategoryPicker
        backgroundUpdatesEnabled = settingsStore.backgroundUpdatesEnabled
        updateNotifications = settingsStore.updateNotifications
        updateInterval = settingsStore.updateInterval
        skipCompleted = settingsStore.skipCompleted

        settingsStore.$alwaysShowCategoryPicker
            .sink { [weak self] value in
                self?.alwaysShowCategoryPicker = value
            }
            .store(in: &cancellables)
        settingsStore.$backgroundUpdatesEnabled
            .sink { [weak self] value in
                self?.backgroundUpdatesEnabled = value
            }
            .store(in: &cancellables)
        settingsStore.$updateNotifications
            .sink { [weak self] value in
                self?.updateNotifications = value
            }
            .store(in: &cancellables)
        settingsStore.$updateInterval
            .sink { [weak self] value in
                self?.updateInterval = value
            }
            .store(in: &cancellables)
        settingsStore.$skipCompleted
            .sink { [weak self] value in
                self?.skipCompleted = value
            }
            .store(in: &cancellables)
    }

    func setAlwaysShowCategoryPicker(_ value: Bool) async {
        do {
            try await settingsStore.set(
                value,
                for: AppPreferenceCatalog.alwaysShowCategoryPicker
            )
            alwaysShowCategoryPicker = settingsStore.alwaysShowCategoryPicker
            alert = nil
        } catch {
            alwaysShowCategoryPicker = settingsStore.alwaysShowCategoryPicker
            alert = .saveFailed
        }
    }

    func setBackgroundUpdatesEnabled(_ value: Bool) async {
        do {
            try await settingsStore.set(
                value,
                for: AppPreferenceCatalog.backgroundUpdatesEnabled
            )
            backgroundUpdatesEnabled = settingsStore.backgroundUpdatesEnabled
            alert = nil
        } catch {
            backgroundUpdatesEnabled = settingsStore.backgroundUpdatesEnabled
            alert = .saveFailed
        }
    }

    func setUpdateNotifications(_ value: Bool) async {
        let precedingMutation = notificationMutationTail
        let mutation = Task { @MainActor [weak self] in
            await precedingMutation?.value
            guard let self else { return }
            await self.performUpdateNotificationsMutation(value)
        }
        notificationMutationTail = mutation
        await mutation.value
    }

    private func performUpdateNotificationsMutation(_ value: Bool) async {
        do {
            try await settingsStore.set(value, for: AppPreferenceCatalog.updateNotifications)
            updateNotifications = settingsStore.updateNotifications
            alert = nil
        } catch {
            updateNotifications = settingsStore.updateNotifications
            alert = .saveFailed
            return
        }

        guard value else { return }
        let granted = await notificationAuthorization.requestPermission()
        guard !granted else { return }

        do {
            try await settingsStore.set(false, for: AppPreferenceCatalog.updateNotifications)
            updateNotifications = settingsStore.updateNotifications
            alert = .notificationsDisabled
        } catch {
            updateNotifications = settingsStore.updateNotifications
            alert = .notificationRollbackFailed
        }
    }

    func setUpdateInterval(_ value: UpdateIntervalPreference) async {
        do {
            try await settingsStore.set(value, for: AppPreferenceCatalog.updateInterval)
            updateInterval = settingsStore.updateInterval
            alert = nil
        } catch {
            updateInterval = settingsStore.updateInterval
            alert = .saveFailed
        }
    }

    func setSkipCompleted(_ value: Bool) async {
        do {
            try await settingsStore.set(value, for: AppPreferenceCatalog.skipCompleted)
            skipCompleted = settingsStore.skipCompleted
            alert = nil
        } catch {
            skipCompleted = settingsStore.skipCompleted
            alert = .saveFailed
        }
    }

    func openApplicationSettings() async {
        if await applicationSettingsOpener.openApplicationSettings() {
            alert = nil
        } else {
            alert = .applicationSettingsOpenFailed
        }
    }

    func dismissAlert() {
        alert = nil
    }
}
