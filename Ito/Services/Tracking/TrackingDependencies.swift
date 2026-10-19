import Combine
import Foundation
import UIKit

struct TrackerProviderPresentation: Identifiable, Equatable {
    let identifier: String
    let name: String
    let isAuthenticated: Bool
    let username: String?
    var credentialState: TrackerSettingsCredentialState = .ready

    var id: String { identifier }
}

enum TrackerSettingsCredentialState: Equatable {
    case loading
    case deferred
    case ready
    case unavailable

    init(_ bootstrapState: TrackerManager.CredentialBootstrapState) {
        switch bootstrapState {
        case .notStarted, .inFlight:
            self = .loading
        case .retryableProtectedDataFailure:
            self = .deferred
        case .ready, .conflict:
            self = .ready
        case .recoverableVerificationFailure, .permanentFailure:
            self = .unavailable
        }
    }
}

struct TrackerSettingsAuthoritativeState: Equatable {
    let credentialState: TrackerSettingsCredentialState
    let providers: [TrackerProviderPresentation]
}

enum TrackingServiceError: Error, Equatable {
    case providerUnavailable
    case unavailable
}

@MainActor
protocol TrackerSettingsServicing: AnyObject {
    var settingsState: TrackerSettingsAuthoritativeState { get }
    var settingsStatePublisher: AnyPublisher<TrackerSettingsAuthoritativeState, Never> { get }

    func authenticate(providerID: String) async throws
    func logout(providerID: String) async throws
    func refreshSettingsState()
}

@MainActor
protocol TrackerOAuthAuthenticating: AnyObject {
    func authenticate(provider: any TrackerProvider) async throws
}

@MainActor
protocol TrackerSheetServicing: AnyObject {
    var sheetStatePublisher: AnyPublisher<Void, Never> { get }
    func authenticatedProviders() -> [TrackerProviderPresentation]
    func hasAuthenticatedLink(for media: MediaIdentity) -> Bool
    func remoteMediaID(for media: MediaIdentity, providerID: String) -> String?
    func refreshState() async throws
}

@MainActor
protocol TrackerSearchServicing: AnyObject {
    func searchMedia(
        providerID: String,
        title: String,
        isAnime: Bool
    ) async throws -> [TrackerMedia]
}

@MainActor
protocol TrackerDetailsServicing: AnyObject {
    func getMediaListEntry(
        providerID: String,
        mediaID: String
    ) async throws -> TrackerMediaEntry?

    func updateProgress(
        providerID: String,
        mediaID: String,
        progress: Int?,
        status: String?
    ) async throws
}

@MainActor
protocol TrackerLinkPersisting: AnyObject {
    func remoteMediaID(for media: MediaIdentity, providerID: String) -> String?

    func link(
        media: MediaIdentity,
        providerID: String,
        remoteMediaID: String
    ) async throws

    func unlink(media: MediaIdentity, providerID: String) async throws
}

@MainActor
protocol TrackerSettingsPreferenceStoring: AnyObject {
    var autoSyncTrackersToLocal: Bool { get }
    func setAutoSyncTrackersToLocal(_ value: Bool) async throws
}

@MainActor
protocol TrackerLocalProgressReading: AnyObject {
    func readProgress(for media: MediaIdentity) -> Set<Float>
}

@MainActor
protocol TrackerExternalURLOpening: AnyObject {
    func open(providerID: String, media: TrackerMedia) async throws
}

enum TrackingMessage: Equatable {
    case preferencePersistenceFailed
    case remoteUpdateFailed
    case linkPersistenceFailed
    case unlinkFailed
    case externalURLOpenFailed
}

@MainActor
protocol TrackingMessagePresenting: AnyObject {
    func present(_ message: TrackingMessage)
}

@MainActor
final class AppMessageTrackingPresenter: TrackingMessagePresenting {
    private let messageCenter: AppMessageCenter

    init(messageCenter: AppMessageCenter) {
        self.messageCenter = messageCenter
    }

    func present(_ message: TrackingMessage) {
        switch message {
        case .preferencePersistenceFailed:
            messageCenter.publish(.trackingPreferencePersistenceFailed)
        case .remoteUpdateFailed:
            messageCenter.publish(.trackingRemoteUpdateFailed)
        case .linkPersistenceFailed:
            messageCenter.publish(.trackingLinkPersistenceFailed)
        case .unlinkFailed:
            messageCenter.publish(.trackingUnlinkFailed)
        case .externalURLOpenFailed:
            messageCenter.publish(.trackingExternalPageOpenFailed)
        }
    }
}

