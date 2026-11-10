import Combine
import Foundation

@MainActor
final class StorageSettingsViewModel: ObservableObject {
    @Published private(set) var diskCacheLimitGB: Double
    @Published private(set) var formattedCurrentUsage: String
    @Published private(set) var isClearingCache = false
    @Published private(set) var alert: SettingsAlert?
    @Published private(set) var downloadBytes: Int64?
    @Published private(set) var isClearingDownloads = false
    /// The outcome of Delete Downloaded Chapters. Only dismissing it or the next deletion replaces it.
    @Published var downloadsMessage: String?
    /// The error of the latest storage measurement. A measurement replaces or clears only this.
    @Published private(set) var measurementMessage: String?

    var hasDownloads: Bool { downloads != nil }
    var formattedDownloadUsage: String {
        downloadBytes.map { DownloadsViewModel.bytes($0) }
            ?? String(localized: "Calculating…", comment: "Offline storage total is being measured")
    }

    let cacheLimitChoices = (1...50).map(Double.init)

    private let settingsStore: AppSettingsStore
    private let storageAccess: any SettingsStorageAccessing
    private let downloads: (any StorageDownloadsServing)?
    private var cancellables = Set<AnyCancellable>()
    private var downloadsRevision: UInt64 = 0

    init(
        settingsStore: AppSettingsStore,
        storageAccess: any SettingsStorageAccessing,
        downloads: (any StorageDownloadsServing)? = nil
    ) {
        self.settingsStore = settingsStore
        self.storageAccess = storageAccess
        self.downloads = downloads
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

    func refreshDownloadsUsage() async {
        guard let downloads else { return }
        downloadsRevision &+= 1
        let revision = downloadsRevision
        do {
            let bytes = try await downloads.inventorySummary().reduce(0) { $0 + $1.byteCount }
            guard downloadsRevision == revision else { return }
            downloadBytes = bytes
            measurementMessage = nil
        } catch {
            guard downloadsRevision == revision else { return }
            downloadBytes = nil
            measurementMessage = String(localized: "Download storage couldn't be measured. Try opening Storage again.",
                                        comment: "Storage settings failed to read offline inventory totals")
        }
    }

    /// Cache and downloads have separate authorities and separate destructive actions. The outcome of the
    /// deletion never depends on the measurement revision; the measurement only follows it.
    func clearDownloads() async {
        guard let downloads, !isClearingDownloads else { return }
        isClearingDownloads = true
        downloadsMessage = nil
        downloadsRevision &+= 1
        defer { isClearingDownloads = false }
        // "Delete everything" covers series with saved copies and series that only have queued work.
        let identities: Set<MediaIdentity>
        do {
            // Jobs first: a finishing download turns its job into a saved copy in one transaction,
            // so a chapter that completes between the two reads is still seen by the second one.
            let queued = try await downloads.queuedMedia()
            identities = Set(try await downloads.inventorySummary().map(\.media)).union(queued)
        } catch {
            downloadsMessage = String(localized: "Downloads couldn't be deleted. Open Manage Downloads to review them.",
                                      comment: "Storage settings could not read downloads before deletion")
            return
        }
        var failed = 0
        for identity in identities {
            do { _ = try await downloads.deleteMedia(identity, suppress: true) } catch { failed += 1 }
        }
        if failed > 0 {
            downloadsMessage = String(
                localized: "Downloads couldn't be fully deleted for \(failed) series. Other deletions were kept. Review the remaining downloads in Manage Downloads.",
                comment: "Storage settings reports partial download deletion, never rollback"
            )
        }
        await refreshDownloadsUsage()
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
        storageAccess.currentCacheSizeBytes.map { storageAccess.formatBytes($0) } ?? String(localized: "Calculating…")
    }
}
