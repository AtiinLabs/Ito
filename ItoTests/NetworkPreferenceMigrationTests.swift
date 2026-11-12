import Foundation
import GRDB
import Testing
@testable import Ito

@MainActor
struct NetworkPreferenceMigrationTests {
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
            let adjacent = try #require(AppPreference.fetchOne(db, key: AppPreferenceKeys.adjacentChapterPrefetchCount))
            #expect(try adjacent.decodedValue(for: AppPreferenceCatalog.adjacentChapterPrefetchCount) == .none)
            let novel = try #require(AppPreference.fetchOne(db, key: AppPreferenceKeys.novelPrefetchChapters))
            #expect(try !novel.decodedValue(for: AppPreferenceCatalog.novelPrefetchChapters))
            let wifi = try #require(AppPreference.fetchOne(db, key: AppPreferenceKeys.wifiOnlyUpdates))
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