@MainActor
final class NoopTrackingMessagePresenter: TrackingMessagePresenting {
    func present(_ message: TrackingMessage) {
        _ = message
    }
}

extension AppSettingsStore: TrackerSettingsPreferenceStoring {
    func setAutoSyncTrackersToLocal(_ value: Bool) async throws {
        try await set(value, for: AppPreferenceCatalog.autoSyncTrackersToLocal)
    }
}

extension ReadProgressManager: TrackerLocalProgressReading {
    func readProgress(for media: MediaIdentity) -> Set<Float> {
        readChapterNumbers(for: media)
    }
}

extension OAuthManager: TrackerOAuthAuthenticating {
    func authenticate(provider: any TrackerProvider) async throws {
        try await provider.authenticate(using: self)
    }
}

@MainActor
final class TrackerProviderService:
    TrackerSettingsServicing,
    TrackerSheetServicing,
    TrackerSearchServicing,
    TrackerDetailsServicing,
    TrackerLinkPersisting {
    private let trackerManager: TrackerManager
    private let oauthAuthenticator: any TrackerOAuthAuthenticating
    private let stateSubject: CurrentValueSubject<TrackerSettingsAuthoritativeState, Never>
    private let sheetStateSubject = PassthroughSubject<Void, Never>()
    private var cancellables = Set<AnyCancellable>()

    init(
        trackerManager: TrackerManager,
        oauthAuthenticator: any TrackerOAuthAuthenticating
    ) {
        self.trackerManager = trackerManager
        self.oauthAuthenticator = oauthAuthenticator
        stateSubject = CurrentValueSubject(Self.makeSettingsState(from: trackerManager))

        trackerManager.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.publishSettingsState()
                    self?.sheetStateSubject.send()
                }
            }
            .store(in: &cancellables)

        for provider in trackerManager.providers {
            observeSettingsChanges(from: provider)
        }
    }

    var settingsState: TrackerSettingsAuthoritativeState {
        Self.makeSettingsState(from: trackerManager)
    }

    var settingsStatePublisher: AnyPublisher<TrackerSettingsAuthoritativeState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    var sheetStatePublisher: AnyPublisher<Void, Never> {
        sheetStateSubject.eraseToAnyPublisher()
    }

    func authenticate(providerID: String) async throws {
        let provider = try provider(for: providerID)
        try await oauthAuthenticator.authenticate(provider: provider)
        publishSettingsState()
    }

    func logout(providerID: String) async throws {
        let provider = try provider(for: providerID)
        try await provider.logout()
        publishSettingsState()
    }

    func refreshSettingsState() {
        publishSettingsState()
    }

    func authenticatedProviders() -> [TrackerProviderPresentation] {
        trackerManager.authenticatedProviders.map { Self.presentation(for: $0) }
    }

    func hasAuthenticatedLink(for media: MediaIdentity) -> Bool {
        trackerManager.hasAuthenticatedLink(for: media)
    }

    func remoteMediaID(for media: MediaIdentity, providerID: String) -> String? {
        trackerManager.trackerId(for: media, providerId: providerID)
    }

    func refreshState() async throws {
        try await trackerManager.reload()
        publishSettingsState()
    }

    func searchMedia(
        providerID: String,
        title: String,
        isAnime: Bool
    ) async throws -> [TrackerMedia] {
        try await provider(for: providerID).searchMedia(title: title, isAnime: isAnime)
    }

    func getMediaListEntry(
        providerID: String,
        mediaID: String
    ) async throws -> TrackerMediaEntry? {
        try await provider(for: providerID).getMediaListEntry(mediaId: mediaID)
    }

    func updateProgress(
        providerID: String,
        mediaID: String,
        progress: Int?,
        status: String?
    ) async throws {
        try await provider(for: providerID).updateProgress(
            mediaId: mediaID,
            progress: progress,
            status: status
        )
    }

    func link(
        media: MediaIdentity,
        providerID: String,
        remoteMediaID: String
    ) async throws {
        try await trackerManager.link(
            media: media,
            providerId: providerID,
            remoteMediaId: remoteMediaID
        )
    }

    func unlink(media: MediaIdentity, providerID: String) async throws {
        try await trackerManager.unlink(media: media, providerId: providerID)
    }

    private func provider(for identifier: String) throws -> any TrackerProvider {
        guard let provider = trackerManager.providers.first(where: { $0.identifier == identifier }) else {
            throw TrackingServiceError.providerUnavailable
        }
        return provider
    }

    private func observeSettingsChanges<Provider: TrackerProvider>(
        from provider: Provider
    ) {
        provider.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.publishSettingsState()
                    self?.sheetStateSubject.send()
                }
            }
            .store(in: &cancellables)
    }

    private func publishSettingsState() {
        let state = Self.makeSettingsState(from: trackerManager)
        guard stateSubject.value != state else { return }
        stateSubject.send(state)
    }

    private static func makeSettingsState(
        from trackerManager: TrackerManager
    ) -> TrackerSettingsAuthoritativeState {
        TrackerSettingsAuthoritativeState(
            credentialState: TrackerSettingsCredentialState(
                trackerManager.credentialBootstrapState
            ),
            providers: trackerManager.providers.map {
                presentation(for: $0, credentialState: TrackerSettingsCredentialState(
                    trackerManager.credentialBootstrapState(for: $0.identifier)
                ))
            }
        )
    }

    private static func presentation(
        for provider: any TrackerProvider,
        credentialState: TrackerSettingsCredentialState = .ready
    ) -> TrackerProviderPresentation {
        TrackerProviderPresentation(
            identifier: provider.identifier,
            name: provider.name,
            isAuthenticated: provider.isAuthenticated,
            username: provider.username,
            credentialState: credentialState
        )
    }
}

