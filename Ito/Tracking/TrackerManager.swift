import Combine
import Foundation
import GRDB
import mal
import MangaBakaSDK
import OSLog

@MainActor
public final class TrackerManager: ObservableObject {
    enum CredentialBootstrapState: Equatable {
        case notStarted
        case inFlight
        case ready
        case retryableProtectedDataFailure
        case recoverableVerificationFailure
        case conflict
        case permanentFailure
    }

    @Published private var trackerMappings: [MediaIdentity: [String: String]] = [:]
    /// AniList's credential state; kept as the overall state for existing consumers.
    @Published private(set) var credentialBootstrapState: CredentialBootstrapState = .notStarted
    @Published private(set) var malCredentialBootstrapState: CredentialBootstrapState = .notStarted
    @Published private(set) var mangaBakaCredentialBootstrapState: CredentialBootstrapState = .notStarted

    public let providers: [any TrackerProvider]

    private let dbPool: DatabasePool
    private let anilistTracker: AnilistTracker
    private let malTracker: MALTracker
    private let mangaBakaTracker: MangaBakaTracker
    private var credentialBootstrapTask: Task<AniListCredentialRepository.BootstrapOutcome, any Error>?
    private var malBootstrapTask: Task<MALCredentialRepository.BootstrapState, Never>?
    private var mangaBakaBootstrapTask: Task<MangaBakaCredentialRepository.BootstrapState, Never>?

    init(
        dbPool: DatabasePool,
        credentialStore: any TrackerCredentialStoring,
        malCredentialStore: any TrackerCredentialStoring,
        mangaBakaCredentialStore: any TrackerCredentialStoring,
        legacyTokenStore: any LegacyTokenStoring,
        usernameDefaults: UserDefaults,
        backgroundExecution: BackgroundExecution = .none,
        malSession: URLSession = .shared,
        mangaBakaSession: URLSession = .shared
    ) {
        self.dbPool = dbPool
        let credentialRepository = AniListCredentialRepository(
            secureStore: credentialStore,
            legacyStore: legacyTokenStore
        )
        let tracker = AnilistTracker(
            credentialRepository: credentialRepository,
            usernameDefaults: usernameDefaults
        )
        let malOAuth = MALOAuth(clientID: MALTracker.clientID, session: malSession)
        let malTracker = MALTracker(
            credentialRepository: MALCredentialRepository(
                store: malCredentialStore,
                refresher: malOAuth,
                backgroundExecution: backgroundExecution
            ),
            oauth: malOAuth,
            usernameDefaults: usernameDefaults,
            session: malSession
        )
        anilistTracker = tracker
        self.malTracker = malTracker
        let mangaBakaOAuth = MangaBakaOAuth(
            clientID: MangaBakaTracker.clientID,
            redirectURI: MangaBakaTracker.redirectURI,
            session: mangaBakaSession
        )
        mangaBakaTracker = MangaBakaTracker(
            credentialRepository: MangaBakaCredentialRepository(
                store: mangaBakaCredentialStore,
                refresher: mangaBakaOAuth,
                backgroundExecution: backgroundExecution
            ),
            oauth: mangaBakaOAuth,
            usernameDefaults: usernameDefaults,
            session: mangaBakaSession
        )
        providers = [tracker, malTracker, mangaBakaTracker]
    }

    func reload() async throws {
        let records = try await dbPool.read { db in
            try TrackerLinkRecord.fetchAll(db)
        }
        trackerMappings = Dictionary(grouping: records) {
            MediaIdentity(pluginId: $0.pluginId, canonicalMediaId: $0.canonicalMediaId)
        }.mapValues { Dictionary(uniqueKeysWithValues: $0.map { ($0.providerId, $0.remoteMediaId) }) }
    }

    /// Loads every provider's saved credentials. Providers load independently, so a failure in
    /// one never blocks another.
    func bootstrapCredentials() async {
        async let anilist: Void = bootstrapAniListCredentials()
        async let mal: Void = bootstrapMALCredentials()
        async let mangaBaka: Void = bootstrapMangaBakaCredentials()
        _ = await (anilist, mal, mangaBaka)
    }

    func credentialBootstrapState(for providerID: String) -> CredentialBootstrapState {
        switch providerID {
        case malTracker.identifier: malCredentialBootstrapState
        case mangaBakaTracker.identifier: mangaBakaCredentialBootstrapState
        default: credentialBootstrapState
        }
    }

