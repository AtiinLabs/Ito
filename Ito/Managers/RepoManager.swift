import OSLog
import Foundation
import Combine
import CryptoKit
import GRDB
import ito_runner

nonisolated public struct RepoPackage: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let minAppVersion: String
    public let downloadUrl: String
    public let iconUrl: String?
    public let sha256: String
    public let pluginType: String
    public let archived: Bool?
    public let archivedReason: String?
    public let archivedDate: String?
    /// The ABI the plugin was built for, as its packager recorded it. Absent in older indexes.
    public let abi: Int?
    /// The SDK the plugin was built with, such as "ito-rs 0.1.1". Absent in older indexes.
    public let sdk: String?
    /// The host functions the plugin imports, as "module.name". Absent in older indexes.
    public let imports: [String]?
    /// Optional hints for the media kinds served by this package. Absent in older indexes.
    public let kinds: [String]?

    public var supportedKinds: [MediaKind] {
        if let kinds {
            var seen = Set<MediaKind>()
            var result: [MediaKind] = []
            for raw in kinds {
                if let kind = MediaKind(rawValue: raw.lowercased()), seen.insert(kind).inserted {
                    result.append(kind)
                }
            }
            if !result.isEmpty {
                return result
            }
        }
        if let fallback = MediaKind(rawValue: pluginType.lowercased()) {
            return [fallback]
        }
        return []
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, minAppVersion = "min_app_version"
        case downloadUrl = "download_url"
        case iconUrl = "icon_url"
        case sha256
        case pluginType = "type"
        case archived
        case archivedReason = "archived_reason"
        case archivedDate = "archived_date"
        case abi, sdk, imports, kinds
    }

    public init(
        id: String, name: String, version: String, minAppVersion: String, downloadUrl: String,
        iconUrl: String?, sha256: String, pluginType: String, archived: Bool?,
        archivedReason: String?, archivedDate: String?,
        abi: Int? = nil, sdk: String? = nil, imports: [String]? = nil,
        kinds: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.minAppVersion = minAppVersion
        self.downloadUrl = downloadUrl
        self.iconUrl = iconUrl
        self.sha256 = sha256
        self.pluginType = pluginType
        self.archived = archived
        self.archivedReason = archivedReason
        self.archivedDate = archivedDate
        self.abi = abi
        self.sdk = sdk
        self.imports = imports
        self.kinds = kinds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.version = try container.decode(String.self, forKey: .version)
        self.minAppVersion = try container.decode(String.self, forKey: .minAppVersion)
        self.downloadUrl = try container.decode(String.self, forKey: .downloadUrl)
        self.iconUrl = try container.decodeIfPresent(String.self, forKey: .iconUrl)
        self.sha256 = try container.decode(String.self, forKey: .sha256)
        self.pluginType = try container.decode(String.self, forKey: .pluginType)
        self.archived = try container.decodeIfPresent(Bool.self, forKey: .archived)
        self.archivedReason = try container.decodeIfPresent(String.self, forKey: .archivedReason)
        self.archivedDate = try container.decodeIfPresent(String.self, forKey: .archivedDate)
        self.abi = try container.decodeIfPresent(Int.self, forKey: .abi)
        self.sdk = try container.decodeIfPresent(String.self, forKey: .sdk)
        self.imports = try container.decodeIfPresent([String].self, forKey: .imports)
        self.kinds = try? container.decodeIfPresent([String].self, forKey: .kinds)
    }
}

extension RepoPackage {
    public var isArchived: Bool { archived ?? false }

    /// Why this package can't run in an Ito at `currentAppVersion`, or nil when it can.
    func compatibilityRefusal(currentAppVersion: String = AppVersion.marketing) -> PluginRequiresNewerAppError? {
        PluginRequiresNewerAppError.refusal(
            minAppVersion: minAppVersion,
            abi: abi,
            imports: imports,
            currentAppVersion: currentAppVersion
        )
    }
}

