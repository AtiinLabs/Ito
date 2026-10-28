import Combine
import CryptoKit
import Foundation
import ito_runner

protocol SourceRunnerContext: SearchDetailLoading {
    var runnerIdentity: ObjectIdentifier { get }
    func loadHome() async throws -> HomeLayout
    func loadSettingsSurface() async throws -> SettingsSurface?
    func loadSearchCapabilities(kind: MediaKind?) async throws -> SearchCapabilities?
    func loadOptionPage(_ request: OptionRequest) async throws -> OptionPage?
    func loadSearchSuggestions(query: String, kind: MediaKind?) async throws -> [SearchSuggestion]?
    func search(
        kind: MediaKind?,
        query: String,
        page: Int32,
        filterValues: [String: ControlValue]
    ) async throws -> MediaPageResult
    func loadListing(
        listing: Listing,
        page: Int32
    ) async throws -> MediaPageResult
}

final class ItoRunnerSourceContext: SourceRunnerContext {
    let runner: ItoRunner

    var runnerIdentity: ObjectIdentifier { ObjectIdentifier(runner) }

    init(runner: ItoRunner) {
        self.runner = runner
    }

    func loadHome() async throws -> HomeLayout {
        try await pluginCall { try await runner.getHome() }
    }

    func loadSettingsSurface() async throws -> SettingsSurface? {
        try await pluginCall { try await runner.getSettingsSurface() }
    }

    func loadSearchCapabilities(kind: MediaKind?) async throws -> SearchCapabilities? {
        try await pluginCall { try await runner.getSearchCapabilities(kind: kind) }
    }

    func loadOptionPage(_ request: OptionRequest) async throws -> OptionPage? {
        try await pluginCall { try await runner.getOptionPage(request) }
    }

    func loadSearchSuggestions(query: String, kind: MediaKind?) async throws -> [SearchSuggestion]? {
        try await pluginCall { try await runner.getSearchSuggestions(query: query, kind: kind) }
    }

    func search(
        kind: MediaKind?,
        query: String,
        page: Int32,
        filterValues: [String: ControlValue]
    ) async throws -> MediaPageResult {
        try await pluginCall {
            try await runner.search(query: query, page: page, kind: kind, filterValues: filterValues)
        }
    }

    func loadListing(
        listing: Listing,
        page: Int32
    ) async throws -> MediaPageResult {
        try await pluginCall {
            try await runner.getListing(listing, page: page)
        }
    }

    func loadManga(_ manga: Manga) async throws -> Manga {
        try await pluginCall { try await runner.getMediaUpdate(.manga(manga)).expecting(\.manga) }
    }

    func loadAnime(_ anime: Anime) async throws -> Anime {
        try await pluginCall { try await runner.getMediaUpdate(.anime(anime)).expecting(\.anime) }
    }

    func loadNovel(_ novel: Novel) async throws -> Novel {
        try await pluginCall { try await runner.getMediaUpdate(.novel(novel)).expecting(\.novel) }
    }
}

@MainActor
protocol SourceRunnerProviding: AnyObject {
    func sourceRunnerContext(for pluginID: String) async throws -> any SourceRunnerContext
    func evictSourceRunner(for pluginID: String)
    func pendingTrust(for pluginID: String) -> PendingTrust?
    func clearPendingTrust(for pluginID: String)
}

extension SourceRunnerProviding {
    func pendingTrust(for pluginID: String) -> PendingTrust? { nil }
    func clearPendingTrust(for pluginID: String) {}
}

extension PluginManager: SourceRunnerProviding {
    func sourceRunnerContext(for pluginID: String) async throws -> any SourceRunnerContext {
        ItoRunnerSourceContext(runner: try await getRunner(for: pluginID))
    }

    func evictSourceRunner(for pluginID: String) {
        evictRunner(for: pluginID)
    }

    func pendingTrust(for pluginID: String) -> PendingTrust? {
        pluginSettingsStore.trust.pending(pluginID: pluginID)
    }

    func clearPendingTrust(for pluginID: String) {
        pluginSettingsStore.trust.clearPending(pluginID: pluginID)
    }
}

