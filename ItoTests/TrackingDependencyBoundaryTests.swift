import XCTest
import ito_runner
@testable import Ito

@MainActor
final class TrackingDependencyBoundaryTests: XCTestCase {
    func testAniListExternalURLAdapterPreservesFormatSpecificLegacyURLs() async throws {
        let applicationOpener = TrackerApplicationURLOpenerFake()
        let opener = TrackerExternalURLOpener(applicationOpener: applicationOpener)

        try await opener.open(
            providerID: "anilist",
            media: trackerTestMedia(id: "manga-id", format: "MANGA")
        )
        try await opener.open(
            providerID: "anilist",
            media: trackerTestMedia(id: "anime-id", format: "TV")
        )

        XCTAssertEqual(
            applicationOpener.urls.map(\.absoluteString),
            ["https://anilist.co/manga/manga-id", "https://anilist.co/anime/anime-id"]
        )
    }

    func testMyAnimeListExternalURLUsesTheLinkedKindAndRejectsMalformedIDs() async throws {
        let applicationOpener = TrackerApplicationURLOpenerFake()
        let opener = TrackerExternalURLOpener(applicationOpener: applicationOpener)

        try await opener.open(providerID: "myanimelist", media: trackerTestMedia(id: "manga:2", format: "TV"))
        try await opener.open(providerID: "myanimelist", media: trackerTestMedia(id: "anime:52991", format: "MANGA"))
        do {
            try await opener.open(providerID: "myanimelist", media: trackerTestMedia(id: "52991"))
            XCTFail("Expected a bare id to be rejected")
        } catch {
            XCTAssertEqual(error as? TrackingServiceError, .providerUnavailable)
        }

        XCTAssertEqual(
            applicationOpener.urls.map(\.absoluteString),
            ["https://myanimelist.net/manga/2", "https://myanimelist.net/anime/52991"]
        )
    }

    func testExternalURLAdapterRejectsUnknownProviderWithoutOpeningURL() async {
        let applicationOpener = TrackerApplicationURLOpenerFake()
        let opener = TrackerExternalURLOpener(applicationOpener: applicationOpener)

        do {
            try await opener.open(providerID: "unknown", media: trackerTestMedia())
            XCTFail("Expected provider rejection")
        } catch {
            XCTAssertEqual(error as? TrackingServiceError, .providerUnavailable)
        }
        XCTAssertTrue(applicationOpener.urls.isEmpty)
    }

    func testTrackingFactorySnapshotsZeroOneAndMultipleAuthenticatedProviders() {
        let identity = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media", mediaKind: .manga)
        let sheetService = TrackerSheetServiceFake()
        let factory = makeFactory(sheetService: sheetService)

        let zero = factory.makeTrackerSheet(
            mediaIdentity: identity,
            title: "Title",
            isAnime: false
        )
        XCTAssertTrue(zero.configuration.providers.isEmpty)

        sheetService.providers = [provider(id: "anilist", name: "AniList")]
        let one = factory.makeTrackerSheet(
            mediaIdentity: identity,
            title: "Title",
            isAnime: false
        )
        XCTAssertEqual(one.configuration.providers.map(\.id), ["anilist"])
        XCTAssertFalse(one.configuration.providers[0].isTracked)

        sheetService.providers.append(provider(id: "second", name: "Second"))
        sheetService.remoteIDs[identity] = ["second": "remote-2"]
        let multiple = factory.makeTrackerSheet(
            mediaIdentity: identity,
            title: "Title",
            isAnime: true
        )
        XCTAssertEqual(multiple.configuration.providers.map(\.id), ["anilist", "second"])
        XCTAssertFalse(multiple.configuration.providers[0].isTracked)
        XCTAssertTrue(multiple.configuration.providers[1].isTracked)
        XCTAssertEqual(multiple.configuration.providers[1].linkedRemoteMediaID, "remote-2")
        XCTAssertEqual(sheetService.lookupRequests.count, 3)
    }

