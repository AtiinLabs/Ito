import Foundation
import GRDB
import Security
import Testing
@testable import Ito

@MainActor
struct PluginImageCacheEpochTests {
    private final class SpyPluginSecretKeychain: PluginSecretKeychain, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        private(set) var setDataCalls = 0
        private(set) var deleteCalls = 0
        private(set) var deleteAllCalls = 0

        func data(account: String) -> (OSStatus, Data?) {
            lock.lock()
            defer { lock.unlock() }
            guard let data = items[account] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }

        func setData(_ data: Data, account: String) -> OSStatus {
            lock.lock()
            defer { lock.unlock() }
            setDataCalls += 1
            items[account] = data
            return errSecSuccess
        }

        func delete(account: String) -> OSStatus {
            lock.lock()
            defer { lock.unlock() }
            deleteCalls += 1
            return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }

        func accounts() -> (OSStatus, [String]) {
            lock.lock()
            defer { lock.unlock() }
            return (errSecSuccess, Array(items.keys))
        }

        func deleteAll() -> OSStatus {
            lock.lock()
            defer { lock.unlock() }
            deleteAllCalls += 1
            let hadItems = !items.isEmpty
            items.removeAll()
            return hadItems ? errSecSuccess : errSecItemNotFound
        }
    }

    private final class EpochCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String?] = []

        func append(_ epoch: String?) {
            lock.lock()
            recorded.append(epoch)
            lock.unlock()
        }

        func snapshot() -> [String?] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    private struct SimulatedPersistenceError: Error, Equatable {}

    @Test func epochSurvivesRelaunch() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let initialEpoch = try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        }
        let epoch = try #require(initialEpoch)
        #expect(PluginImageCacheEpoch.isValidEpoch(epoch))

        try database.dbPool.close()

        let reopenedPool = try DatabasePool(path: database.databaseURL.path)
        defer { try? reopenedPool.close() }

        let reopenedEpoch = try reopenedPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        }
        #expect(reopenedEpoch == epoch)
    }

    @Test func meaningfulPlainWritesRotateAndEqualValueWritesDoNot() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let store = PluginSettingsStore(dbPool: database.dbPool)
        let initialEpoch = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })

        // 1. Initial meaningful set rotates epoch
        #expect(store.set(pluginId: "com.test.plugin", key: "theme", value: "dark"))
        let epochAfterSet = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epochAfterSet != initialEpoch)
        #expect(PluginImageCacheEpoch.isValidEpoch(epochAfterSet))

        // 2. Equal-value write does not rotate epoch
        #expect(store.set(pluginId: "com.test.plugin", key: "theme", value: "dark"))
        let epochAfterEqualSet = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epochAfterEqualSet == epochAfterSet)

        // 3. Different-value write rotates epoch
        #expect(store.set(pluginId: "com.test.plugin", key: "theme", value: "light"))
        let epochAfterUpdate = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epochAfterUpdate != epochAfterSet)

        // 4. Remove setting rotates epoch
        #expect(store.remove(pluginId: "com.test.plugin", key: "theme"))
        let epochAfterRemove = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epochAfterRemove != epochAfterUpdate)
    }

    @Test func rollbackPreservesEpoch() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let initialEpoch = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })

        struct ForcedRollback: Error {}

        do {
            try database.dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO pluginSetting (pluginId, key, value)
                    VALUES ('com.test.rollback', 'key1', X'616263')
                    """)
                let inTxEpoch = try PluginImageCacheEpoch.current(in: db)
                #expect(inTxEpoch != initialEpoch)
                throw ForcedRollback()
            }
        } catch is ForcedRollback {}

        let epochAfterRollback = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epochAfterRollback == initialEpoch)
    }

    @Test func directRestoreLikeWritesRotate() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let initialEpoch = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })

        // Direct INSERT mimicking ComponentAwareBackupRestoreOperation restore
        try database.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO pluginSetting (pluginId, key, value)
                VALUES ('restored.plugin', 'api_endpoint', X'68747470')
                """)
        }

        let epochAfterRestoreInsert = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epochAfterRestoreInsert != initialEpoch)

        // Direct DELETE mimicking restore clearing old rows
        try database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM pluginSetting WHERE pluginId = 'restored.plugin'")
        }

        let epochAfterRestoreDelete = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epochAfterRestoreDelete != epochAfterRestoreInsert)
    }

    @Test func secretOnlyOperationsRotateEvenWithNoPlainRow() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let keychain = InMemoryPluginSecretKeychain()
        let secrets = PluginSecretStore(keychain: keychain)
        _ = PluginSettingsStore(dbPool: database.dbPool, secrets: secrets)

        let plainRowCount = try database.dbPool.read { db in
            try PluginSettingRecord.fetchCount(db)
        }
        #expect(plainRowCount == 0)

        let initialEpoch = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })

        // 1. setValue rotates
        try secrets.setValue("token1", pluginID: "com.test.secret", key: "auth")
        let epoch1 = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epoch1 != initialEpoch)

        // 2. removeValue rotates
        try secrets.removeValue(pluginID: "com.test.secret", key: "auth")
        let epoch2 = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epoch2 != epoch1)

        // 3. removeAll(pluginID:) rotates
        try secrets.setValue("token2", pluginID: "com.test.secret", key: "auth2")
        let epoch3 = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epoch3 != epoch2)
        try secrets.removeAll(pluginID: "com.test.secret")
        let epoch4 = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epoch4 != epoch3)

        // 4. removeAll() rotates
        try secrets.setValue("token3", pluginID: "com.other.secret", key: "pass")
        let epoch5 = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epoch5 != epoch4)
        try secrets.removeAll()
        let epoch6 = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epoch6 != epoch5)
    }

    @Test func forcedEpochPersistenceFailurePreventsKeychainMutation() throws {
        let spyKeychain = SpyPluginSecretKeychain()
        let secrets = PluginSecretStore(keychain: spyKeychain)

        secrets.configureBeforeMutation { _ in
            throw SimulatedPersistenceError()
        }

        #expect(throws: SimulatedPersistenceError.self) {
            try secrets.setValue("secretVal", pluginID: "p1", key: "k1")
        }
        #expect(spyKeychain.setDataCalls == 0)

        #expect(throws: SimulatedPersistenceError.self) {
            try secrets.removeValue(pluginID: "p1", key: "k1")
        }
        #expect(spyKeychain.deleteCalls == 0)

        #expect(throws: SimulatedPersistenceError.self) {
            try secrets.removeAll(pluginID: "p1")
        }
        #expect(spyKeychain.deleteCalls == 0)

        #expect(throws: SimulatedPersistenceError.self) {
            try secrets.removeAll()
        }
        #expect(spyKeychain.deleteAllCalls == 0)
    }

    @Test func secretFailureAfterRotationIsHarmless() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let keychain = InMemoryPluginSecretKeychain()
        let secrets = PluginSecretStore(keychain: keychain)
        _ = PluginSettingsStore(dbPool: database.dbPool, secrets: secrets)

        let initialEpoch = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })

        keychain.failingStatus = errSecInteractionNotAllowed

        #expect(throws: PluginSecretStoreError.self) {
            try secrets.setValue("secretVal", pluginID: "p1", key: "k1")
        }

        // Epoch rotated safely; database is unharmed and valid
        let epochAfterFailedKeychain = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epochAfterFailedKeychain != initialEpoch)
        #expect(PluginImageCacheEpoch.isValidEpoch(epochAfterFailedKeychain))
    }

    @Test func constructorInjectionHooksCanonicalSharedStore() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        // Test PluginSettingsStore init hooks secrets
        let secretsForStore = PluginSecretStore(keychain: InMemoryPluginSecretKeychain())
        let initialEpoch = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        _ = PluginSettingsStore(dbPool: database.dbPool, secrets: secretsForStore)
        try secretsForStore.setValue("v", pluginID: "p", key: "k")
        let epochAfterStoreSecret = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epochAfterStoreSecret != initialEpoch)

        // Test DurableStateBootstrap init hooks secrets
        let secretsForBootstrap = PluginSecretStore(keychain: InMemoryPluginSecretKeychain())
        _ = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: {},
            sourceDatabaseURL: database.databaseURL,
            pluginSecrets: secretsForBootstrap
        )
        try secretsForBootstrap.setValue("v2", pluginID: "p", key: "k")
        let epochAfterBootstrapSecret = try #require(try database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        })
        #expect(epochAfterBootstrapSecret != epochAfterStoreSecret)
    }

    @Test func observeImageCacheEpochReceivesInitialAndSubsequentChanges() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let store = PluginSettingsStore(dbPool: database.dbPool)
        let capture = EpochCapture()

        let token = try store.observeImageCacheEpoch { epoch in
            capture.append(epoch)
        }
        _ = token

        // Initial callback delivered synchronously
        let initialSnapshot = capture.snapshot()
        #expect(initialSnapshot.count == 1)
        let initialObserved = try #require(initialSnapshot.first ?? nil)
        #expect(PluginImageCacheEpoch.isValidEpoch(initialObserved))

        // 1. Setting mutation triggers observer synchronously on commit
        #expect(store.set(pluginId: "com.test.obs", key: "k1", value: "v1"))
        let afterSetSnapshot = capture.snapshot()
        #expect(afterSetSnapshot.count == 2)
        let secondObserved = try #require(afterSetSnapshot.last ?? nil)
        #expect(secondObserved != initialObserved)

        // 2. Equal-value write does not trigger observer
        #expect(store.set(pluginId: "com.test.obs", key: "k1", value: "v1"))
        let afterEqualSetSnapshot = capture.snapshot()
        #expect(afterEqualSetSnapshot.count == 2)

        // 3. Secret mutation triggers observer
        #expect(store.setSecret(pluginId: "com.test.obs", key: "secKey", value: "secret123"))
        let afterSecretSnapshot = capture.snapshot()
        #expect(afterSecretSnapshot.count >= 3)
        let secretObserved = try #require(afterSecretSnapshot.last ?? nil)
        #expect(secretObserved != secondObserved)

        // 4. Rollback does not trigger observer
        struct ObserverRollback: Error {}
        do {
            try database.dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO pluginSetting (pluginId, key, value)
                    VALUES ('com.test.obs', 'k_rollback', X'61')
                    """)
                throw ObserverRollback()
            }
        } catch is ObserverRollback {}

        let afterRollbackSnapshot = capture.snapshot()
        #expect(afterRollbackSnapshot.count == afterSecretSnapshot.count)
    }

    @Test func preMigrationTolerance() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ItoUnmigrated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("empty.sqlite").path
        let pool = try DatabasePool(path: dbPath)
        defer { try? pool.close() }

        // Table does not exist
        let current = try pool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        }
        #expect(current == nil)

        // Rotate does not throw or fail when table does not exist
        #expect(throws: Never.self) {
            try pool.write { db in try PluginImageCacheEpoch.rotate(in: db) }
        }
    }
}
