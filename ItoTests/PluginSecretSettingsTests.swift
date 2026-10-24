import Foundation
import GRDB
import Security
import Testing
import ito_runner
@testable import Ito

@MainActor
struct PluginSecretSettingsTests {
    @Test func savingASecretReplacesThePlainValueAndKeepsItOutOfTheDatabase() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = makeStore(database)
        let module = AppDefaultsModule(pluginId: "komga", store: store)
        module.set(key: "api_key", value: "plain-old")

        #expect(store.setSecret(pluginId: "komga", key: "api_key", value: "secret-new"))

        #expect(module.get(key: "api_key") == "secret-new")
        #expect(try settingRowCount(database, key: "api_key") == 0)
    }

    @Test func aPluginCannotOverwriteOrShadowASecret() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = makeStore(database)
        let module = AppDefaultsModule(pluginId: "komga", store: store)
        store.setSecret(pluginId: "komga", key: "api_key", value: "secret")

        module.set(key: "api_key", value: "from-plugin")

        #expect(module.get(key: "api_key") == "secret")
        #expect(try settingRowCount(database, key: "api_key") == 0)
    }

    @Test func clearingASecretLeavesNothingForThePluginToRead() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = makeStore(database)
        let module = AppDefaultsModule(pluginId: "komga", store: store)
        module.set(key: "api_key", value: "plain-old")
        store.setSecret(pluginId: "komga", key: "api_key", value: "secret")

        #expect(store.removeSecret(pluginId: "komga", key: "api_key"))

        #expect(module.get(key: "api_key") == nil)
    }

    @Test func aPluginRemovingASettingKeepsTheUsersSecret() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = makeStore(database)
        let module = AppDefaultsModule(pluginId: "komga", store: store)
        store.setSecret(pluginId: "komga", key: "api_key", value: "secret")

        module.remove(key: "api_key")

        #expect(module.get(key: "api_key") == "secret")
        #expect(store.secrets.value(pluginID: "komga", key: "api_key") == "secret")
    }

    @Test func aTokenIsReadBackButNeverReachesTheDatabase() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = makeStore(database)
        let module = AppDefaultsModule(pluginId: "komga", store: store)
        module.set(key: "token", value: "plain-copy")

        module.setSecret(key: "token", value: "access-token")

        #expect(module.get(key: "token") == "access-token")
        #expect(try settingRowCount(database, key: "token") == 0)
        #expect(store.secrets.value(pluginID: "komga", key: "token") == nil)
    }

    @Test func aTokenNeverReplacesTheUsersSecret() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = makeStore(database)
        let module = AppDefaultsModule(pluginId: "komga", store: store)
        store.setSecret(pluginId: "komga", key: "api_key", value: "typed")

        module.setSecret(key: "api_key", value: "from-plugin")

        #expect(module.get(key: "api_key") == "typed")
        #expect(store.tokens.value(pluginID: "komga", key: "api_key") == nil)
    }

    @Test func removingForgetsTheTokenAndPlainValue() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = makeStore(database)
        let module = AppDefaultsModule(pluginId: "komga", store: store)
        module.setSecret(key: "token", value: "access-token")
        module.set(key: "other", value: "plain")

        module.remove(key: "token")
        module.remove(key: "other")

        #expect(module.get(key: "token") == nil)
        #expect(module.get(key: "other") == nil)
    }

    @Test func aSnapshotLayersSecretsOverTokensOverPlainValues() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = makeStore(database)
        let module = AppDefaultsModule(pluginId: "komga", store: store)
        module.set(key: "plain", value: "p")
        module.set(key: "token", value: "p")
        module.setSecret(key: "token", value: "t")
        module.setSecret(key: "both", value: "t")
        store.setSecret(pluginId: "komga", key: "both", value: "s")

        let snapshot = try store.snapshot(pluginId: "komga")

        #expect(snapshot["plain"] == "p")
        #expect(snapshot["token"] == "t")
        #expect(snapshot["both"] == "s")
    }

    @Test func refreshingATokenKeepsImageCaches() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = makeStore(database)
        let module = AppDefaultsModule(pluginId: "komga", store: store)
        let before = try database.dbPool.read { db in try PluginImageCacheEpoch.current(in: db) }

        module.setSecret(key: "token", value: "first")
        module.setSecret(key: "token", value: "refreshed")
        module.remove(key: "token")

        let after = try database.dbPool.read { db in try PluginImageCacheEpoch.current(in: db) }
        #expect(after == before)
    }

    @Test func aLaterPlainValueReplacesAToken() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = makeStore(database)
        let module = AppDefaultsModule(pluginId: "komga", store: store)
        module.setSecret(key: "auth", value: "token")

        module.set(key: "auth", value: "plain")

        #expect(module.get(key: "auth") == "plain")
        #expect(store.tokens.value(pluginID: "komga", key: "auth") == nil)
    }

    @Test func removingAPluginsSecretsKeepsEveryOtherPlugin() throws {
        let secrets = PluginSecretStore(keychain: InMemoryPluginSecretKeychain())
        try secrets.setValue("a", pluginID: "com.atiinlabs.komga", key: "api_key")
        try secrets.setValue("b", pluginID: "com.atiinlabs.komga", key: "password")
        try secrets.setValue("c", pluginID: "com.atiinlabs.komga.beta", key: "api_key")
        try secrets.setValue("d", pluginID: "com.atiinlabs.kavita", key: "api_key")

        try secrets.removeAll(pluginID: "com.atiinlabs.komga")

        #expect(secrets.value(pluginID: "com.atiinlabs.komga", key: "api_key") == nil)
        #expect(secrets.value(pluginID: "com.atiinlabs.komga", key: "password") == nil)
        #expect(secrets.value(pluginID: "com.atiinlabs.komga.beta", key: "api_key") == "c")
        #expect(secrets.value(pluginID: "com.atiinlabs.kavita", key: "api_key") == "d")
    }

    @Test func aLockedKeychainIsNotRememberedAsMissing() throws {
        let keychain = InMemoryPluginSecretKeychain()
        try PluginSecretStore(keychain: keychain).setValue("secret", pluginID: "komga", key: "api_key")
        let secrets = PluginSecretStore(keychain: keychain)
        keychain.failingStatus = errSecInteractionNotAllowed

        #expect(secrets.value(pluginID: "komga", key: "api_key") == nil)

        keychain.failingStatus = nil
        #expect(secrets.value(pluginID: "komga", key: "api_key") == "secret")
    }

    @Test func settingsScreenTrimsSecretsAndIgnoresBlankOnes() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = makeStore(database)
        let viewModel = PluginSettingsViewModel(
            plugin: pr7bPlugin(id: "komga", name: "Komga"),
            schema: try pr7bSettingsSchema(settings: [.secret(id: "api_key", name: "API key", summary: nil)]),
            settingsStore: store,
            messagePresenter: PR7BMessagePresenterSpy()
        )

        #expect(viewModel.persistSecret(key: "api_key", value: "   ") == false)
        #expect(viewModel.hasSecret(key: "api_key") == false)
        #expect(viewModel.persistSecret(key: "api_key", value: "  key-value \n"))
        #expect(store.secrets.value(pluginID: "komga", key: "api_key") == "key-value")
        #expect(viewModel.clearSecret(key: "api_key"))
        #expect(viewModel.hasSecret(key: "api_key") == false)
    }

    private func makeStore(_ database: TestDatabase) -> PluginSettingsStore {
        PluginSettingsStore(
            dbPool: database.dbPool,
            domainFactory: { SecretTestPluginDomain(name: $0) },
            secrets: PluginSecretStore(keychain: InMemoryPluginSecretKeychain()),
            cookies: PluginCookieJar(keychain: InMemoryPluginSecretKeychain()),
            tokens: PluginSecretStore(keychain: InMemoryPluginSecretKeychain())
        )
    }

    private func settingRowCount(_ database: TestDatabase, key: String) throws -> Int {
        try database.dbPool.read { db in
            try PluginSettingRecord.filter(Column("key") == key).fetchCount(db)
        }
    }
}

