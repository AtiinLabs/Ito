import Combine
import Foundation
import GRDB

public struct AppSettingsLoadIssue: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case invalidStoredValue
    }

    public let key: String
    public let reason: Reason
}

public protocol AppSettingsPersistence: Sendable {
    func readPreferences() async throws -> [AppPreference]
    func writePreferences(_ preferences: [AppPreference]) async throws -> [AppPreference]
    func insertAbsentNetworkPreferences() async throws -> [AppPreference]
}

public struct GRDBAppSettingsPersistence: AppSettingsPersistence {
    private let dbPool: DatabasePool

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    public func readPreferences() async throws -> [AppPreference] {
        try await dbPool.read { db in
            try AppPreference.fetchAll(db)
        }
    }

    public func writePreferences(_ preferences: [AppPreference]) async throws -> [AppPreference] {
        try await dbPool.write { db in
            for preference in preferences {
                try preference.save(db)
            }
            return try AppPreference.fetchAll(db)
        }
    }

    public func insertAbsentNetworkPreferences() async throws -> [AppPreference] {
        try await dbPool.write { db in
            try NetworkPreferenceMigration.insertMissing(in: db)
            return try AppPreference.fetchAll(db)
        }
    }
}

@MainActor
public final class AppSettingsStore: ObservableObject {
    @Published public private(set) var libraryLayoutStyle = AppPreferenceCatalog.libraryLayoutStyle.defaultValue
    @Published public private(set) var alwaysShowCategoryPicker = AppPreferenceCatalog.alwaysShowCategoryPicker.defaultValue
    @Published public private(set) var backgroundUpdatesEnabled = AppPreferenceCatalog.backgroundUpdatesEnabled.defaultValue
    @Published public private(set) var updateInterval = AppPreferenceCatalog.updateInterval.defaultValue
    @Published public private(set) var skipCompleted = AppPreferenceCatalog.skipCompleted.defaultValue
    @Published public private(set) var updateNotifications = AppPreferenceCatalog.updateNotifications.defaultValue
    @Published public private(set) var wifiOnlyUpdates = AppPreferenceCatalog.wifiOnlyUpdates.defaultValue
    @Published public private(set) var discordRPCEnabled = AppPreferenceCatalog.discordRPCEnabled.defaultValue
    @Published public private(set) var discordRPCURL = AppPreferenceCatalog.discordRPCURL.defaultValue
    @Published public private(set) var appTheme = AppPreferenceCatalog.appTheme.defaultValue
    @Published public private(set) var novelFontSize = AppPreferenceCatalog.novelFontSize.defaultValue
    @Published public private(set) var novelLineSpacing = AppPreferenceCatalog.novelLineSpacing.defaultValue
    @Published public private(set) var novelFontFamily = AppPreferenceCatalog.novelFontFamily.defaultValue
    @Published public private(set) var novelTheme = AppPreferenceCatalog.novelTheme.defaultValue
    @Published public private(set) var novelIsPaging = AppPreferenceCatalog.novelIsPaging.defaultValue
    @Published public private(set) var novelPrefetchChapters = AppPreferenceCatalog.novelPrefetchChapters.defaultValue
    @Published public private(set) var preloadImageCount = AppPreferenceCatalog.preloadImageCount.defaultValue
    @Published public private(set) var incognitoMode = AppPreferenceCatalog.incognitoMode.defaultValue
    @Published public private(set) var autoSyncTrackersToLocal = AppPreferenceCatalog.autoSyncTrackersToLocal.defaultValue
    @Published public private(set) var diskCacheLimitGB = AppPreferenceCatalog.diskCacheLimitGB.defaultValue
    @Published public private(set) var networkDownloadMode = AppPreferenceCatalog.networkDownloadMode.defaultValue
    @Published public private(set) var adjacentChapterPrefetchCount = AppPreferenceCatalog.adjacentChapterPrefetchCount.defaultValue
    @Published public private(set) var loadIssues: [AppSettingsLoadIssue] = []

