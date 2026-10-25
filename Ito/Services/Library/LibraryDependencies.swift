import Combine
import Foundation
import ito_runner

struct LibraryRootSnapshot: Equatable {
    let items: [LibraryItem]
    let categories: [LibraryCategory]
    let links: [ItemCategoryLink]
    let isLoading: Bool
}

@MainActor
protocol LibraryRootServing: AnyObject {
    var rootSnapshot: LibraryRootSnapshot { get }
    var rootSnapshotPublisher: AnyPublisher<LibraryRootSnapshot, Never> { get }

    func removeItem(itemID: String, pluginID: String, mediaKind: MediaKind) async throws
}

extension LibraryManager: LibraryRootServing {
    var rootSnapshot: LibraryRootSnapshot {
        LibraryRootSnapshot(
            items: items,
            categories: categories,
            links: links,
            isLoading: isLoading
        )
    }

    var rootSnapshotPublisher: AnyPublisher<LibraryRootSnapshot, Never> {
        Publishers.CombineLatest(
            Publishers.CombineLatest3($items, $categories, $links),
            $isLoading
        )
        .map { values, isLoading in
            LibraryRootSnapshot(
                items: values.0,
                categories: values.1,
                links: values.2,
                isLoading: isLoading
            )
        }
        .eraseToAnyPublisher()
    }

    func removeItem(itemID: String, pluginID: String, mediaKind: MediaKind) async throws {
        try await removeItemDurably(itemID: itemID, pluginId: pluginID, mediaKind: mediaKind)
    }
}

@MainActor
protocol LibraryLayoutPersisting: AnyObject {
    var storedLibraryLayoutStyle: Int { get }
    var storedLibraryLayoutStylePublisher: AnyPublisher<Int, Never> { get }

    func persistLibraryLayoutStyle(_ rawValue: Int) async throws
}

extension AppSettingsStore: LibraryLayoutPersisting {
    var storedLibraryLayoutStyle: Int { libraryLayoutStyle }

    var storedLibraryLayoutStylePublisher: AnyPublisher<Int, Never> {
        $libraryLayoutStyle.eraseToAnyPublisher()
    }

    func persistLibraryLayoutStyle(_ rawValue: Int) async throws {
        try await set(rawValue, for: AppPreferenceCatalog.libraryLayoutStyle)
    }
}

/// Volatile presentation state: a source can fail some series while others still update.
struct LibraryUpdateFailure: Identifiable, Equatable, Sendable {
    let pluginID: String
    let reason: String
    let needsSettings: Bool
    /// The source needs a sign-in on its website.
    let needsLogin: Bool
    /// An untrusted certificate waiting for user confirmation, if any.
    let pendingTrust: PendingTrust?

    init(pluginID: String, reason: String, needsSettings: Bool, needsLogin: Bool = false, pendingTrust: PendingTrust? = nil) {
        self.pluginID = pluginID
        self.reason = reason
        self.needsSettings = needsSettings
        self.needsLogin = needsLogin
        self.pendingTrust = pendingTrust
    }

    var isActionable: Bool { needsSettings || needsLogin || pendingTrust != nil }

    var id: String { pluginID }
}

struct LibraryUpdateSnapshot: Equatable {
    let isRefreshing: Bool
    let current: Int
    let total: Int
    let badgeCounts: [MediaIdentity: Int]
    var sourceFailures: [LibraryUpdateFailure] = []

    func badgeCount(for media: MediaIdentity) -> Int {
        max(0, badgeCounts[media] ?? 0)
    }
}

@MainActor
protocol LibraryUpdateServing: AnyObject {
    var libraryUpdateSnapshot: LibraryUpdateSnapshot { get }
    var libraryUpdateSnapshotPublisher: AnyPublisher<LibraryUpdateSnapshot, Never> { get }

    func checkLibraryForUpdates() async throws
    func clearLibraryBadge(for media: MediaIdentity) async throws
}

extension UpdateManager: LibraryUpdateServing {
    var libraryUpdateSnapshot: LibraryUpdateSnapshot {
        LibraryUpdateSnapshot(
            isRefreshing: isRefreshing,
            current: itemsCheckedCurrentRun,
            total: totalItemsToCheck,
            badgeCounts: libraryBadgeCountsSnapshot,
            sourceFailures: sourceFailures
        )
    }

