import Foundation
import GRDB
import OSLog

/// One-time setup for this database, run during bootstrap:
/// - removes plugin secrets, plugin tokens and website cookies an earlier installation left in the
///   Keychain (iOS keeps Keychain items after the app is deleted, so a reinstall would otherwise
///   inherit old credentials and sessions);
/// - adds the AtiinLabs plugin repository. It is added once: a user who removes it keeps it removed.
///
/// If the Keychain can't be cleared yet (a background launch before the first unlock), nothing is
/// recorded and the setup runs again on the next launch.
struct FirstRunSetupBootstrapExtension: DurableStateBootstrapExtension {
    private let secrets: PluginSecretStore
    private let cookies: PluginCookieJar
    private let tokens: PluginSecretStore
    private let defaultRepositoryURL: String
    private let clock: @Sendable () -> Date

    init(
        secrets: PluginSecretStore,
        cookies: PluginCookieJar,
        tokens: PluginSecretStore,
        defaultRepositoryURL: String = RepoManager.defaultRepositoryURL,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.secrets = secrets
        self.cookies = cookies
        self.tokens = tokens
        self.defaultRepositoryURL = defaultRepositoryURL
        self.clock = clock
    }

    func prepare(dbPool: DatabasePool) async throws {
        let hasRun = try await dbPool.read { db in
            try FirstRunSetupRecord.fetchCount(db) > 0
        }
        guard !hasRun else { return }

        do {
            try secrets.removeAll()
            try cookies.removeEveryPlugin()
            try tokens.removeAll()
        } catch {
            AppLogger.plugin.error("First-run setup deferred: plugin secrets, tokens or cookies could not be cleared.")
            return
        }

        let completedAt = clock()
        let repositoryURL = defaultRepositoryURL
        try await dbPool.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO repository (url, lastFetched, indexPayload) VALUES (?, NULL, NULL)",
                arguments: [repositoryURL]
            )
            try FirstRunSetupRecord(completedAt: completedAt).insert(db)
        }
    }
}
