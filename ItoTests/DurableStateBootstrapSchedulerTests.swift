import Foundation
import Testing
@testable import Ito

/// Where the bootstrap composes automatic downloads: the one production sink, the foreground scheduler behind the one
/// lifecycle gate, and the facade the screens get. Over the real offline store in a temporary root.
@MainActor
struct DurableStateBootstrapSchedulerTests {
    private final class ReadyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var observed: [Bool?] = []

        var values: [Bool?] { lock.withLock { observed } }

        func record(_ active: Bool?) {
            lock.withLock { observed.append(active) }
        }
    }

    private final class BootstrapBox: @unchecked Sendable {
        nonisolated(unsafe) var value: DurableStateBootstrap?
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scheduler-wiring-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func theCenterIsTheSinkAndTheSchedulerRunsOnlyReadyAndInTheForeground() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let offlineRoot = root()
        defer { try? FileManager.default.removeItem(at: offlineRoot) }
        let probe = ReadyProbe()
        let box = BootstrapBox()
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: {},
            onReady: { @MainActor in probe.record(box.value?.subscriptionScheduler?.isActive) },
            sourceDatabaseURL: database.databaseURL,
            offlineChaptersRoot: offlineRoot,
            networkPath: ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied))
        )
        box.value = bootstrap
        #expect(bootstrap.subscriptionScheduler == nil)

        #expect(await bootstrap.prepare())
        #expect(bootstrap.state == .ready)

        // The scheduler existed and was inactive when the bootstrap announced readiness: it starts only after.
        #expect(probe.values == [false])
        // The update manager's one sink is the composed download center.
        let scope = try #require(bootstrap.appScope)
        let center = try #require(scope.dependencies.mediaDetail?.downloads)
        let updates = try #require(bootstrap.updateManager)
        #expect(updates.subscriptionSinkIdentity == ObjectIdentifier(center as AnyObject))
        #expect(scope.dependencies.automaticDownloads.isAvailable)

        let scheduler = try #require(bootstrap.subscriptionScheduler)
        bootstrap.setCompletionForeground(true)
        #expect(scheduler.isActive)
        bootstrap.setCompletionForeground(false)
        #expect(!scheduler.isActive)
        bootstrap.setCompletionForeground(true)
        #expect(scheduler.isActive)
    }

    @Test func withoutAnOfflineStoreNothingIsComposed() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: {},
            sourceDatabaseURL: database.databaseURL,
            networkPath: ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied))
        )

        #expect(await bootstrap.prepare())

        #expect(bootstrap.subscriptionScheduler == nil)
        #expect(bootstrap.updateManager?.subscriptionSinkIdentity == nil)
        #expect(try #require(bootstrap.appScope).dependencies.automaticDownloads.isAvailable == false)
    }
}
