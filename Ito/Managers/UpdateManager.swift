import OSLog
import Combine
import Foundation
import SwiftUI
import GRDB
import Network
import ito_runner

/// Whether the device is on a network that automatic update checks may use with "Wi-Fi only" on.
nonisolated protocol UpdateNetworkConditions: Sendable {
    /// `true` on Wi-Fi or wired networks; `false` on cellular, personal hotspots or no network.
    nonisolated func isOnUnmeteredNetwork() async -> Bool
}

/// Reads the current network path once.
nonisolated struct PathMonitorNetworkConditions: UpdateNetworkConditions {
    nonisolated func isOnUnmeteredNetwork() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let firstPath = OnceFlag()
            monitor.pathUpdateHandler = { path in
                guard firstPath.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied && !path.isExpensive)
            }
            monitor.start(queue: DispatchQueue(label: "moe.itoapp.ito.update-network-path"))
        }
    }
}

/// Lets exactly one caller through, from any thread.
nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// - Returns: `true` the first time only.
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// Fetches the current chapter count and status of library series from their sources.
@MainActor
protocol LibraryUpdateSource: AnyObject {
    /// The sources that can be checked now.
    var installedPluginIDs: Set<String> { get }
    func fetchUpdate(for item: LibraryItem) async throws -> UpdateManager.SuccessfulUpdate
}

/// Checks series through their installed plugins.
@MainActor
final class PluginLibraryUpdateSource: LibraryUpdateSource {
    private let pluginManager: PluginManager

    init(pluginManager: PluginManager) {
        self.pluginManager = pluginManager
    }

    var installedPluginIDs: Set<String> {
        Set(pluginManager.installedPlugins.keys)
    }

    func fetchUpdate(for item: LibraryItem) async throws -> UpdateManager.SuccessfulUpdate {
        let runner = try await pluginManager.getRunner(for: item.pluginId)
        switch item.effectiveType {
        case .manga:
            let manga = try await runner.getMangaUpdate(manga: try JSONDecoder().decode(Manga.self, from: item.rawPayload))
            return UpdateManager.SuccessfulUpdate(
                freshCount: manga.chapters?.distinctChapterCount ?? 0,
                status: String(describing: manga.status)
            )
        case .anime:
            let anime = try await runner.getAnimeUpdate(
                anime: try JSONDecoder().decode(Anime.self, from: item.rawPayload),
                needsDetails: false,
                needsEpisodes: true
            )
            return UpdateManager.SuccessfulUpdate(
                freshCount: anime.episodes?.distinctChapterCount ?? 0,
                status: String(describing: anime.status)
            )
        case .novel:
            let novel = try await runner.getNovelUpdate(novel: try JSONDecoder().decode(Novel.self, from: item.rawPayload))
            return UpdateManager.SuccessfulUpdate(
                freshCount: novel.chapters?.distinctChapterCount ?? 0,
                status: String(describing: novel.status)
            )
        }
    }
}

@MainActor
public class UpdateManager: ObservableObject {
    @Published private var newChapterCounts: [MediaIdentity: Int] = [:]

    internal var libraryBadgeCountsSnapshot: [MediaIdentity: Int] {
        newChapterCounts
    }

    internal var libraryBadgeCountsPublisher: AnyPublisher<[MediaIdentity: Int], Never> {
        $newChapterCounts.eraseToAnyPublisher()
    }

    /// Indicates if a refresh operation is currently actively running
    @Published public private(set) var isRefreshing: Bool = false

    /// Determinate Progress Tracking
    @Published public private(set) var totalItemsToCheck: Int = 0
    @Published public private(set) var itemsCheckedCurrentRun: Int = 0

    /// Sources checked at the same time. Series of one source are always checked one at a time.
    static let maxConcurrentSources = 3
    /// Background checks look at most this share of the eligible library, at least `minimumBackgroundBatch`.
    private static let backgroundBatchDivisor = 4
    private static let minimumBackgroundBatch = 5

    private let dbPool: DatabasePool
    private let updateSource: (any LibraryUpdateSource)?
    private let networkConditions: any UpdateNetworkConditions
    private let sourcePacingNanoseconds: UInt64
    private let now: () -> Date
    private var settingsStore: AppSettingsStore?
    /// No new series are started after this, so a background run ends inside its time.
    private var runDeadline: Date?