    func testTrackersWithoutAnimeAreOfferedForMangaOnly() {
        let identity = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media", mediaKind: .manga)
        var mangaBaka = provider(id: "mangabaka", name: "MangaBaka")
        mangaBaka.tracksAnime = false
        let sheetService = TrackerSheetServiceFake(providers: [provider(id: "anilist", name: "AniList"), mangaBaka])
        let factory = makeFactory(sheetService: sheetService)

        let anime = factory.makeTrackerSheet(
            mediaIdentity: MediaIdentity(pluginId: "plugin", canonicalMediaId: "media", mediaKind: .anime),
            title: "Title", isAnime: true
        )
        let manga = factory.makeTrackerSheet(mediaIdentity: identity, title: "Title", isAnime: false)

        XCTAssertEqual(anime.configuration.providers.map(\.id), ["anilist"])
        XCTAssertEqual(manga.configuration.providers.map(\.id), ["anilist", "mangabaka"])
    }

    func testMangaBakaLinksOpenTheSeriesPage() {
        let media = TrackerMedia(id: "1995", title: "Frieren", titleRomaji: nil, coverImage: nil, format: "MANGA", episodes: nil, chapters: nil)
        XCTAssertEqual(
            TrackerExternalURLOpener.url(providerID: "mangabaka", media: media)?.absoluteString,
            "https://mangabaka.org/manga/1995"
        )
    }

    func testExistingLinkDestinationUsesStableIdentityMediaKindAndNoService() throws {
        let identity = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media", mediaKind: .manga)
        let sheetService = TrackerSheetServiceFake(
            providers: [provider(id: "anilist", name: "AniList")],
            remoteIDs: [identity: ["anilist": "remote-9"]]
        )
        let factory = makeFactory(sheetService: sheetService)
        let configuration = factory.makeTrackerSheet(
            mediaIdentity: identity,
            title: "Title",
            isAnime: false
        ).configuration
        let destination = try XCTUnwrap(
            factory.makeExistingDetailsDestination(
                configuration: configuration,
                provider: configuration.providers[0]
            )
        )

        XCTAssertEqual(destination.providerID, "anilist")
        XCTAssertEqual(destination.mediaIdentity, identity)
        XCTAssertEqual(destination.media.id, "remote-9")
        XCTAssertEqual(destination.media.title, "Title")
        XCTAssertEqual(destination.media.format, "MANGA")
        XCTAssertTrue(destination.media.isReadingFormat)
        XCTAssertTrue(destination.showCancelButton)
        XCTAssertTrue(destination.isLocallyLinked)
        XCTAssertTrue(Mirror(reflecting: destination).children.allSatisfy {
            !String(describing: type(of: $0.value)).contains("Service")
        })

        let animeConfiguration = factory.makeTrackerSheet(
            mediaIdentity: identity,
            title: "Title",
            isAnime: true
        ).configuration
        let animeDestination = try XCTUnwrap(
            factory.makeExistingDetailsDestination(
                configuration: animeConfiguration,
                provider: animeConfiguration.providers[0]
            )
        )
        XCTAssertEqual(animeDestination.media.format, "TV")
        XCTAssertFalse(animeDestination.media.isReadingFormat)
    }

