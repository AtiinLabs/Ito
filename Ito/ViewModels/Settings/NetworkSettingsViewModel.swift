import Combine

@MainActor
final class NetworkSettingsViewModel: ObservableObject {
    @Published private(set) var wifiOnlyUpdates: Bool
    @Published private(set) var isClearingSiteData = false
    @Published private(set) var alert: SettingsAlert?

    private let settingsStore: AppSettingsStore
    private let siteDataClearer: any SiteDataClearing
    private var cancellables = Set<AnyCancellable>()

    init(
        settingsStore: AppSettingsStore,
        siteDataClearer: any SiteDataClearing
    ) {
        self.settingsStore = settingsStore
        self.siteDataClearer = siteDataClearer
        wifiOnlyUpdates = settingsStore.wifiOnlyUpdates

        settingsStore.$wifiOnlyUpdates
            .sink { [weak self] value in
                self?.wifiOnlyUpdates = value
            }
            .store(in: &cancellables)
    }

    func setWifiOnlyUpdates(_ value: Bool) async {
        do {
            try await settingsStore.set(value, for: AppPreferenceCatalog.wifiOnlyUpdates)
            wifiOnlyUpdates = settingsStore.wifiOnlyUpdates
            alert = nil
        } catch {
            wifiOnlyUpdates = settingsStore.wifiOnlyUpdates
            alert = .saveFailed
        }
    }

    func clearSiteData() async {
        guard !isClearingSiteData else { return }
        isClearingSiteData = true
        defer { isClearingSiteData = false }

        do {
            try await siteDataClearer.clearSiteData()
            alert = .siteDataCleared
        } catch {
            alert = .siteDataClearFailed
        }
    }

    func dismissAlert() {
        alert = nil
    }
}
