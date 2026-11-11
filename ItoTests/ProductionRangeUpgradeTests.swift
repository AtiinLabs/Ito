import CryptoKit
import Foundation
import ito_runner
import Testing
@testable import Ito

/// The ABI 2 to ABI 3 upgrade at the production range. Nothing is injected: these checks run against the runner and
/// gate this build links, as an installed user's app does.
@MainActor
struct ProductionRangeUpgradeTests {
    private func installedABI2() throws -> InstalledPlugin {
        InstalledPlugin(
            url: URL(fileURLWithPath: "/test/abi2.ito"),
            info: PluginInfo(id: "plugin.abi2", name: "ABI 2", version: "1.0", minAppVersion: "1.0", type: .manga),
            iconData: nil,
            binary: try ItoRunner.inspectBinary([UInt8](makeTestPluginWasm(abi: 2)))
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func anInstalledABI2SourceNeedsASourceUpdateInThisBuild() throws {
        #expect(try installedABI2().compatibilityRefusal() == .requiresSourceUpdate)
    }

    @Test func anABI1SourceWithoutErrorVersionOrKindsNeedsASourceUpdate() throws {
        // The module helper cannot omit the kinds export, so no kinds is the nearest a test module gets to an ABI 1 file.
        let plugin = InstalledPlugin(
            url: URL(fileURLWithPath: "/test/abi1.ito"),
            info: PluginInfo(id: "plugin.abi1", name: "ABI 1", version: "1.0", minAppVersion: "1.0", type: .manga),
            iconData: nil,
            binary: try ItoRunner.inspectBinary([UInt8](makeTestPluginWasm(abi: 1, kindsMask: 0, errorVersion: nil)))
        )
        #expect(plugin.compatibilityRefusal() == .requiresSourceUpdate)
    }

    @Test func aDeclaredABI2ListingNeedsASourceUpdateInThisBuild() {
        #expect(PluginIncompatibility.declared(abi: 2, imports: nil) == .requiresSourceUpdate)
    }

    @Test func theMinimumAppVersionOfTheABI3FeedIsSatisfiedByThisBuild() {
        #expect(AppVersion.isAtLeast("1.5.0", current: AppVersion.marketing))
    }

    @Test func aSameVersionABI3RebuildReplacesTheInstalledABI2FileAndKeepsItsSettings() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductionRangeUpgrade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let installedFile = pluginsDirectory.appendingPathComponent("plugin.upgrade.ito")
        try makeTestPluginArchiveData(id: "plugin.upgrade", version: "1.0", wasm: makeTestPluginWasm(abi: 2))
            .write(to: installedFile)
        let settings = PluginSettingsStore(dbPool: database.dbPool)
        #expect(settings.set(pluginId: "plugin.upgrade", key: "endpoint", value: "kept"))
        let pluginManager = PluginManager(pluginSettingsStore: settings, pluginsDirectory: pluginsDirectory)
        await pluginManager.reloadInstalledPlugins()
        let installed = try #require(pluginManager.installedPlugins["plugin.upgrade"])
        let rebuilt = try makeTestPluginArchiveData(
            id: "plugin.upgrade", version: "1.0", wasm: makeTestPluginWasm(abi: ItoRunner.supportedABIVersions.upperBound)
        )
        let package = RepoPackage(
            id: "plugin.upgrade",
            name: "plugin.upgrade",
            version: "1.0",
            minAppVersion: "1.0",
            downloadUrl: "package.ito",
            iconUrl: nil,
            sha256: sha256(rebuilt),
            pluginType: "manga",
            archived: nil,
            archivedReason: nil,
            archivedDate: nil,
            abi: ItoRunner.supportedABIVersions.upperBound
        )
        #expect(
            PackageInstallStatus.resolve(
                for: package,
                feedRefusal: package.compatibilityRefusal(),
                installed: installed,
                supported: ItoRunner.supportedABIVersions
            ) == .sourceUpdateRequired
        )
        let manager = RepoManager(
            dbPool: database.dbPool,
            pluginManager: pluginManager,
            pluginsDirectory: nil,
            packageFetcher: { _ in rebuilt }
        )

        try await manager.installPackage(package, repositoryUrl: "https://example.com")

        #expect(try Data(contentsOf: installedFile) == rebuilt)
        #expect(pluginManager.installedPlugins["plugin.upgrade"]?.compatibilityRefusal() == nil)
        #expect(settings.get(pluginId: "plugin.upgrade", key: "endpoint") == "kept")
    }
}
