import Combine
import Foundation
import OSLog
import ito_runner

@MainActor
protocol BrowsePluginManaging: AnyObject {
    var installedPlugins: [String: InstalledPlugin] { get }
    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> { get }

    func reloadInstalledPlugins() async
    /// Pauses source-bound delivery before its installed file can be removed.
    func holdCompletionDelivery(for pluginID: String) async throws
    /// Forgets a removed source's held delivery.
    func purgeCompletionDelivery(for pluginID: String) async
    /// Forgets a deleted plugin's secret settings.
    func removeSecrets(for pluginID: String)
}

@MainActor
protocol BrowseRepositoryManaging: AnyObject {
    var repositories: [Repository] { get }
    var repositoriesPublisher: AnyPublisher<[Repository], Never> { get }

    func addRepository(url: String) async throws -> RepositoryAdditionResult
    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws
    func refreshAll() async
}

@MainActor
protocol BrowsePluginFileOperating: AnyObject {
    func supportsPluginFile(at url: URL) -> Bool
    func installPluginFile(from url: URL) throws
    func deletePluginFile(at url: URL) throws
}

public enum BrowseImportSource: Equatable {
    case drop
    case openURL
}

enum BrowseMessage: Equatable {
    case updateFailed(reason: String)
    case deleteFailed(pluginName: String, reason: String)
    case dropLoadFailed(reason: String)
    case unsupportedPluginFile
    case pluginDirectoryUnavailable
    case importFailed(source: BrowseImportSource, reason: String)
    case repositoryAdded
    case repositoryAlreadyAdded
    case repositoryAddFailed
}

@MainActor
protocol BrowseMessagePresenting: AnyObject {
    func present(_ message: BrowseMessage)
}

extension PluginManager: BrowsePluginManaging {
    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        $installedPlugins.eraseToAnyPublisher()
    }

    /// Deleting a plugin removes its secrets (API keys, passwords), the tokens it stored and its
    /// website cookies from the Keychain. Its plain settings stay, as they always have, so a
    /// reinstall keeps them.
    func removeSecrets(for pluginID: String) {
        do {
            try pluginSettingsStore.secrets.removeAll(pluginID: pluginID)
        } catch {
            AppLogger.plugin.error("The secrets of a deleted plugin could not be removed.")
        }
        do {
            try pluginSettingsStore.tokens.removeAll(pluginID: pluginID)
        } catch {
            AppLogger.plugin.error("The tokens of a deleted plugin could not be removed.")
        }
        do {
            try pluginSettingsStore.cookies.removeAll(pluginID: pluginID)
        } catch {
            AppLogger.plugin.error("The cookies of a deleted plugin could not be removed.")
        }
    }
}

extension RepoManager: BrowseRepositoryManaging {
    var repositoriesPublisher: AnyPublisher<[Repository], Never> {
        $repositories.eraseToAnyPublisher()
    }

    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws {
        try await installPackage(package, repositoryUrl: repositoryURL)
    }
}

enum BrowsePluginFileError: LocalizedError {
    case unsupportedPluginFile
    case pluginsDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedPluginFile:
            return "The selected file is not an Ito plugin."
        case .pluginsDirectoryUnavailable:
            return "The plugins directory is unavailable."
        }
    }
}