    private func bootstrapAniListCredentials() async {
        switch credentialBootstrapState {
        case .ready, .conflict, .permanentFailure:
            return
        case .notStarted, .inFlight, .retryableProtectedDataFailure, .recoverableVerificationFailure:
            break
        }
        if let credentialBootstrapTask {
            await finishBootstrap(credentialBootstrapTask)
            return
        }
        credentialBootstrapState = .inFlight
        let task = Task { try await anilistTracker.bootstrapCredentials() }
        credentialBootstrapTask = task
        await finishBootstrap(task)
    }

    private func bootstrapMALCredentials() async {
        // `.ready` still runs: it flushes a refreshed token the Keychain could not take yet.
        let task = malBootstrapTask ?? Task { await malTracker.bootstrapCredentials() }
        malBootstrapTask = task
        if malCredentialBootstrapState != .ready {
            malCredentialBootstrapState = .inFlight
        }
        let state = await task.value
        malBootstrapTask = nil
        malCredentialBootstrapState = switch state {
        case .notStarted: .notStarted
        case .ready: .ready
        case .retryableProtectedDataFailure: .retryableProtectedDataFailure
        }
    }

    private func bootstrapMangaBakaCredentials() async {
        let task = mangaBakaBootstrapTask ?? Task { await mangaBakaTracker.bootstrapCredentials() }
        mangaBakaBootstrapTask = task
        if mangaBakaCredentialBootstrapState != .ready {
            mangaBakaCredentialBootstrapState = .inFlight
        }
        let state = await task.value
        mangaBakaBootstrapTask = nil
        mangaBakaCredentialBootstrapState = switch state {
        case .notStarted: .notStarted
        case .ready: .ready
        case .retryableProtectedDataFailure: .retryableProtectedDataFailure
        }
    }

    private func finishBootstrap(
        _ task: Task<AniListCredentialRepository.BootstrapOutcome, any Error>
    ) async {
        do {
            credentialBootstrapState = CredentialBootstrapState(try await task.value.state)
        } catch {
            credentialBootstrapState = .permanentFailure
        }
        credentialBootstrapTask = nil
    }

    public func link(
        media: MediaIdentity,
        providerId: String,
        remoteMediaId: String
    ) async throws {
        try await dbPool.write { db in
            try TrackerLinkRecord(
                pluginId: media.pluginId,
                canonicalMediaId: media.canonicalMediaId,
                providerId: providerId,
                remoteMediaId: remoteMediaId,
                updatedAt: Date(),
                provenance: .runtime
            ).save(db)
        }
        trackerMappings[media, default: [:]][providerId] = remoteMediaId
    }

    public func unlink(media: MediaIdentity, providerId: String) async throws {
        _ = try await dbPool.write { db in
            try TrackerLinkRecord
                .filter(Column("pluginId") == media.pluginId)
                .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                .filter(Column("providerId") == providerId)
                .deleteAll(db)
        }
        trackerMappings[media]?.removeValue(forKey: providerId)
        if trackerMappings[media]?.isEmpty == true {
            trackerMappings.removeValue(forKey: media)
        }
    }

    public func trackerId(for media: MediaIdentity, providerId: String) -> String? {
        trackerMappings[media]?[providerId]
    }

    /// Whether the media is linked to a tracker the user is signed in to. Links to signed-out trackers do not count.
    public func hasAuthenticatedLink(for media: MediaIdentity) -> Bool {
        authenticatedProviders.contains { trackerMappings[media]?[$0.identifier] != nil }
    }

    public var authenticatedProviders: [any TrackerProvider] {
        providers.filter(\.isAuthenticated)
    }

    public func updateProgress(media: MediaIdentity, progress: Int) async {
        let mappings = trackerMappings[media] ?? [:]
        for provider in authenticatedProviders {
            guard let remoteMediaId = mappings[provider.identifier] else { continue }
            do {
                try await provider.updateProgress(mediaId: remoteMediaId, progress: progress, status: nil)
            } catch {
                AppLogger.auth.error(
                    "Failed to update progress on \(provider.name): \(error.localizedDescription)"
                )
            }
        }
    }
}

private extension TrackerManager.CredentialBootstrapState {
    init(_ state: AniListCredentialRepository.BootstrapState) {
        switch state {
        case .notStarted: self = .notStarted
        case .ready: self = .ready
        case .retryableProtectedDataFailure: self = .retryableProtectedDataFailure
        case .recoverableVerificationFailure: self = .recoverableVerificationFailure
        case .conflict: self = .conflict
        case .permanentFailure: self = .permanentFailure
        }
    }
}