@MainActor
struct FirstRunSetupTests {
    @Test func setupRunsOnceAddingTheRepositoryAndClearingLeftoverCredentials() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let keychain = InMemoryPluginSecretKeychain()
        let secrets = PluginSecretStore(keychain: keychain)
        try secrets.setValue("from-an-old-install", pluginID: "com.atiinlabs.komga", key: "api_key")
        let cookieKeychain = InMemoryPluginSecretKeychain()
        let cookies = PluginCookieJar(keychain: cookieKeychain)
        try cookies.store([try #require(HTTPCookie(properties: [
            .name: "session", .value: "old", .domain: "example.com", .path: "/"
        ]))], pluginID: "com.atiinlabs.komga")
        let tokenKeychain = InMemoryPluginSecretKeychain()
        let tokens = PluginSecretStore(keychain: tokenKeychain)
        try tokens.setValue("old-token", pluginID: "com.atiinlabs.komga", key: "token")
        let setup = FirstRunSetupBootstrapExtension(secrets: secrets, cookies: cookies, tokens: tokens)

        try await setup.prepare(dbPool: database.dbPool)

        #expect(try await repositoryURLs(database) == [RepoManager.defaultRepositoryURL])
        #expect(keychain.storedAccounts.isEmpty)
        #expect(cookieKeychain.storedAccounts.isEmpty)
        #expect(tokenKeychain.storedAccounts.isEmpty)

        // The user then signs in and removes the repository; later launches change neither.
        try secrets.setValue("current", pluginID: "com.atiinlabs.komga", key: "api_key")
        try await database.dbPool.write { db in
            _ = try RepositoryRecord.deleteOne(db, key: RepoManager.defaultRepositoryURL)
        }
        try await setup.prepare(dbPool: database.dbPool)

        #expect(try await repositoryURLs(database).isEmpty)
        #expect(secrets.value(pluginID: "com.atiinlabs.komga", key: "api_key") == "current")
    }

    @Test func aLockedKeychainDefersTheWholeSetupToTheNextLaunch() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let cookieKeychain = InMemoryPluginSecretKeychain()
        cookieKeychain.failingStatus = errSecInteractionNotAllowed
        let setup = FirstRunSetupBootstrapExtension(
            secrets: PluginSecretStore(keychain: InMemoryPluginSecretKeychain()),
            cookies: PluginCookieJar(keychain: cookieKeychain),
            tokens: PluginSecretStore(keychain: InMemoryPluginSecretKeychain())
        )

        try await setup.prepare(dbPool: database.dbPool)
        #expect(try await repositoryURLs(database).isEmpty)

        cookieKeychain.failingStatus = nil
        try await setup.prepare(dbPool: database.dbPool)
        #expect(try await repositoryURLs(database) == [RepoManager.defaultRepositoryURL])
    }

    @Test func addingTheDefaultRepositoryByHandFindsItAlreadyPresent() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let setup = FirstRunSetupBootstrapExtension(
            secrets: PluginSecretStore(keychain: InMemoryPluginSecretKeychain()),
            cookies: PluginCookieJar(keychain: InMemoryPluginSecretKeychain()),
            tokens: PluginSecretStore(keychain: InMemoryPluginSecretKeychain())
        )
        try await setup.prepare(dbPool: database.dbPool)
        let repositories = RepoManager(
            dbPool: database.dbPool,
            indexFetcher: { _ in throw URLError(.notConnectedToInternet) }
        )
        try await repositories.reload()

        let result = try await repositories.addRepository(url: "https://atiinlabs.github.io/sources/index.json")

        #expect(result == .alreadyPresent)
    }

    private func repositoryURLs(_ database: TestDatabase) async throws -> [String] {
        try await database.dbPool.read { db in
            try RepositoryRecord.fetchAll(db).map(\.url)
        }
    }
}

private final class SecretTestPluginDomain: LegacyDefaultsDomain, @unchecked Sendable {
    let domainName: String

    init(name: String) {
        domainName = name
    }

    func persistentDomain() -> [String: Any] { [:] }
    func removeObject(forKey key: String) {}
}