@MainActor
protocol PluginSettingsPersisting: AnyObject {
    var settingsRevisionPublisher: AnyPublisher<Int, Never> { get }

    func prepareSettings(pluginID: String) throws
    func storedValue(pluginID: String, key: String) -> String?
    func persistValue(pluginID: String, key: String, value: String) -> Bool
    func removeValue(pluginID: String, key: String) -> Bool
    func hasSecret(pluginID: String, key: String) -> Bool
    func persistSecret(pluginID: String, key: String, value: String) -> Bool
    func clearSecret(pluginID: String, key: String) -> Bool
    func reloadPersistedSettings() async throws
}

extension PluginSettingsStore: PluginSettingsPersisting {
    var settingsRevisionPublisher: AnyPublisher<Int, Never> {
        revisionPublisher.eraseToAnyPublisher()
    }

    func prepareSettings(pluginID: String) throws {
        try prepare(pluginId: pluginID)
    }

    func storedValue(pluginID: String, key: String) -> String? {
        get(pluginId: pluginID, key: key)
    }

    func persistValue(pluginID: String, key: String, value: String) -> Bool {
        set(pluginId: pluginID, key: key, value: value)
    }

    func removeValue(pluginID: String, key: String) -> Bool {
        remove(pluginId: pluginID, key: key)
    }

    func hasSecret(pluginID: String, key: String) -> Bool {
        secrets.value(pluginID: pluginID, key: key) != nil
    }

    func persistSecret(pluginID: String, key: String, value: String) -> Bool {
        setSecret(pluginId: pluginID, key: key, value: value)
    }

    func clearSecret(pluginID: String, key: String) -> Bool {
        removeSecret(pluginId: pluginID, key: key)
    }

    func reloadPersistedSettings() async throws {
        try reload()
    }
}

@MainActor
protocol SourcePluginStatePublishing: AnyObject {
    func currentSourcePlugin(for pluginID: String) -> InstalledPlugin?
    func prepareSourcePluginStatePublication() async throws -> any SourcePluginStatePublication
    func holdCompletionDelivery(for pluginID: String) async throws
    func revokeTrust(for pluginID: String) throws
    func purgeCompletionDelivery(for pluginID: String) async
    func removeSecrets(for pluginID: String)
}

@MainActor
protocol SourcePluginStatePublication: AnyObject {
    func validateCurrentState() throws
    func publish()
}

@MainActor
private final class PluginManagerSourcePluginStatePublication: SourcePluginStatePublication {
    private let pluginManager: PluginManager
    private let installedPlugins: [String: InstalledPlugin]
    private let expectedInstalledPluginIdentities: [String: SourcePluginDeletionIdentity]
    private var isPublished = false

    init(
        pluginManager: PluginManager,
        installedPlugins: [String: InstalledPlugin],
        expectedInstalledPluginIdentities: [String: SourcePluginDeletionIdentity]
    ) {
        self.pluginManager = pluginManager
        self.installedPlugins = installedPlugins
        self.expectedInstalledPluginIdentities = expectedInstalledPluginIdentities
    }

    func validateCurrentState() throws {
        let currentIdentities = pluginManager.installedPlugins.mapValues(
            SourcePluginDeletionIdentity.init(plugin:)
        )
        guard currentIdentities == expectedInstalledPluginIdentities else {
            throw SourcePluginFileError.stalePluginState
        }
    }

    func publish() {
        guard !isPublished else { return }
        isPublished = true
        pluginManager.publishPreparedInstalledPlugins(installedPlugins)
    }
}

extension PluginManager: SourcePluginStatePublishing {
    func currentSourcePlugin(for pluginID: String) -> InstalledPlugin? {
        installedPlugins[pluginID]
    }

    func prepareSourcePluginStatePublication() async throws -> any SourcePluginStatePublication {
        let expectedIdentities = installedPlugins.mapValues(
            SourcePluginDeletionIdentity.init(plugin:)
        )
        return PluginManagerSourcePluginStatePublication(
            pluginManager: self,
            installedPlugins: try prepareInstalledPluginsPublication(),
            expectedInstalledPluginIdentities: expectedIdentities
        )
    }
}

