import GRDB
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

    @Test func aLocalPluginNeedingANewerItoIsRefusedAndNothingIsInstalled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginGating-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginsDirectory = root.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("future.ito")
        try makeTestPluginArchiveData(id: "future", version: "1.0", minAppVersion: "999.0").write(to: source)
        let operations = LocalBrowsePluginFileOperations(pluginsDirectory: pluginsDirectory)

        await #expect(throws: PluginIncompatibility.requiresNewerApp(minimumAppVersion: "999.0")) {
            try await operations.installPluginFile(from: source, PluginDirectoryLease())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: pluginsDirectory.path).isEmpty)
    }

    @Test func aFileThatIsNotAPluginBundleIsRefusedAsSuch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginGating-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginsDirectory = root.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("broken.ito")
        try Data("not a zip".utf8).write(to: source)
        let operations = LocalBrowsePluginFileOperations(pluginsDirectory: pluginsDirectory)

        await #expect {
            try await operations.installPluginFile(from: source, PluginDirectoryLease())
        } throws: { error in
            if case BrowsePluginFileError.unsupportedPluginFile = error { return true }
            return false
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: pluginsDirectory.path).isEmpty)
    }

    @Test func anIncompatibleManualImportLeavesTheInstalledFileAndPluginsDirectoryUnchanged() async throws {
        let fixture = try ManualImportFixture(incoming: makeTestPluginWasm(abi: ItoRunner.supportedABIVersions.upperBound + 1))
        defer { fixture.cleanup() }
        let operations = LocalBrowsePluginFileOperations(pluginsDirectory: fixture.pluginsDirectory)

        await #expect(throws: PluginIncompatibility.requiresNewerApp(minimumAppVersion: nil)) {
            try await operations.installPluginFile(from: fixture.source, PluginDirectoryLease())
        }
        try fixture.expectInstalledFileUntouched()
    }

    @Test func aManualImportOfAModuleOlderThanThisHostReadsIsRefusedAsASourceUpdate() async throws {
        // The host here reads only ABI 3, so the ABI 2 module is too old for it: the source must be updated.
        let fixture = try ManualImportFixture(incoming: makeTestPluginWasm(abi: 2))
        defer { fixture.cleanup() }
        let operations = LocalBrowsePluginFileOperations(
            pluginsDirectory: fixture.pluginsDirectory,
            supportedABI: 3...3
        )

        await #expect(throws: PluginIncompatibility.requiresSourceUpdate) {
            try await operations.installPluginFile(from: fixture.source, PluginDirectoryLease())
        }
        try fixture.expectInstalledFileUntouched()
    }

    @Test func aManualImportOfABI2IsRefusedAsASourceUpdateAtTheProductionRange() async throws {
        let fixture = try ManualImportFixture(incoming: makeTestPluginWasm(abi: 2))
        defer { fixture.cleanup() }
        let operations = LocalBrowsePluginFileOperations(pluginsDirectory: fixture.pluginsDirectory)

        await #expect(throws: PluginIncompatibility.requiresSourceUpdate) {
            try await operations.installPluginFile(from: fixture.source, PluginDirectoryLease())
        }
        try fixture.expectInstalledFileUntouched()
    }

    @Test(arguments: [
        makeTestPluginWasm(abi: ItoRunner.supportedABIVersions.upperBound, errorVersion: nil),
        makeTestPluginWasm(abi: ItoRunner.supportedABIVersions.upperBound, kindsMask: 0)
    ])
    func aManualImportTheStaticGateRefusesIsUnreadableAndLeavesTheInstalledFileUntouched(incoming: Data) async throws {
        let fixture = try ManualImportFixture(incoming: incoming)
        defer { fixture.cleanup() }
        let operations = LocalBrowsePluginFileOperations(pluginsDirectory: fixture.pluginsDirectory)

        await #expect {
            try await operations.installPluginFile(from: fixture.source, PluginDirectoryLease())
        } throws: { error in
            if case BrowsePluginFileError.unsupportedPluginFile = error { return true }
            return false
        }
        try fixture.expectInstalledFileUntouched()
    }

    @Test func aMalformedModuleManualImportLeavesTheInstalledFileAndPluginsDirectoryUnchanged() async throws {
        let fixture = try ManualImportFixture(incoming: Data("not a module".utf8))
        defer { fixture.cleanup() }
        let operations = LocalBrowsePluginFileOperations(pluginsDirectory: fixture.pluginsDirectory)

        await #expect {
            try await operations.installPluginFile(from: fixture.source, PluginDirectoryLease())
        } throws: { error in
            if case BrowsePluginFileError.unsupportedPluginFile = error { return true }
            return false
        }
        try fixture.expectInstalledFileUntouched()
    }

    @Test func aCompatibleManualImportReplacesTheInstalledFile() async throws {
        let incoming = makeTestPluginWasm(abi: ItoRunner.supportedABIVersions.upperBound)
        let fixture = try ManualImportFixture(incoming: incoming)
        defer { fixture.cleanup() }
        let operations = LocalBrowsePluginFileOperations(pluginsDirectory: fixture.pluginsDirectory)

        try await operations.installPluginFile(from: fixture.source, PluginDirectoryLease())

        let installed = try Data(contentsOf: fixture.installedFile)
        #expect(installed == fixture.incomingArchive)
        #expect(installed != fixture.installedArchive)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.pluginsDirectory.path) == ["plugin.ito"])
    }

    @Test func strictDiscoveryListsAMalformedOrIncompatibleModuleWithItsSettingsPrepared() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginDiscovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        try makeTestPluginArchiveData(id: "malformed", version: "1.0", wasm: Data("not a module".utf8))
            .write(to: pluginsDirectory.appendingPathComponent("malformed.ito"))
        try makeTestPluginArchiveData(
            id: "newer-abi", version: "1.0", wasm: makeTestPluginWasm(abi: ItoRunner.supportedABIVersions.upperBound + 1)
        )
            .write(to: pluginsDirectory.appendingPathComponent("newer-abi.ito"))
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter()),
            pluginsDirectory: pluginsDirectory
        )

        try await manager.discoverAndPrepareInstalledPlugins(failOnInvalidPlugin: true)

        #expect(manager.installedPlugins["malformed"]?.binary == nil)
        #expect(manager.installedPlugins["newer-abi"]?.binary?.abiVersion == ItoRunner.supportedABIVersions.upperBound + 1)
        let registered = try await database.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT pluginId FROM pluginIdentityRegistry ORDER BY pluginId")
        }
        #expect(registered == ["malformed", "newer-abi"])
    }

    @Test func aPluginNeedingANewerItoIsNotLoaded() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        var loads = 0
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter()),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: { _, _, _ in
                loads += 1
                return ItoRunner()
            }
        )
        let plugins = [
            InstalledPlugin(
                url: URL(fileURLWithPath: "/test/future.ito"),
                info: PluginInfo(id: "future", name: "Future", version: "1.0", minAppVersion: "999.0", type: .manga),
                iconData: nil,
                binary: makeRunnableBinary()
            ),
            InstalledPlugin(
                url: URL(fileURLWithPath: "/test/newer-abi.ito"),
                info: PluginInfo(
                    id: "newer-abi", name: "Newer", version: "1.0", minAppVersion: "1.0", type: .manga,
                    abi: ItoRunner.supportedABIVersions.upperBound + 1
                ),
                iconData: nil,
                binary: makeRunnableBinary(abi: ItoRunner.supportedABIVersions.upperBound + 1)
            )
        ]
        manager.publishPreparedInstalledPlugins(Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0) }))

        await #expect(throws: PluginIncompatibility.requiresNewerApp(minimumAppVersion: "999.0")) {
            try await manager.getRunner(for: "future")
        }
        await #expect(throws: PluginIncompatibility.requiresNewerApp(minimumAppVersion: nil)) {
            try await manager.getRunner(for: "newer-abi")
        }
        #expect(loads == 0)
    }

    @Test func anInstalledSourceBuiltForAnOlderABIIsNotLoadedAndReportsASourceUpdate() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        var loads = 0
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter()),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: { _, _, _ in
                loads += 1
                return ItoRunner()
            },
            supportedABI: 3...3
        )
        // The manifest declares no ABI, so the module's own interface is what refuses it.
        let plugin = InstalledPlugin(
            url: URL(fileURLWithPath: "/test/old-abi.ito"),
            info: PluginInfo(id: "old-abi", name: "Old", version: "1.0", minAppVersion: "1.0", type: .manga),
            iconData: nil,
            binary: try ItoRunner.inspectBinary([UInt8](makeTestPluginWasm(abi: 2)))
        )
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])

        await #expect(throws: PluginIncompatibility.requiresSourceUpdate) {
            try await manager.getRunner(for: plugin.id)
        }
        #expect(loads == 0)
    }

    @Test func aPluginWhoseModuleNeedsAMissingHostFunctionIsRefusedWhenItLoads() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginsDirectory = database.databaseURL.deletingLastPathComponent()
        // A module built for this host that imports ito:core/net.fetch_v9, which no host has; its manifest records nothing.
        let wasm = Data(TestWasm.build(TestWasm.Fixture(
            completed: nil,
            imports: [TestWasm.Import(module: "ito:core/net", name: "fetch_v9", type: 3)]
        )))
        let url = pluginsDirectory.appendingPathComponent("future.ito")
        try makeTestPluginArchiveData(id: "future", version: "1.0", wasm: wasm).write(to: url)
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter()),
            pluginsDirectory: pluginsDirectory
        )
        let plugin = InstalledPlugin(
            url: url,
            info: PluginInfo(id: "future", name: "Future", version: "1.0", minAppVersion: "1.0", type: .manga),
            iconData: nil,
            binary: try ItoRunner.inspectBinary([UInt8](wasm))
        )
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])

        await #expect(throws: PluginIncompatibility.requiresNewerApp(minimumAppVersion: nil)) {
            try await manager.getRunner(for: plugin.id)
        }
    }

    @Test func aPluginWithoutAReadableModuleIsUnsupportedOnEveryRouteWhateverItsManifestSaysAndNeverLoads() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        var loads = 0
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter()),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: { _, _, _ in
                loads += 1
                return ItoRunner()
            },
            downloadRunnerLoader: { _, _, _, _, _, _ in
                loads += 1
                return ItoRunner()
            }
        )
        // One manifest names an in-range ABI and one names none. The manifest never makes an unreadable module runnable.
        let plugins = [
            InstalledPlugin(
                url: URL(fileURLWithPath: "/test/unreadable-in-range.ito"),
                info: PluginInfo(id: "unreadable-in-range", name: "In Range", version: "1.0", minAppVersion: "1.0", type: .manga, abi: 2),
                iconData: nil,
                binary: nil
            ),
            InstalledPlugin(
                url: URL(fileURLWithPath: "/test/unreadable-undeclared.ito"),
                info: PluginInfo(id: "unreadable-undeclared", name: "Undeclared", version: "1.0", minAppVersion: "1.0", type: .manga),
                iconData: nil,
                binary: nil
            )
        ]
        manager.publishPreparedInstalledPlugins(Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0) }))
        let modules = PluginRunnerHostModules(
            net: DownloadNetModule(
                inner: ScriptedInnerNet(contexts: NetworkContextRecorder()),
                gate: NetworkPathAdmissionGate(observer: ManualNetworkPathObserver(), policy: NetworkPolicyCenter()),
                recorder: DownloadPolicyRecorder()
            ),
            webview: DownloadWebviewModule(recorder: DownloadPolicyRecorder())
        )

        for plugin in plugins {
            await #expect(throws: PluginIncompatibility.unsupportedFile) {
                try await manager.getRunner(for: plugin.id)
            }
            await #expect(throws: PluginIncompatibility.unsupportedFile) {
                try await manager.getImageRunner(for: plugin.id)
            }
            await #expect(throws: PluginIncompatibility.unsupportedFile) {
                _ = try await manager.makeDownloadRuntime(for: plugin.id, modules: modules, operation: makeTestNetworkOperation(.manualBulkDownload), frozenScope: nil)
            }
        }
        #expect(loads == 0)
    }

    @Test(arguments: [
        makeTestPluginWasm(abi: ItoRunner.supportedABIVersions.upperBound, errorVersion: nil),
        makeTestPluginWasm(abi: ItoRunner.supportedABIVersions.upperBound, kindsMask: 0)
    ])
    func aModuleTheStaticGateRefusesIsUnsupportedOnEveryRouteAndNeverLoads(wasm: Data) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        var loads = 0
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter()),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: { _, _, _ in
                loads += 1
                return ItoRunner()
            },
            downloadRunnerLoader: { _, _, _, _, _, _ in
                loads += 1
                return ItoRunner()
            }
        )
        let plugin = InstalledPlugin(
            url: URL(fileURLWithPath: "/test/static-gate.ito"),
            info: PluginInfo(id: "static-gate", name: "Static Gate", version: "1.0", minAppVersion: "1.0", type: .manga),
            iconData: nil,
            binary: try ItoRunner.inspectBinary([UInt8](wasm))
        )
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])
        let modules = PluginRunnerHostModules(
            net: DownloadNetModule(
                inner: ScriptedInnerNet(contexts: NetworkContextRecorder()),
                gate: NetworkPathAdmissionGate(observer: ManualNetworkPathObserver(), policy: NetworkPolicyCenter()),
                recorder: DownloadPolicyRecorder()
            ),
            webview: DownloadWebviewModule(recorder: DownloadPolicyRecorder())
        )

        await #expect(throws: PluginIncompatibility.unsupportedFile) {
            try await manager.getRunner(for: plugin.id)
        }
        await #expect(throws: PluginIncompatibility.unsupportedFile) {
            try await manager.getImageRunner(for: plugin.id)
        }
        await #expect(throws: PluginIncompatibility.unsupportedFile) {
            _ = try await manager.makeDownloadRuntime(for: plugin.id, modules: modules, operation: makeTestNetworkOperation(.manualBulkDownload), frozenScope: nil)
        }
        #expect(loads == 0)
    }

    @Test func anInstalledModuleWithAStartSectionIsUnsupportedWithANeutralMessageAndNeverLoads() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        var loads = 0
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter()),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: { _, _, _ in
                loads += 1
                return ItoRunner()
            }
        )
        // Readable, and declaring an in-range ABI, but a start section means no host runs it.
        let plugin = InstalledPlugin(
            url: URL(fileURLWithPath: "/test/start-section.ito"),
            info: PluginInfo(id: "start-section", name: "Start", version: "1.0", minAppVersion: "1.0", type: .manga, abi: 2),
            iconData: nil,
            binary: PluginBinaryInterface(abiVersion: 2, imports: [], kinds: [.manga], hasStartSection: true)
        )
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])

        await #expect(throws: PluginIncompatibility.unsupportedFile) {
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
        let packages = [
            RepoPackage(
                id: "future", name: "Future", version: "1.0", minAppVersion: "999.0",
                downloadUrl: "future.ito", iconUrl: nil, sha256: "unused", pluginType: "manga",
                archived: nil, archivedReason: nil, archivedDate: nil
            ),
            RepoPackage(
                id: "newer-abi", name: "Newer", version: "1.0", minAppVersion: "1.0",
                downloadUrl: "newer.ito", iconUrl: nil, sha256: "unused", pluginType: "manga",
                archived: nil, archivedReason: nil, archivedDate: nil, abi: ItoRunner.supportedABIVersions.upperBound + 1
            )
        ]

        await #expect(throws: PluginIncompatibility.requiresNewerApp(minimumAppVersion: "999.0")) {
            try await repositories.installPackage(packages[0], repositoryUrl: "https://repo.example")
        }
        await #expect(throws: PluginIncompatibility.requiresNewerApp(minimumAppVersion: nil)) {
            try await repositories.installPackage(packages[1], repositoryUrl: "https://repo.example")
        }
        #expect(await downloads.value == 0)
    }

    @Test func aRepositoryPackageBuiltForAnOlderABIThanThisHostReadsIsNotDownloaded() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let downloads = Counter()
        let repositories = RepoManager(
            dbPool: database.dbPool,
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            packageFetcher: { _ in
                await downloads.increment()
                return Data()
            },
            supportedABI: 3...3
        )
        let package = RepoPackage(
            id: "old-abi", name: "Old", version: "1.0", minAppVersion: "1.0",
            downloadUrl: "old.ito", iconUrl: nil, sha256: "unused", pluginType: "manga",
            archived: nil, archivedReason: nil, archivedDate: nil, abi: 2
        )

        await #expect(throws: PluginIncompatibility.requiresSourceUpdate) {
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
        let refused = PluginIncompatibility.requiresNewerApp(minimumAppVersion: nil)
        let current = ItoRunner.supportedABIVersions.upperBound

        #expect(package(abi: current + 1, imports: nil).compatibilityRefusal() == refused)
        #expect(package(abi: current, imports: ["ito:core/net.fetch_v9"]).compatibilityRefusal() == refused)
        #expect(package(abi: current, imports: ["ito:core/net.fetch_v2", "ito:core/std.print"]).compatibilityRefusal() == nil)
        #expect(package(abi: current, imports: ["ito:core/std.print"]).compatibilityRefusal() == nil)
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

    @Test func repoPackageDecodesKindsLenientlyWithStableDeduplicatedMediaKinds() throws {
        let base = """
            "id": "multi", "name": "Multi", "version": "1.0", "min_app_version": "1.0",
            "download_url": "packages/multi.ito", "sha256": "x", "type": "manga"
            """
        // Declared kinds with duplicates, case differences, and unknown kind strings
        let declared = try JSONDecoder().decode(RepoPackage.self, from: Data("""
            {\(base), "kinds": ["manga", "anime", "NOVEL", "manga", "unknown_future_kind", "ANIME"]}
            """.utf8))
        #expect(declared.kinds == ["manga", "anime", "NOVEL", "manga", "unknown_future_kind", "ANIME"])
        #expect(declared.supportedKinds == [.manga, .anime, .novel])

        // Older package without kinds field falls back to type
        let legacy = try JSONDecoder().decode(RepoPackage.self, from: Data("{\(base)}".utf8))
        #expect(legacy.kinds == nil)
        #expect(legacy.supportedKinds == [.manga])

        // Malformed kinds value (e.g. integer or object instead of array of strings) is ignored leniently
        let malformedKinds = try JSONDecoder().decode(RepoPackage.self, from: Data("""
            {\(base), "kinds": 12345}
            """.utf8))
        #expect(malformedKinds.kinds == nil)
        #expect(malformedKinds.supportedKinds == [.manga])

        // Unknown kinds only falls back to legacy type if valid
        let unknownOnly = try JSONDecoder().decode(RepoPackage.self, from: Data("""
            {\(base), "kinds": ["podcast", "game"]}
            """.utf8))
        #expect(unknownOnly.supportedKinds == [.manga])

        // Invalid fallback type with unknown kinds yields empty supportedKinds
        let invalidBoth = try JSONDecoder().decode(RepoPackage.self, from: Data("""
            {
                "id": "x", "name": "X", "version": "1.0", "min_app_version": "1.0",
                "download_url": "x.ito", "sha256": "x", "type": "unrecognized",
                "kinds": ["weird_kind"]
            }
            """.utf8))
        #expect(invalidBoth.supportedKinds.isEmpty)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// A plugins directory holding an installed `plugin.ito` at the host's ABI, and a source file of the same name
/// outside it whose module is `incoming`.
private struct ManualImportFixture {
    let root: URL
    let pluginsDirectory: URL
    let installedFile: URL
    let installedArchive: Data
    let source: URL
    let incomingArchive: Data

    init(incoming: Data) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ManualImport-\(UUID().uuidString)")
        pluginsDirectory = root.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        installedFile = pluginsDirectory.appendingPathComponent("plugin.ito")
        installedArchive = try makeTestPluginArchiveData(
            id: "plugin", version: "1.0", wasm: makeTestPluginWasm(abi: ItoRunner.supportedABIVersions.upperBound)
        )
        try installedArchive.write(to: installedFile)
        source = root.appendingPathComponent("plugin.ito")
        incomingArchive = try makeTestPluginArchiveData(id: "plugin", version: "2.0", wasm: incoming)
        try incomingArchive.write(to: source)
    }

    func expectInstalledFileUntouched() throws {
        #expect(try Data(contentsOf: installedFile) == installedArchive)
        #expect(try FileManager.default.contentsOfDirectory(atPath: pluginsDirectory.path) == ["plugin.ito"])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
