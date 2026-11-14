import CryptoKit
import Foundation
import Testing
import ito_runner
@testable import Ito

/// Installs that replace an installed source with a rebuilt package, and candidate choice across repositories, with
/// real archives, real repository indexes, and a real plugin directory.
@MainActor
struct PackageRebuildReplacementTests {
    private func makePackage(
        id: String,
        version: String = "1.0",
        sha256: String,
        downloadUrl: String = "package.ito",
        abi: Int? = nil
    ) -> RepoPackage {
        RepoPackage(
            id: id,
            name: id,
            version: version,
            minAppVersion: "1.0",
            downloadUrl: downloadUrl,
            iconUrl: nil,
            sha256: sha256,
            pluginType: "manga",
            archived: nil,
            archivedReason: nil,
            archivedDate: nil,
            abi: abi
        )
    }

    private func makeIndex(packages: [RepoPackage]) -> RepoIndex {
        RepoIndex(
            repoName: "Fixture",
            repoUrl: "https://example.com/repo",
            description: "",
            packages: packages
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func aDeclaredRebuildReplacesTheIncompatibleFileKeepsItsSettingsAndRunsAfterwards() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let host = 3...3
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryInstallDeclaredRebuild-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let installedFile = pluginsDirectory.appendingPathComponent("plugin.declared.ito")
        try makeTestPluginArchiveData(id: "plugin.declared", version: "1.0", wasm: makeTestPluginWasm(abi: 2))
            .write(to: installedFile)
        let settings = PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter())
        #expect(settings.set(pluginId: "plugin.declared", key: "endpoint", value: "kept"))
        let pluginManager = PluginManager(
            pluginSettingsStore: settings,
            pluginsDirectory: pluginsDirectory,
            supportedABI: host
        )
        await pluginManager.reloadInstalledPlugins()
        let installed = try #require(pluginManager.installedPlugins["plugin.declared"])
        let rebuilt = try makeTestPluginArchiveData(
            id: "plugin.declared", version: "1.0", wasm: makeTestPluginWasm(abi: 3)
        )
        // The feed declares the build's ABI, which this host runs, so the listing is compatible before download.
        let package = makePackage(id: "plugin.declared", version: "1.0", sha256: sha256(rebuilt), abi: 3)
        #expect(
            PackageInstallStatus.resolve(
                for: package,
                feedRefusal: package.compatibilityRefusal(supported: host),
                installed: installed,
                supported: host
            ) == .sourceUpdateRequired
        )
        let manager = RepoManager(
            dbPool: database.dbPool,
            pluginManager: pluginManager,
            pluginsDirectory: nil,
            packageFetcher: { _ in rebuilt },
            supportedABI: host
        )

        try await manager.installPackage(package, repositoryUrl: "https://example.com")

        #expect(try Data(contentsOf: installedFile) == rebuilt)
        #expect(pluginManager.installedPlugins["plugin.declared"]?.compatibilityRefusal(supported: host) == nil)
        #expect(settings.get(pluginId: "plugin.declared", key: "endpoint") == "kept")
    }

    @Test func aDeclaredListingIsInstalledFromBeforeANewerUnknownOneFromAnotherRepository() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        // The first repository lists a newer build with no ABI; the second lists an older build declared for this host.
        let unknown = makePackage(id: "plugin.ranked", version: "2.0", sha256: "unused")
        let declared = makePackage(id: "plugin.ranked", version: "1.0", sha256: "unused", abi: 3)
        let unknownIndex = try JSONEncoder().encode(makeIndex(packages: [unknown]))
        let declaredIndex = try JSONEncoder().encode(makeIndex(packages: [declared]))
        let manager = RepoManager(
            dbPool: database.dbPool,
            pluginsDirectory: nil,
            indexFetcher: { url in url.host == "unknown.example" ? unknownIndex : declaredIndex },
            supportedABI: 3...3
        )
        try await manager.addRepository(url: "https://unknown.example/repo")
        try await manager.addRepository(url: "https://declared.example/repo")

        let candidate = try await manager.findPackage(forExactPluginID: "plugin.ranked")

        #expect(candidate?.repositoryURL == "https://declared.example/repo")
        #expect(candidate?.package.abi == 3)
    }
}
