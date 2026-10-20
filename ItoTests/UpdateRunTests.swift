import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

/// Answers update checks from fixed results and records which series were checked.
@MainActor
final class FakeLibraryUpdateSource: LibraryUpdateSource {
    var installedPluginIDs: Set<String>
    var failingItemIDs: Set<String> = []
    /// Every check waits here when set, so a test can look at a run while it is in flight.
    var gate: AsyncTestGate?
    /// Runs at the start of every check, for example to move a test clock.
    var onCheck: (() -> Void)?
    private(set) var checkedItemIDs: [String] = []

    init(installedPluginIDs: Set<String>) {
        self.installedPluginIDs = installedPluginIDs
    }

    func fetchUpdate(for item: LibraryItem) async throws -> UpdateManager.SuccessfulUpdate {
        checkedItemIDs.append(item.id)
        onCheck?()
        await gate?.enter()
        if failingItemIDs.contains(item.id) {
            throw FakeUpdateError.sourceFailed
        }
        return UpdateManager.SuccessfulUpdate(freshCount: item.knownChapterCount ?? 0, status: nil)
    }
}

enum FakeUpdateError: Error {
    case sourceFailed
}

nonisolated struct FakeNetworkConditions: UpdateNetworkConditions {
    let isUnmetered: Bool

    func isOnUnmeteredNetwork() async -> Bool {
        isUnmetered
    }
}

@MainActor
final class TestClock {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }
}

@MainActor
struct UpdateRunTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aRunBeforeSettingsAreReadyDoesNotBlockLaterRuns() async throws {
        let source = FakeLibraryUpdateSource(installedPluginIDs: ["p"])
        let (database, manager, settings) = try await makeManager(
            items: [Self.item("a", plugin: "p")],
            source: source,
            clock: TestClock(start),
            configureSettings: false
        )
        defer { database.cleanup() }

        await manager.checkForUpdates()
        #expect(source.checkedItemIDs.isEmpty)
        #expect(!manager.isRefreshing)

