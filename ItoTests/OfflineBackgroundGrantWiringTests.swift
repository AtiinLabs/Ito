import Foundation
import Testing
@testable import Ito

/// The bootstrap's use of the background grant on a backgrounding transition. The bootstrap composes the real
/// offline store over a temporary root, with the grant injected, and drives `setCompletionForeground` as the scene
/// phases do.
@MainActor
struct OfflineBackgroundGrantWiringTests {
    @Test func backgroundingWithNoDownloadInFlightAsksForNoGrantAndRepeatsAsksForNone() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-wiring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grants = ManualBackgroundExecutionGranting()
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: {},
            sourceDatabaseURL: database.databaseURL,
            offlineChaptersRoot: root,
            networkPath: ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied)),
            backgroundGranting: grants
        )
        #expect(await bootstrap.prepare())
        #expect(bootstrap.state == .ready)
        #expect(bootstrap.offlineChapterStore != nil)

        bootstrap.setCompletionForeground(false)
        #expect(grants.grantsBegun == 0)
        bootstrap.setCompletionForeground(false)
        #expect(grants.grantsBegun == 0)

        // Returning to the foreground restarts the worker without asking for time.
        bootstrap.setCompletionForeground(true)
        #expect(grants.grantsBegun == 0)
        #expect(bootstrap.state == .ready)
    }
}