    /// - Parameters:
    ///   - updateSource: Where series are checked; without one, checks do nothing.
    ///   - networkConditions: Whether the current network allows automatic checks on Wi-Fi only.
    ///   - sourcePacingNanoseconds: The pause between two requests to the same source.
    ///   - now: The clock used for ordering, recorded check times and time budgets.
    internal init(
        dbPool: DatabasePool,
        updateSource: (any LibraryUpdateSource)? = nil,
        networkConditions: any UpdateNetworkConditions = PathMonitorNetworkConditions(),
        sourcePacingNanoseconds: UInt64 = 500_000_000,
        now: @escaping () -> Date = Date.init
    ) {
        self.dbPool = dbPool
        self.updateSource = updateSource
        self.networkConditions = networkConditions
        self.sourcePacingNanoseconds = sourcePacingNanoseconds
        self.now = now
    }

    func configure(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
    }

    // MARK: - Core Refresh Flow

    /// Checks every eligible series, for a refresh the user asked for. Runs on any network.
    public func checkForUpdates() async {
        _ = await runSmartUpdate(isBackground: false, budget: nil)
    }

    /// Entry point for BGAppRefreshTask: checks the series most likely to have new chapters. With
    /// "Wi-Fi only" on, it does nothing on cellular or other expensive networks.
    /// - Parameter budget: Seconds after which no new series are started; iOS gives an app
    ///   refresh task about 30 seconds in all.
    /// - Returns: The series with new chapters and how many are new.
    public func checkForUpdatesInBackground(budget: TimeInterval = 20) async -> [(LibraryItem, Int)] {
        await runSmartUpdate(isBackground: true, budget: budget)
    }

    private func runSmartUpdate(isBackground: Bool, budget: TimeInterval?) async -> [(LibraryItem, Int)] {
        guard !isRefreshing else {
            AppLogger.update.debug("🔄 [UpdateManager] Already refreshing, skipping.")
            return []
        }
        guard let settingsStore else {
            AppLogger.update.error("🔄 [UpdateManager] Settings unavailable before durable bootstrap.")
            return []
        }
        guard let updateSource, case let installed = updateSource.installedPluginIDs, !installed.isEmpty else {
            AppLogger.update.debug("🔄 [UpdateManager] No plugins installed, nothing to check.")
            return []
        }
        isRefreshing = true
        let started = now()
        runDeadline = budget.map { started.addingTimeInterval($0) }
        defer {
            isRefreshing = false
            runDeadline = nil
        }
        if isBackground, settingsStore.wifiOnlyUpdates, await !networkConditions.isOnUnmeteredNetwork() {
            AppLogger.update.debug("🔄 [UpdateManager] Wi-Fi only: skipping the automatic check on this network.")
            return []
        }

        let items: [LibraryItem]
        do {
            items = try await dbPool.read { db in try LibraryItem.fetchAll(db) }
        } catch {
            AppLogger.update.error("🔄 [UpdateManager] Failed to load library: \(error)")
            return []
        }

        let batch = plannedBatch(
            from: items,
            installedPluginIDs: installed,
            skipCompleted: settingsStore.skipCompleted,
            isBackground: isBackground
        )
        totalItemsToCheck = batch.count
        itemsCheckedCurrentRun = 0
        AppLogger.update.debug("🔄 [UpdateManager] Checking \(batch.count) of \(items.count) series.")

        let updated = await check(Self.sourceQueues(batch))
        AppLogger.update.debug("🔄 [UpdateManager] Finished: \(updated.count) series have new chapters.")
        return updated
    }

