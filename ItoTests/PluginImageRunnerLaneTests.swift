import Combine
import Foundation
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class PluginImageRunnerLaneTests: XCTestCase {
    func testConcurrentImageWaitersShareOnePendingLoad() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let loader = ControllableRunnerLoader()
        let manager = makeManager(loader: loader, database: database)
        let plugin = installedPlugin()
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])

        let task1 = Task { try await manager.getImageRunner(for: plugin.id) }
        let task2 = Task { try await manager.getImageRunner(for: plugin.id) }

        let call = await loader.nextCall()
        XCTAssertEqual(loader.callCount, 1)

        let expectedRunner = ItoRunner()
        call.continuation.resume(returning: expectedRunner)

        let runner1 = try await task1.value
        let runner2 = try await task2.value

        XCTAssertTrue(runner1 === expectedRunner)
        XCTAssertTrue(runner2 === expectedRunner)
        XCTAssertEqual(loader.callCount, 1)

        let cached = try await manager.getImageRunner(for: plugin.id)
        XCTAssertTrue(cached === expectedRunner)
        XCTAssertEqual(loader.callCount, 1)
    }

    func testCancellingOneWaiterDoesNotPoisonOthers() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let loader = ControllableRunnerLoader()
        let manager = makeManager(loader: loader, database: database)
        let plugin = installedPlugin()
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])

        let task1 = Task { try await manager.getImageRunner(for: plugin.id) }
        let task2 = Task { try await manager.getImageRunner(for: plugin.id) }

        let call = await loader.nextCall()
        XCTAssertEqual(loader.callCount, 1)

        task1.cancel()

        let expectedRunner = ItoRunner()
        call.continuation.resume(returning: expectedRunner)

        do {
            _ = try await task1.value
            XCTFail("Cancelled waiter must throw CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let runner2 = try await task2.value
        XCTAssertTrue(runner2 === expectedRunner)

        let cached = try await manager.getImageRunner(for: plugin.id)
        XCTAssertTrue(cached === expectedRunner)
        XCTAssertEqual(loader.callCount, 1)
    }

    func testExplicitEvictionWhileSuspendedDiscardsOldResult() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let loader = ControllableRunnerLoader()
        let manager = makeManager(loader: loader, database: database)
        let plugin = installedPlugin()
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])

        let task1 = Task { try await manager.getImageRunner(for: plugin.id) }
        let call1 = await loader.nextCall()
        XCTAssertEqual(loader.callCount, 1)

        manager.evictRunner(for: plugin.id)

        let staleRunner = ItoRunner()
        call1.continuation.resume(returning: staleRunner)

        do {
            _ = try await task1.value
            XCTFail("Task awaiting evicted load must fail")
        } catch {
            XCTAssertTrue(error is PluginRunnerAuthorityError || error is CancellationError)
        }

        let task2 = Task { try await manager.getImageRunner(for: plugin.id) }
        let call2 = await loader.nextCall()
        XCTAssertEqual(loader.callCount, 2)

        let freshRunner = ItoRunner()
        call2.continuation.resume(returning: freshRunner)

        let result2 = try await task2.value
        XCTAssertTrue(result2 === freshRunner)
        XCTAssertFalse(result2 === staleRunner)
    }

    func testFailedOldLoadCannotClearReplacementPendingLoadOrCache() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let loader = ControllableRunnerLoader()
        let manager = makeManager(loader: loader, database: database)
        let plugin = installedPlugin()
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])

        let task1 = Task { try await manager.getImageRunner(for: plugin.id) }
        let call1 = await loader.nextCall()

        manager.evictRunner(for: plugin.id)

        let task2 = Task { try await manager.getImageRunner(for: plugin.id) }
        let call2 = await loader.nextCall()
        XCTAssertEqual(loader.callCount, 2)

        struct SimulatedLoaderFailure: Error, Equatable {}
        call1.continuation.resume(throwing: SimulatedLoaderFailure())

        do {
            _ = try await task1.value
            XCTFail("Old task must fail")
        } catch {
            XCTAssertTrue(error is SimulatedLoaderFailure || error is PluginRunnerAuthorityError)
        }

        let replacementRunner = ItoRunner()
        call2.continuation.resume(returning: replacementRunner)

        let result2 = try await task2.value
        XCTAssertTrue(result2 === replacementRunner)

        let cached = try await manager.getImageRunner(for: plugin.id)
        XCTAssertTrue(cached === replacementRunner)
        XCTAssertEqual(loader.callCount, 2)
    }

    func testStaleLoadSuccessAfterReplacementCannotOverwriteCache() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let loader = ControllableRunnerLoader()
        let manager = makeManager(loader: loader, database: database)
        let plugin = installedPlugin()
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])

        let task1 = Task { try await manager.getImageRunner(for: plugin.id) }
        let call1 = await loader.nextCall()

        manager.evictRunner(for: plugin.id)

        let task2 = Task { try await manager.getImageRunner(for: plugin.id) }
        let call2 = await loader.nextCall()
        XCTAssertEqual(loader.callCount, 2)

        let staleRunner = ItoRunner()
        call1.continuation.resume(returning: staleRunner)

        do {
            _ = try await task1.value
            XCTFail("Old task must not succeed")
        } catch {
            // Expected authority/cancellation error
        }

        let replacementRunner = ItoRunner()
        call2.continuation.resume(returning: replacementRunner)

        let result2 = try await task2.value
        XCTAssertTrue(result2 === replacementRunner)

        let cached = try await manager.getImageRunner(for: plugin.id)
        XCTAssertTrue(cached === replacementRunner)
        XCTAssertFalse(cached === staleRunner)
        XCTAssertEqual(loader.callCount, 2)
    }

    func testPublicationReplaceAndRemoveInvalidatesPendingAndWarmImageCache() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let loader = ControllableRunnerLoader()
        let manager = makeManager(loader: loader, database: database)
        let v1 = installedPlugin(version: "1.0.0")
        let v2 = installedPlugin(version: "2.0.0")
        manager.publishPreparedInstalledPlugins([v1.id: v1])

        let warmTask = Task { try await manager.getImageRunner(for: v1.id) }
        let call1 = await loader.nextCall()
        let v1Runner = ItoRunner()
        call1.continuation.resume(returning: v1Runner)
        let warmResult = try await warmTask.value
        XCTAssertTrue(warmResult === v1Runner)
        XCTAssertEqual(loader.callCount, 1)

        manager.evictRunner(for: v1.id)
        let pendingTask = Task { try await manager.getImageRunner(for: v1.id) }
        let call2 = await loader.nextCall()
        XCTAssertEqual(loader.callCount, 2)

        manager.publishPreparedInstalledPlugins([v2.id: v2])

        let lateV1Runner = ItoRunner()
        call2.continuation.resume(returning: lateV1Runner)

        do {
            _ = try await pendingTask.value
            XCTFail("Replaced publication must invalidate in-flight pending load")
        } catch {
            // Expected authority error
        }

        let v2Task = Task { try await manager.getImageRunner(for: v2.id) }
        let call3 = await loader.nextCall()
        XCTAssertEqual(loader.callCount, 3)
        let v2Runner = ItoRunner()
        call3.continuation.resume(returning: v2Runner)
        let v2Result = try await v2Task.value
        XCTAssertTrue(v2Result === v2Runner)
        XCTAssertFalse(v2Result === v1Runner)
        XCTAssertFalse(v2Result === lateV1Runner)

        manager.publishPreparedInstalledPlugins([:])

        do {
            _ = try await manager.getImageRunner(for: v2.id)
            XCTFail("Removed plugin must throw fileDoesNotExist")
        } catch let urlError as URLError {
            XCTAssertEqual(urlError.code, .fileDoesNotExist)
        }
        XCTAssertEqual(loader.callCount, 3)
    }

    func testFullEvictForcesReloadOfBothForegroundAndImageCaches() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let loader = ControllableRunnerLoader()
        let manager = makeManager(loader: loader, database: database)
        let plugin = installedPlugin()
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])

        let fgTask1 = Task { try await manager.getRunner(for: plugin.id) }
        let fgRunner1 = ItoRunner()
        await loader.respondNext(with: fgRunner1)
        let loadedFG1 = try await fgTask1.value
        XCTAssertTrue(loadedFG1 === fgRunner1)

        let imgTask1 = Task { try await manager.getImageRunner(for: plugin.id) }
        let imgRunner1 = ItoRunner()
        await loader.respondNext(with: imgRunner1)
        let loadedImg1 = try await imgTask1.value
        XCTAssertTrue(loadedImg1 === imgRunner1)

        XCTAssertFalse(loadedFG1 === loadedImg1)
        XCTAssertEqual(loader.callCount, 2)

        let cachedFG = try await manager.getRunner(for: plugin.id)
        let cachedImg = try await manager.getImageRunner(for: plugin.id)
        XCTAssertTrue(cachedFG === fgRunner1)
        XCTAssertTrue(cachedImg === imgRunner1)
        XCTAssertEqual(loader.callCount, 2)

        manager.evictRunner(for: plugin.id)

        let fgTask2 = Task { try await manager.getRunner(for: plugin.id) }
        let fgRunner2 = ItoRunner()
        await loader.respondNext(with: fgRunner2)
        let loadedFG2 = try await fgTask2.value
        XCTAssertTrue(loadedFG2 === fgRunner2)
        XCTAssertFalse(loadedFG2 === fgRunner1)
        XCTAssertEqual(loader.callCount, 3)

        let imgTask2 = Task { try await manager.getImageRunner(for: plugin.id) }
        let imgRunner2 = ItoRunner()
        await loader.respondNext(with: imgRunner2)
        let loadedImg2 = try await imgTask2.value
        XCTAssertTrue(loadedImg2 === imgRunner2)
        XCTAssertFalse(loadedImg2 === imgRunner1)
        XCTAssertEqual(loader.callCount, 4)
    }

    func testLateImageCrashMatchingOldInstanceCannotEvictNewerImageOrForeground() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let loader = ControllableRunnerLoader()
        let manager = makeManager(loader: loader, database: database)
        let plugin = installedPlugin()
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])

        let fgTask = Task { try await manager.getRunner(for: plugin.id) }
        let fgRunner = ItoRunner()
        await loader.respondNext(with: fgRunner)
        let fgLoaded = try await fgTask.value
        XCTAssertTrue(fgLoaded === fgRunner)

        let oldImgTask = Task { try await manager.getImageRunner(for: plugin.id) }
        let oldImgRunner = ItoRunner()
        await loader.respondNext(with: oldImgRunner)
        let oldImgLoaded = try await oldImgTask.value
        XCTAssertTrue(oldImgLoaded === oldImgRunner)
        XCTAssertEqual(loader.callCount, 2)

        manager.evictImageRunner(for: plugin.id, matching: oldImgRunner)
        let newImgTask = Task { try await manager.getImageRunner(for: plugin.id) }
        let newImgRunner = ItoRunner()
        await loader.respondNext(with: newImgRunner)
        let newImgLoaded = try await newImgTask.value
        XCTAssertTrue(newImgLoaded === newImgRunner)
        XCTAssertFalse(newImgLoaded === oldImgRunner)
        XCTAssertEqual(loader.callCount, 3)

        // A late crash callback matching oldImgRunner must not evict newImgRunner or foreground runner
        manager.evictImageRunner(for: plugin.id, matching: oldImgRunner)

        let cachedImg = try await manager.getImageRunner(for: plugin.id)
        XCTAssertTrue(cachedImg === newImgRunner)
        XCTAssertEqual(loader.callCount, 3)

        let cachedFG = try await manager.getRunner(for: plugin.id)
        XCTAssertTrue(cachedFG === fgRunner)
        XCTAssertEqual(loader.callCount, 3)

        // Evicting matching newImgRunner evicts the image cache, leaving foreground intact
        manager.evictImageRunner(for: plugin.id, matching: newImgRunner)

        let reloadedImgTask = Task { try await manager.getImageRunner(for: plugin.id) }
        let thirdImgRunner = ItoRunner()
        await loader.respondNext(with: thirdImgRunner)
        let reloadedImg = try await reloadedImgTask.value
        XCTAssertTrue(reloadedImg === thirdImgRunner)
        XCTAssertEqual(loader.callCount, 4)

        let stillCachedFG = try await manager.getRunner(for: plugin.id)
        XCTAssertTrue(stillCachedFG === fgRunner)
        XCTAssertEqual(loader.callCount, 4)
    }

    private func installedPlugin(
        id: String = "plugin.test",
        version: String = "1.0.0",
        url: URL = URL(fileURLWithPath: "/test/plugin.test.ito")
    ) -> InstalledPlugin {
        InstalledPlugin(
            url: url,
            info: PluginInfo(
                id: id,
                name: "Test Plugin",
                version: version,
                minAppVersion: "1.0",
                type: .manga
            ),
            iconData: nil
        )
    }

    private func makeManager(
        loader: ControllableRunnerLoader,
        database: TestDatabase
    ) -> PluginManager {
        PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: loader.load
        )
    }
}

