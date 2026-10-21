import Foundation
import Testing
import ito_runner
@testable import Ito

@MainActor
struct PluginGatingTests {
    @Test(arguments: [
        ("1.2.0", "1.2", true),
        ("1.2", "1.2.0", true),
        ("1.10.0", "1.9.0", true),
        ("1.2.0", "1.3", false),
        ("1.2.0", "1.2.1", false),
        ("1.2.0-beta", "1.2.0", true),
        ("1.2.0", "1.2.0-beta.1", true),
        ("1.2.0", "1.2.0+build.5", true),
        ("2", "1.99.99", true)
    ])
    func appVersionsCompareByNumericComponents(current: String, minimum: String, satisfied: Bool) {
        #expect(AppVersion.isAtLeast(minimum, current: current) == satisfied)
    }

    @Test(arguments: [
        ("https://img.example.com/cover.jpg", true),
        ("https://img.example.com/cover.jpg?token=secret", false),
        ("https://user:pass@img.example.com/cover.jpg", false),
        ("https://img.example.com/cover.jpg#frag", false),
        ("http://img.example.com/cover.jpg", false),
        ("ito://com.example.plugin/https://img.example.com/cover.jpg", false)
    ])
    func discordOnlyGetsURLsThatCarryNoCredentials(url: String, shared: Bool) {
        #expect((DiscordRPCManager.shareableURL(url) != nil) == shared)
    }

    @Test func aLocalPluginNeedingANewerItoIsRefusedAndNothingIsInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginGating-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginsDirectory = root.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("future.ito")
        try makeTestPluginArchiveData(id: "future", version: "1.0", minAppVersion: "999.0").write(to: source)
        let operations = LocalBrowsePluginFileOperations(pluginsDirectory: pluginsDirectory)

        #expect(throws: PluginRequiresNewerAppError(minimumAppVersion: "999.0")) {
            try operations.installPluginFile(from: source)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: pluginsDirectory.path).isEmpty)
    }

    @Test func aFileThatIsNotAPluginBundleIsRefusedAsSuch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginGating-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginsDirectory = root.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("broken.ito")
        try Data("not a zip".utf8).write(to: source)
        let operations = LocalBrowsePluginFileOperations(pluginsDirectory: pluginsDirectory)

        #expect {
            try operations.installPluginFile(from: source)
        } throws: { error in
            if case BrowsePluginFileError.unsupportedPluginFile = error { return true }
            return false
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: pluginsDirectory.path).isEmpty)
    }

    @Test func aPluginNeedingANewerItoIsNotLoaded() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        var loads = 0
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: { _, _, _ in
                loads += 1
                return ItoRunner()
            }
        )
        let plugin = InstalledPlugin(
            url: URL(fileURLWithPath: "/test/future.ito"),
            info: PluginInfo(id: "future", name: "Future", version: "1.0", minAppVersion: "999.0", type: .manga),
            iconData: nil
        )
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])

        await #expect(throws: PluginRequiresNewerAppError(minimumAppVersion: "999.0")) {
            try await manager.getRunner(for: plugin.id)
        }
        #expect(loads == 0)
    }

    @Test func aRepositoryPackageNeedingANewerItoIsNotDownloaded() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let downloads = Counter()
        let repositories = RepoManager(
            dbPool: database.dbPool,
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            packageFetcher: { _ in
                await downloads.increment()
                return Data()
            }
        )
        let package = RepoPackage(
            id: "future", name: "Future", version: "1.0", minAppVersion: "999.0",
            downloadUrl: "future.ito", iconUrl: nil, sha256: "unused", pluginType: "manga",
            archived: nil, archivedReason: nil, archivedDate: nil
        )

        await #expect(throws: PluginRequiresNewerAppError(minimumAppVersion: "999.0")) {
            try await repositories.installPackage(package, repositoryUrl: "https://repo.example")
        }
        #expect(await downloads.value == 0)
    }

    @Test func aPackageBuiltForANewerABIOrNeedingAMissingFunctionIsRefusedWithoutNamingAVersion() {
        func package(abi: Int?, imports: [String]?) -> RepoPackage {
            RepoPackage(
                id: "p", name: "P", version: "1.0", minAppVersion: "1.0", downloadUrl: "p.ito",
                iconUrl: nil, sha256: "x", pluginType: "manga", archived: nil, archivedReason: nil,
                archivedDate: nil, abi: abi, imports: imports
            )
        }
        let refused = PluginRequiresNewerAppError(minimumAppVersion: nil)

        #expect(package(abi: 2, imports: nil).compatibilityRefusal() == refused)
        #expect(package(abi: 1, imports: ["ito:core/net.fetch_v9"]).compatibilityRefusal() == refused)
        #expect(package(abi: 1, imports: ["ito:core/net.fetch_v2", "ito:core/std.print"]).compatibilityRefusal() == nil)
        #expect(package(abi: nil, imports: nil).compatibilityRefusal() == nil)
        #expect(refused.localizedDescription == "This source needs a newer version of Ito. Update Ito to use it.")
    }

    @Test func indexesWithAndWithoutTheRecordedInterfaceDecode() throws {
        let entry = """
            "id": "p", "name": "P", "version": "1.0", "min_app_version": "1.0",
            "download_url": "packages/p.ito", "sha256": "x", "type": "manga"
            """
        let newer = try JSONDecoder().decode(RepoPackage.self, from: Data("""
            {\(entry), "abi": 1, "sdk": "ito-rs 0.1.1 (39749ae)", "imports": ["ito:core/net.fetch_v2"]}
            """.utf8))
        let older = try JSONDecoder().decode(RepoPackage.self, from: Data("{\(entry)}".utf8))

        #expect(newer.abi == 1)
        #expect(newer.imports == ["ito:core/net.fetch_v2"])
        #expect(older.abi == nil && older.imports == nil)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