nonisolated public struct RepoIndex: Codable, Equatable, Sendable {
    public let repoName: String
    public let repoUrl: String
    public let description: String
    public let packages: [RepoPackage]

    enum CodingKeys: String, CodingKey {
        case repoName = "repo_name"
        case repoUrl = "repo_url"
        case description, packages
    }
}

nonisolated public struct Repository: Codable, Identifiable, Equatable, Sendable {
    public var id: String { url }
    public let url: String
    public var lastFetched: Date?
    public var index: RepoIndex?
}

public enum RepositoryAdditionResult: Equatable {
    case added
    case alreadyPresent
}

public struct RepositoryRefreshFailure: LocalizedError, Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let repositoryURL: String
        public let reason: String
    }

    public let items: [Item]

    public var errorDescription: String? {
        guard !items.isEmpty else { return nil }
        if items.count == 1 {
            return "Failed to refresh \(items[0].repositoryURL): \(items[0].reason)"
        }
        return "Failed to refresh \(items.count) repositories."
    }
}

public enum RepositoryPackageInstallationError: LocalizedError {
    case invalidPackageIdentifier
    case packageUnavailable
    case archived
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPackageIdentifier:
            return "The repository package identifier is invalid."
        case .packageUnavailable:
            return "The package is no longer available from the repository."
        case .archived:
            return "Archived plugins cannot be installed or updated."
        case .rollbackFailed:
            return "The package installation failed and the previous plugin could not be restored."
        }
    }
}

private actor RepositoryMutationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private struct PackageInstallationRequest: Equatable {
    let repositoryURL: String
    let version: String
    let downloadURL: String
    let sha256: String
}

@MainActor
public class RepoManager: ObservableObject {
    @Published public private(set) var repositories: [Repository] = []
    private let dbPool: DatabasePool
    private let pluginStatePublisher: (any RepositoryPluginStatePublishing)?
    private let indexFetcher: @Sendable (URL) async throws -> Data
    private let packageFetcher: @Sendable (URLRequest) async throws -> Data
    private let configuredPluginsDirectory: URL?
    private let repositoryMutationGate = RepositoryMutationGate()
    private var activeRefresh: (id: UUID, task: Task<Void, Error>)?
    private var activePackageInstallations: [
        String: (id: UUID, request: PackageInstallationRequest, task: Task<Void, Error>)
    ] = [:]

    /// The running app's version, compared with each package's `min_app_version`.
    public let currentAppVersion = AppVersion.marketing

    /// The AtiinLabs plugin repository (first-party reading-service plugins), in normalized form.
    /// New databases start with it; see FirstRunSetupBootstrapExtension.
    public nonisolated static let defaultRepositoryURL = "https://atiinlabs.github.io/sources"

    public convenience init(
        dbPool: DatabasePool,
        pluginManager: PluginManager? = nil,
        indexFetcher: (@Sendable (URL) async throws -> Data)? = nil
    ) {
        self.init(
            dbPool: dbPool,
            pluginManager: pluginManager,
            pluginsDirectory: pluginManager?.configuredInstalledPluginsDirectory,
            packageFetcher: nil,
            indexFetcher: indexFetcher
        )
    }

    public init(
        dbPool: DatabasePool,
        pluginManager: PluginManager? = nil,
        pluginsDirectory: URL?,
        packageFetcher: (@Sendable (URLRequest) async throws -> Data)? = nil,
        indexFetcher: (@Sendable (URL) async throws -> Data)? = nil
    ) {
        self.dbPool = dbPool
        self.pluginStatePublisher = pluginManager
        self.configuredPluginsDirectory = pluginsDirectory ?? pluginManager?.configuredInstalledPluginsDirectory
        if let packageFetcher {
            self.packageFetcher = packageFetcher
        } else {
            self.packageFetcher = { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                if let response = response as? HTTPURLResponse,
                   !(200...299).contains(response.statusCode) {
                    if response.statusCode == 404 || response.statusCode == 410 {
                        throw RepositoryPackageInstallationError.packageUnavailable
                    }
                    throw URLError(.fileDoesNotExist)
                }
                return data
            }
        }
        if let indexFetcher {
            self.indexFetcher = indexFetcher
        } else {
            #if DEBUG
            if UITestLaunchConfiguration.current.repositoryDeepLinkEnabled {
                self.indexFetcher = { url in
                    try UITestLaunchConfiguration.repositoryIndexData(for: url)
                }
                return
            }
            #endif
            self.indexFetcher = { url in
                // Skip the local HTTP cache. GitHub Pages sends max-age=600, so a cached
                // index hid newly published versions for up to ten minutes after refresh.
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                let (data, response) = try await URLSession.shared.data(for: request)
                if let response = response as? HTTPURLResponse,
                   !(200...299).contains(response.statusCode) {
                    throw URLError(URLError.Code(rawValue: response.statusCode))
                }
                return data
            }
        }
    }

