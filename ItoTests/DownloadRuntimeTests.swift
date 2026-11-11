import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

@MainActor
struct DownloadRuntimeTests {
    private static func installedPlugin() -> InstalledPlugin {
        InstalledPlugin(
            url: URL(fileURLWithPath: "/test/download-source.ito"),
            info: PluginInfo(id: "download.source", name: "Download Source", version: "1.0", minAppVersion: "1.0", type: .manga),
            iconData: nil,
            binary: makeRunnableBinary()
        )
    }

    @Test func aDownloadRuntimeLoadsItsOwnRunnerAndLeavesTheForegroundCacheEmpty() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let foregroundLoads = DownloadCallCounter()
        let downloadLoads = DownloadCallCounter()
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: { _, _, _ in
                foregroundLoads.increment()
                return ItoRunner()
            },
            downloadRunnerLoader: { _, _, _, _ in
                downloadLoads.increment()
                return ItoRunner()
            }
        )
        manager.publishPreparedInstalledPlugins([Self.installedPlugin().id: Self.installedPlugin()])
        let recorder = DownloadPolicyRecorder()
        let modules = PluginRunnerHostModules(
            net: DownloadNetModule(
                inner: ScriptedInnerNet(),
                gate: NetworkPathAdmissionGate(observer: ManualNetworkPathObserver()),
                recorder: recorder
            ),
            webview: DownloadWebviewModule(recorder: recorder)
        )

        _ = try await manager.makeDownloadRuntime(for: "download.source", modules: modules)

        #expect(downloadLoads.count == 1)
        #expect(foregroundLoads.count == 0)

        _ = try await manager.getRunner(for: "download.source")
        #expect(foregroundLoads.count == 1)
    }

    @Test func aRepublishedPluginMakesTheDownloadRuntimeNotCurrent() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: { _, _, _ in ItoRunner() },
            downloadRunnerLoader: { _, _, _, _ in ItoRunner() }
        )
        manager.publishPreparedInstalledPlugins([Self.installedPlugin().id: Self.installedPlugin()])
        let recorder = DownloadPolicyRecorder()
        let modules = PluginRunnerHostModules(
            net: DownloadNetModule(
                inner: ScriptedInnerNet(),
                gate: NetworkPathAdmissionGate(observer: ManualNetworkPathObserver()),
                recorder: recorder
            ),
            webview: DownloadWebviewModule(recorder: recorder)
        )
        let runtime = try await manager.makeDownloadRuntime(for: "download.source", modules: modules)
        #expect(runtime.isPluginCurrent())

        manager.publishPreparedInstalledPlugins([Self.installedPlugin().id: Self.installedPlugin()])

        #expect(runtime.isPluginCurrent() == false)
    }

    @Test func aMissingPluginHasNoDownloadRuntime() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: { _, _, _ in ItoRunner() },
            downloadRunnerLoader: { _, _, _, _ in ItoRunner() }
        )
        let recorder = DownloadPolicyRecorder()
        let modules = PluginRunnerHostModules(
            net: ScriptedInnerNet(),
            webview: DownloadWebviewModule(recorder: recorder)
        )

        await #expect(throws: URLError.self) {
            try await manager.makeDownloadRuntime(for: "not.installed", modules: modules)
        }
    }

    @Test func publishedChaptersAreReportedAsDownloadedFromTheInventory() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        _ = await fixture.enqueue(chapterKey: "chapter-1")
        _ = await fixture.enqueue(chapterKey: "chapter-2")
        fixture.coordinator.start()
        await fixture.coordinator.untilIdle()
        let copies = try await fixture.offline.database.dbPool.read { db in
            try DownloadedChapterRecord.fetchAll(db)
        }
        let jobs = try await fixture.store.jobs()

        let states = DownloadCenter.states(copies: copies, jobs: jobs, progress: [:])

        let identity = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)
        #expect(states[identity]?["chapter-1"] == .downloaded)
        #expect(states[identity]?["chapter-2"] == .downloaded)
    }

    @Test func aQueuedChapterShowsItsWaitingReasonAndAnInFlightOneShowsProgress() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        _ = await fixture.enqueue(chapterKey: "chapter-1")
        let staged = try await fixture.store.beginAttempt(jobID: try #require(try await fixture.job()).id)
        let downloading = try #require(try await fixture.job())
        #expect(downloading.state == .downloading)

        let progress = DownloadProgress(jobID: downloading.id, completedPages: 2, totalPages: 3, bytes: 90)
        let states = DownloadCenter.states(copies: [], jobs: [downloading], progress: [downloading.id: progress])
        let identity = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)
        #expect(states[identity]?["chapter-1"] == .downloading(completed: 2, total: 3))
        #expect(DownloadCenter.state(of: downloading, progress: nil) == .downloading(completed: 0, total: nil))

        try await fixture.store.abandonAttempt(jobID: downloading.id, versionId: staged.versionId, outcome: .waiting(.noConnection))
        let waiting = try #require(try await fixture.job())
        #expect(DownloadCenter.state(of: waiting, progress: nil) == .waiting(.noConnection))
    }
}