    var libraryUpdateSnapshotPublisher: AnyPublisher<LibraryUpdateSnapshot, Never> {
        Publishers.CombineLatest3(
            Publishers.CombineLatest3($isRefreshing, $itemsCheckedCurrentRun, $totalItemsToCheck),
            libraryBadgeCountsPublisher,
            $sourceFailures
        )
        .map { values, badgeCounts, sourceFailures in
            LibraryUpdateSnapshot(
                isRefreshing: values.0,
                current: values.1,
                total: values.2,
                badgeCounts: badgeCounts,
                sourceFailures: sourceFailures
            )
        }
        .eraseToAnyPublisher()
    }

    func checkLibraryForUpdates() async throws {
        try await checkForUpdates()
    }

    func clearLibraryBadge(for media: MediaIdentity) async throws {
        try await clearBadge(for: media)
    }
}

struct LibraryExportArtifact {
    let document: BackupDocument
    let defaultFilename: String
}

@MainActor
protocol LibraryExportServing: AnyObject {
    func generateLibraryExport() async throws -> LibraryExportArtifact
}

extension BackupManager: LibraryExportServing {
    func generateLibraryExport() async throws -> LibraryExportArtifact {
        let fileURL = try await createBackupFile()
        return LibraryExportArtifact(
            document: BackupDocument(url: fileURL),
            defaultFilename: fileURL.lastPathComponent
        )
    }
}

@MainActor
protocol LibraryDiscordPresenting: AnyObject {
    func presentLibrary(categoryName: String?)
}

extension DiscordRPCManager: LibraryDiscordPresenting {
    func presentLibrary(categoryName: String?) {
        updateLibraryStatus(categoryName: categoryName)
    }
}

@MainActor
protocol LibraryPluginServing: AnyObject {
    var libraryPluginSnapshot: LibraryPluginSnapshot { get }
    var libraryPluginSnapshotPublisher: AnyPublisher<LibraryPluginSnapshot, Never> { get }

    func libraryRunner(
        for plugin: LibraryInstalledPluginIdentity,
        publicationRevision: UInt64
    ) async throws -> ItoRunner
}

struct LibraryInstalledPluginIdentity: Equatable {
    let id: String
    let version: String
    let supportedKinds: Set<MediaKind>
    let fileIdentity: URL
}

struct LibraryPluginSnapshot: Equatable {
    let publicationRevision: UInt64
    let plugins: [String: LibraryInstalledPluginIdentity]
}

private enum LibraryPluginBoundaryError: Error {
    case authorityChanged
}

extension PluginManager: LibraryPluginServing {
    var libraryPluginSnapshot: LibraryPluginSnapshot {
        LibraryPluginSnapshot(
            publicationRevision: installedPluginsPublicationRevision,
            plugins: installedPlugins.mapValues(Self.libraryIdentity)
        )
    }

    var libraryPluginSnapshotPublisher: AnyPublisher<LibraryPluginSnapshot, Never> {
        $installedPluginsPublicationRevision
            .map { [weak self] publicationRevision in
                LibraryPluginSnapshot(
                    publicationRevision: publicationRevision,
                    plugins: self?.installedPlugins.mapValues(Self.libraryIdentity) ?? [:]
                )
            }
            .eraseToAnyPublisher()
    }

    func libraryRunner(
        for plugin: LibraryInstalledPluginIdentity,
        publicationRevision: UInt64
    ) async throws -> ItoRunner {
        guard libraryPluginSnapshot.publicationRevision == publicationRevision,
              libraryPluginSnapshot.plugins[plugin.id] == plugin else {
            throw LibraryPluginBoundaryError.authorityChanged
        }
        let runner = try await getRunner(for: plugin.id)
        guard libraryPluginSnapshot.publicationRevision == publicationRevision,
              libraryPluginSnapshot.plugins[plugin.id] == plugin else {
            throw LibraryPluginBoundaryError.authorityChanged
        }
        return runner
    }

    private static func libraryIdentity(
        _ plugin: InstalledPlugin
    ) -> LibraryInstalledPluginIdentity {
        LibraryInstalledPluginIdentity(
            id: plugin.id,
            version: plugin.info.version,
            supportedKinds: Set(plugin.info.supportedKinds),
            fileIdentity: plugin.url.standardizedFileURL
        )
    }
}

