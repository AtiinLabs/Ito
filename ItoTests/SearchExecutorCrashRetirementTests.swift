import Foundation
import Testing
import ito_runner
@testable import Ito

/// A global search retires the runner whose export trapped, and only that one: the next acquisition is a new
/// instance after a crash, and the same instance after an ordinary failure.
@MainActor
struct SearchExecutorCrashRetirementTests {
    private static let siteURL = "https://example.test"

    @Test func aSearchThatTrapsRetiresItsRunner() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = try makeManager(database: database, search: [0x00])
        let before = try await manager.getRunner(for: "plugin.test")

        let error = await searchError(manager, query: "query")

        #expect((error as? PluginCallError)?.kind == .crashed)
        #expect(try await manager.getRunner(for: "plugin.test") !== before)
    }

    @Test func aLinkThatTrapsRetiresItsRunner() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = try makeManager(database: database, handleUrl: [0x00])
        let before = try await manager.getRunner(for: "plugin.test")

        let error = await searchError(manager, query: "\(Self.siteURL)/title/1")

        #expect((error as? PluginCallError)?.kind == .crashed)
        #expect(try await manager.getRunner(for: "plugin.test") !== before)
    }

    @Test func anOrdinaryFailureKeepsTheRunner() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = try makeManager(database: database, search: [0x42, 0x00], reportsFailure: true)
        let before = try await manager.getRunner(for: "plugin.test")

        let error = await searchError(manager, query: "query")

        let callError = try #require(error as? PluginCallError)
        #expect(callError.kind != .crashed)
        #expect(try await manager.getRunner(for: "plugin.test") === before)
    }

    private func searchError(_ manager: PluginManager, query: String) async -> (any Error)? {
        let plugin = SearchPluginDescriptor(id: "plugin.test", name: "Test", kinds: [.manga], siteURL: Self.siteURL)
        do {
            _ = try await PluginManagerSearchExecutor(pluginManager: manager).search(
                plugin: plugin,
                kind: nil,
                query: query,
                limit: 10,
                operation: makeTestNetworkOperation(.interactiveSearch)
            )
            return nil
        } catch {
            return error
        }
    }

    /// A manager whose runner for `plugin.test` is a module with the given `search` / `handle_url` bodies; every
    /// load is a new runner instance.
    private func makeManager(
        database: TestDatabase,
        search: [UInt8]? = nil,
        handleUrl: [UInt8]? = nil,
        reportsFailure: Bool = false
    ) throws -> PluginManager {
        var fixture = reportsFailure ? try TestWasm.failing(with: "network") : TestWasm.Fixture()
        fixture.search = search
        fixture.handleUrl = handleUrl
        let wasm = TestWasm.build(fixture)
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter()),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: { _, _, _ in
                let runner = ItoRunner()
                try await runner.loadPlugin(fromBytes: wasm)
                return runner
            }
        )
        let plugin = InstalledPlugin(
            url: URL(fileURLWithPath: "/test/plugin.test.ito"),
            info: PluginInfo(
                id: "plugin.test", name: "Test", version: "1.0.0", minAppVersion: "1.0",
                url: Self.siteURL, type: .manga
            ),
            iconData: nil,
            binary: makeRunnableBinary()
        )
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])
        return manager
    }
}
