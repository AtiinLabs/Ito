import CryptoKit
import Foundation
import GRDB
import Testing
import ZIPFoundation
import ito_runner
@testable import Ito

@MainActor
struct RepositoryAndAliasStoreTests {
    @Test func repositoryAndAliasRoundTripWithoutDefaults() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let index = RepoIndex(
            repoName: "Offline",
            repoUrl: "https://example.com/repo",
            description: "Cached metadata",
            packages: []
        )
        let payload = try JSONEncoder().encode(index)
        let repositories = RepoManager(dbPool: database.dbPool) { _ in payload }

        try await repositories.addRepository(url: "https://example.com/repo/index.json")
        #expect(repositories.repositories.single?.url == "https://example.com/repo")
        #expect(repositories.repositories.single?.index == index)

        let reloadedRepositories = RepoManager(dbPool: database.dbPool)
        try await reloadedRepositories.reload()
        #expect(reloadedRepositories.repositories.single?.index == index)

        let resolver = PluginResolver(
            dbPool: database.dbPool,
            repoManager: reloadedRepositories,
            installedPluginIds: { ["plugin.target"] }
        )
        try await resolver.saveUserAlias(
            foreignId: "source.foreign-v2",
            itoPluginId: "plugin.target"
        )
        let reloadedResolver = PluginResolver(
            dbPool: database.dbPool,
            repoManager: reloadedRepositories,
            installedPluginIds: { ["plugin.target"] }
        )
        try await reloadedResolver.reload()
        #expect(reloadedResolver.resolveId(foreignId: "source.foreign-v3") == "plugin.target")
    }

    @Test func repositoryFailureDoesNotPublishOrPersistPartialState() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let index = RepoIndex(
            repoName: "Fixture",
            repoUrl: "https://example.com",
            description: "",
            packages: []
        )
        let payload = try JSONEncoder().encode(index)
        let manager = RepoManager(dbPool: database.dbPool) { _ in payload }
        try await manager.addRepository(url: "https://example.com/first")
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_repository_insert
                BEFORE INSERT ON repository
                BEGIN
                    SELECT RAISE(ABORT, 'injected repository failure');
                END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await manager.addRepository(url: "https://example.com/second")
        }

        #expect(manager.repositories.map(\.url) == ["https://example.com/first"])
        try await database.dbPool.read { db in
            let records = try RepositoryRecord.fetchAll(db)
            #expect(records.map(\.url) == ["https://example.com/first"])
        }
    }

    @Test func aStoredIndexThatCantBeReadDoesNotHideTheOtherRepositories() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let index = RepoIndex(repoName: "Good", repoUrl: "https://good.example", description: "", packages: [])
        try await database.dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO repository (url, indexPayload) VALUES (?, ?)",
                arguments: ["https://bad.example", Data("not-json".utf8)]
            )
            try db.execute(
                sql: "INSERT INTO repository (url, indexPayload) VALUES (?, ?)",
                arguments: ["https://good.example", try JSONEncoder().encode(index)]
            )
        }
        let manager = RepoManager(dbPool: database.dbPool)

        try await manager.reload()

        #expect(manager.repositories.map(\.url) == ["https://bad.example", "https://good.example"])
        #expect(manager.repositories.map(\.index) == [nil, index])
    }

    @Test func repositoryRefreshUsesCanonicalFetcherPersistenceAndPublicationPath() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let originalIndex = RepoIndex(
            repoName: "Original",
            repoUrl: "https://example.com/repo",
            description: "Before refresh",
            packages: []
        )
        let originalPayload = try JSONEncoder().encode(originalIndex)
        let initialManager = RepoManager(dbPool: database.dbPool) { _ in originalPayload }
        try await initialManager.addRepository(url: "https://example.com/repo")

        let refreshedIndex = RepoIndex(
            repoName: "Refreshed",
            repoUrl: "https://example.com/repo",
            description: "After refresh",
            packages: []
        )
        let refreshedPayload = try JSONEncoder().encode(refreshedIndex)
        let refreshingManager = RepoManager(dbPool: database.dbPool) { _ in refreshedPayload }
        try await refreshingManager.reload()

        try await refreshingManager.refreshAllReportingFailures()

        #expect(refreshingManager.repositories.single?.index == refreshedIndex)
        let reloadedManager = RepoManager(dbPool: database.dbPool)
        try await reloadedManager.reload()
        #expect(reloadedManager.repositories.single?.index == refreshedIndex)
    }

    @Test func reportingRefreshFailurePreservesLastDurableRepositorySnapshot() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let index = RepoIndex(
            repoName: "Durable",
            repoUrl: "https://example.com/repo",
            description: "Committed",
            packages: []
        )
        let payload = try JSONEncoder().encode(index)
        let initialManager = RepoManager(dbPool: database.dbPool) { _ in payload }
        try await initialManager.addRepository(url: "https://example.com/repo")

        let failingManager = RepoManager(dbPool: database.dbPool) { _ in
            throw URLError(.notConnectedToInternet)
        }
        try await failingManager.reload()

        await #expect(throws: RepositoryRefreshFailure.self) {
            try await failingManager.refreshAllReportingFailures()
        }

        #expect(failingManager.repositories.single?.index == index)
        let reloadedManager = RepoManager(dbPool: database.dbPool)
        try await reloadedManager.reload()
        #expect(reloadedManager.repositories.single?.index == index)
    }

    @Test func concurrentEquivalentAddsSerializeAtAuthoritativeManagerBoundary() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let index = RepoIndex(
            repoName: "Serialized",
            repoUrl: "https://example.com/repo",
            description: "One durable record",
            packages: []
        )
        let fetchGate = RepositoryIndexFetchGate(payload: try JSONEncoder().encode(index))
        let manager = RepoManager(dbPool: database.dbPool) { _ in
            await fetchGate.fetch()
        }

        let first = Task {
            try await manager.addRepository(url: "https://example.com/repo/")
        }
        await waitUntil { await fetchGate.callCount == 1 }
        let second = Task {
            try await manager.addRepository(url: "https://example.com/repo/index.json")
        }
        await Task.yield()

        #expect(await fetchGate.callCount == 1)
        await fetchGate.resume()
        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(firstResult == .added)
        #expect(secondResult == .alreadyPresent)
        #expect(manager.repositories.map(\.url) == ["https://example.com/repo"])
        try await database.dbPool.read { db in
            let count = try RepositoryRecord.fetchCount(db)
            #expect(count == 1)
        }
    }

    @Test func removeWaitsForRefreshSoStaleIndexCannotResurrectDurableRepository() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let originalIndex = RepoIndex(
            repoName: "Original",
            repoUrl: "https://example.com/repo",
            description: "Before refresh",
            packages: []
        )
        let initialPayload = try JSONEncoder().encode(originalIndex)
        let initialManager = RepoManager(dbPool: database.dbPool) { _ in initialPayload }
        try await initialManager.addRepository(url: "https://example.com/repo")

        let refreshedIndex = RepoIndex(
            repoName: "Refreshed",
            repoUrl: "https://example.com/repo",
            description: "Fetched before removal",
            packages: []
        )
        let fetchGate = RepositoryIndexFetchGate(
            payload: try JSONEncoder().encode(refreshedIndex)
        )
        let manager = RepoManager(dbPool: database.dbPool) { _ in
            await fetchGate.fetch()
        }
        try await manager.reload()

        let refresh = Task { try await manager.refreshAllReportingFailures() }
        await waitUntil { await fetchGate.callCount == 1 }
        let removal = Task {
            try await manager.removeRepository(url: "https://example.com/repo")
        }
        await Task.yield()

        #expect(manager.repositories.count == 1)
        await fetchGate.resume()
        try await refresh.value
        try await removal.value

        #expect(manager.repositories.isEmpty)
        try await database.dbPool.read { db in
            let count = try RepositoryRecord.fetchCount(db)
            #expect(count == 0)
        }
    }

    @Test func distinctSameIDInstallRunsAfterPredecessorFailureAndUsesDigestIdentity() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryInstallQueue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }
        let successfulData = Data("second package".utf8)
        let fetchGate = RepositoryPackageFetchGate(successfulData: successfulData)
        let manager = RepoManager(
            dbPool: database.dbPool,
            pluginsDirectory: pluginsDirectory,
            packageFetcher: { request in try await fetchGate.fetch(request) }
        )
        let failedRequest = makePackage(
            id: "plugin.queue",
            version: "1.0",
            sha256: String(repeating: "0", count: 64)
        )
        let succeedingRequest = makePackage(
            id: "plugin.queue",
            version: "1.0",
            sha256: sha256(successfulData)
        )

        let first = Task {
            try await manager.installPackage(failedRequest, repositoryUrl: "https://example.com")
        }
        await waitUntil { await fetchGate.callCount == 1 }
        let second = Task {
            try await manager.installPackage(succeedingRequest, repositoryUrl: "https://example.com")
        }
        await Task.yield()

        #expect(await fetchGate.callCount == 1)
        await fetchGate.failFirstRequest()
        await #expect(throws: RepositoryPackageFetchFailure.self) {
            try await first.value
        }
        try await second.value

        #expect(await fetchGate.callCount == 2)
        let installedData = try Data(
            contentsOf: pluginsDirectory.appendingPathComponent("plugin.queue.ito")
        )
        #expect(installedData == successfulData)
    }

    @Test func invalidPackageIdentifierCannotEscapePluginsDirectoryOrFetchNetwork() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryInstallTraversal-\(UUID().uuidString)")
        let pluginsDirectory = root.appendingPathComponent("Plugins")
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = RepositoryPackageFetchRecorder(data: Data())
        let manager = RepoManager(
            dbPool: database.dbPool,
            pluginsDirectory: pluginsDirectory,
            packageFetcher: { request in await fetcher.fetch(request) }
        )
        let package = makePackage(
            id: "../payload",
            sha256: String(repeating: "0", count: 64)
        )

        await #expect(throws: RepositoryPackageInstallationError.self) {
            try await manager.installPackage(package, repositoryUrl: "https://example.com")
        }

        #expect(await fetcher.callCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("payload.ito").path))
    }

    @Test func installUsesPluginManagersConfiguredDirectoryAndPublishesAuthoritativeState() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryInstallPublication-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }
        let packageID = "plugin.authoritative"
        let archiveData = try makeTestPluginArchiveData(id: packageID, version: "2.0")
        let pluginManager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: pluginsDirectory
        )
        let manager = RepoManager(
            dbPool: database.dbPool,
            pluginManager: pluginManager,
            pluginsDirectory: nil,
            packageFetcher: { _ in archiveData }
        )
        let package = makePackage(id: packageID, version: "2.0", sha256: sha256(archiveData))

        try await manager.installPackage(package, repositoryUrl: "https://example.com")

        #expect(
            FileManager.default.fileExists(
                atPath: pluginsDirectory.appendingPathComponent("\(packageID).ito").path
            )
        )
        #expect(pluginManager.installedPlugins[packageID]?.info.version == "2.0")
    }

    @Test func publicationFailureRollsBackNewPackageFile() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryInstallRollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }
        let invalidArchiveData = Data("not an Ito archive".utf8)
        let pluginManager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool),
            pluginsDirectory: pluginsDirectory
        )
        let manager = RepoManager(
            dbPool: database.dbPool,
            pluginManager: pluginManager,
            pluginsDirectory: nil,
            packageFetcher: { _ in invalidArchiveData }
        )
        let package = makePackage(
            id: "plugin.rollback",
            sha256: sha256(invalidArchiveData)
        )

        await #expect(throws: (any Error).self) {
            try await manager.installPackage(package, repositoryUrl: "https://example.com")
        }

        #expect(
            !FileManager.default.fileExists(
                atPath: pluginsDirectory.appendingPathComponent("plugin.rollback.ito").path
            )
        )
        #expect(pluginManager.installedPlugins.isEmpty)
    }

    @Test func removedPackageVersionInstallsTheVersionTheRefreshedIndexLists() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryInstallRemovedVersion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }
        let currentData = Data("current package".utf8)
        let stale = makePackage(
            id: "plugin.moved",
            version: "1.0",
            sha256: String(repeating: "0", count: 64),
            downloadUrl: "packages/plugin.moved-v1.0.ito"
        )
        let current = makePackage(
            id: "plugin.moved",
            version: "1.1",
            sha256: sha256(currentData),
            downloadUrl: "packages/plugin.moved-v1.1.ito"
        )
        let indexes = RepositoryIndexSequence(payloads: [
            try JSONEncoder().encode(makeIndex(packages: [stale])),
            try JSONEncoder().encode(makeIndex(packages: [current]))
        ])
        let manager = RepoManager(
            dbPool: database.dbPool,
            pluginsDirectory: pluginsDirectory,
            packageFetcher: { request in
                guard request.url?.lastPathComponent == "plugin.moved-v1.1.ito" else {
                    throw RepositoryPackageInstallationError.packageUnavailable
                }
                return currentData
            },
            indexFetcher: { _ in await indexes.next() }
        )
        try await manager.addRepository(url: "https://example.com/repo")

        try await manager.installPackage(stale, repositoryUrl: "https://example.com/repo")

        let installed = try Data(contentsOf: pluginsDirectory.appendingPathComponent("plugin.moved.ito"))
        #expect(installed == currentData)
        #expect(manager.repositories.first?.index?.packages.map(\.version) == ["1.1"])
    }

    @Test func removedPackageWithoutReplacementReportsUnavailable() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let pluginsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryInstallUnavailable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pluginsDirectory) }
        let stale = makePackage(id: "plugin.gone", sha256: String(repeating: "0", count: 64))
        let payload = try JSONEncoder().encode(makeIndex(packages: [stale]))
        let manager = RepoManager(
            dbPool: database.dbPool,
            pluginsDirectory: pluginsDirectory,
            packageFetcher: { _ in throw RepositoryPackageInstallationError.packageUnavailable },
            indexFetcher: { _ in payload }
        )
        try await manager.addRepository(url: "https://example.com/repo")

        await #expect(throws: RepositoryPackageInstallationError.packageUnavailable) {
            try await manager.installPackage(stale, repositoryUrl: "https://example.com/repo")
        }
        #expect(!FileManager.default.fileExists(atPath: pluginsDirectory.appendingPathComponent("plugin.gone.ito").path))
    }

    @Test func aliasFailureKeepsPriorCommittedAliasPublished() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let repositories = RepoManager(dbPool: database.dbPool)
        let resolver = PluginResolver(
            dbPool: database.dbPool,
            repoManager: repositories,
            installedPluginIds: { ["old.plugin", "new.plugin"] }
        )
        try await resolver.saveUserAlias(foreignId: "foreign", itoPluginId: "old.plugin")
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_alias_update
                BEFORE UPDATE ON pluginMigrationAlias
                BEGIN
                    SELECT RAISE(ABORT, 'injected alias failure');
                END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await resolver.saveUserAlias(
                foreignId: "foreign",
                itoPluginId: "new.plugin"
            )
        }

        #expect(resolver.resolveId(foreignId: "foreign") == "old.plugin")
        try await database.dbPool.read { db in
            let record = try PluginMigrationAliasRecord.fetchOne(db, key: "foreign")
            #expect(record?.pluginId == "old.plugin")
        }
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func makePackage(
        id: String,
        version: String = "1.0",
        sha256: String,
        downloadUrl: String = "package.ito"
    ) -> RepoPackage {
        RepoPackage(
            id: id,
            name: id,
            version: version,
            minAppVersion: "1.0",
            downloadUrl: downloadUrl,
            iconUrl: nil,
            sha256: sha256,
            pluginType: "manga",
            archived: nil,
            archivedReason: nil,
            archivedDate: nil
        )
    }

    private func makeIndex(packages: [RepoPackage]) -> RepoIndex {
        RepoIndex(
            repoName: "Fixture",
            repoUrl: "https://example.com/repo",
            description: "",
            packages: packages
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum RepositoryPackageFetchFailure: Error {
    case failed
}

private actor RepositoryPackageFetchGate {
    let successfulData: Data
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(successfulData: Data) {
        self.successfulData = successfulData
    }

    func fetch(_ request: URLRequest) async throws -> Data {
        _ = request
        callCount += 1
        if callCount == 1 {
            await withCheckedContinuation { continuation = $0 }
            throw RepositoryPackageFetchFailure.failed
        }
        return successfulData
    }

    func failFirstRequest() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RepositoryPackageFetchRecorder {
    let data: Data
    private(set) var callCount = 0

    init(data: Data) {
        self.data = data
    }

    func fetch(_ request: URLRequest) -> Data {
        _ = request
        callCount += 1
        return data
    }
}

private actor RepositoryIndexFetchGate {
    let payload: Data
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(payload: Data) {
        self.payload = payload
    }

    func fetch() async -> Data {
        callCount += 1
        await withCheckedContinuation { continuation = $0 }
        return payload
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

/// Serves each payload once in order, then repeats the last one.
private actor RepositoryIndexSequence {
    private var payloads: [Data]

    init(payloads: [Data]) {
        self.payloads = payloads
    }

    func next() -> Data {
        payloads.count > 1 ? payloads.removeFirst() : payloads[0]
    }
}

private extension Collection {
    var single: Element? {
        count == 1 ? first : nil
    }
}