@MainActor
final class LocalBrowsePluginFileOperations: BrowsePluginFileOperating, SourcePluginFileDeleting {
    private let fileManager: FileManager
    private let applicationSupportDirectory: URL?
    let configuredPluginsDirectory: URL?

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        pluginsDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory
        self.configuredPluginsDirectory = pluginsDirectory
    }

    func supportsPluginFile(at url: URL) -> Bool {
        url.pathExtension.lowercased() == "ito"
    }

    func installPluginFile(from url: URL) throws {
        guard supportsPluginFile(at: url) else {
            throw BrowsePluginFileError.unsupportedPluginFile
        }

        let pluginsDirectory = try pluginsDirectory()
        let destinationURL = pluginsDirectory.appendingPathComponent(url.lastPathComponent)
        let stagingURL = pluginsDirectory.appendingPathComponent(".browse-import-\(UUID().uuidString)")

        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.copyItem(at: url, to: stagingURL)
        let info: PluginInfo
        do {
            info = try ItoRunner.extractPluginInfo(from: stagingURL).manifest.info
        } catch {
            throw BrowsePluginFileError.unsupportedPluginFile
        }
        if let refusal = info.compatibilityRefusal {
            throw refusal
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    func deletePluginFile(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func snapshotPluginFile(for plugin: InstalledPlugin) throws -> SourcePluginFileSnapshot {
        let pluginURL = try validatedPluginURL(plugin.url)
        let fileData = try Data(contentsOf: pluginURL, options: .mappedIfSafe)
        let extracted = try ItoRunner.extractPluginInfo(from: pluginURL)
        let identity = SourcePluginDeletionIdentity(
            fileURL: pluginURL,
            info: extracted.manifest.info,
            iconData: extracted.icon
        )
        guard identity == SourcePluginDeletionIdentity(plugin: plugin) else {
            throw SourcePluginFileError.stalePluginIdentity
        }
        return SourcePluginFileSnapshot(identity: identity, fileData: fileData)
    }

    func stagePluginFileDeletion(
        from snapshot: SourcePluginFileSnapshot
    ) throws -> any PluginFileDeletionTransaction {
        let pluginURL = try validatedPluginURL(snapshot.identity.fileURL)
        let pluginsDirectory = try pluginsDirectory().standardizedFileURL
        let stagedURL = pluginsDirectory.appendingPathComponent(
            ".source-delete-\(UUID().uuidString).pending",
            isDirectory: false
        )
        try fileManager.moveItem(at: pluginURL, to: stagedURL)
        let transaction = LocalPluginFileDeletionTransaction(
            fileManager: fileManager,
            originalURL: pluginURL,
            stagedURL: stagedURL
        )

        do {
            let stagedData = try Data(contentsOf: stagedURL, options: .mappedIfSafe)
            let extracted = try ItoRunner.extractPluginInfo(from: stagedURL)
            let stagedIdentity = SourcePluginDeletionIdentity(
                fileURL: pluginURL,
                info: extracted.manifest.info,
                iconData: extracted.icon
            )
            guard snapshot.matches(fileData: stagedData), stagedIdentity == snapshot.identity else {
                throw SourcePluginFileError.stalePluginIdentity
            }
            return transaction
        } catch {
            do {
                try transaction.rollback()
            } catch {
                throw SourcePluginFileError.rollbackFailed
            }
            throw error
        }
    }

    private func validatedPluginURL(_ url: URL) throws -> URL {
        let pluginsDirectory = try pluginsDirectory().standardizedFileURL
        let pluginURL = url.standardizedFileURL
        guard pluginURL.pathExtension.lowercased() == "ito",
              pluginURL.deletingLastPathComponent().path == pluginsDirectory.path else {
            throw SourcePluginFileError.invalidPluginLocation
        }
        guard fileManager.fileExists(atPath: pluginURL.path) else {
            throw SourcePluginFileError.missingPluginFile
        }
        return pluginURL
    }

    private func pluginsDirectory() throws -> URL {
        if let configuredPluginsDirectory {
            if !fileManager.fileExists(atPath: configuredPluginsDirectory.path) {
                do {
                    try fileManager.createDirectory(
                        at: configuredPluginsDirectory,
                        withIntermediateDirectories: true
                    )
                } catch {
                    throw BrowsePluginFileError.pluginsDirectoryUnavailable
                }
            }
            return configuredPluginsDirectory
        }

        let baseDirectory: URL
        if let applicationSupportDirectory {
            baseDirectory = applicationSupportDirectory
        } else if let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            baseDirectory = directory
        } else {
            throw BrowsePluginFileError.pluginsDirectoryUnavailable
        }

        let pluginsDirectory = baseDirectory.appendingPathComponent("Plugins", isDirectory: true)
        if !fileManager.fileExists(atPath: pluginsDirectory.path) {
            do {
                try fileManager.createDirectory(
                    at: pluginsDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw BrowsePluginFileError.pluginsDirectoryUnavailable
            }
        }
        return pluginsDirectory
    }
}

@MainActor
final class AppMessageBrowseMessagePresenter: BrowseMessagePresenting {
    private let messageCenter: AppMessageCenter

    init(messageCenter: AppMessageCenter) {
        self.messageCenter = messageCenter
    }

    func present(_ message: BrowseMessage) {
        messageCenter.publish(message.appMessageKind)
    }
}

private extension BrowseMessage {
    var appMessageKind: AppMessageKind {
        switch self {
        case .updateFailed:
            return .browseUpdateFailed
        case .deleteFailed:
            return .browseDeleteFailed
        case .dropLoadFailed:
            return .browseDropLoadFailed
        case .unsupportedPluginFile:
            return .browseUnsupportedPluginFile
        case .pluginDirectoryUnavailable:
            return .browsePluginDirectoryUnavailable
        case .importFailed(let source, _):
            return .browseImportFailed(source)
        case .repositoryAdded:
            return .repositoryAdded
        case .repositoryAlreadyAdded:
            return .repositoryAlreadyAdded
        case .repositoryAddFailed:
            return .repositoryAddFailed
        }
    }
}