    private let persistence: any AppSettingsPersistence
    /// The live network policy this store feeds. It is told the configured values only after they are stored.
    let networkPolicy: NetworkPolicyCenter
    private var operationTail = Task<Void, Never> {}

    /// - Parameter networkPolicy: the process's live network policy, which this store feeds with every
    ///   acknowledged change of the configured values.
    convenience init(dbPool: DatabasePool, networkPolicy: NetworkPolicyCenter) {
        self.init(persistence: GRDBAppSettingsPersistence(dbPool: dbPool), networkPolicy: networkPolicy)
    }

    init(persistence: any AppSettingsPersistence, networkPolicy: NetworkPolicyCenter) {
        self.persistence = persistence
        self.networkPolicy = networkPolicy
    }

    public func reload() async throws {
        try await enqueue { [self] in
            let rows = try await persistence.readPreferences()
            let resolved = try await resolveAndMaterialize(rows)
            publish(resolved.snapshot, issues: resolved.issues)
        }
    }

    public func reloadAfterRestore() async throws {
        try await enqueue { [self] in
            var rows = try await persistence.readPreferences()
            // Derive absent network values when a restored preload supplies legacy configuration to preserve.
            // An explicitly empty/partial represented component with no preload has no dependent value to
            // migrate: refresh must remain read-only rather than materializing unrelated defaults.
            let hasPreload = rows.contains { $0.key == AppPreferenceKeys.preloadImageCount }
            // Decided inside the write, from the rows it reads, so only keys that are absent are inserted.
            if hasPreload, !NetworkPreferenceMigration.missingRows(in: rows).isEmpty {
                rows = try await persistence.insertAbsentNetworkPreferences()
            }
            let resolved = AppSettingsSnapshot.resolve(rows)
            publish(resolved.snapshot, issues: resolved.issues)
        }
    }

    public func set<Value: Codable & Sendable>(
        _ value: Value,
        for key: AppPreferenceKey<Value>
    ) async throws {
        guard key.isValid(value) else {
            throw AppPreferenceError.invalidValue(key: key.name)
        }

        try await enqueue { [self] in
            let preference = try AppPreference(key: key, value: value)
            let rows = try await persistence.writePreferences([preference])
            let resolved = try await resolveAndMaterialize(rows)
            publish(resolved.snapshot, issues: resolved.issues)
        }
    }

    /// Writes the default of every network and prefetch preference in one transaction and publishes them only
    /// after the write is acknowledged: the download mode, Wi-Fi-only automatic updates, the image preload,
    /// the adjacent-chapter prefetch amount and the novel prefetch toggle. No other preference, and no
    /// credential, site data or read state, is touched. A failed write changes nothing that is published.
    public func resetNetworkPreferences() async throws {
        try await enqueue { [self] in
            let rows = try Self.networkDefaultRows()
            let written = try await persistence.writePreferences(rows)
            let resolved = try await resolveAndMaterialize(written)
            publish(resolved.snapshot, issues: resolved.issues)
        }
    }

    /// The keys `resetNetworkPreferences()` writes.
    public static let networkPreferenceKeys: Set<String> = [
        AppPreferenceKeys.networkDownloadMode,
        AppPreferenceKeys.wifiOnlyUpdates,
        AppPreferenceKeys.preloadImageCount,
        AppPreferenceKeys.adjacentChapterPrefetchCount,
        AppPreferenceKeys.novelPrefetchChapters
    ]