@MainActor
protocol TrackerApplicationURLOpening: AnyObject {
    func open(_ url: URL) async throws
}

@MainActor
final class SystemTrackerApplicationURLOpener: TrackerApplicationURLOpening {
    func open(_ url: URL) async throws {
        guard UIApplication.shared.canOpenURL(url) else {
            throw TrackingServiceError.unavailable
        }
        let opened = await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { opened in
                continuation.resume(returning: opened)
            }
        }
        guard opened else { throw TrackingServiceError.unavailable }
    }
}

@MainActor
final class TrackerExternalURLOpener: TrackerExternalURLOpening {
    private let applicationOpener: any TrackerApplicationURLOpening

    init(applicationOpener: any TrackerApplicationURLOpening) {
        self.applicationOpener = applicationOpener
    }

    func open(providerID: String, media: TrackerMedia) async throws {
        guard let url = Self.url(providerID: providerID, media: media) else {
            throw TrackingServiceError.providerUnavailable
        }
        try await applicationOpener.open(url)
    }

    static func url(providerID: String, media: TrackerMedia) -> URL? {
        switch providerID {
        case "anilist":
            let kind = media.isReadingFormat ? "manga" : "anime"
            return URL(string: "https://anilist.co/\(kind)/\(media.id)")
        case MALCredentialRepository.providerID:
            guard let id = MALMediaID(rawValue: media.id) else { return nil }
            return URL(string: "https://myanimelist.net/\(id.kind.rawValue)/\(id.id)")
        default:
            return nil
        }
    }
}