struct DeferredPluginPackageCandidate: Equatable {
    let package: RepoPackage
    let repositoryURL: String
    /// Why the package can't run here, or nil when it can.
    let incompatibility: PluginRequiresNewerAppError?

    var supportedKinds: [MediaKind] { package.supportedKinds }
}

@MainActor
protocol DeferredPluginInstalling: AnyObject {
    func findPackage(forExactPluginID pluginID: String) async throws
        -> DeferredPluginPackageCandidate?
    func install(_ candidate: DeferredPluginPackageCandidate) async throws
}

extension RepoManager: DeferredPluginInstalling {
    func findPackage(forExactPluginID pluginID: String) async throws
        -> DeferredPluginPackageCandidate? {
        try await refreshAllReportingFailures()

        for repository in repositories {
            guard let package = repository.index?.packages.first(where: { $0.id == pluginID }) else {
                continue
            }
            return DeferredPluginPackageCandidate(
                package: package,
                repositoryURL: repository.url,
                incompatibility: compatibilityRefusal(for: package)
            )
        }
        return nil
    }

    func install(_ candidate: DeferredPluginPackageCandidate) async throws {
        try await installPackage(
            candidate.package,
            repositoryUrl: candidate.repositoryURL
        )
    }
}

enum DeferredPluginMedia {
    case manga(Manga)
    case anime(Anime)
    case novel(Novel)
}

protocol DeferredPluginPayloadDecoding {
    func decode(_ item: LibraryItem) async throws -> DeferredPluginMedia
}

private enum DeferredPluginPayloadError: Error {
    case inconsistentMediaType
}

struct JSONDeferredPluginPayloadDecoder: DeferredPluginPayloadDecoding {
    func decode(_ item: LibraryItem) async throws -> DeferredPluginMedia {
        if let pluginType = item.pluginType,
           (pluginType == .anime) != item.isAnime {
            throw DeferredPluginPayloadError.inconsistentMediaType
        }
        let object = try JSONSerialization.jsonObject(with: item.rawPayload)
        guard let payload = object as? [String: Any] else {
            throw DeferredPluginPayloadError.inconsistentMediaType
        }
        switch item.effectiveType {
        case .manga:
            guard payload["viewer"] != nil else {
                throw DeferredPluginPayloadError.inconsistentMediaType
            }
            return .manga(try JSONDecoder().decode(Manga.self, from: item.rawPayload))
        case .anime:
            guard payload["viewer"] == nil else {
                throw DeferredPluginPayloadError.inconsistentMediaType
            }
            return .anime(try JSONDecoder().decode(Anime.self, from: item.rawPayload))
        case .novel:
            guard payload["viewer"] == nil else {
                throw DeferredPluginPayloadError.inconsistentMediaType
            }
            return .novel(try JSONDecoder().decode(Novel.self, from: item.rawPayload))
        }
    }
}

enum LibraryMessage: Equatable {
    case layoutPersistenceFailed
    case itemRemovalFailed
    case updateFailed
    case noUpdateSources
}

@MainActor
protocol LibraryMessagePresenting: AnyObject {
    func present(_ message: LibraryMessage)
}

@MainActor
final class AppMessageLibraryPresenter: LibraryMessagePresenting {
    private let messageCenter: AppMessageCenter

    init(messageCenter: AppMessageCenter) {
        self.messageCenter = messageCenter
    }

    func present(_ message: LibraryMessage) {
        switch message {
        case .layoutPersistenceFailed:
            messageCenter.publish(.libraryLayoutPersistenceFailed)
        case .itemRemovalFailed:
            messageCenter.publish(.libraryItemRemovalFailed)
        case .updateFailed:
            messageCenter.publish(.libraryUpdateFailed)
        case .noUpdateSources:
            messageCenter.publish(.libraryNoUpdateSources)
        }
    }
}

@MainActor
struct PreparedLibraryDependencies {
    let library: any LibraryRootServing
    let layout: any LibraryLayoutPersisting
    let updates: any LibraryUpdateServing
    let export: any LibraryExportServing
    let discord: any LibraryDiscordPresenting
    let plugins: any LibraryPluginServing
    let installer: any DeferredPluginInstalling
    let payloadDecoder: any DeferredPluginPayloadDecoding