@MainActor
protocol PluginFileDeletionTransaction: AnyObject {
    func commit() throws
    func rollback() throws
}

@MainActor
protocol SourcePluginFileDeleting: AnyObject {
    func snapshotPluginFile(for plugin: InstalledPlugin) throws -> SourcePluginFileSnapshot
    func stagePluginFileDeletion(
        from snapshot: SourcePluginFileSnapshot
    ) throws -> any PluginFileDeletionTransaction
}

enum SourcePluginFileError: LocalizedError, Equatable {
    case invalidPluginLocation
    case missingPluginFile
    case stalePluginIdentity
    case stalePluginState
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .invalidPluginLocation:
            return "The plugin file is outside the configured plugins directory."
        case .missingPluginFile:
            return "The plugin file no longer exists."
        case .stalePluginIdentity:
            return "The plugin changed after this screen was opened. Refresh and try again."
        case .stalePluginState:
            return "Installed plugins changed during removal. Refresh and try again."
        case .rollbackFailed:
            return "The plugin removal failed and the original file could not be restored."
        }
    }
}

struct SourcePluginDeletionIdentity: Equatable {
    let fileURL: URL
    let pluginID: String
    let name: String
    let version: String
    let minimumAppVersion: String
    let websiteURL: String?
    let sourceURL: String?
    let contentRating: Int32?
    let nsfw: Int?
    let language: String?
    let languages: [String]?
    let pluginType: String
    let author: String?
    let pluginDescription: String?
    let tags: [String]?
    let archived: Bool?
    let archivedReason: String?
    let archivedDate: String?
    let iconData: Data?

    init(plugin: InstalledPlugin) {
        self.init(fileURL: plugin.url, info: plugin.info, iconData: plugin.iconData)
    }

    init(fileURL: URL, info: PluginInfo, iconData: Data?) {
        self.fileURL = fileURL.standardizedFileURL
        pluginID = info.id
        name = info.name
        version = info.version
        minimumAppVersion = info.minAppVersion
        websiteURL = info.url
        sourceURL = info.sourceUrl
        contentRating = info.contentRating?.rawValue
        nsfw = info.nsfw
        language = info.language
        languages = info.languages
        pluginType = info.type.rawValue
        author = info.author
        pluginDescription = info.description
        tags = info.tags
        archived = info.archived
        archivedReason = info.archivedReason
        archivedDate = info.archivedDate
        self.iconData = iconData
    }
}

struct SourcePluginFileSnapshot: Equatable {
    let identity: SourcePluginDeletionIdentity
    let digest: Data

    init(identity: SourcePluginDeletionIdentity, fileData: Data) {
        self.identity = identity
        digest = Data(SHA256.hash(data: fileData))
    }

    func matches(fileData: Data) -> Bool {
        digest == Data(SHA256.hash(data: fileData))
    }
}

@MainActor
final class LocalPluginFileDeletionTransaction: PluginFileDeletionTransaction {
    private let fileManager: FileManager
    private let originalURL: URL
    private let stagedURL: URL
    private var isFinished = false

    init(fileManager: FileManager, originalURL: URL, stagedURL: URL) {
        self.fileManager = fileManager
        self.originalURL = originalURL
        self.stagedURL = stagedURL
    }

    func commit() throws {
        guard !isFinished else { return }
        try fileManager.removeItem(at: stagedURL)
        isFinished = true
    }

    func rollback() throws {
        guard !isFinished else { return }
        guard fileManager.fileExists(atPath: stagedURL.path) else {
            throw SourcePluginFileError.rollbackFailed
        }
        guard !fileManager.fileExists(atPath: originalURL.path) else {
            throw SourcePluginFileError.rollbackFailed
        }
        try fileManager.moveItem(at: stagedURL, to: originalURL)
        isFinished = true
    }
}