    private static func networkDefaultRows() throws -> [AppPreference] {
        [
            try AppPreference(key: AppPreferenceCatalog.networkDownloadMode, value: AppPreferenceCatalog.networkDownloadMode.defaultValue),
            try AppPreference(key: AppPreferenceCatalog.wifiOnlyUpdates, value: AppPreferenceCatalog.wifiOnlyUpdates.defaultValue),
            try AppPreference(key: AppPreferenceCatalog.preloadImageCount, value: AppPreferenceCatalog.preloadImageCount.defaultValue),
            try AppPreference(
                key: AppPreferenceCatalog.adjacentChapterPrefetchCount,
                value: AppPreferenceCatalog.adjacentChapterPrefetchCount.defaultValue
            ),
            try AppPreference(key: AppPreferenceCatalog.novelPrefetchChapters, value: AppPreferenceCatalog.novelPrefetchChapters.defaultValue)
        ]
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let preceding = operationTail
        let task = Task { @MainActor in
            await preceding.value
            try await operation()
        }
        operationTail = Task { @MainActor in
            _ = try? await task.value
        }
        try await task.value
    }

    private func resolveAndMaterialize(
        _ rows: [AppPreference]
    ) async throws -> (snapshot: AppSettingsSnapshot, issues: [AppSettingsLoadIssue]) {
        // Absent network preferences are derived from the stored ones before any generic default is
        // materialized, so a stored image preload of zero is never overtaken by a default adjacent amount.
        var rows = rows
        if !NetworkPreferenceMigration.missingRows(in: rows).isEmpty {
            rows = try await persistence.insertAbsentNetworkPreferences()
        }
        let first = AppSettingsSnapshot.resolve(rows)
        guard !first.repairs.isEmpty else {
            return (first.snapshot, first.issues)
        }

        let repairedRows = try await persistence.writePreferences(first.repairs)
        let repaired = AppSettingsSnapshot.resolve(repairedRows)
        guard repaired.repairs.isEmpty else {
            throw AppSettingsStoreError.materializationDidNotConverge
        }
        return (repaired.snapshot, first.issues)
    }

    private func publish(_ snapshot: AppSettingsSnapshot, issues: [AppSettingsLoadIssue]) {
        libraryLayoutStyle = snapshot.libraryLayoutStyle
        alwaysShowCategoryPicker = snapshot.alwaysShowCategoryPicker
        backgroundUpdatesEnabled = snapshot.backgroundUpdatesEnabled
        updateInterval = snapshot.updateInterval
        skipCompleted = snapshot.skipCompleted
        updateNotifications = snapshot.updateNotifications
        wifiOnlyUpdates = snapshot.wifiOnlyUpdates
        discordRPCEnabled = snapshot.discordRPCEnabled
        discordRPCURL = snapshot.discordRPCURL
        appTheme = snapshot.appTheme
        novelFontSize = snapshot.novelFontSize
        novelLineSpacing = snapshot.novelLineSpacing
        novelFontFamily = snapshot.novelFontFamily
        novelTheme = snapshot.novelTheme
        novelIsPaging = snapshot.novelIsPaging
        novelPrefetchChapters = snapshot.novelPrefetchChapters
        preloadImageCount = snapshot.preloadImageCount
        incognitoMode = snapshot.incognitoMode
        autoSyncTrackersToLocal = snapshot.autoSyncTrackersToLocal
        diskCacheLimitGB = snapshot.diskCacheLimitGB
        networkDownloadMode = snapshot.networkDownloadMode
        adjacentChapterPrefetchCount = snapshot.adjacentChapterPrefetchCount
        loadIssues = issues
        // The configuration is published only here, after persistence acknowledged it, so the live policy
        // revision never runs ahead of what is stored.
        networkPolicy.apply(snapshot.networkConfiguration)
    }
}

public enum AppSettingsStoreError: Error, Equatable {
    case materializationDidNotConverge
}