@MainActor
final class UnavailableTrackingService:
    TrackerSettingsServicing,
    TrackerSheetServicing,
    TrackerSearchServicing,
    TrackerDetailsServicing,
    TrackerLinkPersisting {
    private let subject = CurrentValueSubject<TrackerSettingsAuthoritativeState, Never>(
        .init(credentialState: .unavailable, providers: [])
    )

    var settingsState: TrackerSettingsAuthoritativeState { subject.value }

    var settingsStatePublisher: AnyPublisher<TrackerSettingsAuthoritativeState, Never> {
        subject.eraseToAnyPublisher()
    }

    var sheetStatePublisher: AnyPublisher<Void, Never> {
        Empty().eraseToAnyPublisher()
    }

    func authenticate(providerID: String) async throws {
        _ = providerID
        throw TrackingServiceError.unavailable
    }

    func logout(providerID: String) async throws {
        _ = providerID
        throw TrackingServiceError.unavailable
    }

    func refreshSettingsState() {}

    func authenticatedProviders() -> [TrackerProviderPresentation] { [] }

    func hasAuthenticatedLink(for media: MediaIdentity) -> Bool {
        _ = media
        return false
    }

    func remoteMediaID(for media: MediaIdentity, providerID: String) -> String? {
        _ = media
        _ = providerID
        return nil
    }

    func refreshState() async throws {
        throw TrackingServiceError.unavailable
    }

    func searchMedia(
        providerID: String,
        title: String,
        isAnime: Bool
    ) async throws -> [TrackerMedia] {
        _ = providerID
        _ = title
        _ = isAnime
        throw TrackingServiceError.unavailable
    }

    func getMediaListEntry(
        providerID: String,
        mediaID: String
    ) async throws -> TrackerMediaEntry? {
        _ = providerID
        _ = mediaID
        throw TrackingServiceError.unavailable
    }

    func updateProgress(
        providerID: String,
        mediaID: String,
        progress: Int?,
        status: String?
    ) async throws {
        _ = providerID
        _ = mediaID
        _ = progress
        _ = status
        throw TrackingServiceError.unavailable
    }

    func link(
        media: MediaIdentity,
        providerID: String,
        remoteMediaID: String
    ) async throws {
        _ = media
        _ = providerID
        _ = remoteMediaID
        throw TrackingServiceError.unavailable
    }

    func unlink(media: MediaIdentity, providerID: String) async throws {
        _ = media
        _ = providerID
        throw TrackingServiceError.unavailable
    }
}

@MainActor
final class UnavailableTrackingPreferenceStore: TrackerSettingsPreferenceStoring {
    var autoSyncTrackersToLocal = AppPreferenceCatalog.autoSyncTrackersToLocal.defaultValue

    func setAutoSyncTrackersToLocal(_ value: Bool) async throws {
        _ = value
        throw TrackingServiceError.unavailable
    }
}

@MainActor
final class UnavailableTrackerLocalProgressReader: TrackerLocalProgressReading {
    func readProgress(for media: MediaIdentity) -> Set<Float> {
        _ = media
        return []
    }
}

@MainActor
final class UnavailableTrackerExternalURLOpener: TrackerExternalURLOpening {
    func open(providerID: String, media: TrackerMedia) async throws {
        _ = providerID
        _ = media
        throw TrackingServiceError.unavailable
    }
}

@MainActor
struct PreparedTrackingDependencies {
    let settingsService: any TrackerSettingsServicing
    let sheetService: any TrackerSheetServicing
    let searchService: any TrackerSearchServicing
    let detailsService: any TrackerDetailsServicing
    let linkStore: any TrackerLinkPersisting
    let settingsStore: any TrackerSettingsPreferenceStoring
    let localProgressReader: any TrackerLocalProgressReading
    let externalURLOpener: any TrackerExternalURLOpening

    static func production(
        trackerManager: TrackerManager,
        settingsStore: AppSettingsStore,
        readProgressManager: ReadProgressManager,
        oauthAuthenticator: any TrackerOAuthAuthenticating = OAuthManager.shared,
        applicationURLOpener: any TrackerApplicationURLOpening =
            SystemTrackerApplicationURLOpener()
    ) -> Self {
        let providerService = TrackerProviderService(
            trackerManager: trackerManager,
            oauthAuthenticator: oauthAuthenticator
        )
        return Self(
            settingsService: providerService,
            sheetService: providerService,
            searchService: providerService,
            detailsService: providerService,
            linkStore: providerService,
            settingsStore: settingsStore,
            localProgressReader: readProgressManager,
            externalURLOpener: TrackerExternalURLOpener(
                applicationOpener: applicationURLOpener
            )
        )
    }

    static func unavailable() -> Self {
        let service = UnavailableTrackingService()
        return Self(
            settingsService: service,
            sheetService: service,
            searchService: service,
            detailsService: service,
            linkStore: service,
            settingsStore: UnavailableTrackingPreferenceStore(),
            localProgressReader: UnavailableTrackerLocalProgressReader(),
            externalURLOpener: UnavailableTrackerExternalURLOpener()
        )
    }
}

extension TrackerMedia {
    var isReadingFormat: Bool {
        if let malID = MALMediaID(rawValue: id) {
            return malID.kind == .manga
        }
        return format == "MANGA" || format == "NOVEL" || format == "ONE_SHOT"
    }
}
