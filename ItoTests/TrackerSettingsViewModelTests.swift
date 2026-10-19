import XCTest
@testable import Ito

@MainActor
final class TrackerSettingsViewModelTests: XCTestCase {
    func testCredentialBootstrapPresentationMappingIsExact() {
        XCTAssertEqual(TrackerSettingsCredentialState(.notStarted), .loading)
        XCTAssertEqual(TrackerSettingsCredentialState(.inFlight), .loading)
        XCTAssertEqual(TrackerSettingsCredentialState(.retryableProtectedDataFailure), .deferred)
        XCTAssertEqual(TrackerSettingsCredentialState(.ready), .ready)
        XCTAssertEqual(TrackerSettingsCredentialState(.conflict), .ready)
        XCTAssertEqual(TrackerSettingsCredentialState(.recoverableVerificationFailure), .unavailable)
        XCTAssertEqual(TrackerSettingsCredentialState(.permanentFailure), .unavailable)
    }

    func testInitialPresentationUsesAuthoritativeProviderAndPreferenceState() {
        let authenticated = provider(id: "anilist", authenticated: true, username: "reader")
        let unauthenticated = provider(id: "other", authenticated: false)
        let service = TrackerSettingsServiceFake(
            state: state(credential: .ready, providers: [authenticated, unauthenticated])
        )
        let preference = TrackingPreferenceStoreFake(initialValue: true)
        let viewModel = makeViewModel(service: service, preference: preference)

        XCTAssertEqual(viewModel.credentialState, .ready)
        XCTAssertEqual(viewModel.providers, [authenticated, unauthenticated])
        XCTAssertEqual(viewModel.providers.first?.username, "reader")
        XCTAssertTrue(viewModel.syncTrackersToLocal)
        XCTAssertFalse(viewModel.isPersistingPreference)
        XCTAssertNil(viewModel.operatingProviderID)
    }

    func testAuthenticateSuccessRefreshesExactProviderAndSuppressesOverlap() async {
        let service = TrackerSettingsServiceFake(
            state: state(providers: [provider(id: "anilist"), provider(id: "other")])
        )
        service.suspendsAuthentication = true
        let logger = PresentationEventCaptureSpy()
        let viewModel = makeViewModel(service: service, logger: logger)

        viewModel.authenticate(providerID: "anilist")
        await trackingWaitUntil { service.pendingAuthenticationCount == 1 }
        viewModel.authenticate(providerID: "anilist")
        viewModel.authenticate(providerID: "other")
        viewModel.logout(providerID: "other")

        XCTAssertEqual(service.authenticationInvocations, ["anilist"])
        XCTAssertTrue(service.logoutInvocations.isEmpty)
        XCTAssertEqual(viewModel.operatingProviderID, "anilist")
        XCTAssertEqual(viewModel.operationKind, .authentication)

        service.send(state(providers: [provider(id: "anilist", authenticated: true, username: "reader")]))
        service.completeAuthentication(with: .success(()))
        await trackingWaitUntil { !viewModel.isAuthenticationOperationActive }

        XCTAssertEqual(service.refreshCount, 1)
        XCTAssertTrue(viewModel.providers[0].isAuthenticated)
        XCTAssertEqual(viewModel.providers[0].username, "reader")
        XCTAssertNil(viewModel.failure(for: "anilist"))
        XCTAssertEqual(logger.events.map(\.kind), [.authentication, .authentication])
        XCTAssertEqual(logger.events.last?.outcome, .succeeded)
    }

    func testAuthenticateFailureIsVisibleRetryableAndDoesNotLeakError() async {
        let service = TrackerSettingsServiceFake(state: state(providers: [provider(id: "anilist")]))
        service.authenticationError = TrackingTestError.secret("access-token-secret")
        let logger = PresentationEventCaptureSpy()
        let viewModel = makeViewModel(service: service, logger: logger)

        viewModel.authenticate(providerID: "anilist")
        await trackingWaitUntil { !viewModel.isAuthenticationOperationActive }

        XCTAssertEqual(viewModel.failure(for: "anilist"), .authentication)
        XCTAssertEqual(service.refreshCount, 1)
        XCTAssertFalse(logger.formattedMessages.joined().contains("access-token-secret"))

        service.authenticationError = nil
        service.send(state(providers: [provider(id: "anilist", authenticated: true)]))
        viewModel.authenticate(providerID: "anilist")
        await trackingWaitUntil { !viewModel.isAuthenticationOperationActive }

        XCTAssertNil(viewModel.failure(for: "anilist"))
        XCTAssertTrue(viewModel.providers[0].isAuthenticated)
        XCTAssertEqual(service.authenticationInvocations, ["anilist", "anilist"])
    }

