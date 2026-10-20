import OSLog
import Combine
import Foundation
import SwiftUI
import GRDB
import ito_runner

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

    private let dbPool: DatabasePool
    private let pluginManager: PluginManager?
    private var settingsStore: AppSettingsStore?

    internal init(
        dbPool: DatabasePool,
        pluginManager: PluginManager? = nil
    ) {
        self.dbPool = dbPool
        self.pluginManager = pluginManager
    }

    func configure(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
    }

    // MARK: - Core Refresh Flow

    @MainActor
    public func checkForUpdates() async {
        guard !isRefreshing else {
            AppLogger.update.debug("🔄 [UpdateManager] Already refreshing, skipping.")
            return
        }

        let items: [LibraryItem]
        do {
            items = try await dbPool.read { db in try LibraryItem.fetchAll(db) }
        } catch {
            AppLogger.update.error("🔄 [UpdateManager] Failed to load library: \(error)")
            return
        }
        guard !items.isEmpty else {
            AppLogger.update.debug("🔄 [UpdateManager] No library items to check.")
            return
        }

        _ = await runSmartUpdate(items: items, isBackground: false)
    }

    /// Entry point for BGAppRefreshTask.
    /// Returns the items that have new chapters and their new chapter count.
    @MainActor
    public func checkForUpdatesInBackground() async -> [(LibraryItem, Int)] {
        guard !isRefreshing else { return [] }

        AppLogger.update.debug("🔄 [UpdateManager] Starting background update check.")
        let items: [LibraryItem]
        do {
            items = try await dbPool.read { db in
                try LibraryItem.fetchAll(db)
            }
        } catch {
            AppLogger.update.error("🔄 [UpdateManager] Background error fetching items: \(error)")
            return []
        }

        return await runSmartUpdate(items: items, isBackground: true)
    }

    @MainActor
    private func runSmartUpdate(items: [LibraryItem], isBackground: Bool) async -> [(LibraryItem, Int)] {
        AppLogger.update.debug("\("🔄 [UpdateManager] Starting smart update check for \(items.count)") total items...")

        // Wait for PluginManager to finish loading plugins on cold start
        var waitAttempts = 0
        while pluginManager?.installedPlugins.isEmpty == true && waitAttempts < 20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waitAttempts += 1
        }

        guard pluginManager?.installedPlugins.isEmpty == false else {
            AppLogger.update.debug("🔄 [UpdateManager] No plugins loaded, aborting.")
            return []
        }

        isRefreshing = true
        var updatedItemsWithCounts: [(LibraryItem, Int)] = []

        // 1. Filter out completed/cancelled if setting is on
        guard let settingsStore else {
            AppLogger.update.error("🔄 [UpdateManager] Settings unavailable before durable bootstrap.")
            return []
        }
        let skipCompleted = settingsStore.skipCompleted
        var candidates = items
        if skipCompleted {
            candidates = candidates.filter { item in
                let status = item.status?.lowercased() ?? ""
                return status != "completed" && status != "cancelled"
            }
        }

        // 2. Score items
        var scoredItems: [(item: LibraryItem, score: Int)] = candidates.map { item in
            let score = calculateScore(for: item)
            return (item, score)
        }

        scoredItems.sort { $0.score > $1.score }

        // 3. Dynamic Batch Size (only for background updates)
        let maxBatchSize = max(5, items.count / 4)
        let batchItems = isBackground && items.count > 10
            ? Array(scoredItems.prefix(maxBatchSize).map(\.item))
            : scoredItems.map(\.item)

        totalItemsToCheck = batchItems.count
        itemsCheckedCurrentRun = 0

        AppLogger.update.debug("🔄 [UpdateManager] Batch size: \(batchItems.count)")

        // 4. Check Items
        for item in batchItems {
            if Task.isCancelled { break }

            AppLogger.update.debug("🔄 [UpdateManager] Checking: \(item.title)")
            if let newCount = await checkSingleItem(item) {
                updatedItemsWithCounts.append((item, newCount))
            }
            itemsCheckedCurrentRun += 1
            AppLogger.update.debug("🔄 [UpdateManager] Progress: \(self.itemsCheckedCurrentRun)/\(self.totalItemsToCheck)")

            // Be gentle on source networks for big manual updates
            if !isBackground {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            }
        }

        AppLogger.update.debug("\("🔄 [UpdateManager] Finished smart update. Found \(updatedItemsWithCounts.count)") new updates.")
        isRefreshing = false
        return updatedItemsWithCounts
    }

    private func calculateScore(for item: LibraryItem) -> Int {
        var baseStatusScore = 7 // Unknown/nil
        if let status = item.status?.lowercased() {
            if status.contains("ongoing") { baseStatusScore = 10 } else if status.contains("hiatus") { baseStatusScore = 3 }
        }

        let hoursSinceChecked: Int
        if let lastChecked = item.lastCheckedAt {
            let diff = Calendar.current.dateComponents([.hour], from: lastChecked, to: Date()).hour ?? 0
            hoursSinceChecked = min(24, max(0, diff))
        } else {
            hoursSinceChecked = 24
        }

        var recentUpdateBonus = 0
        if let lastUpdated = item.lastUpdatedAt {
            let daysSinceUpdate = Calendar.current.dateComponents([.day], from: lastUpdated, to: Date()).day ?? 999
            if daysSinceUpdate <= 7 {
                recentUpdateBonus = 30
            }
        }

        return baseStatusScore + hoursSinceChecked + recentUpdateBonus
    }

    private func checkSingleItem(_ item: LibraryItem) async -> Int? {
        do {
            guard let pluginManager else { return nil }
            let runner = try await pluginManager.getRunner(for: item.pluginId)

            let delta = await processUpdate(for: item) {
                switch item.effectiveType {
                case .manga:
                    let baseManga = try JSONDecoder().decode(Manga.self, from: item.rawPayload)
                    let fullManga = try await runner.getMangaUpdate(manga: baseManga)
                    return SuccessfulUpdate(
                        freshCount: fullManga.chapters?.distinctChapterCount ?? 0,
                        status: String(describing: fullManga.status)
                    )
                case .anime:
                    let baseAnime = try JSONDecoder().decode(Anime.self, from: item.rawPayload)
                    let fullAnime = try await runner.getAnimeUpdate(
                        anime: baseAnime,
                        needsDetails: false,
                        needsEpisodes: true
                    )
                    return SuccessfulUpdate(
                        freshCount: fullAnime.episodes?.distinctChapterCount ?? 0,
                        status: String(describing: fullAnime.status)
                    )
                case .novel:
                    let baseNovel = try JSONDecoder().decode(Novel.self, from: item.rawPayload)
                    let fullNovel = try await runner.getNovelUpdate(novel: baseNovel)
                    return SuccessfulUpdate(
                        freshCount: fullNovel.chapters?.distinctChapterCount ?? 0,
                        status: String(describing: fullNovel.status)
                    )
                }
            }

            guard let delta, delta > 0 else { return nil }
            return delta

        } catch {
            AppLogger.update.error("\("🔄 [UpdateManager] ❌ Failed for \(item.title)"): \(error)")
            return nil
        }
    }

    internal struct SuccessfulUpdate: Sendable {
        let freshCount: Int
        let status: String?
    }

    /// Persists a fetched update and derives badge state only from committed database state. New
    /// chapters add to the series' unread badge, which stays until the series is opened or cleared.
    /// - Returns: The chapters new in this check, or `nil` when nothing was recorded.
    internal func processUpdate(
        for item: LibraryItem,
        checkedAt: Date = Date(),
        fetchUpdate: () async throws -> SuccessfulUpdate
    ) async -> Int? {
        do {
            let update = try await fetchUpdate()
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
            AppLogger.update.error("🔄 [UpdateManager] ❌ Failed for \(item.title): \(error)")
            return nil
        }
    }

    // MARK: - State Management

    @MainActor
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