        manager.configure(settingsStore: settings)
        await manager.checkForUpdates()
        #expect(source.checkedItemIDs == ["a"])
        #expect(!manager.isRefreshing)
    }

    @Test func seriesThatKeepFailingMoveBehindOthersInBackgroundRuns() async throws {
        let ids = (0..<12).map { String(format: "s%02d", $0) }
        let source = FakeLibraryUpdateSource(installedPluginIDs: ["p"])
        source.failingItemIDs = ["s00", "s01"]
        let clock = TestClock(start)
        let (database, manager, _) = try await makeManager(
            items: ids.map { Self.item($0, plugin: "p") },
            source: source,
            clock: clock
        )
        defer { database.cleanup() }

        _ = await manager.checkForUpdatesInBackground()
        #expect(source.checkedItemIDs == ["s00", "s01", "s02", "s03", "s04"])

        clock.date = start.addingTimeInterval(2 * 3_600)
        _ = await manager.checkForUpdatesInBackground()
        #expect(Array(source.checkedItemIDs.dropFirst(5)) == ["s05", "s06", "s07", "s08", "s09"])
    }

    @Test func seriesOfUninstalledPluginsAreNotChecked() async throws {
        let source = FakeLibraryUpdateSource(installedPluginIDs: ["installed"])
        let removed = Self.item("removed", plugin: "uninstalled")
        let (database, manager, _) = try await makeManager(
            items: [Self.item("kept", plugin: "installed"), removed],
            source: source,
            clock: TestClock(start)
        )
        defer { database.cleanup() }

        await manager.checkForUpdates()

        #expect(source.checkedItemIDs == ["kept"])
        let stored = try await database.dbPool.read { db in try LibraryItem.fetchOne(db, key: removed.id) }
        #expect(stored?.lastCheckedAt == nil)
    }

    @Test func theBackgroundBatchIsSizedFromSeriesThatCanBeChecked() async throws {
        let completed = (0..<60).map { Self.item("done\($0)", plugin: "p", status: "Completed") }
        let ongoing = (0..<40).map { Self.item("open\($0)", plugin: "p") }
        let source = FakeLibraryUpdateSource(installedPluginIDs: ["p"])
        let (database, manager, _) = try await makeManager(
            items: completed + ongoing,
            source: source,
            clock: TestClock(start),
            skipCompleted: true
        )
        defer { database.cleanup() }

        _ = await manager.checkForUpdatesInBackground()

        // A quarter of the 40 series that can be checked, not of the whole library.
        #expect(source.checkedItemIDs.count == 10)
        #expect(source.checkedItemIDs.allSatisfy { $0.hasPrefix("open") })
    }

    @Test func sourcesAreCheckedTogetherButEachSourceOneSeriesAtATime() async throws {
        let plugins = ["a", "b", "c", "d"]
        let items = plugins.flatMap { plugin in [Self.item("\(plugin)1", plugin: plugin), Self.item("\(plugin)2", plugin: plugin)] }
        let gate = AsyncTestGate()
        let source = FakeLibraryUpdateSource(installedPluginIDs: Set(plugins))
        source.gate = gate
        let (database, manager, _) = try await makeManager(items: items, source: source, clock: TestClock(start))
        defer { database.cleanup() }

        let run = Task { await manager.checkForUpdates() }
        await gate.waitForAdmissions(UpdateManager.maxConcurrentSources)

        // Three sources are in flight, each with its first series; the fourth waits for a free slot.
        #expect(source.checkedItemIDs.count == UpdateManager.maxConcurrentSources)
        #expect(Set(source.checkedItemIDs.map { $0.prefix(1) }).count == UpdateManager.maxConcurrentSources)
        #expect(source.checkedItemIDs.allSatisfy { $0.hasSuffix("1") })

        await gate.open()
        await run.value
        #expect(Set(source.checkedItemIDs) == Set(items.map(\.id)))
        for plugin in plugins {
            #expect(source.checkedItemIDs.filter { $0.hasPrefix(plugin) } == ["\(plugin)1", "\(plugin)2"])
        }
    }

    @Test func aBackgroundRunStartsNoSeriesAfterItsTimeBudget() async throws {
        let ids = (0..<12).map { String(format: "s%02d", $0) }
        let clock = TestClock(start)
        let source = FakeLibraryUpdateSource(installedPluginIDs: ["p"])
        // Each check takes eight seconds.
        source.onCheck = { clock.date = clock.date.addingTimeInterval(8) }
        let (database, manager, _) = try await makeManager(
            items: ids.map { Self.item($0, plugin: "p") },
            source: source,
            clock: clock
        )
        defer { database.cleanup() }

        _ = await manager.checkForUpdatesInBackground(budget: 20)

        // Started at 0, 8 and 16 seconds; the fourth would start at 24.
        #expect(source.checkedItemIDs == ["s00", "s01", "s02"])
        #expect(!manager.isRefreshing)
    }

    @Test func wifiOnlyStopsAutomaticChecksOnExpensiveNetworksButNotManualOnes() async throws {
        let source = FakeLibraryUpdateSource(installedPluginIDs: ["p"])
        let (database, manager, _) = try await makeManager(
            items: [Self.item("a", plugin: "p")],
            source: source,
            clock: TestClock(start),
            wifiOnly: true,
            network: FakeNetworkConditions(isUnmetered: false)
        )
        defer { database.cleanup() }

        _ = await manager.checkForUpdatesInBackground()
        #expect(source.checkedItemIDs.isEmpty)
        #expect(!manager.isRefreshing)

        await manager.checkForUpdates()
        #expect(source.checkedItemIDs == ["a"])
    }

    @Test func wifiOnlyAllowsAutomaticChecksOnWifi() async throws {
        let source = FakeLibraryUpdateSource(installedPluginIDs: ["p"])
        let (database, manager, _) = try await makeManager(
            items: [Self.item("a", plugin: "p")],
            source: source,
            clock: TestClock(start),
            wifiOnly: true,
            network: FakeNetworkConditions(isUnmetered: true)
        )
        defer { database.cleanup() }

        _ = await manager.checkForUpdatesInBackground()

        #expect(source.checkedItemIDs == ["a"])
    }

    // MARK: Helpers

    private func makeManager(
        items: [LibraryItem],
        source: FakeLibraryUpdateSource,
        clock: TestClock,
        skipCompleted: Bool = false,
        wifiOnly: Bool = false,
        network: FakeNetworkConditions = FakeNetworkConditions(isUnmetered: true),
        configureSettings: Bool = true
    ) async throws -> (TestDatabase, UpdateManager, AppSettingsStore) {
        let database = try TestDatabase()
        try await database.dbPool.write { db in
            for item in items {
                try item.insert(db)
            }
        }
        let settings = AppSettingsStore(dbPool: database.dbPool)
        try await settings.reload()
        try await settings.set(skipCompleted, for: AppPreferenceCatalog.skipCompleted)
        try await settings.set(wifiOnly, for: AppPreferenceCatalog.wifiOnlyUpdates)
        let manager = UpdateManager(
            dbPool: database.dbPool,
            updateSource: source,
            networkConditions: network,
            sourcePacingNanoseconds: 0,
            now: { clock.date }
        )
        if configureSettings {
            manager.configure(settingsStore: settings)
        }
        return (database, manager, settings)
    }

    private static func item(_ id: String, plugin: String, status: String? = nil) -> LibraryItem {
        LibraryItem(
            id: id,
            title: id,
            coverUrl: nil,
            pluginId: plugin,
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil,
            status: status,
            lastCheckedAt: nil,
            lastUpdatedAt: nil,
            knownChapterCount: 5
        )
    }
}
