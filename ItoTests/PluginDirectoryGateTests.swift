import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// Holds a scan at a known point, so a test can start other directory operations while the scan holds the gate.
/// `hold()` runs in the package reader after a file is read and waits there until `release()`. `waitUntilHeld()`
/// returns once a scan is held. Both throw `CancellationError` when their task is cancelled, so a test that ends
/// by its time limit never leaves a continuation behind.
actor ScanHold {
    private var isArmed = false
    private var isHeld = false
    private var isReleased = false
    private var heldWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var releaseWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func arm() {
        isArmed = true
    }

    func hold() async throws {
        guard isArmed else { return }
        isHeld = true
        let waiters = heldWaiters
        heldWaiters = [:]
        for waiter in waiters.values {
            waiter.resume()
        }
        if isReleased {
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                releaseWaiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelReleaseWaiter(id) }
        }
    }

    func waitUntilHeld() async throws {
        if isHeld {
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                heldWaiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelHeldWaiter(id) }
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters = [:]
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    private func cancelHeldWaiter(_ id: UUID) {
        heldWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func cancelReleaseWaiter(_ id: UUID) {
        releaseWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

/// What the deletion did while a scan held the gate: it queued behind the gate, or it finished without waiting.
/// `awaitOutcome()` returns the first of the two and throws when its task is cancelled.
actor DeletionProgress {
    enum Outcome: Equatable, Sendable {
        case queuedBehindScan
        case finishedWithoutWaiting
    }

    private var recorded: Outcome?
    private var waiters: [UUID: CheckedContinuation<Outcome, Error>] = [:]

    func record(_ outcome: Outcome) {
        guard recorded == nil else { return }
        recorded = outcome
        let pending = waiters
        waiters = [:]
        for waiter in pending.values {
            waiter.resume(returning: outcome)
        }
    }

    func awaitOutcome() async throws -> Outcome {
        if let recorded {
            return recorded
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

@MainActor
struct PluginDirectoryGateTests {
    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func anOperationHoldingTheGateCannotAcquireItAgain() async throws {
        let gate = PluginDirectoryGate()

        await #expect(throws: PluginDirectoryGateError.reentrantAcquire) {
            try await gate.withLease { _ in
                try await gate.withLease { _ in }
            }
        }
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aTaskSpawnedInsideALeaseCanAcquireTheGateAfterTheLeaseEnds() async throws {
        let gate = PluginDirectoryGate()
        // The task inherits the lease's ID. The lease ends before the task runs, so the task's request is not made
        // inside the operation that holds the gate and must succeed.
        let spawned = try await gate.withLease { _ in
            Task { try await gate.withLease { _ in "acquired" } }
        }
        #expect(try await spawned.value == "acquired")
    }

    @Test(arguments: [true, false])
    func aPluginFileRemovedAfterListingIsAbsentNotInvalid(strict: Bool) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VanishedPlugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try makeTestPluginArchiveData(id: "kept", version: "1.0").write(to: directory.appendingPathComponent("kept.ito"))
        try makeTestPluginArchiveData(id: "gone", version: "1.0").write(to: directory.appendingPathComponent("gone.ito"))
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter()),
            pluginsDirectory: directory,
            packageReader: { url in
                // Another party removes the file after the scan has listed it and before it is read.
                if url.lastPathComponent == "gone.ito" {
                    try FileManager.default.removeItem(at: url)
                }
                return try await PluginPackageReading.readInBackground(at: url)
            }
        )

        if strict {
            try await manager.discoverAndPrepareInstalledPlugins()
        } else {
            await manager.reloadInstalledPlugins()
        }

        #expect(Set(manager.installedPlugins.keys) == ["kept"])
    }

    @Test func aRestoreScanPublishesInstalledPluginsWithoutRegisteringTheirIdentities() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreScan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try makeTestPluginArchiveData(id: "restored", version: "1.0")
            .write(to: directory.appendingPathComponent("restored.ito"))
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter()),
            pluginsDirectory: directory
        )

        try await manager.reloadAfterRestore()

        #expect(manager.installedPlugins["restored"]?.info.version == "1.0")
        let registered = try await database.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT pluginId FROM pluginIdentityRegistry")
        }
        #expect(registered.isEmpty)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aDeletionThatOverlapsAScanQueuesBehindItAndNeverPublishesOrTrustsTheDeletedPlugin() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeletionAndScan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pluginURL = directory.appendingPathComponent("archived.ito")
        try makeTestPluginArchiveData(id: "archived", version: "1.0", archived: true).write(to: pluginURL)
        let hold = ScanHold()
        let progress = DeletionProgress()
        let store = PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter())
        let manager = PluginManager(
            pluginSettingsStore: store,
            pluginsDirectory: directory,
            directoryGate: PluginDirectoryGate(onWaiting: {
                Task { await progress.record(.queuedBehindScan) }
            }),
            packageReader: { url in
                let reading = try await PluginPackageReading.readInBackground(at: url)
                try await hold.hold()
                return reading
            }
        )
        // Published, so the deletion has a plugin to remove.
        await manager.reloadInstalledPlugins()
        let plugin = try #require(manager.installedPlugins["archived"])
        let viewModel = SourceViewModel(
            plugin: plugin,
            runnerProvider: PR7BSourceRunnerProviderSpy(),
            pluginStatePublisher: manager,
            fileDeletion: LocalBrowsePluginFileOperations(fileManager: .default, pluginsDirectory: directory),
            messagePresenter: PR7BMessagePresenterSpy(),
            searchDebounceNanoseconds: nil
        )
        viewModel.requestArchivedPluginDeletion()

        // A scan reads the plugin and then holds the gate. The deletion is requested while it holds the gate. The
        // deletion can only remove the file, revoke trust and publish once it has the gate, so it either queues
        // behind the scan or, if it runs alongside it, finishes first. Both outcomes are observed; nothing waits on
        // a timer.
        await hold.arm()
        let scan = Task { await manager.reloadInstalledPlugins() }
        var deletion: Task<Void, Never>?
        let outcome: DeletionProgress.Outcome
        do {
            try await hold.waitUntilHeld()
            deletion = Task {
                await viewModel.confirmArchivedPluginDeletion()
                await progress.record(.finishedWithoutWaiting)
            }
            outcome = try await progress.awaitOutcome()
        } catch {
            deletion?.cancel()
            scan.cancel()
            await scan.value
            throw error
        }
        await hold.release()
        await scan.value
        await deletion?.value

        #expect(outcome == .queuedBehindScan, "The deletion must wait for the scan that holds the gate.")
        #expect(viewModel.shouldDismiss)
        #expect(manager.installedPlugins["archived"] == nil)
        #expect(!FileManager.default.fileExists(atPath: pluginURL.path))
        // A blocked plugin records no pending trust request. A scan that published after the revoke would have
        // reactivated trust for the deleted plugin, and this would then record one.
        store.trust.recordPending(PendingTrust(pluginID: "archived", host: "example.com", fingerprint: "AA"))
        #expect(store.trust.pending(pluginID: "archived") == nil)
    }
}
