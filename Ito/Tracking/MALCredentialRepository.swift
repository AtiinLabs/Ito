import Foundation
import mal
import OSLog
import UIKit

/// Refreshes MyAnimeList tokens. `MALOAuth` in production; fakes in tests.
nonisolated protocol MALTokenRefreshing: Sendable {
    func refresh(_ token: MALToken) async throws -> MALToken
}

nonisolated extension MALOAuth: MALTokenRefreshing {}

/// Keeps work alive while the app moves to the background, so a token rotation that MyAnimeList
/// has already accepted is not abandoned before the new token reaches the Keychain.
nonisolated struct BackgroundExecution: Sendable {
    let run: @Sendable (_ work: @escaping @Sendable () async throws -> MALToken) async throws -> MALToken

    static let none = BackgroundExecution { work in try await work() }

    /// Runs the work inside a UIKit background task.
    static let application = BackgroundExecution { work in
        let identifier = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "MyAnimeList token refresh", expirationHandler: nil)
        }
        do {
            let result = try await work()
            await MainActor.run { UIApplication.shared.endBackgroundTask(identifier) }
            return result
        } catch {
            await MainActor.run { UIApplication.shared.endBackgroundTask(identifier) }
            throw error
        }
    }
}

/// The signed-in MyAnimeList session: the token in the Keychain and its refresh.
///
/// MyAnimeList rotates refresh tokens: every refresh returns a new refresh token and revokes the
/// old one. So a refresh runs at most once at a time, is never cancelled by a caller, and its
/// result is kept in memory until the Keychain write succeeds.
actor MALCredentialRepository {
    nonisolated enum BootstrapState: Equatable, Sendable {
        case notStarted
        case ready
        case retryableProtectedDataFailure
    }

    nonisolated enum CredentialError: Error, Equatable, Sendable, LocalizedError {
        /// No MyAnimeList session.
        case notSignedIn
        /// MyAnimeList rejected the refresh token; the session was removed.
        case sessionExpired

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                "Not signed in to MyAnimeList."
            case .sessionExpired:
                "The MyAnimeList session expired. Sign in again."
            }
        }
    }

    static let providerID = "myanimelist"

    private let store: any TrackerCredentialStoring
    private let refresher: any MALTokenRefreshing
    private let backgroundExecution: BackgroundExecution
    private let now: @Sendable () -> Date
    private(set) var bootstrapState: BootstrapState = .notStarted
    private var token: MALToken?
    /// A token MyAnimeList issued that is not yet in the Keychain.
    private var pendingPersistence: MALToken?
    /// Incremented on sign-in and sign-out so a refresh that finishes afterwards is discarded.
    private var sessionEpoch: UInt64 = 0
    private var refreshTask: Task<MALToken, any Error>?

    init(
        store: any TrackerCredentialStoring,
        refresher: any MALTokenRefreshing,
        backgroundExecution: BackgroundExecution = .none,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.refresher = refresher
        self.backgroundExecution = backgroundExecution
        self.now = now
    }

    /// Loads the stored session. Never touches the network.
    /// - Returns: The resulting state and whether a session exists.
    func bootstrap() async -> (state: BootstrapState, isSignedIn: Bool) {
        if bootstrapState == .ready {
            await flushPendingPersistence()
            return (.ready, token != nil)
        }
        do {
            if let stored = try await store.token(for: Self.providerID) {
                token = try JSONDecoder().decode(MALToken.self, from: Data(stored.utf8))
            } else {
                token = nil
            }
            bootstrapState = .ready
        } catch TrackerCredentialStoreError.protectedDataUnavailable {
            bootstrapState = .retryableProtectedDataFailure
        } catch {
            // Unreadable credentials count as signed out, so signing in again replaces them.
            AppLogger.auth.error("Stored MyAnimeList credentials are unreadable: \(error.localizedDescription)")
            token = nil
            bootstrapState = .ready
        }
        return (bootstrapState, token != nil)
    }

    /// Stores a token from a completed sign-in, replacing any earlier session.
    func persist(_ newToken: MALToken) async {
        sessionEpoch += 1
        refreshTask = nil
        token = newToken
        pendingPersistence = newToken
        bootstrapState = .ready
        await flushPendingPersistence()
    }

    /// Ends the session locally. MyAnimeList has no token revocation endpoint.
    func logout() async throws {
        sessionEpoch += 1
        refreshTask = nil
        token = nil
        pendingPersistence = nil
        try await store.removeToken(for: Self.providerID)
        bootstrapState = .ready
    }

    /// An access token that is not about to expire, refreshing it first when needed.
    func validAccessToken() async throws -> String {
        await flushPendingPersistence()
        guard let token else { throw CredentialError.notSignedIn }
        if !token.isExpired(at: now(), leeway: 60) {
            return token.accessToken
        }
        return try await refreshed(from: token).accessToken
    }

    /// A replacement for an access token MyAnimeList rejected with HTTP 401. When another caller
    /// already replaced it, returns the current token without refreshing again.
    func accessToken(replacing failedAccessToken: String) async throws -> String {
        guard let token else { throw CredentialError.notSignedIn }
        if token.accessToken != failedAccessToken {
            return token.accessToken
        }
        return try await refreshed(from: token).accessToken
    }

    private func refreshed(from oldToken: MALToken) async throws -> MALToken {
        if let refreshTask {
            return try await refreshTask.value
        }
        let epoch = sessionEpoch
        // Unstructured on purpose: cancelling a caller must not cancel a rotation in flight.
        let task = Task { try await self.performRefresh(from: oldToken, epoch: epoch) }
        refreshTask = task
        return try await task.value
    }

    private func performRefresh(from oldToken: MALToken, epoch: UInt64) async throws -> MALToken {
        defer {
            if epoch == sessionEpoch {
                refreshTask = nil
            }
        }
        let newToken: MALToken
        do {
            newToken = try await backgroundExecution.run { [refresher] in
                try await refresher.refresh(oldToken)
            }
        } catch let error as MALError where error.statusCode == 400 || error.statusCode == 401 {
            guard epoch == sessionEpoch else { throw CredentialError.notSignedIn }
            AppLogger.auth.error("MyAnimeList rejected the refresh token; signing out.")
            sessionEpoch += 1
            refreshTask = nil
            token = nil
            pendingPersistence = nil
            try? await store.removeToken(for: Self.providerID)
            throw CredentialError.sessionExpired
        }
        guard epoch == sessionEpoch else { throw CredentialError.notSignedIn }
        token = newToken
        pendingPersistence = newToken
        await flushPendingPersistence()
        return newToken
    }

    /// Writes a token MyAnimeList issued to the Keychain. On failure (for example a locked
    /// device) it stays in memory and is written on the next call.
    private func flushPendingPersistence() async {
        guard let pending = pendingPersistence else { return }
        do {
            guard let encoded = String(bytes: try JSONEncoder().encode(pending), encoding: .utf8) else { return }
            try await store.setToken(encoded, for: Self.providerID)
            if pendingPersistence == pending {
                pendingPersistence = nil
            }
        } catch {
            AppLogger.auth.error("Saving MyAnimeList credentials failed; will retry.")
        }
    }
}
