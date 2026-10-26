import Combine
import Foundation
import GRDB
import Testing
@testable import Ito

@MainActor
struct AppSettingsStoreTests {
    @Test func materializesAllTwentyOneDocumentedDefaultsWithTypedState() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = AppSettingsStore(dbPool: database.dbPool)

        try await store.reload()

        #expect(store.libraryLayoutStyle == 1)
        #expect(store.alwaysShowCategoryPicker == false)
        #expect(store.backgroundUpdatesEnabled == false)
        #expect(store.updateInterval == .fourHours)
        #expect(store.skipCompleted == false)
        #expect(store.updateNotifications)
        #expect(store.wifiOnlyUpdates == false)
        #expect(store.discordRPCEnabled == false)
        #expect(store.discordRPCURL == "ws://127.0.0.1:3000")
        #expect(store.appTheme == .system)
        #expect(store.novelFontSize == 18)
        #expect(store.novelLineSpacing == 8)
        #expect(store.novelFontFamily == .system)
        #expect(store.novelTheme == .system)
        #expect(store.novelIsPaging == false)
        #expect(store.novelPrefetchChapters)
        #expect(store.preloadImageCount == .five)
        #expect(store.incognitoMode == false)
        #expect(store.autoSyncTrackersToLocal)
        #expect(store.diskCacheLimitGB == 10)
        #expect(store.mangaWordLookup)
        #expect(store.loadIssues.isEmpty)

