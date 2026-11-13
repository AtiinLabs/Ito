import Foundation
import GRDB
import Testing
@testable import Ito

@MainActor
struct NetworkPreferenceMigrationTests {
    @Test func representedEmptyScalarWipeAndRefreshDoNotMaterializeNetworkDefaults() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let settings = AppSettingsStore(dbPool: database.dbPool)
        try await settings.reload()
        let backup = ImportedBackup(
            metadata: BackupMetadataRecord(formatVersion: 1, createdAt: Date(timeIntervalSince1970: 1)),
            capabilities: [BackupCapabilityRecord(component: .scalarAppPreferences, representation: .representedEmpty)]
        )
        let operation = ComponentAwareBackupRestoreOperation(dbPool: database.dbPool, standardApplicationDomain: "test.app")
        _ = try await operation.restore(backup, mode: .wipe, operationId: UUID().uuidString)
        try await settings.reloadAfterRestore()
        let rows = try await database.dbPool.read { db in try AppPreference.fetchAll(db) }
        #expect(rows.isEmpty)
        #expect(settings.adjacentChapterPrefetchCount == .two)
        #expect(settings.networkDownloadMode == .unmeteredOnly)
    }

    @Test(arguments: [BackupRestoreMode.merge, .wipe])
    func olderCompleteScalarCatalogRestoresThroughComponentOperation(mode: BackupRestoreMode) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let settings = AppSettingsStore(dbPool: database.dbPool)
        try await settings.reload()
        try await settings.set(.allowMetered, for: AppPreferenceCatalog.networkDownloadMode)
        try await settings.set(.one, for: AppPreferenceCatalog.adjacentChapterPrefetchCount)
        try await settings.set(.ten, for: AppPreferenceCatalog.preloadImageCount)
        let olderPreferences = AppPreferenceCatalogEntry.allCases.filter(\.hasLegacyDefaultsSource).map { entry in
            AppPreference(key: entry.rawValue, value: entry == .preloadImageCount ? Data("0".utf8) : entry.canonicalDefaultJSON)
        }
        let backup = ImportedBackup(
            metadata: BackupMetadataRecord(formatVersion: 1, createdAt: Date(timeIntervalSince1970: 1)),
            capabilities: [BackupCapabilityRecord(component: .scalarAppPreferences, representation: .representedNonempty)],
            preferences: olderPreferences
        )
        let operation = ComponentAwareBackupRestoreOperation(dbPool: database.dbPool, standardApplicationDomain: "test.app")
        _ = try await operation.restore(backup, mode: mode, operationId: UUID().uuidString)
        try await settings.reloadAfterRestore()
        if mode == .wipe {
            #expect(settings.preloadImageCount == .none)
            #expect(settings.adjacentChapterPrefetchCount == .none)
            #expect(settings.networkDownloadMode == .unmeteredOnly)
        } else {
            #expect(settings.preloadImageCount == .ten)
            #expect(settings.adjacentChapterPrefetchCount == .one)
            #expect(settings.networkDownloadMode == .allowMetered)
        }
    }

    @Test func legacyAdoptionRunsBeforeAdjacentDerivation() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let name = "network-upgrade-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(0, forKey: AppPreferenceKeys.preloadImageCount)
        defaults.set(false, forKey: AppPreferenceKeys.wifiOnlyUpdates)
        defaults.set(false, forKey: AppPreferenceKeys.novelPrefetchChapters)
        let migrator = LegacyDefaultsMigrator(
            dbPool: database.dbPool, domain: UserDefaultsLegacyDomain(defaults: defaults, domainName: name)
        )
        try migrator.migrate()
        try migrator.migrate()
        try database.dbPool.read { db in
            let adjacent = try #require(try AppPreference.fetchOne(db, key: AppPreferenceKeys.adjacentChapterPrefetchCount))
            #expect(try adjacent.decodedValue(for: AppPreferenceCatalog.adjacentChapterPrefetchCount) == .none)
            let novel = try #require(try AppPreference.fetchOne(db, key: AppPreferenceKeys.novelPrefetchChapters))
            #expect(try !novel.decodedValue(for: AppPreferenceCatalog.novelPrefetchChapters))
            let wifi = try #require(try AppPreference.fetchOne(db, key: AppPreferenceKeys.wifiOnlyUpdates))
            #expect(try !wifi.decodedValue(for: AppPreferenceCatalog.wifiOnlyUpdates))
        }
    }

    @Test func upgradeAndRestorePreserveZeroAndFalse() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await database.dbPool.write { db in
            try AppPreference(key: AppPreferenceCatalog.preloadImageCount, value: .none).save(db)
            try AppPreference(key: AppPreferenceCatalog.wifiOnlyUpdates, value: false).save(db)
            try AppPreference(key: AppPreferenceCatalog.novelPrefetchChapters, value: false).save(db)
            try NetworkPreferenceMigration.insertMissing(in: db)
        }
        let store = AppSettingsStore(dbPool: database.dbPool)
        try await store.reload()
        #expect(store.adjacentChapterPrefetchCount == .none)
        #expect(store.preloadImageCount == .none)
        #expect(!store.wifiOnlyUpdates)
        #expect(!store.novelPrefetchChapters)
        try await database.dbPool.write { db in
            _ = try AppPreference.deleteOne(db, key: AppPreferenceKeys.adjacentChapterPrefetchCount)
        }
        try await store.reloadAfterRestore()
        #expect(store.adjacentChapterPrefetchCount == .none)
        try await store.set(.one, for: AppPreferenceCatalog.adjacentChapterPrefetchCount)
        try await store.reloadAfterRestore()
        #expect(store.adjacentChapterPrefetchCount == .one)
    }

    @Test func positiveAndNewInstallDeriveTwo() throws {
        #expect(NetworkPreferenceMigration.adjacentAmount(derivedFromPreload: nil) == .two)
        for amount in ImagePreloadCountPreference.allCases where amount != .none {
            #expect(NetworkPreferenceMigration.adjacentAmount(derivedFromPreload: try AppPreference(key: AppPreferenceCatalog.preloadImageCount, value: amount)) == .two)
        }
    }

    @Test func resetTouchesOnlyNetworkPreferences() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = AppSettingsStore(dbPool: database.dbPool)
        try await store.reload()
        try await store.set(.dark, for: AppPreferenceCatalog.appTheme)
        try await store.set(true, for: AppPreferenceCatalog.incognitoMode)
        try await store.set(.allowMetered, for: AppPreferenceCatalog.networkDownloadMode)
        try await store.set(.none, for: AppPreferenceCatalog.preloadImageCount)
        let before = try await database.dbPool.read { db in try AppPreference.fetchAll(db) }
        try await store.resetNetworkPreferences()
        let after = try await database.dbPool.read { db in try AppPreference.fetchAll(db) }
        #expect(Set(before.filter { !AppSettingsStore.networkPreferenceKeys.contains($0.key) }) == Set(after.filter { !AppSettingsStore.networkPreferenceKeys.contains($0.key) }))
        #expect(store.networkDownloadMode == .unmeteredOnly)
        #expect(store.preloadImageCount == .five)
        #expect(store.adjacentChapterPrefetchCount == .two)
        #expect(store.novelPrefetchChapters)
        #expect(!store.wifiOnlyUpdates)
    }

    @Test func oldCompleteBackupCatalogIsAccepted() {
        #expect(AppPreferenceCatalogEntry.isCompleteBackupKeySet(AppPreferenceCatalogEntry.backupRequiredKeys))
        var missing = AppPreferenceCatalogEntry.backupRequiredKeys
        missing.remove(AppPreferenceKeys.preloadImageCount)
        #expect(!AppPreferenceCatalogEntry.isCompleteBackupKeySet(missing))
    }
}