    func testProviderServiceUsesInjectedOAuthBoundaryForExactProviderAndCancellation() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let suiteName = "TrackingDependencyBoundaryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: defaults
        )
        let authenticator = TrackerOAuthAuthenticatorFake()
        let service = TrackerProviderService(
            trackerManager: manager,
            oauthAuthenticator: authenticator
        )

        try await service.authenticate(providerID: "anilist")
        XCTAssertEqual(authenticator.providerIDs, ["anilist"])

        authenticator.error = CancellationError()
        do {
            try await service.authenticate(providerID: "anilist")
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(authenticator.providerIDs, ["anilist", "anilist"])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await service.authenticate(providerID: "unknown")
            XCTFail("Expected provider rejection")
        } catch {
            XCTAssertEqual(error as? TrackingServiceError, .providerUnavailable)
        }
        XCTAssertEqual(authenticator.providerIDs, ["anilist", "anilist"])
    }

    func testTrackingScreensOwnViewModelsAndContainNoForbiddenPresentationGlobals() throws {
        let paths = [
            "Ito/ViewModels/Tracking/TrackerSettingsViewModel.swift",
            "Ito/ViewModels/Tracking/TrackerSearchViewModel.swift",
            "Ito/ViewModels/Tracking/TrackerDetailsViewModel.swift",
            "Ito/Views/Settings/TrackerSettingsView.swift",
            "Ito/Views/Tracker/TrackerSheets.swift"
        ]
        let sources = try paths.map(source)
        for forbidden in [
            "OAuthManager.shared",
            "UIApplication.shared",
            "SnackBarManager.shared",
            "AppDatabase.shared",
            "UserDefaults.standard",
            "FileManager.default",
            "URLSession.shared",
            "AppLogger",
            "configure(",
            "AnyView"
        ] {
            for (path, contents) in zip(paths, sources) {
                XCTAssertFalse(contents.contains(forbidden), "Forbidden \(forbidden) in \(path)")
            }
        }

        XCTAssertTrue(sources[3].contains("@StateObject private var viewModel"))
        XCTAssertEqual(sources[4].components(separatedBy: "@StateObject private var viewModel").count - 1, 2)
        XCTAssertTrue(
            sources[4].contains(
                ".navigationBarBackButtonHidden(viewModel.isDurableOperationInFlight)"
            )
        )
        XCTAssertTrue(
            sources[4].contains(
                ".interactiveDismissDisabled(viewModel.isDurableOperationInFlight)"
            )
        )
        let appScope = try source("Ito/AppScope.swift")
        XCTAssertFalse(appScope.contains("storedTrackerSettingsViewModel"))
        XCTAssertFalse(appScope.contains("storedTrackerSearchViewModel"))
        XCTAssertFalse(appScope.contains("storedTrackerDetailsViewModel"))
    }

    func testTrackingMessagePresenterPublishesOnlyTypedSanitizedCases() throws {
        let center = AppMessageCenter()
        let presenter = AppMessageTrackingPresenter(messageCenter: center)
        let expected: [(TrackingMessage, AppMessageKind)] = [
            (.preferencePersistenceFailed, .trackingPreferencePersistenceFailed),
            (.remoteUpdateFailed, .trackingRemoteUpdateFailed),
            (.linkPersistenceFailed, .trackingLinkPersistenceFailed),
            (.unlinkFailed, .trackingUnlinkFailed),
            (.externalURLOpenFailed, .trackingExternalPageOpenFailed)
        ]

        for (trackingMessage, expectedKind) in expected {
            presenter.present(trackingMessage)
            let message = try XCTUnwrap(center.currentMessage)
            XCTAssertEqual(message.kind, expectedKind)
            XCTAssertFalse(String(describing: message).contains("secret-token-sentinel"))
            center.dismiss(messageID: message.id)
        }
    }

    private func makeFactory(sheetService: TrackerSheetServiceFake) -> TrackingViewFactory {
        let unavailable = UnavailableTrackingService()
        return TrackingViewFactory(
            dependencies: PreparedTrackingDependencies(
                settingsService: unavailable,
                sheetService: sheetService,
                searchService: unavailable,
                detailsService: unavailable,
                linkStore: unavailable,
                settingsStore: UnavailableTrackingPreferenceStore(),
                localProgressReader: UnavailableTrackerLocalProgressReader(),
                externalURLOpener: UnavailableTrackerExternalURLOpener()
            ),
            messagePresenter: TrackingMessageCaptureSpy(),
            presentationLogger: PresentationEventCaptureSpy()
        )
    }

    private func provider(id: String, name: String) -> TrackerProviderPresentation {
        TrackerProviderPresentation(
            identifier: id,
            name: name,
            isAuthenticated: true,
            username: nil
        )
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
