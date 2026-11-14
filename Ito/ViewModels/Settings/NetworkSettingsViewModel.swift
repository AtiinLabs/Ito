import Combine
import Foundation

@MainActor
final class NetworkSettingsViewModel: ObservableObject {
    @Published private(set) var wifiOnlyUpdates: Bool
    @Published private(set) var downloadMode: NetworkDownloadMode
    @Published private(set) var preloadImageCount: ImagePreloadCountPreference
    @Published private(set) var adjacentPrefetch: AdjacentChapterPrefetchPreference
    @Published private(set) var novelPrefetch: Bool
    @Published private(set) var isClearingSiteData = false
    @Published private(set) var alert: SettingsAlert?
    private let settingsStore: AppSettingsStore
    private let siteDataClearer: any SiteDataClearing
    private var cancellables = Set<AnyCancellable>()

    init(settingsStore: AppSettingsStore, siteDataClearer: any SiteDataClearing) {
        self.settingsStore = settingsStore
        self.siteDataClearer = siteDataClearer
        wifiOnlyUpdates = settingsStore.wifiOnlyUpdates
        downloadMode = settingsStore.networkDownloadMode
        preloadImageCount = settingsStore.preloadImageCount
        adjacentPrefetch = settingsStore.adjacentChapterPrefetchCount
        novelPrefetch = settingsStore.novelPrefetchChapters
        settingsStore.$wifiOnlyUpdates.sink { [weak self] in self?.wifiOnlyUpdates = $0 }.store(in: &cancellables)
        settingsStore.$networkDownloadMode.sink { [weak self] in self?.downloadMode = $0 }.store(in: &cancellables)
        settingsStore.$preloadImageCount.sink { [weak self] in self?.preloadImageCount = $0 }.store(in: &cancellables)
        settingsStore.$adjacentChapterPrefetchCount.sink { [weak self] in self?.adjacentPrefetch = $0 }.store(in: &cancellables)
        settingsStore.networkPolicy.changes.sink { @Sendable [weak self] in
            Task { @MainActor in self?.objectWillChange.send() }
        }.store(in: &cancellables)
        settingsStore.$novelPrefetchChapters.sink { [weak self] in self?.novelPrefetch = $0 }.store(in: &cancellables)
    }

    var effective: NetworkEffectiveProjection {
        let policy = settingsStore.networkPolicy
        return policy.projection(path: policy.observedPath ?? .unknown)
    }

    func setWifiOnlyUpdates(_ value: Bool) async { await save { try await self.settingsStore.set(value, for: AppPreferenceCatalog.wifiOnlyUpdates) } }
    func setDownloadMode(_ value: NetworkDownloadMode) async { await save { try await self.settingsStore.set(value, for: AppPreferenceCatalog.networkDownloadMode) } }
    func setPreload(_ value: ImagePreloadCountPreference) async { await save { try await self.settingsStore.set(value, for: AppPreferenceCatalog.preloadImageCount) } }
    func setAdjacent(_ value: AdjacentChapterPrefetchPreference) async { await save { try await self.settingsStore.set(value, for: AppPreferenceCatalog.adjacentChapterPrefetchCount) } }
    func setNovelPrefetch(_ value: Bool) async { await save { try await self.settingsStore.set(value, for: AppPreferenceCatalog.novelPrefetchChapters) } }
    func resetNetworkPreferences() async { await save { try await self.settingsStore.resetNetworkPreferences() } }

    private func save(_ operation: () async throws -> Void) async {
        do { try await operation(); alert = nil } catch { alert = .saveFailed }
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

    func dismissAlert() { alert = nil }
}
