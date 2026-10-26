#if DEBUG
import Combine
import Foundation
import GRDB
import ito_runner

struct UITestLaunchConfiguration {
    nonisolated static let resetStorageArgument = "--ui-test-reset-storage"
    nonisolated static let repositoryDeepLinkArgument = "--ui-test-repository-deep-link"
    nonisolated static let backupWipeArgument = "--ui-test-backup-wipe"
    nonisolated static let mangaReaderArgument = "--ui-test-manga-reader"
    nonisolated static let repositoryURLString = "https://repository.ui-test.invalid/fixture"
    nonisolated static let fixtureDirectoryName = "UITestFixtures"
    nonisolated static let productionDatabaseDirectoryName = "Database"
    nonisolated static let fixtureDatabaseDirectoryName = "Database"
    nonisolated static let fixturePluginsDirectoryName = "Plugins"
    nonisolated static let fixtureDefaultsSuiteName = "moe.itoapp.ito.ui-tests"
    nonisolated static let fixtureTrackerKeychainService =
        "moe.itoapp.ito.ui-tests.tracker.oauth-token"
    nonisolated static let fixturePluginSecretKeychainService =
        "moe.itoapp.ito.ui-tests.plugin-secret"
    nonisolated static let fixturePluginCookieKeychainService =
        "moe.itoapp.ito.ui-tests.plugin-cookies"
    nonisolated static let fixturePluginTokenKeychainService =
        "moe.itoapp.ito.ui-tests.plugin-tokens"
    nonisolated static let fixturePluginTrustKeychainService =
        "moe.itoapp.ito.ui-tests.plugin-tls-trust"

    let resetsStorage: Bool
    let repositoryDeepLinkEnabled: Bool
    let backupWipeEnabled: Bool
    let mangaReaderEnabled: Bool

    static var current: Self {
        let arguments = ProcessInfo.processInfo.arguments
        return Self(
            resetsStorage: arguments.contains(resetStorageArgument),
            repositoryDeepLinkEnabled: arguments.contains(repositoryDeepLinkArgument),
            backupWipeEnabled: arguments.contains(backupWipeArgument),
            mangaReaderEnabled: arguments.contains(mangaReaderArgument)
        )
    }

    var isEnabled: Bool {
        resetsStorage || repositoryDeepLinkEnabled || backupWipeEnabled || mangaReaderEnabled
    }

    nonisolated static func fixtureRootURL(fileManager: FileManager = .default) throws -> URL {
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupportURL.appendingPathComponent(fixtureDirectoryName, isDirectory: true)
    }

    static var repositoryDeepLink: URL {
        var components = URLComponents()
        components.scheme = "ito"
        components.host = "repo"
        components.path = "/add"
        components.queryItems = [
            URLQueryItem(name: "url", value: repositoryURLString)
        ]
        return components.url!
    }

    nonisolated static func repositoryIndexData(for url: URL) throws -> Data {
        guard url.absoluteString == "\(repositoryURLString)/index.json" else {
            throw URLError(.unsupportedURL)
        }
        return Data(
            """
            {
              "repo_name": "UI Test Repository",
              "repo_url": "\(repositoryURLString)",
              "description": "Disposable local UI test fixture",
              "packages": []
            }
            """.utf8
        )
    }
}

@MainActor
final class UITestLaunchFixtureCoordinator: ObservableObject {
    enum BackupFixtureState: String {
        case unavailable = "Backup fixture unavailable"
        case preparing = "Preparing backup fixture"
        case itemPresent = "Fixture item present"
        case itemRemoved = "Fixture item removed"
        case failed = "Backup fixture failed"
    }

    static let shared = UITestLaunchFixtureCoordinator()
    nonisolated static let backupFixtureItemID = "ui-test-backup-fixture-item"

    @Published private(set) var backupURL: URL?
    @Published private(set) var backupFixtureState: BackupFixtureState = .unavailable

    private var hasPrepared = false

    private init() {}

    func prepareIfNeeded(
        appScope: AppScope,
        backupManager: BackupManager,
        libraryManager: LibraryManager
    ) async {
        let configuration = UITestLaunchConfiguration.current
        guard configuration.isEnabled, !hasPrepared else { return }
        hasPrepared = true

        if configuration.repositoryDeepLinkEnabled {
            appScope.router.handleRepositoryDeepLink(UITestLaunchConfiguration.repositoryDeepLink)
        }

        if configuration.backupWipeEnabled {
            await prepareBackupFixture(
                backupManager: backupManager,
                libraryManager: libraryManager
            )
        }
    }

    func redeliverRepositoryDeepLink(using router: AppRouter) {
        guard UITestLaunchConfiguration.current.repositoryDeepLinkEnabled else { return }
        router.handleRepositoryDeepLink(UITestLaunchConfiguration.repositoryDeepLink)
    }

    func refreshBackupFixtureState() async {
        guard UITestLaunchConfiguration.current.backupWipeEnabled else { return }
        do {
            let exists = try await AppDatabase.shared.dbPool.read { database in
                try LibraryItem.fetchOne(
                    database,
                    key: Self.backupFixtureItemID
                ) != nil
            }
            backupFixtureState = exists ? .itemPresent : .itemRemoved
        } catch {
            backupFixtureState = .failed
        }
    }

    private func prepareBackupFixture(
        backupManager: BackupManager,
        libraryManager: LibraryManager
    ) async {
        backupFixtureState = .preparing
        do {
            // The v9 migration guarantees the system list.
            let categoryID = try await AppDatabase.shared.dbPool.read { database in
                try String.fetchOne(
                    database,
                    sql: "SELECT id FROM libraryCategory WHERE isSystemCategory = 1"
                )
            }
            guard let categoryID else {
                backupFixtureState = .failed
                return
            }
            let backupURL = try await backupManager.createBackupFile()
            try await AppDatabase.shared.dbPool.write { database in
                let item = LibraryItem(
                    id: Self.backupFixtureItemID,
                    title: "Disposable Backup Fixture",
                    coverUrl: nil,
                    pluginId: "ui-test-plugin",
                    isAnime: false,
                    pluginType: .manga,
                    rawPayload: Data(),
                    anilistId: nil
                )
                try item.insert(database)
                try ItemCategoryLink(itemId: item.id, categoryId: categoryID)
                    .insert(database)
            }
            try await libraryManager.reload()
            self.backupURL = backupURL
            backupFixtureState = .itemPresent
        } catch {
            backupFixtureState = .failed
        }
    }
}
#endif