    public func reload() async throws {
        try await withRepositoryMutation {
            repositories = try await dbPool.read { db in
                try RepositoryRecord.order(Column("url")).fetchAll(db).map { record in
                    Repository(url: record.url, lastFetched: record.lastFetched, index: Self.storedIndex(record))
                }
            }
        }
    }

    /// The repository's stored index. One that can't be read is dropped, so that repository
    /// shows no packages until it is refreshed, and the other repositories still load.
    nonisolated private static func storedIndex(_ record: RepositoryRecord) -> RepoIndex? {
        guard let payload = record.indexPayload else { return nil }
        guard let index = try? JSONDecoder().decode(RepoIndex.self, from: payload) else {
            AppLogger.plugin.error("RepoManager: a stored repository index couldn't be read; refresh to replace it")
            return nil
        }
        return index
    }

    private func normalizedURL(_ rawURL: String) throws -> String {
        guard var components = URLComponents(string: rawURL) else {
            throw URLError(.badURL)
        }
        if components.path.hasSuffix("/index.json") {
            components.path.removeLast("/index.json".count)
        }
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let normalized = components.url?.absoluteString else {
            throw URLError(.badURL)
        }
        return normalized
    }

    @discardableResult
    public func addRepository(url: String) async throws -> RepositoryAdditionResult {
        let normalizedUrl = try normalizedURL(url)

        return try await withRepositoryMutation {
            guard !repositories.contains(where: { $0.url == normalizedUrl }) else {
                return .alreadyPresent
            }

            var repo = Repository(url: normalizedUrl)
            do {
                let fetchedIndex = try await fetchIndex(for: normalizedUrl)
                try Task.checkCancellation()
                repo.index = fetchedIndex
                repo.lastFetched = Date()

                let record = RepositoryRecord(
                    url: repo.url,
                    lastFetched: repo.lastFetched,
                    indexPayload: try JSONEncoder().encode(fetchedIndex)
                )
                try await dbPool.write { db in try record.insert(db) }
                repositories.append(repo)
                repositories.sort { $0.url < $1.url }
                return .added
            } catch {
                AppLogger.database.error(
                    "Repository add failed; category=\(Self.logCategory(error), privacy: .public)"
                )
                throw error
            }
        }
    }

    public func removeRepository(url: String) async throws {
        let normalized = try normalizedURL(url)
        try await withRepositoryMutation {
            _ = try await dbPool.write { db in
                try RepositoryRecord.deleteOne(db, key: normalized)
            }
            repositories.removeAll { $0.url == normalized }
        }
    }

    public func refreshAll() async {
        try? await refreshAllReportingFailures()
    }