    func testLogoutSuccessAndFailureRefreshAuthoritativeProviderState() async {
        let service = TrackerSettingsServiceFake(
            state: state(providers: [provider(id: "anilist", authenticated: true, username: "reader")])
        )
        let viewModel = makeViewModel(service: service)

        service.logoutError = TrackingTestError.failure
        viewModel.logout(providerID: "anilist")
        await trackingWaitUntil { !viewModel.isAuthenticationOperationActive }
        XCTAssertEqual(viewModel.failure(for: "anilist"), .logout)
        XCTAssertTrue(viewModel.providers[0].isAuthenticated)

        service.logoutError = nil
        service.send(state(providers: [provider(id: "anilist")]))
        viewModel.logout(providerID: "anilist")
        await trackingWaitUntil { !viewModel.isAuthenticationOperationActive }

        XCTAssertNil(viewModel.failure(for: "anilist"))
        XCTAssertFalse(viewModel.providers[0].isAuthenticated)
        XCTAssertEqual(service.logoutInvocations, ["anilist", "anilist"])
        XCTAssertEqual(service.refreshCount, 2)
    }

    func testDuplicateLogoutIsSuppressedWhileFirstLogoutIsPending() async {
        let service = TrackerSettingsServiceFake(
            state: state(providers: [provider(id: "anilist", authenticated: true)])
        )
        service.suspendsLogout = true
        let viewModel = makeViewModel(service: service)

        viewModel.logout(providerID: "anilist")
        await trackingWaitUntil { service.pendingLogoutCount == 1 }
        viewModel.logout(providerID: "anilist")

        XCTAssertEqual(service.logoutInvocations, ["anilist"])
        service.completeLogout(with: .success(()))
        await trackingWaitUntil { !viewModel.isAuthenticationOperationActive }
    }

    func testStaleAuthenticationCompletionCannotClearNewerOperation() async {
        let service = TrackerSettingsServiceFake(state: state(providers: [provider(id: "anilist")]))
        service.suspendsAuthentication = true
        let viewModel = makeViewModel(service: service)

        viewModel.authenticate(providerID: "anilist")
        await trackingWaitUntil { service.pendingAuthenticationCount == 1 }
        viewModel.cancelOwnedWork()
        viewModel.authenticate(providerID: "anilist")
        await trackingWaitUntil { service.pendingAuthenticationCount == 2 }

        service.completeAuthentication(at: 0, with: .failure(TrackingTestError.failure))
        await Task.yield()
        XCTAssertTrue(viewModel.isAuthenticationOperationActive)
        XCTAssertNil(viewModel.failure(for: "anilist"))

        service.send(state(providers: [provider(id: "anilist", authenticated: true)]))
        service.completeAuthentication(with: .success(()))
        await trackingWaitUntil { !viewModel.isAuthenticationOperationActive }
        XCTAssertTrue(viewModel.providers[0].isAuthenticated)
    }

    func testPreferencePersistenceSuccessAndFailurePublishOnlyAuthoritativeTruth() async {
        let preference = TrackingPreferenceStoreFake(initialValue: false)
        let messages = TrackingMessageCaptureSpy()
        let viewModel = makeViewModel(preference: preference, messages: messages)

        viewModel.syncTrackersToLocal = true
        await trackingWaitUntil { !viewModel.isPersistingPreference }
        XCTAssertTrue(preference.autoSyncTrackersToLocal)
        XCTAssertTrue(viewModel.syncTrackersToLocal)

        preference.nextError = TrackingTestError.failure
        viewModel.syncTrackersToLocal = false
        await trackingWaitUntil { !viewModel.isPersistingPreference }

        XCTAssertTrue(preference.autoSyncTrackersToLocal)
        XCTAssertTrue(viewModel.syncTrackersToLocal)
        XCTAssertEqual(messages.messages, [.preferencePersistenceFailed])
    }