private struct AppSettingsSnapshot: Sendable {
    let libraryLayoutStyle: Int
    let alwaysShowCategoryPicker: Bool
    let backgroundUpdatesEnabled: Bool
    let updateInterval: UpdateIntervalPreference
    let skipCompleted: Bool
    let updateNotifications: Bool
    let wifiOnlyUpdates: Bool
    let discordRPCEnabled: Bool
    let discordRPCURL: String
    let appTheme: AppThemePreference
    let novelFontSize: Double
    let novelLineSpacing: Double
    let novelFontFamily: NovelFontPreference
    let novelTheme: NovelThemePreference
    let novelIsPaging: Bool
    let novelPrefetchChapters: Bool
    let preloadImageCount: ImagePreloadCountPreference
    let incognitoMode: Bool
    let autoSyncTrackersToLocal: Bool
    let diskCacheLimitGB: Double
    let networkDownloadMode: NetworkDownloadMode
    let adjacentChapterPrefetchCount: AdjacentChapterPrefetchPreference

    var networkConfiguration: NetworkPolicyConfiguration {
        NetworkPolicyConfiguration(
            downloadMode: networkDownloadMode,
            wifiOnlyUpdates: wifiOnlyUpdates,
            preloadImageCount: preloadImageCount.rawValue,
            adjacentChapterPrefetch: adjacentChapterPrefetchCount.rawValue,
            novelPrefetchChapters: novelPrefetchChapters
        )
    }

    static func resolve(
        _ preferences: [AppPreference]
    ) -> (snapshot: AppSettingsSnapshot, repairs: [AppPreference], issues: [AppSettingsLoadIssue]) {
        let rows = Dictionary(preferences.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
        var repairs: [AppPreference] = []
        var issues: [AppSettingsLoadIssue] = []

        func value<Value: Codable & Sendable>(_ key: AppPreferenceKey<Value>) -> Value {
            if let row = rows[key.name], let decoded = try? row.decodedValue(for: key) {
                return decoded
            }
            if rows[key.name] != nil {
                issues.append(AppSettingsLoadIssue(key: key.name, reason: .invalidStoredValue))
            }
            if let replacement = try? AppPreference(key: key, value: key.defaultValue) {
                repairs.append(replacement)
            }
            return key.defaultValue
        }

        return (
            AppSettingsSnapshot(
                libraryLayoutStyle: value(AppPreferenceCatalog.libraryLayoutStyle),
                alwaysShowCategoryPicker: value(AppPreferenceCatalog.alwaysShowCategoryPicker),
                backgroundUpdatesEnabled: value(AppPreferenceCatalog.backgroundUpdatesEnabled),
                updateInterval: value(AppPreferenceCatalog.updateInterval),
                skipCompleted: value(AppPreferenceCatalog.skipCompleted),
                updateNotifications: value(AppPreferenceCatalog.updateNotifications),
                wifiOnlyUpdates: value(AppPreferenceCatalog.wifiOnlyUpdates),
                discordRPCEnabled: value(AppPreferenceCatalog.discordRPCEnabled),
                discordRPCURL: value(AppPreferenceCatalog.discordRPCURL),
                appTheme: value(AppPreferenceCatalog.appTheme),
                novelFontSize: value(AppPreferenceCatalog.novelFontSize),
                novelLineSpacing: value(AppPreferenceCatalog.novelLineSpacing),
                novelFontFamily: value(AppPreferenceCatalog.novelFontFamily),
                novelTheme: value(AppPreferenceCatalog.novelTheme),
                novelIsPaging: value(AppPreferenceCatalog.novelIsPaging),
                novelPrefetchChapters: value(AppPreferenceCatalog.novelPrefetchChapters),
                preloadImageCount: value(AppPreferenceCatalog.preloadImageCount),
                incognitoMode: value(AppPreferenceCatalog.incognitoMode),
                autoSyncTrackersToLocal: value(AppPreferenceCatalog.autoSyncTrackersToLocal),
                diskCacheLimitGB: value(AppPreferenceCatalog.diskCacheLimitGB),
                networkDownloadMode: value(AppPreferenceCatalog.networkDownloadMode),
                adjacentChapterPrefetchCount: value(AppPreferenceCatalog.adjacentChapterPrefetchCount)
            ),
            repairs,
            issues
        )
    }
}