    public func refreshAllReportingFailures() async throws {
        if let activeRefresh {
            try await activeRefresh.task.value
            return
        }

        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.performRefreshAll()
        }
        activeRefresh = (operationID, task)
        defer {
            if activeRefresh?.id == operationID {
                activeRefresh = nil
            }
        }
        try await task.value
    }

    private func performRefreshAll() async throws {
        try await withRepositoryMutation {
            try await performLockedRefreshAll()
        }
    }

    private func performLockedRefreshAll() async throws {
        let repositoriesToRefresh = repositories
        var failures: [RepositoryRefreshFailure.Item] = []

        for repo in repositoriesToRefresh {
            do {
                try await storeFreshIndex(for: repo.url)
            } catch {
                AppLogger.database.error(
                    "Repository refresh failed; category=\(Self.logCategory(error), privacy: .public)"
                )
                failures.append(
                    RepositoryRefreshFailure.Item(
                        repositoryURL: repo.url,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        if !failures.isEmpty {
            throw RepositoryRefreshFailure(items: failures)
        }
    }

    /// Fetches and persists the current index of a repository. Requires the mutation gate.
    @discardableResult
    private func storeFreshIndex(for repositoryURL: String) async throws -> RepoIndex {
        let newIndex = try await fetchIndex(for: repositoryURL)
        let fetchedAt = Date()
        let record = RepositoryRecord(
            url: repositoryURL,
            lastFetched: fetchedAt,
            indexPayload: try JSONEncoder().encode(newIndex)
        )
        try await dbPool.write { db in try record.save(db) }
        if let index = repositories.firstIndex(where: { $0.url == repositoryURL }) {
            repositories[index].index = newIndex
            repositories[index].lastFetched = fetchedAt
        }
        return newIndex
    }

    private func fetchIndex(for urlStr: String) async throws -> RepoIndex {
        guard let url = URL(string: urlStr) else {
            throw URLError(.badURL)
        }
        let indexUrl = url.lastPathComponent == "index.json" ? url : url.appendingPathComponent("index.json")

        let data = try await indexFetcher(indexUrl)

        return try JSONDecoder().decode(RepoIndex.self, from: data)
    }

    /// A fixed description of why a repository operation failed. Repository URLs,
    /// names and response content never reach the log.
    private static func logCategory(_ error: any Error) -> String {
        switch error {
        case is CancellationError:
            return "cancelled"
        case let error as URLError:
            return "network(\(error.code.rawValue))"
        case is DecodingError:
            return "decoding"
        case is DatabaseError:
            return "database"
        default:
            return "other"
        }
    }

    /// Why `package` can't run in this app, or nil when it can.
    func compatibilityRefusal(for package: RepoPackage) -> PluginRequiresNewerAppError? {
        package.compatibilityRefusal(currentAppVersion: currentAppVersion)
    }

    public func installPackage(_ pkg: RepoPackage, repositoryUrl: String) async throws {
        try requireActivePackage(pkg, repositoryURL: repositoryUrl)
        if let refusal = compatibilityRefusal(for: pkg) {
            throw refusal
        }
        let request = PackageInstallationRequest(
            repositoryURL: repositoryUrl,
            version: pkg.version,
            downloadURL: pkg.downloadUrl,
            sha256: pkg.sha256
        )
        if let activeInstallation = activePackageInstallations[pkg.id] {
            if activeInstallation.request == request {
                try await activeInstallation.task.value
                return
            }
            _ = try? await activeInstallation.task.value
            if activePackageInstallations[pkg.id]?.id == activeInstallation.id {
                activePackageInstallations[pkg.id] = nil
            }
            try await installPackage(pkg, repositoryUrl: repositoryUrl)
            return
        }

        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.performInstallPackage(pkg, repositoryUrl: repositoryUrl)
        }
        activePackageInstallations[pkg.id] = (operationID, request, task)
        defer {
            if activePackageInstallations[pkg.id]?.id == operationID {
                activePackageInstallations[pkg.id] = nil
            }
        }
        try await task.value
    }

    private func performInstallPackage(_ pkg: RepoPackage, repositoryUrl: String) async throws {
        do {
            try await downloadAndInstall(pkg, repositoryUrl: repositoryUrl)
        } catch RepositoryPackageInstallationError.packageUnavailable {
            // Publishing a new version removes the old package file, so a stored index
            // can name a download that is gone. Install what the repository lists now.
            guard let current = try await currentPackage(id: pkg.id, repositoryUrl: repositoryUrl),
                  current.downloadUrl != pkg.downloadUrl || current.sha256 != pkg.sha256,
                  compatibilityRefusal(for: current) == nil else {
                throw RepositoryPackageInstallationError.packageUnavailable
            }
            try await downloadAndInstall(current, repositoryUrl: repositoryUrl)
        }
    }

    private func currentPackage(id: String, repositoryUrl: String) async throws -> RepoPackage? {
        try await withRepositoryMutation {
            guard repositories.contains(where: { $0.url == repositoryUrl }) else { return nil }
            return try await storeFreshIndex(for: repositoryUrl).packages.first { $0.id == id }
        }
    }

    private func requireActivePackage(_ package: RepoPackage, repositoryURL: String) throws {
        let listed = repositories.first { $0.url == repositoryURL }?.index?.packages.first { $0.id == package.id }
        guard !package.isArchived, listed?.isArchived != true else {
            throw RepositoryPackageInstallationError.archived
        }
    }

    private func downloadAndInstall(_ pkg: RepoPackage, repositoryUrl: String) async throws {
        // Re-check replacements resolved from a refreshed index as well as the original request.
        try requireActivePackage(pkg, repositoryURL: repositoryUrl)
        let pluginsDirectory = try resolvedPluginsDirectory()
        let destUrl = try packageDestinationURL(
            packageID: pkg.id,
            pluginsDirectory: pluginsDirectory
        )
        guard let url = URL(string: "\(repositoryUrl)/\(pkg.downloadUrl)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data = try await packageFetcher(request)

        // Verify Hash
        let digest = SHA256.hash(data: data)
        let computedHash = digest.compactMap { String(format: "%02x", $0) }.joined()

        guard computedHash.lowercased() == pkg.sha256.lowercased() else {
            AppLogger.database.error("Package install refused; downloaded file does not match its index hash")
            throw URLError(.cannotDecodeRawData) // Or a custom error
        }

        // Save to Application Support/Plugins
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: pluginsDirectory.path) {
            try fileManager.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        }

        let previousData: Data?
        if fileManager.fileExists(atPath: destUrl.path) {
            previousData = try Data(contentsOf: destUrl)
        } else {
            previousData = nil
        }
        try data.write(to: destUrl, options: .atomic)

        AppLogger.database.debug("Package installed")

        do {
            try await pluginStatePublisher?.publishInstalledPluginState()
        } catch {
            do {
                if let previousData {
                    try previousData.write(to: destUrl, options: .atomic)
                } else if fileManager.fileExists(atPath: destUrl.path) {
                    try fileManager.removeItem(at: destUrl)
                }
            } catch {
                throw RepositoryPackageInstallationError.rollbackFailed
            }
            throw error
        }
    }

    private func resolvedPluginsDirectory() throws -> URL {
        if let configuredPluginsDirectory {
            return configuredPluginsDirectory.standardizedFileURL
        }
        guard let appSupportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw URLError(.cannotCreateFile)
        }
        return appSupportDir.appendingPathComponent("Plugins", isDirectory: true).standardizedFileURL
    }

    private func packageDestinationURL(packageID: String, pluginsDirectory: URL) throws -> URL {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard let firstCharacter = packageID.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(firstCharacter),
              packageID.unicodeScalars.allSatisfy(allowedCharacters.contains) else {
            throw RepositoryPackageInstallationError.invalidPackageIdentifier
        }

        let standardizedDirectory = pluginsDirectory.standardizedFileURL
        let destination = standardizedDirectory
            .appendingPathComponent("\(packageID).ito", isDirectory: false)
            .standardizedFileURL
        guard destination.deletingLastPathComponent().standardizedFileURL.path == standardizedDirectory.path else {
            throw RepositoryPackageInstallationError.invalidPackageIdentifier
        }
        return destination
    }

    private func withRepositoryMutation<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        await repositoryMutationGate.acquire()
        if Task.isCancelled {
            await repositoryMutationGate.release()
            throw CancellationError()
        }
        do {
            let value = try await operation()
            await repositoryMutationGate.release()
            return value
        } catch {
            await repositoryMutationGate.release()
            throw error
        }
    }
}