        let rows = try await database.dbPool.read { db in try AppPreference.fetchAll(db) }
        #expect(rows.count == AppPreferenceCatalogEntry.allCases.count)
        #expect(Set(rows.map(\.key)) == Set(AppPreferenceCatalogEntry.allCases.map(\.rawValue)))
    }

    @Test func allTwentyOneTypedWritesRoundTripThroughGRDB() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = AppSettingsStore(dbPool: database.dbPool)
        try await store.reload()

        try await store.set(0, for: AppPreferenceCatalog.libraryLayoutStyle)
        try await store.set(true, for: AppPreferenceCatalog.alwaysShowCategoryPicker)
        try await store.set(true, for: AppPreferenceCatalog.backgroundUpdatesEnabled)
        try await store.set(.daily, for: AppPreferenceCatalog.updateInterval)
        try await store.set(true, for: AppPreferenceCatalog.skipCompleted)
        try await store.set(false, for: AppPreferenceCatalog.updateNotifications)
        try await store.set(true, for: AppPreferenceCatalog.wifiOnlyUpdates)
        try await store.set(true, for: AppPreferenceCatalog.discordRPCEnabled)
        try await store.set("wss://example.com/socket", for: AppPreferenceCatalog.discordRPCURL)
        try await store.set(.dark, for: AppPreferenceCatalog.appTheme)
        try await store.set(144.5, for: AppPreferenceCatalog.novelFontSize)
        try await store.set(12.5, for: AppPreferenceCatalog.novelLineSpacing)
        try await store.set(.lora, for: AppPreferenceCatalog.novelFontFamily)
        try await store.set(.sepia, for: AppPreferenceCatalog.novelTheme)
        try await store.set(true, for: AppPreferenceCatalog.novelIsPaging)
        try await store.set(false, for: AppPreferenceCatalog.novelPrefetchChapters)
        try await store.set(.twenty, for: AppPreferenceCatalog.preloadImageCount)
        try await store.set(true, for: AppPreferenceCatalog.incognitoMode)
        try await store.set(false, for: AppPreferenceCatalog.autoSyncTrackersToLocal)
        try await store.set(50, for: AppPreferenceCatalog.diskCacheLimitGB)
        try await store.set(false, for: AppPreferenceCatalog.mangaWordLookup)

        let reloaded = AppSettingsStore(dbPool: database.dbPool)
        try await reloaded.reload()
        #expect(reloaded.libraryLayoutStyle == 0)
        #expect(reloaded.alwaysShowCategoryPicker)
        #expect(reloaded.backgroundUpdatesEnabled)
        #expect(reloaded.updateInterval == .daily)
        #expect(reloaded.skipCompleted)
        #expect(reloaded.updateNotifications == false)
        #expect(reloaded.wifiOnlyUpdates)
        #expect(reloaded.discordRPCEnabled)
        #expect(reloaded.discordRPCURL == "wss://example.com/socket")
        #expect(reloaded.appTheme == .dark)
        #expect(reloaded.novelFontSize == 144.5)
        #expect(reloaded.novelLineSpacing == 12.5)
        #expect(reloaded.novelFontFamily == .lora)
        #expect(reloaded.novelTheme == .sepia)
        #expect(reloaded.novelIsPaging)
        #expect(reloaded.novelPrefetchChapters == false)
        #expect(reloaded.preloadImageCount == .twenty)
        #expect(reloaded.incognitoMode)
        #expect(reloaded.autoSyncTrackersToLocal == false)
        #expect(reloaded.diskCacheLimitGB == 50)
        #expect(reloaded.mangaWordLookup == false)
    }

    @Test func writeDoesNotPublishUntilPersistenceCommits() async throws {
        let persistence = ControlledSettingsPersistence()
        let store = AppSettingsStore(persistence: persistence)
        try await store.reload()
        await persistence.suspendWrites()

        let write = Task {
            try await store.set(true, for: AppPreferenceCatalog.incognitoMode)
        }
        while await persistence.writeStarted == false {
            await Task.yield()
        }

        #expect(store.incognitoMode == false)
        await persistence.resumeWrites()
        try await write.value
        #expect(store.incognitoMode)
    }

    @Test func databaseFailureLeavesCommittedAndPublishedStateUnchanged() async throws {
        let persistence = ControlledSettingsPersistence()
        let store = AppSettingsStore(persistence: persistence)
        try await store.reload()
        try await store.set(.light, for: AppPreferenceCatalog.appTheme)
        await persistence.failNextWrite()

        do {
            try await store.set(.dark, for: AppPreferenceCatalog.appTheme)
            Issue.record("Expected injected persistence failure")
        } catch is InjectedSettingsFailure {
            // Expected.
        }

        #expect(store.appTheme == .light)
        let rows = try await persistence.readPreferences()
        let row = try #require(rows.first { $0.key == AppPreferenceKeys.appTheme })
        #expect(try row.decodedValue(for: AppPreferenceCatalog.appTheme) == .light)
    }

    @Test func invalidRowsRecoverToDefaultsAndReportExactKeys() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            try AppPreference(
                key: AppPreferenceKeys.updateInterval,
                value: Data("3".utf8)
            ).insert(db)
            try AppPreference(
                key: AppPreferenceKeys.novelLineSpacing,
                value: Data("99".utf8)
            ).insert(db)
            try AppPreference(
                key: AppPreferenceKeys.appTheme,
                value: Data("\"Blue\"".utf8)
            ).insert(db)
        }
        let store = AppSettingsStore(dbPool: database.dbPool)

        try await store.reload()

        #expect(store.updateInterval == .fourHours)
        #expect(store.novelLineSpacing == 8)
        #expect(store.appTheme == .system)
        #expect(Set(store.loadIssues.map(\.key)) == [
            AppPreferenceKeys.updateInterval,
            AppPreferenceKeys.novelLineSpacing,
            AppPreferenceKeys.appTheme
        ])
        let repaired = try await database.dbPool.read { db in
            try AppPreference.fetchAll(db)
        }
        #expect(repaired.count == AppPreferenceCatalogEntry.allCases.count)
        #expect(try #require(repaired.first {
            $0.key == AppPreferenceKeys.updateInterval
        }).decodedValue(for: AppPreferenceCatalog.updateInterval) == .fourHours)
    }

    @Test func invalidRuntimeWriteIsRejectedBeforePersistence() async throws {
        let persistence = ControlledSettingsPersistence()
        let store = AppSettingsStore(persistence: persistence)
        try await store.reload()
        let writesBefore = await persistence.writeCount

        do {
            try await store.set(0, for: AppPreferenceCatalog.diskCacheLimitGB)
            Issue.record("Expected validation failure")
        } catch let error as AppPreferenceError {
            #expect(error == .invalidValue(key: AppPreferenceKeys.diskCacheLimitGB))
        }

        #expect(store.diskCacheLimitGB == 10)
        #expect(await persistence.writeCount == writesBefore)
    }

    @Test func sequentialAndConcurrentUpdatesRemainCommittedAndObservable() async throws {
        let persistence = ControlledSettingsPersistence()
        let store = AppSettingsStore(persistence: persistence)
        try await store.reload()
        var observed: [Bool] = []
        let cancellable = store.$skipCompleted.dropFirst().sink { observed.append($0) }

        try await store.set(true, for: AppPreferenceCatalog.skipCompleted)
        try await store.set(false, for: AppPreferenceCatalog.skipCompleted)
        await withTaskGroup(of: Void.self) { group in
            for value in [true, false, true, false, true] {
                group.addTask {
                    try? await store.set(value, for: AppPreferenceCatalog.skipCompleted)
                }
            }
        }

        let rows = try await persistence.readPreferences()
        let row = try #require(rows.first { $0.key == AppPreferenceKeys.skipCompleted })
        #expect(try row.decodedValue(for: AppPreferenceCatalog.skipCompleted) == store.skipCompleted)
        #expect(observed.contains(true))
        #expect(observed.contains(false))
        _ = cancellable
    }

    @Test func reloadAfterRestorePublishesRestoredValuesToObservers() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = AppSettingsStore(dbPool: database.dbPool)
        try await store.reload()
        var observed: [AppThemePreference] = []
        let cancellable = store.$appTheme.dropFirst().sink { observed.append($0) }

        try await database.dbPool.write { db in
            try AppPreference(key: AppPreferenceCatalog.appTheme, value: .dark).save(db)
            try AppPreference(key: AppPreferenceCatalog.novelFontSize, value: 96.0).save(db)
        }
        try await store.reload()

        #expect(store.appTheme == .dark)
        #expect(store.novelFontSize == 96)
        #expect(observed.last == .dark)
        _ = cancellable
    }

    @Test func everyPlannedScalarCallsiteUsesTheStore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "Ito/ItoApp.swift",
            "Ito/Managers/AppearanceManager.swift",
            "Ito/Managers/StorageManager.swift",
            "Ito/Managers/DiscordRPCManager.swift",
            "Ito/Managers/HistoryManager.swift",
            "Ito/Managers/NotificationManager.swift",
            "Ito/Managers/UpdateManager.swift",
            "Ito/Views/Browse/MediaDetailView.swift",
            "Ito/Views/Library/LibraryView.swift",
            "Ito/Views/Reader/ReaderView.swift",
            "Ito/Views/Reader/NovelReaderView.swift",
            "Ito/Views/Settings/AppearanceSettingsView.swift",
            "Ito/Views/Settings/LibrarySettingsView.swift",
            "Ito/Views/Settings/PrivacySettingsView.swift",
            "Ito/Views/Settings/StorageSettingsView.swift",
            "Ito/Views/Settings/TrackerSettingsView.swift"
        ]

        for path in files {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
            #expect(!source.contains("@AppStorage"), "Durable AppStorage remains in \(path)")
            if path != "Ito/Managers/UpdateManager.swift" {
                #expect(!source.contains("UserDefaults."), "Direct defaults access remains in \(path)")
            }
        }
    }
}

private struct InjectedSettingsFailure: Error {}

private actor ControlledSettingsPersistence: AppSettingsPersistence {
    private var rows: [String: AppPreference] = [:]
    private var shouldFailNextWrite = false
    private var writesSuspended = false
    private(set) var writeStarted = false
    private(set) var writeCount = 0

    func readPreferences() async throws -> [AppPreference] {
        Array(rows.values)
    }

    func writePreferences(_ preferences: [AppPreference]) async throws -> [AppPreference] {
        writeStarted = true
        while writesSuspended {
            await Task.yield()
        }
        if shouldFailNextWrite {
            shouldFailNextWrite = false
            throw InjectedSettingsFailure()
        }
        writeCount += 1
        for preference in preferences {
            rows[preference.key] = preference
        }
        return Array(rows.values)
    }

    func failNextWrite() {
        shouldFailNextWrite = true
    }

    func suspendWrites() {
        writeStarted = false
        writesSuspended = true
    }

    func resumeWrites() {
        writesSuspended = false
    }
}