    static func production(
        libraryManager: LibraryManager,
        settingsStore: AppSettingsStore,
        updateManager: UpdateManager,
        backupManager: BackupManager,
        discordRPCManager: DiscordRPCManager,
        pluginManager: PluginManager,
        repoManager: RepoManager
    ) -> Self {
        Self(
            library: libraryManager,
            layout: settingsStore,
            updates: updateManager,
            export: backupManager,
            discord: discordRPCManager,
            plugins: pluginManager,
            installer: repoManager,
            payloadDecoder: JSONDeferredPluginPayloadDecoder()
        )
    }

    static func unavailable() -> Self {
        let unavailable = UnavailableLibraryDependency()
        return Self(
            library: unavailable,
            layout: unavailable,
            updates: unavailable,
            export: unavailable,
            discord: unavailable,
            plugins: unavailable,
            installer: unavailable,
            payloadDecoder: unavailable
        )
    }
}

private enum UnavailableLibraryDependencyError: Error {
    case unavailable
}

@MainActor
private final class UnavailableLibraryDependency: LibraryRootServing,
    LibraryLayoutPersisting, LibraryUpdateServing, LibraryExportServing,
    LibraryDiscordPresenting, LibraryPluginServing, DeferredPluginInstalling,
    DeferredPluginPayloadDecoding {
    let rootSnapshot = LibraryRootSnapshot(
        items: [],
        categories: [],
        links: [],
        isLoading: false
    )
    let storedLibraryLayoutStyle = LibraryLayoutStyle.sectioned.rawValue
    let libraryUpdateSnapshot = LibraryUpdateSnapshot(
        isRefreshing: false,
        current: 0,
        total: 0,
        badgeCounts: [:]
    )
    let libraryPluginSnapshot = LibraryPluginSnapshot(
        publicationRevision: 0,
        plugins: [:]
    )

    var rootSnapshotPublisher: AnyPublisher<LibraryRootSnapshot, Never> {
        Just(rootSnapshot).eraseToAnyPublisher()
    }

    var storedLibraryLayoutStylePublisher: AnyPublisher<Int, Never> {
        Just(storedLibraryLayoutStyle).eraseToAnyPublisher()
    }

    var libraryUpdateSnapshotPublisher: AnyPublisher<LibraryUpdateSnapshot, Never> {
        Just(libraryUpdateSnapshot).eraseToAnyPublisher()
    }

    var libraryPluginSnapshotPublisher: AnyPublisher<LibraryPluginSnapshot, Never> {
        Just(libraryPluginSnapshot).eraseToAnyPublisher()
    }

    func removeItem(itemID: String, pluginID: String, mediaKind: MediaKind) async throws {
        _ = itemID
        _ = pluginID
        throw UnavailableLibraryDependencyError.unavailable
    }

    func persistLibraryLayoutStyle(_ rawValue: Int) async throws {
        _ = rawValue
        throw UnavailableLibraryDependencyError.unavailable
    }

    func checkLibraryForUpdates() async throws {
        throw UnavailableLibraryDependencyError.unavailable
    }

    func clearLibraryBadge(for media: MediaIdentity) async throws {
        _ = media
        throw UnavailableLibraryDependencyError.unavailable
    }

    func generateLibraryExport() async throws -> LibraryExportArtifact {
        throw UnavailableLibraryDependencyError.unavailable
    }

    func presentLibrary(categoryName: String?) {
        _ = categoryName
    }

    func libraryRunner(
        for plugin: LibraryInstalledPluginIdentity,
        publicationRevision: UInt64
    ) async throws -> ItoRunner {
        _ = plugin
        _ = publicationRevision
        throw UnavailableLibraryDependencyError.unavailable
    }

    func findPackage(forExactPluginID pluginID: String) async throws
        -> DeferredPluginPackageCandidate? {
        _ = pluginID
        return nil
    }

    func install(_ candidate: DeferredPluginPackageCandidate) async throws {
        _ = candidate
        throw UnavailableLibraryDependencyError.unavailable
    }

    func decode(_ item: LibraryItem) async throws -> DeferredPluginMedia {
        _ = item
        throw UnavailableLibraryDependencyError.unavailable
    }
}
