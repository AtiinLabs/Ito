import Foundation
import Security
import Testing
@testable import Ito

@MainActor
struct TrackerCredentialBootstrapTests {
    @Test func concurrentLaunchAndActiveBootstrapCoalesce() async throws {
        let readGate = AsyncTestGate()
        let secureStore = FakeTrackerCredentialStore(readGates: [readGate])
        let legacyStore = FakeLegacyTokenStore()
        let subject = try makeSubject(secureStore: secureStore, legacyStore: legacyStore)
        defer { subject.cleanup() }
        let lifecycle = TrackerCredentialLifecycle(manager: subject.manager)

        async let launch: Void = lifecycle.appDidLaunch()
        async let active: Void = lifecycle.appDidBecomeActive()
        await readGate.waitForAdmissions()

        #expect(subject.manager.credentialBootstrapState == .inFlight)
        #expect(TrackerSettingsCredentialState(subject.manager.credentialBootstrapState) == .loading)
        #expect(await secureStore.recordedOperations() == [.read(providerID: "anilist")])

        await readGate.open()
        _ = await (launch, active)

        #expect(subject.manager.credentialBootstrapState == .ready)
        #expect(await secureStore.recordedOperations() == [.read(providerID: "anilist")])
    }

    @Test func protectedDataDeferralRetriesOnActiveAndPublishesLegacySession() async throws {
        let secureStore = FakeTrackerCredentialStore(readResults: [
            .failure(.protectedDataUnavailable(errSecInteractionNotAllowed)),
            .success(nil)
        ])
        let legacyStore = FakeLegacyTokenStore(token: "legacy-fixture")
        let subject = try makeSubject(secureStore: secureStore, legacyStore: legacyStore)
        defer { subject.cleanup() }
        let lifecycle = TrackerCredentialLifecycle(manager: subject.manager)

        await lifecycle.appDidLaunch()

        let tracker = try #require(subject.manager.providers.first as? AnilistTracker)
        #expect(subject.manager.credentialBootstrapState == .retryableProtectedDataFailure)
        #expect(TrackerSettingsCredentialState(subject.manager.credentialBootstrapState) == .deferred)
        #expect(tracker.anilistToken == nil)
        #expect(subject.manager.authenticatedProviders.isEmpty)
        #expect(await legacyStore.currentToken() == "legacy-fixture")

        await lifecycle.appDidBecomeActive()

        #expect(subject.manager.credentialBootstrapState == .ready)
        #expect(TrackerSettingsCredentialState(subject.manager.credentialBootstrapState) == .ready)
        #expect(tracker.anilistToken == "legacy-fixture")
        #expect(subject.manager.authenticatedProviders.map(\.identifier) == ["anilist"])
        #expect(await secureStore.recordedOperations() == [
            .read(providerID: "anilist"),
            .read(providerID: "anilist"),
            .set(providerID: "anilist"),
            .read(providerID: "anilist")
        ])
    }

    @Test func protectedMigrationReadbackIsDeferredAndRetriesOnActive() async throws {
        let secureStore = FakeTrackerCredentialStore(readResults: [
            .success(nil),
            .failure(.protectedDataUnavailable(errSecNotAvailable))
        ])
        let legacyStore = FakeLegacyTokenStore(token: "legacy-fixture")
        let subject = try makeSubject(secureStore: secureStore, legacyStore: legacyStore)
        defer { subject.cleanup() }
        let lifecycle = TrackerCredentialLifecycle(manager: subject.manager)

        await lifecycle.appDidLaunch()

        let tracker = try #require(subject.manager.providers.first as? AnilistTracker)
        #expect(subject.manager.credentialBootstrapState == .retryableProtectedDataFailure)
        #expect(TrackerSettingsCredentialState(subject.manager.credentialBootstrapState) == .deferred)
        #expect(tracker.anilistToken == nil)
        #expect(await secureStore.currentToken() == "legacy-fixture")
        #expect(await legacyStore.currentToken() == "legacy-fixture")

        await lifecycle.appDidBecomeActive()

        #expect(subject.manager.credentialBootstrapState == .ready)
        #expect(TrackerSettingsCredentialState(subject.manager.credentialBootstrapState) == .ready)
        #expect(tracker.anilistToken == "legacy-fixture")
        #expect(await legacyStore.currentToken() == nil)
    }

    @Test func lifecycleInvokesBootstrapForLaunchAndActive() async {
        var invocationCount = 0
        let lifecycle = TrackerCredentialLifecycle {
            invocationCount += 1
        }

        await lifecycle.appDidLaunch()
        await lifecycle.appDidBecomeActive()

        #expect(invocationCount == 2)
    }

    @Test func lifecycleRetriesRecoverableVerificationFailureOnActive() async throws {
        let secureStore = FakeTrackerCredentialStore(readResults: [
            .success(nil),
            .success("mismatch-fixture")
        ])
        let legacyStore = FakeLegacyTokenStore(token: "legacy-fixture")
        let subject = try makeSubject(secureStore: secureStore, legacyStore: legacyStore)
        defer { subject.cleanup() }
        let lifecycle = TrackerCredentialLifecycle(manager: subject.manager)

        await lifecycle.appDidLaunch()

        let tracker = try #require(subject.manager.providers.first as? AnilistTracker)
        #expect(subject.manager.credentialBootstrapState == .recoverableVerificationFailure)
        #expect(TrackerSettingsCredentialState(subject.manager.credentialBootstrapState) == .unavailable)
        #expect(tracker.anilistToken == nil)

        await lifecycle.appDidBecomeActive()

        #expect(subject.manager.credentialBootstrapState == .ready)
        #expect(tracker.anilistToken == "legacy-fixture")
        #expect(await legacyStore.currentToken() == nil)
    }

    @Test func settingsStateDoesNotTreatUnconfirmedBootstrapAsLoginReady() {
        #expect(TrackerSettingsCredentialState(.notStarted) == .loading)
        #expect(TrackerSettingsCredentialState(.inFlight) == .loading)
        #expect(TrackerSettingsCredentialState(.retryableProtectedDataFailure) == .deferred)
        #expect(TrackerSettingsCredentialState(.recoverableVerificationFailure) == .unavailable)
        #expect(TrackerSettingsCredentialState(.permanentFailure) == .unavailable)
        #expect(TrackerSettingsCredentialState(.ready) == .ready)
        #expect(TrackerSettingsCredentialState(.conflict) == .ready)
    }

    private func makeSubject(
        secureStore: FakeTrackerCredentialStore,
        legacyStore: FakeLegacyTokenStore
    ) throws -> TrackerCredentialBootstrapSubject {
        let suiteName = "TrackerCredentialBootstrapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let subjectDatabase = try TestDatabase()
        let manager = TrackerManager(
            dbPool: subjectDatabase.dbPool,
            credentialStore: secureStore,
            malCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: legacyStore,
            usernameDefaults: defaults
        )
        return TrackerCredentialBootstrapSubject(
            manager: manager,
            database: subjectDatabase,
            defaults: defaults,
            suiteName: suiteName
        )
    }
}

@MainActor
private struct TrackerCredentialBootstrapSubject {
    let manager: TrackerManager
    let database: TestDatabase
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        database.cleanup()
    }
}