    func testRapidPreferenceWritesAreSerializedAndOlderCompletionCannotOverwriteLatest() async {
        let preference = TrackingPreferenceStoreFake(initialValue: false)
        preference.suspendsWrites = true
        let viewModel = makeViewModel(preference: preference)

        viewModel.syncTrackersToLocal = true
        viewModel.syncTrackersToLocal = false
        await trackingWaitUntil { preference.pendingWriteCount == 1 }
        XCTAssertEqual(preference.invocations, [true])

        preference.completeWrite(with: .success(()))
        await trackingWaitUntil { preference.pendingWriteCount == 1 && preference.invocations.count == 2 }
        XCTAssertEqual(preference.invocations, [true, false])
        XCTAssertTrue(viewModel.isPersistingPreference)

        preference.completeWrite(with: .success(()))
        await trackingWaitUntil { !viewModel.isPersistingPreference }
        XCTAssertFalse(preference.autoSyncTrackersToLocal)
        XCTAssertFalse(viewModel.syncTrackersToLocal)
    }

    func testViewModelStateAndLogsExposeNoCredentialsOrTokens() {
        let logger = PresentationEventCaptureSpy()
        let viewModel = makeViewModel(logger: logger)
        viewModel.authenticate(providerID: "anilist")

        let labels = Mirror(reflecting: viewModel).children.compactMap(\.label).joined(separator: " ")
        XCTAssertFalse(labels.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(labels.localizedCaseInsensitiveContains("credentialValue"))
        XCTAssertTrue(logger.formattedMessages.allSatisfy { !$0.contains("anilist") })
    }

    private func makeViewModel(
        service: TrackerSettingsServiceFake? = nil,
        preference: TrackingPreferenceStoreFake? = nil,
        messages: TrackingMessageCaptureSpy? = nil,
        logger: PresentationEventCaptureSpy? = nil
    ) -> TrackerSettingsViewModel {
        TrackerSettingsViewModel(
            service: service ?? TrackerSettingsServiceFake(
                state: state(providers: [provider(id: "anilist")])
            ),
            settingsStore: preference ?? TrackingPreferenceStoreFake(initialValue: false),
            messagePresenter: messages ?? TrackingMessageCaptureSpy(),
            presentationLogger: logger ?? PresentationEventCaptureSpy()
        )
    }

    func testTokenTrackerOpensTokenSheetInsteadOfOAuthAndSignsInWithTheToken() async {
        var mangaBaka = provider(id: "mangabaka")
        mangaBaka.tokenCreationURL = URL(string: "https://mangabaka.org/my/settings/api-and-apps")
        let service = TrackerSettingsServiceFake(state: state(providers: [mangaBaka]))
        let viewModel = makeViewModel(service: service)

        viewModel.authenticate(providerID: "mangabaka")

        XCTAssertEqual(viewModel.signInSheetProvider, mangaBaka)
        XCTAssertTrue(service.authenticationInvocations.isEmpty)
        XCTAssertFalse(viewModel.isAuthenticationOperationActive)

        viewModel.signIn(providerID: "mangabaka", token: "mb-token")
        await trackingWaitUntil { !viewModel.isAuthenticationOperationActive }

        XCTAssertNil(viewModel.signInSheetProvider)
        XCTAssertEqual(service.tokenAuthenticationInvocations.map(\.providerID), ["mangabaka"])
        XCTAssertEqual(service.tokenAuthenticationInvocations.map(\.token), ["mb-token"])
        XCTAssertTrue(service.authenticationInvocations.isEmpty)
        XCTAssertNil(viewModel.failure(for: "mangabaka"))
    }

    func testRejectedTokenIsReportedAsSuch() async {
        var mangaBaka = provider(id: "mangabaka")
        mangaBaka.tokenCreationURL = URL(string: "https://mangabaka.org/my/settings/api-and-apps")
        let service = TrackerSettingsServiceFake(state: state(providers: [mangaBaka]))
        service.authenticationError = TrackerTokenError.rejected
        let viewModel = makeViewModel(service: service)

        viewModel.signIn(providerID: "mangabaka", token: "mb-wrong")
        await trackingWaitUntil { !viewModel.isAuthenticationOperationActive }

        XCTAssertEqual(viewModel.failure(for: "mangabaka"), .tokenRejected)
    }

    private func state(
        credential: TrackerSettingsCredentialState = .ready,
        providers: [TrackerProviderPresentation]
    ) -> TrackerSettingsAuthoritativeState {
        TrackerSettingsAuthoritativeState(credentialState: credential, providers: providers)
    }

    private func provider(
        id: String,
        authenticated: Bool = false,
        username: String? = nil
    ) -> TrackerProviderPresentation {
        TrackerProviderPresentation(
            identifier: id,
            name: id == "anilist" ? "AniList" : "Other",
            isAuthenticated: authenticated,
            username: username
        )
    }
}
