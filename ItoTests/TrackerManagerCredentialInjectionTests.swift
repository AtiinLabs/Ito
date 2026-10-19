import Foundation
import Security
import Testing
@testable import Ito

@MainActor
struct TrackerManagerCredentialInjectionTests {
    @Test func injectedStoresDriveLegacyMigrationAndPreserveProviderShape() async throws {
        let secureStore = FakeTrackerCredentialStore()
        let legacyStore = FakeLegacyTokenStore(token: "legacy-fixture")
        let subject = try makeSubject(secureStore: secureStore, legacyStore: legacyStore)
        defer { subject.cleanup() }

        #expect(subject.manager.providers.map(\.identifier) == ["anilist", "myanimelist", "mangabaka"])
        #expect(subject.manager.providers.map(\.name) == ["AniList", "MyAnimeList", "MangaBaka"])
        #expect(subject.manager.authenticatedProviders.isEmpty)
        #expect(!subject.manager.hasAuthenticatedLink(
            for: MediaIdentity(pluginId: "legacy", canonicalMediaId: "local-fixture")
        ))

        await subject.manager.bootstrapCredentials()

        let tracker = try #require(subject.manager.providers.first as? AnilistTracker)
        #expect(tracker.anilistToken == "legacy-fixture")
        #expect(subject.manager.authenticatedProviders.map(\.identifier) == ["anilist"])
        #expect(subject.manager.credentialBootstrapState == .ready)
        #expect(await secureStore.recordedOperations() == [
            .read(providerID: "anilist"),
            .set(providerID: "anilist"),
            .read(providerID: "anilist")
        ])
        #expect(await legacyStore.recordedOperations() == [.read, .remove, .read])
        #expect(await secureStore.currentToken() == "legacy-fixture")
        #expect(await legacyStore.currentToken() == nil)
    }

    @Test func readyBootstrapIsANoOp() async throws {
        let secureStore = FakeTrackerCredentialStore(initialToken: "secure-fixture")
        let legacyStore = FakeLegacyTokenStore()
        let subject = try makeSubject(secureStore: secureStore, legacyStore: legacyStore)
        defer { subject.cleanup() }

        await subject.manager.bootstrapCredentials()
        let operationsAfterFirstBootstrap = await secureStore.recordedOperations()

        await subject.manager.bootstrapCredentials()

        #expect(subject.manager.credentialBootstrapState == .ready)
        #expect(await secureStore.recordedOperations() == operationsAfterFirstBootstrap)
    }

    @Test func permanentFailureDoesNotAutomaticallyRetry() async throws {
        let secureStore = FakeTrackerCredentialStore(
            readResults: [.failure(.configuration(errSecParam))]
        )
        let legacyStore = FakeLegacyTokenStore(token: "legacy-fixture")
        let subject = try makeSubject(secureStore: secureStore, legacyStore: legacyStore)
        defer { subject.cleanup() }

        await subject.manager.bootstrapCredentials()
        await subject.manager.bootstrapCredentials()

        #expect(subject.manager.credentialBootstrapState == .permanentFailure)
        #expect(await secureStore.recordedOperations() == [.read(providerID: "anilist")])
        #expect(await legacyStore.recordedOperations().isEmpty)
        #expect(await legacyStore.currentToken() == "legacy-fixture")
        #expect(subject.manager.authenticatedProviders.isEmpty)
    }

    @Test func recoverableVerificationFailureRetriesOnExplicitBootstrap() async throws {
        let secureStore = FakeTrackerCredentialStore(readResults: [
            .success(nil),
            .success("mismatch-fixture")
        ])
        let legacyStore = FakeLegacyTokenStore(token: "legacy-fixture")
        let subject = try makeSubject(secureStore: secureStore, legacyStore: legacyStore)
        defer { subject.cleanup() }

        await subject.manager.bootstrapCredentials()

        #expect(subject.manager.credentialBootstrapState == .recoverableVerificationFailure)
        #expect(subject.manager.authenticatedProviders.isEmpty)

        await subject.manager.bootstrapCredentials()

        #expect(subject.manager.credentialBootstrapState == .ready)
        #expect(subject.manager.authenticatedProviders.map(\.identifier) == ["anilist"])
        #expect(await legacyStore.currentToken() == nil)
    }

    private func makeSubject(
        secureStore: FakeTrackerCredentialStore,
        legacyStore: FakeLegacyTokenStore
    ) throws -> TrackerManagerSubject {
        let suiteName = "TrackerManagerCredentialInjectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let database = try TestDatabase()
        let manager = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: secureStore,
            malCredentialStore: FakeTrackerCredentialStore(),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: legacyStore,
            usernameDefaults: defaults
        )
        return TrackerManagerSubject(
            manager: manager,
            database: database,
            defaults: defaults,
            suiteName: suiteName
        )
    }
}

@MainActor
private struct TrackerManagerSubject {
    let manager: TrackerManager
    let database: TestDatabase
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        database.cleanup()
    }
}