@MainActor
private final class ControllableRunnerLoader {
    struct SuspendedCall {
        let pluginID: String
        let url: URL
        let continuation: CheckedContinuation<ItoRunner, Error>
    }

    private var waiters: [CheckedContinuation<SuspendedCall, Never>] = []
    private var queuedCalls: [SuspendedCall] = []
    private(set) var callCount: Int = 0

    func nextCall() async -> SuspendedCall {
        if !queuedCalls.isEmpty {
            return queuedCalls.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func respondNext(with runner: ItoRunner) async {
        let call = await nextCall()
        call.continuation.resume(returning: runner)
    }

    func failNext(with error: Error) async {
        let call = await nextCall()
        call.continuation.resume(throwing: error)
    }

    func load(
        pluginID: String,
        pluginURL: URL,
        settingsStore: PluginSettingsStore
    ) async throws -> ItoRunner {
        _ = settingsStore
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            let call = SuspendedCall(
                pluginID: pluginID,
                url: pluginURL,
                continuation: continuation
            )
            if !self.waiters.isEmpty {
                let waiter = self.waiters.removeFirst()
                waiter.resume(returning: call)
            } else {
                self.queuedCalls.append(call)
            }
        }
    }

    deinit {
        for call in queuedCalls {
            call.continuation.resume(throwing: CancellationError())
        }
    }
}
