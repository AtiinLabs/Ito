import Foundation

nonisolated protocol LegacyTokenStoring: Sendable {
    func token() async -> String?
    func removeToken() async throws
}

nonisolated enum LegacyTokenStoreError: Error, Equatable, Sendable, LocalizedError {
    case removalNotVerified

    var errorDescription: String? {
        String(localized: "Legacy credential removal could not be verified.")
    }
}

actor LegacyTokenStore: LegacyTokenStoring {
    static let anilistTokenKey = "anilist_access_token"

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = LegacyTokenStore.anilistTokenKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    #if DEBUG
    init(
        suiteName: String,
        key: String = LegacyTokenStore.anilistTokenKey
    ) {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated defaults suite.")
        }
        self.defaults = defaults
        self.key = key
    }
    #endif

    func token() -> String? {
        defaults.string(forKey: key)
    }

    func removeToken() throws {
        defaults.removeObject(forKey: key)
        guard defaults.object(forKey: key) == nil else {
            throw LegacyTokenStoreError.removalNotVerified
        }
    }
}
