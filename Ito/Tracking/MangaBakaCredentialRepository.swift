import Foundation
import OSLog

/// The signed-in MangaBaka session: a Personal Access Token in the Keychain.
///
/// MangaBaka offers OAuth only to clients that can keep a secret, so Ito signs in with a token the
/// user creates on mangabaka.org. Tokens do not expire or rotate; one is removed when the user
/// signs out or MangaBaka rejects it.
actor MangaBakaCredentialRepository {
    nonisolated enum BootstrapState: Equatable, Sendable {
        case notStarted
        case ready
        case retryableProtectedDataFailure
    }

    nonisolated enum CredentialError: Error, Equatable, Sendable, LocalizedError, TrackerUserFacingError {
        /// No MangaBaka session.
        case notSignedIn
        /// MangaBaka rejected the stored token; the session was removed.
        case tokenRejected

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                "Not signed in to MangaBaka."
            case .tokenRejected:
                "MangaBaka no longer accepts the saved token. Sign in again."
            }
        }

        var userMessage: String {
            errorDescription ?? "Sign in to MangaBaka again."
        }
    }

    static let providerID = "mangabaka"

    private let store: any TrackerCredentialStoring
    private(set) var bootstrapState: BootstrapState = .notStarted
    private var token: String?

    init(store: any TrackerCredentialStoring) {
        self.store = store
    }

    /// Loads the stored token. Never touches the network.
    /// - Returns: The resulting state and whether a session exists.
    func bootstrap() async -> (state: BootstrapState, isSignedIn: Bool) {
        if bootstrapState == .ready {
            return (.ready, token != nil)
        }
        do {
            token = try await store.token(for: Self.providerID)
            bootstrapState = .ready
        } catch TrackerCredentialStoreError.protectedDataUnavailable {
            bootstrapState = .retryableProtectedDataFailure
        } catch {
            // An unreadable token counts as signed out, so signing in again replaces it.
            AppLogger.auth.error("Stored MangaBaka credentials are unreadable: \(error.localizedDescription)")
            token = nil
            bootstrapState = .ready
        }
        return (bootstrapState, token != nil)
    }

    /// Stores a token MangaBaka accepted, replacing any earlier session. Fails when the Keychain
    /// cannot take it, so the user is not shown as signed in to a session that would not survive.
    func persist(_ newToken: String) async throws {
        try await store.setToken(newToken, for: Self.providerID)
        token = newToken
        bootstrapState = .ready
    }

    /// Ends the session locally. Tokens are revoked on mangabaka.org.
    func logout() async throws {
        token = nil
        try await store.removeToken(for: Self.providerID)
        bootstrapState = .ready
    }

    /// The token to send.
    func currentToken() throws -> String {
        guard let token else { throw CredentialError.notSignedIn }
        return token
    }

    /// Removes a token MangaBaka answered with HTTP 401. A token stored since the request started
    /// is kept.
    /// - Returns: Whether the rejected token was the current one and was removed.
    @discardableResult
    func invalidate(_ rejectedToken: String) async -> Bool {
        guard token == rejectedToken else { return false }
        AppLogger.auth.error("MangaBaka rejected the saved token; signing out.")
        token = nil
        try? await store.removeToken(for: Self.providerID)
        return true
    }
}