    /// The series to check, most likely to have new chapters first. Series whose plugin is not
    /// installed are skipped, and with `skipCompleted` so are completed and cancelled ones.
    private func plannedBatch(
        from items: [LibraryItem],
        installedPluginIDs: Set<String>,
        skipCompleted: Bool,
        isBackground: Bool
    ) -> [LibraryItem] {
        let date = now()
        let eligible = items.filter { item in
            guard installedPluginIDs.contains(item.pluginId) else { return false }
            guard skipCompleted else { return true }
            let status = item.status?.lowercased() ?? ""
            return status != "completed" && status != "cancelled"
        }
        let ordered = eligible
            .map { (item: $0, score: Self.score(for: $0, at: date)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.item.id < $1.item.id }
            .map(\.item)
        guard isBackground, ordered.count > 10 else { return ordered }
        return Array(ordered.prefix(max(Self.minimumBackgroundBatch, ordered.count / Self.backgroundBatchDivisor)))
    }

    private static func score(for item: LibraryItem, at date: Date) -> Int {
        var baseStatusScore = 7 // Unknown/nil
        if let status = item.status?.lowercased() {
            if status.contains("ongoing") { baseStatusScore = 10 } else if status.contains("hiatus") { baseStatusScore = 3 }
        }

        // Failed attempts count as checks, so a series that keeps failing does not stay first.
        let hoursSinceChecked: Int
        if let lastChecked = item.lastCheckedAt {
            let diff = Calendar.current.dateComponents([.hour], from: lastChecked, to: date).hour ?? 0
            hoursSinceChecked = min(24, max(0, diff))
        } else {
            hoursSinceChecked = 24
        }

        var recentUpdateBonus = 0
        if let lastUpdated = item.lastUpdatedAt {
            let daysSinceUpdate = Calendar.current.dateComponents([.day], from: lastUpdated, to: date).day ?? 999
            if daysSinceUpdate <= 7 {
                recentUpdateBonus = 30
            }
        }

        return baseStatusScore + hoursSinceChecked + recentUpdateBonus
    }

    /// Groups series by source, keeping their order, with sources in order of their first series.
    private static func sourceQueues(_ batch: [LibraryItem]) -> [[LibraryItem]] {
        let queues = Dictionary(grouping: batch, by: \.pluginId)
        var started = Set<String>()
        return batch.compactMap { item in
            started.insert(item.pluginId).inserted ? queues[item.pluginId] : nil
        }
    }

    /// Checks up to `maxConcurrentSources` sources at once, each one series at a time.
    private func check(_ queues: [[LibraryItem]]) async -> [(LibraryItem, Int)] {
        await withTaskGroup(of: [(LibraryItem, Int)].self) { group in
            var remaining = queues.makeIterator()
            for _ in 0..<Self.maxConcurrentSources {
                guard let queue = remaining.next() else { break }
                group.addTask { await self.check(queue: queue) }
            }
            var updated: [(LibraryItem, Int)] = []
            for await result in group {
                updated += result
                if let queue = remaining.next() {
                    group.addTask { await self.check(queue: queue) }
                }
            }
            return updated
        }
    }

    private func check(queue: [LibraryItem]) async -> [(LibraryItem, Int)] {
        var updated: [(LibraryItem, Int)] = []
        for (index, item) in queue.enumerated() {
            if Task.isCancelled { break }
            if let runDeadline, now() >= runDeadline {
                AppLogger.update.debug("🔄 [UpdateManager] Time budget used up, leaving the rest for the next run.")
                break
            }
            if index > 0, sourcePacingNanoseconds > 0 {
                // Spread requests to one source out; stop when the run is cancelled.
                do {
                    try await Task.sleep(nanoseconds: sourcePacingNanoseconds)
                } catch {
                    break
                }
            }
            if let delta = await checkSingleItem(item), delta > 0 {
                updated.append((item, delta))
            }
            itemsCheckedCurrentRun += 1
        }
        return updated
    }

    private func checkSingleItem(_ item: LibraryItem) async -> Int? {
        guard let updateSource else { return nil }
        AppLogger.update.debug("🔄 [UpdateManager] Checking: \(item.title)")
        return await processUpdate(for: item, checkedAt: now()) {
            try await updateSource.fetchUpdate(for: item)
        }
    }

    internal struct SuccessfulUpdate: Sendable {
        let freshCount: Int
        let status: String?
    }

    /// Persists a fetched update and derives badge state only from committed database state. New
    /// chapters add to the series' unread badge, which stays until the series is opened or cleared.
    /// A failed fetch records only the attempt time, so the series moves behind others next time.
    /// - Returns: The chapters new in this check, or `nil` when nothing was recorded.
    internal func processUpdate(
        for item: LibraryItem,
        checkedAt: Date = Date(),
        fetchUpdate: () async throws -> SuccessfulUpdate
    ) async -> Int? {
        let update: SuccessfulUpdate
        do {
            update = try await fetchUpdate()
        } catch is CancellationError {
            return nil
        } catch {
            AppLogger.update.error("🔄 [UpdateManager] ❌ Failed for \(item.title): \(error)")
            await recordFailedAttempt(for: item.id, at: checkedAt)
            return nil
        }
        do {
            let media = MediaIdentity(pluginId: item.pluginId, itemId: item.id)
            let committed = try await dbPool.write { db -> (
                oldCount: Int?,
                delta: Int,
                unread: Int,
                itemWasMissing: Bool
            ) in
                let badge = UpdateBadgeRecord
                    .filter(Column("pluginId") == media.pluginId)
                    .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                guard var dbItem = try LibraryItem.fetchOne(db, key: item.id) else {
                    _ = try LibraryItem.deleteOne(db, key: item.id)
                    try badge.deleteAll(db)
                    return (nil, 0, 0, true)
                }

                let oldCount = dbItem.knownChapterCount
                let delta = oldCount.map { max(0, update.freshCount - $0) } ?? 0
                dbItem.knownChapterCount = update.freshCount
                dbItem.lastCheckedAt = checkedAt
                if delta > 0 {
                    dbItem.lastUpdatedAt = checkedAt
                }
                if let status = update.status {
                    dbItem.status = status
                }
                try dbItem.update(db)
                var unread = try badge.fetchOne(db)?.count ?? 0
                if delta > 0 {
                    unread += delta
                    try UpdateBadgeRecord(
                        pluginId: media.pluginId,
                        canonicalMediaId: media.canonicalMediaId,
                        count: unread,
                        updatedAt: checkedAt,
                        provenance: .runtime
                    ).save(db)
                }
                return (oldCount, delta, unread, false)
            }

            if committed.itemWasMissing {
                newChapterCounts.removeValue(forKey: media)
                return nil
            }

            AppLogger.update.debug(
                "🔄 [UpdateManager] \(item.title): \(String(describing: committed.oldCount)) known, \(update.freshCount) fresh/persisted -> \(committed.delta) new, \(committed.unread) unread"
            )
            if committed.unread > 0 {
                newChapterCounts[media] = committed.unread
            } else {
                newChapterCounts.removeValue(forKey: media)
            }
            return committed.delta
        } catch {
            AppLogger.update.error("🔄 [UpdateManager] ❌ Failed to save the check for \(item.title): \(error)")
            return nil
        }
    }

    private func recordFailedAttempt(for itemID: String, at date: Date) async {
        do {
            try await dbPool.write { db in
                guard var dbItem = try LibraryItem.fetchOne(db, key: itemID) else { return }
                dbItem.lastCheckedAt = date
                try dbItem.update(db)
            }
        } catch {
            AppLogger.update.error("🔄 [UpdateManager] ❌ Failed to record a failed check: \(error)")
        }
    }

    // MARK: - State Management

    public func badgeCount(for media: MediaIdentity) -> Int {
        max(0, newChapterCounts[media] ?? 0)
    }

    public var totalBadgeCount: Int {
        newChapterCounts.values.reduce(0, +)
    }

    public func advanceBaseline(
        for itemId: String,
        media: MediaIdentity,
        knownChapterCount: Int
    ) async throws {
        try await dbPool.write { db in
            if var item = try LibraryItem.fetchOne(db, key: itemId) {
                item.knownChapterCount = knownChapterCount
                try item.update(db)
            }
            try UpdateBadgeRecord
                .filter(Column("pluginId") == media.pluginId)
                .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                .deleteAll(db)
        }
        newChapterCounts.removeValue(forKey: media)
    }

    public func clearBadge(for media: MediaIdentity) async throws {
        _ = try await dbPool.write { db in
            try UpdateBadgeRecord
                .filter(Column("pluginId") == media.pluginId)
                .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                .deleteAll(db)
        }
        newChapterCounts.removeValue(forKey: media)
    }

    public func reload() async throws {
        let records = try await dbPool.read { db in
            try UpdateBadgeRecord.fetchAll(db)
        }
        newChapterCounts = Dictionary(uniqueKeysWithValues: records.map {
            (
                MediaIdentity(pluginId: $0.pluginId, canonicalMediaId: $0.canonicalMediaId),
                max(0, $0.count)
            )
        })
    }
}
