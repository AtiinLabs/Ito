import Combine

@MainActor
final class StorageSettingsViewModel: ObservableObject {
    @Published private(set) var diskCacheLimitGB: Double
    @Published private(set) var formattedCurrentUsage: String
    @Published private(set) var isClearingCache = false
    @Published private(set) var alert: SettingsAlert?

    let cacheLimitChoices = (1...50).map(Double.init)

    private let settingsStore: AppSettingsStore
    private let storageAccess: any SettingsStorageAccessing
    private var cancellables = Set<AnyCancellable>()

    init(
        settingsStore: AppSettingsStore,
        storageAccess: any SettingsStorageAccessing
    ) {
        self.settingsStore = settingsStore
        self.storageAccess = storageAccess
        diskCacheLimitGB = settingsStore.diskCacheLimitGB
        formattedCurrentUsage = Self.formattedUsage(storageAccess)

        settingsStore.$diskCacheLimitGB
            .sink { [weak self] limit in
                self?.diskCacheLimitGB = limit
            }
            .store(in: &cancellables)
    }

    func setDiskCacheLimitGB(_ value: Double) async {
        do {
            try await settingsStore.set(value, for: AppPreferenceCatalog.diskCacheLimitGB)
            diskCacheLimitGB = settingsStore.diskCacheLimitGB
            alert = nil
        } catch {
            diskCacheLimitGB = settingsStore.diskCacheLimitGB
            alert = .saveFailed
        }
    }

    func refreshCacheUsage() async {
        await storageAccess.refreshCacheSize()
        updateFormattedCurrentUsage()
    }

    func clearCache() async {
        guard !isClearingCache else { return }
        isClearingCache = true
        await storageAccess.clearCache()
        updateFormattedCurrentUsage()
        isClearingCache = false
    }

    func dismissAlert() {
        alert = nil
    }

    private func updateFormattedCurrentUsage() {
        formattedCurrentUsage = Self.formattedUsage(storageAccess)
    }

    private static func formattedUsage(_ storageAccess: any SettingsStorageAccessing) -> String {
        storageAccess.currentCacheSizeBytes.map { storageAccess.formatBytes($0) } ?? "Calculating…"
    }
}