enum SourceMessage: Equatable {
    case loadFailed(pluginName: String, reason: String)
    case searchFailed(pluginName: String, reason: String)
    case settingsLoadFailed(pluginName: String, reason: String)
    case settingsPersistenceFailed(pluginName: String)
    case settingsReloadFailed(pluginName: String, reason: String)
    case archivedPluginDeleteFailed(pluginName: String, reason: String)
}

@MainActor
protocol SourceMessagePresenting: AnyObject {
    func present(_ message: SourceMessage)
}

@MainActor
final class AppMessageSourcePresenter: SourceMessagePresenting {
    private let messageCenter: AppMessageCenter

    init(messageCenter: AppMessageCenter) {
        self.messageCenter = messageCenter
    }

    func present(_ message: SourceMessage) {
        messageCenter.publish(message.appMessageKind)
    }
}

private extension SourceMessage {
    var appMessageKind: AppMessageKind {
        switch self {
        case .loadFailed:
            return .sourceLoadFailed
        case .searchFailed:
            return .sourceSearchFailed
        case .settingsLoadFailed:
            return .pluginSettingsLoadFailed
        case .settingsPersistenceFailed:
            return .pluginSettingsPersistenceFailed
        case .settingsReloadFailed:
            return .pluginSettingsReloadFailed
        case .archivedPluginDeleteFailed:
            return .sourceArchivedPluginDeleteFailed
        }
    }
}

@MainActor
struct PreparedSourceDependencies {
    let runnerProvider: any SourceRunnerProviding
    let settingsStore: any PluginSettingsPersisting
    let pluginStatePublisher: any SourcePluginStatePublishing
    let fileDeletion: any SourcePluginFileDeleting

    static func unavailable() -> Self {
        let dependency = UnavailableSourceDependency()
        return Self(
            runnerProvider: dependency,
            settingsStore: dependency,
            pluginStatePublisher: dependency,
            fileDeletion: dependency
        )
    }
}

private enum SourceDependencyUnavailableError: Error {
    case unavailable
}

@MainActor
private final class UnavailableSourceDependency: SourceRunnerProviding,
    PluginSettingsPersisting, SourcePluginStatePublishing, SourcePluginFileDeleting {
    var settingsRevisionPublisher: AnyPublisher<Int, Never> {
        Just(0).eraseToAnyPublisher()
    }

    func sourceRunnerContext(for pluginID: String) async throws -> any SourceRunnerContext {
        throw SourceDependencyUnavailableError.unavailable
    }

    func evictSourceRunner(for pluginID: String) {}

    func prepareSettings(pluginID: String) throws {
        throw SourceDependencyUnavailableError.unavailable
    }

    func storedValue(pluginID: String, key: String) -> String? { nil }

    func persistValue(pluginID: String, key: String, value: String) -> Bool { false }

    func removeValue(pluginID: String, key: String) -> Bool { false }

    func hasSecret(pluginID: String, key: String) -> Bool { false }

    func persistSecret(pluginID: String, key: String, value: String) -> Bool { false }

    func clearSecret(pluginID: String, key: String) -> Bool { false }

    func reloadPersistedSettings() async throws {
        throw SourceDependencyUnavailableError.unavailable
    }

    func currentSourcePlugin(for pluginID: String) -> InstalledPlugin? { nil }

    func prepareSourcePluginStatePublication() async throws -> any SourcePluginStatePublication {
        throw SourceDependencyUnavailableError.unavailable
    }

    func holdCompletionDelivery(for pluginID: String) async throws {
        throw SourceDependencyUnavailableError.unavailable
    }

    func revokeTrust(for pluginID: String) throws {
        throw SourceDependencyUnavailableError.unavailable
    }

    func purgeCompletionDelivery(for pluginID: String) async {}

    func removeSecrets(for pluginID: String) {}

    func snapshotPluginFile(for plugin: InstalledPlugin) throws -> SourcePluginFileSnapshot {
        throw SourceDependencyUnavailableError.unavailable
    }

    func stagePluginFileDeletion(
        from snapshot: SourcePluginFileSnapshot
    ) throws -> any PluginFileDeletionTransaction {
        throw SourceDependencyUnavailableError.unavailable
    }
}
