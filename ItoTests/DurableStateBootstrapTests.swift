import Foundation
import GRDB
import Testing
@testable import Ito

@MainActor
struct DurableStateBootstrapTests {
    @Test func migrationAndExtensionsFinishBeforeConsumerConstruction() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let events = EventRecorder()
        let bootstrapReference = BootstrapReference()
        let bootstrapExtension = RecordingBootstrapExtension {
            events.append("extension")
        }
        let constructors = DurableConsumerKind.allCases.map { kind in
            DurableConsumerConstructor(kind: kind) {
                events.append(kind.rawValue)
            }
        }
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: {
                Self.expectNoPublishedRuntime(bootstrapReference.value)
                events.append("migration")
            },
            extensions: [bootstrapExtension],
            scalarConsumerConfiguration: { _ in
                Self.expectNoPublishedRuntime(bootstrapReference.value)
                events.append("scalar configuration")
            },
            consumerConstructors: constructors,
            onReady: {
                Self.expectPublishedRuntime(bootstrapReference.value)
                events.append("ready")
            },
            sourceDatabaseURL: database.databaseURL
        )
        bootstrapReference.value = bootstrap

        #expect(events.values().isEmpty)
        Self.expectNoPublishedRuntime(bootstrap)
        #expect(await bootstrap.prepare())
        #expect(bootstrap.state == .ready)
        Self.expectPublishedRuntime(bootstrap)
        #expect(events.values() == ["migration", "extension", "scalar configuration"]
            + DurableConsumerKind.allCases.map(\.rawValue)
            + ["ready"])
    }

    @Test func foregroundAndColdBackgroundUseOneCoalescedGate() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let events = EventRecorder()
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: {
                events.append("migration")
                try await Task.sleep(nanoseconds: 20_000_000)
            },
            sourceDatabaseURL: database.databaseURL
        )

        async let foreground = runEntryPoint("foreground", bootstrap: bootstrap, events: events)
        async let background = runEntryPoint("background", bootstrap: bootstrap, events: events)
        _ = await (foreground, background)

        let values = events.values()
        #expect(values.filter { $0 == "migration" }.count == 1)
        #expect(values.first == "migration")
        #expect(Set(values.dropFirst()) == ["foreground", "background"])
    }

    @Test func theInjectedNetworkPathIsTheOneTheScreensReadOfflineStateFrom() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let path = ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied))
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: {},
            sourceDatabaseURL: database.databaseURL,
            networkPath: path
        )

        #expect(await bootstrap.prepare())

        let scope = try #require(bootstrap.appScope)
        let library = scope.dependencies.library
        let mediaDetail = scope.dependencies.mediaDetail
        let detail = try #require(mediaDetail)
        #expect(!library.connectivity.isOffline)
        #expect(!detail.connectivity.isOffline)
        path.set(NetworkPathSnapshot(status: .unsatisfied))
        #expect(library.connectivity.isOffline)
        #expect(detail.connectivity.isOffline)
    }

    @Test func failureStaysOutOfReadyAndRetryConstructsConsumersOnce() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let attempts = Counter()
        let consumers = Counter()
        let scalarConfigurations = Counter()
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: {
                if attempts.increment() == 1 { throw BootstrapFailure() }
            },
            scalarConsumerConfiguration: { _ in
                _ = scalarConfigurations.increment()
            },
            onReady: { _ = consumers.increment() },
            sourceDatabaseURL: database.databaseURL
        )

        #expect(await bootstrap.prepare() == false)
        if case .failed = bootstrap.state {
            // Expected retryable launch state.
        } else {
            Issue.record("Bootstrap should remain failed until retry")
        }
        #expect(consumers.value == 0)
        #expect(scalarConfigurations.value == 0)
        Self.expectNoPublishedRuntime(bootstrap)

        #expect(await bootstrap.retry())
        #expect(bootstrap.state == .ready)
        #expect(attempts.value == 2)
        #expect(consumers.value == 1)
        #expect(scalarConfigurations.value == 1)
        let settingsStore = try #require(bootstrap.settingsStore)
        let readProgressManager = try #require(bootstrap.readProgressManager)
        #expect(await bootstrap.prepare())
        #expect(consumers.value == 1)
        #expect(scalarConfigurations.value == 1)
        #expect(bootstrap.settingsStore === settingsStore)
        #expect(bootstrap.readProgressManager === readProgressManager)
    }

    @Test func extensionFailurePreventsReadyConsumerConstruction() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let consumers = Counter()
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: {},
            extensions: [RecordingBootstrapExtension { throw BootstrapFailure() }],
            onReady: { _ = consumers.increment() },
            sourceDatabaseURL: database.databaseURL
        )

        #expect(await bootstrap.prepare() == false)
        #expect(consumers.value == 0)
        Self.expectNoPublishedRuntime(bootstrap)
    }

    @Test func unreadableInstalledPluginMetadataFailsBootstrapReadiness() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginsDirectory = database.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pluginsDirectory,
            withIntermediateDirectories: true
        )
        let unreadablePluginURL = pluginsDirectory.appendingPathComponent("broken.ito")
        try Data().write(to: unreadablePluginURL)
        let bootstrapExtension = InstalledPluginSuiteBootstrapExtension(
            pluginsDirectory: pluginsDirectory,
            extractDiscovery: { _ in throw BootstrapFailure() }
        )
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: {},
            extensions: [bootstrapExtension],
            sourceDatabaseURL: database.databaseURL
        )

        #expect(await bootstrap.prepare() == false)
        guard case .failed(let message) = bootstrap.state else {
            Issue.record("Unreadable installed plugin metadata must fail bootstrap")
            return
        }
        #expect(message.contains("broken.ito"))
        Self.expectNoPublishedRuntime(bootstrap)
    }

    @Test func ordinaryPluginReloadSkipsCorruptFileButStrictDiscoveryThrows() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginsDirectory = database.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("Plugins", isDirectory: true)
        try makeCorruptInstalledPlugin(in: pluginsDirectory)
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter()),
            pluginsDirectory: pluginsDirectory
        )

        await manager.reloadInstalledPlugins()
        #expect(manager.installedPlugins.isEmpty)
        await #expect(throws: (any Error).self) {
            try await manager.discoverAndPrepareInstalledPlugins(failOnInvalidPlugin: true)
        }
    }

    @Test func readyRestoreJournalUsesUnpublishedJournalAccessUntilAcknowledged() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let report = try BackupRestoreReport(
            operationId: "ready-before-migration",
            mode: .merge,
            outcomes: [],
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try await insert(report, status: .readyToPresent, database: database)
        let migrations = Counter()
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: { _ = migrations.increment() },
            sourceDatabaseURL: database.databaseURL
        )

        #expect(await bootstrap.prepare() == false)
        #expect(bootstrap.state == .awaitingRestoreAcknowledgment(report))
        #expect(migrations.value == 0)
        Self.expectNoPublishedRuntime(bootstrap)

        #expect(await bootstrap.acknowledgeRestoreReport())
        #expect(bootstrap.state == .ready)
        #expect(migrations.value == 1)
        Self.expectPublishedRuntime(bootstrap)
    }

    @Test func pendingRestoreRecoveryKeepsRuntimeUnpublishedUntilAcknowledgment() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let report = try BackupRestoreReport(
            operationId: "pending-refresh",
            mode: .merge,
            outcomes: [],
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try await insert(report, status: .pendingRefresh, database: database)
        let migrations = Counter()
        let bootstrap = DurableStateBootstrap(
            dbPool: database.dbPool,
            migration: { _ = migrations.increment() },
            sourceDatabaseURL: database.databaseURL
        )

        #expect(await bootstrap.prepare() == false)
        #expect(bootstrap.state == .awaitingRestoreAcknowledgment(report))
        #expect(migrations.value == 1)
        Self.expectNoPublishedRuntime(bootstrap)

        #expect(await bootstrap.acknowledgeRestoreReport())
        #expect(bootstrap.state == .ready)
        #expect(migrations.value == 1)
        Self.expectPublishedRuntime(bootstrap)
    }

    private func runEntryPoint(
        _ name: String,
        bootstrap: DurableStateBootstrap,
        events: EventRecorder
    ) async {
        guard await bootstrap.prepare() else { return }
        events.append(name)
    }

    private static func expectNoPublishedRuntime(_ bootstrap: DurableStateBootstrap?) {
        #expect(bootstrap?.settingsStore == nil)
        #expect(bootstrap?.pluginSettingsStore == nil)
        #expect(bootstrap?.readProgressManager == nil)
        #expect(bootstrap?.trackerManager == nil)
        #expect(bootstrap?.updateManager == nil)
        #expect(bootstrap?.repoManager == nil)
        #expect(bootstrap?.pluginResolver == nil)
        #expect(bootstrap?.libraryManager == nil)
        #expect(bootstrap?.pluginManager == nil)
        #expect(bootstrap?.storageManager == nil)
        #expect(bootstrap?.discordRPCManager == nil)
        #expect(bootstrap?.historyManager == nil)
        #expect(bootstrap?.notificationManager == nil)
        #expect(bootstrap?.backupManager == nil)
        #expect(bootstrap?.librarySourceRemapper == nil)
    }

    private static func expectPublishedRuntime(_ bootstrap: DurableStateBootstrap?) {
        #expect(bootstrap?.settingsStore != nil)
        #expect(bootstrap?.pluginSettingsStore != nil)
        #expect(bootstrap?.readProgressManager != nil)
        #expect(bootstrap?.trackerManager != nil)
        #expect(bootstrap?.updateManager != nil)
        #expect(bootstrap?.repoManager != nil)
        #expect(bootstrap?.pluginResolver != nil)
        #expect(bootstrap?.libraryManager != nil)
        #expect(bootstrap?.pluginManager != nil)
        #expect(bootstrap?.storageManager != nil)
        #expect(bootstrap?.discordRPCManager != nil)
        #expect(bootstrap?.historyManager != nil)
        #expect(bootstrap?.notificationManager != nil)
        #expect(bootstrap?.backupManager != nil)
        #expect(bootstrap?.librarySourceRemapper != nil)
    }

    private func insert(
        _ report: BackupRestoreReport,
        status: RestoreOperationStatus,
        database: TestDatabase
    ) async throws {
        try await database.dbPool.write { db in
            try BackupRestoreJournalRecord(
                operationId: report.operationId,
                status: status,
                reportPayload: try JSONEncoder().encode(report),
                updatedAt: report.createdAt
            ).insert(db)
        }
    }

    private func makeCorruptInstalledPlugin(in pluginsDirectory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: pluginsDirectory,
            withIntermediateDirectories: true
        )
        let pluginURL = pluginsDirectory.appendingPathComponent(
            "corrupt-\(UUID().uuidString).ito"
        )
        try Data("not an ito plugin".utf8).write(to: pluginURL)
    }
}

private struct RecordingBootstrapExtension: DurableStateBootstrapExtension {
    let operation: @Sendable () async throws -> Void

    init(operation: @escaping @Sendable () async throws -> Void) {
        self.operation = operation
    }

    func prepare(dbPool: DatabasePool) async throws {
        try await operation()
    }
}

private struct BootstrapFailure: Error {}

@MainActor
private final class BootstrapReference {
    var value: DurableStateBootstrap?
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }

    func values() -> [String] {
        lock.withLock { storage }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }
}
