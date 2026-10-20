import Foundation
import MangaBakaSDK
import OSLog

/// Refreshes MangaBaka OAuth tokens. `MangaBakaOAuth` in production; fakes in tests.
nonisolated protocol MangaBakaTokenRefreshing: Sendable {
    func refresh(_ token: MangaBakaToken) async throws -> MangaBakaToken
}

nonisolated extension MangaBakaOAuth: MangaBakaTokenRefreshing {}

/// The signed-in MangaBaka session in the Keychain: an OAuth token from "Login with MangaBaka",
/// or a Personal Access Token the user pasted.
///
/// OAuth refresh tokens may be replaced on every refresh, so a refresh runs at most once at a
/// time, is never cancelled by a caller, and its result is kept in memory until the Keychain write
/// succeeds. Personal Access Tokens do not expire; one is removed when MangaBaka rejects it.
actor MangaBakaCredentialRepository {
    nonisolated enum BootstrapState: Equatable, Sendable {
        case notStarted
        case ready
        case retryableProtectedDataFailure
    }

    nonisolated enum CredentialError: Error, Equatable, Sendable, LocalizedError, TrackerUserFacingError {
        /// No MangaBaka session.
        case notSignedIn
        /// MangaBaka rejected the saved Personal Access Token; the session was removed.
        case tokenRejected
        /// MangaBaka rejected the refresh token; the session was removed.
        case sessionExpired

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                "Not signed in to MangaBaka."
            case .tokenRejected:
                "MangaBaka no longer accepts the saved token. Sign in again."
            case .sessionExpired:
                "The MangaBaka session expired. Sign in again."
            }
        }

        var userMessage: String {
            errorDescription ?? "Sign in to MangaBaka again."
        }
    }

    /// What is stored in the Keychain, as JSON.
    nonisolated enum StoredCredential: Codable, Equatable, Sendable {
        case oauth(MangaBakaToken)
        case personalAccessToken(String)

        var requestCredential: MangaBakaCredential {
            switch self {
            case .oauth(let token): .oauthAccessToken(token.accessToken)
            case .personalAccessToken(let token): .personalAccessToken(token)
            }
        }
    }

    static let providerID = "mangabaka"

    private let store: any TrackerCredentialStoring
    private let refresher: any MangaBakaTokenRefreshing
    private let backgroundExecution: BackgroundExecution
    private let now: @Sendable () -> Date
    private(set) var bootstrapState: BootstrapState = .notStarted
    private var credential: StoredCredential?
    /// A credential not yet in the Keychain.
    private var pendingPersistence: StoredCredential?
    /// Incremented on sign-in and sign-out so a refresh that finishes afterwards is discarded.
    private var sessionEpoch: UInt64 = 0
    private var refreshTask: Task<MangaBakaToken, any Error>?

    init(
        store: any TrackerCredentialStoring,
        refresher: any MangaBakaTokenRefreshing,
        backgroundExecution: BackgroundExecution = .none,
        now: @escaping @Sendable () -> Date = { Date() }
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
            return (.ready, credential != nil)
        }
        do {
            credential = try await store.token(for: Self.providerID).map {
                try JSONDecoder().decode(StoredCredential.self, from: Data($0.utf8))
            }
            bootstrapState = .ready
        } catch TrackerCredentialStoreError.protectedDataUnavailable {
            bootstrapState = .retryableProtectedDataFailure
        } catch {
            // Unreadable credentials count as signed out, so signing in again replaces them.
            AppLogger.auth.error("Stored MangaBaka credentials are unreadable: \(error.localizedDescription)")
            credential = nil
            bootstrapState = .ready
        }
        return (bootstrapState, credential != nil)
    }

    /// Stores a credential from a completed sign-in, replacing any earlier session. When the
    /// Keychain cannot take it yet, it is kept in memory and written on the next call.
    func persist(_ newCredential: StoredCredential) async {
        sessionEpoch += 1
        refreshTask = nil
        credential = newCredential
        pendingPersistence = newCredential
        bootstrapState = .ready
        await flushPendingPersistence()
    }

    /// Whether a session is signed in, including one the Keychain has not taken yet.
    var hasSession: Bool {
        credential != nil
    }

    /// Ends the session locally. When the Keychain cannot remove it, the session is kept, so the
    /// Keychain and memory agree and a retry can still revoke it.
    /// - Returns: The OAuth token that was signed in, so it can be revoked on MangaBaka.
    func logout() async throws -> MangaBakaToken? {
        let previous = credential
        let previousPending = pendingPersistence
        sessionEpoch += 1
        let epoch = sessionEpoch
        refreshTask = nil
        credential = nil
        pendingPersistence = nil
        do {
            try await store.removeToken(for: Self.providerID)
        } catch {
            if epoch == sessionEpoch {
                credential = previous
                pendingPersistence = previousPending
            }
            throw error
        }
        bootstrapState = .ready
        if case .oauth(let token)? = previous {
            return token
        }
        return nil
    }

    /// The credential to send, refreshing an OAuth token that is about to expire.
    func validCredential() async throws -> MangaBakaCredential {
        await flushPendingPersistence()
        switch credential {
        case nil:
            throw CredentialError.notSignedIn
        case .personalAccessToken(let token):
            return .personalAccessToken(token)
        case .oauth(let token) where token.isExpired(at: now(), leeway: 60):
            return .oauthAccessToken(try await refreshed(from: token).accessToken)
        case .oauth(let token):
            return .oauthAccessToken(token.accessToken)
        }
    }

    /// A replacement for a credential MangaBaka rejected with HTTP 401. Returns the current
    /// credential when the session changed since the request started; otherwise refreshes an
    /// OAuth token, or removes a rejected Personal Access Token.
    func credential(replacing rejected: MangaBakaCredential) async throws -> MangaBakaCredential {
        guard let current = credential else { throw CredentialError.notSignedIn }
        if current.requestCredential != rejected {
            return current.requestCredential
        }
        switch current {
        case .oauth(let token):
            return .oauthAccessToken(try await refreshed(from: token).accessToken)
        case .personalAccessToken:
            throw await self.rejected(rejected)
        }
    }

    /// Ends the session when MangaBaka rejects its credential and no replacement can help (a Personal
    /// Access Token, or an OAuth token that was just refreshed), so the user signs in again.
    /// - Returns: The error to report; `notSignedIn` when the session already changed.
    func rejected(_ rejected: MangaBakaCredential) async -> CredentialError {
        guard let current = credential, current.requestCredential == rejected else { return .notSignedIn }
        AppLogger.auth.error("MangaBaka rejected the saved credential; signing out.")
        sessionEpoch += 1
        refreshTask = nil
        credential = nil
        pendingPersistence = nil
        try? await store.removeToken(for: Self.providerID)
        if case .oauth = current {
            return .sessionExpired
        }
        return .tokenRejected
    }

    private func refreshed(from oldToken: MangaBakaToken) async throws -> MangaBakaToken {
        if let refreshTask {
            return try await refreshTask.value
        }
        let epoch = sessionEpoch
        // Unstructured on purpose: cancelling a caller must not cancel a rotation in flight.
        let task = Task { try await self.performRefresh(from: oldToken, epoch: epoch) }
        refreshTask = task
        return try await task.value
    }

    private func performRefresh(from oldToken: MangaBakaToken, epoch: UInt64) async throws -> MangaBakaToken {
        defer {
            if epoch == sessionEpoch {
                refreshTask = nil
            }
        }
        let newToken: MangaBakaToken
        do {
            newToken = try await backgroundExecution.run("MangaBaka token refresh") { [refresher] in
                try await refresher.refresh(oldToken)
            }
        } catch let error as MangaBakaOAuthError where error.isInvalidGrant {
            guard epoch == sessionEpoch else { throw CredentialError.notSignedIn }
            AppLogger.auth.error("MangaBaka rejected the refresh token; signing out.")
            sessionEpoch += 1
            refreshTask = nil
            credential = nil
            pendingPersistence = nil
            try? await store.removeToken(for: Self.providerID)
            throw CredentialError.sessionExpired
        }
        guard epoch == sessionEpoch else { throw CredentialError.notSignedIn }
        credential = .oauth(newToken)
        pendingPersistence = .oauth(newToken)
        await flushPendingPersistence()
        return newToken
    }

    /// Writes a credential to the Keychain. On failure (for example a locked device) it stays in
    /// memory and is written on the next call.
    private func flushPendingPersistence() async {
        guard let pending = pendingPersistence else { return }
        do {
            guard let encoded = String(bytes: try JSONEncoder().encode(pending), encoding: .utf8) else { return }
            try await store.setToken(encoded, for: Self.providerID)
            if pendingPersistence == pending {
                pendingPersistence = nil
            }
        } catch {
            AppLogger.auth.error("Saving MangaBaka credentials failed; will retry.")
        }
    }
}
