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
    /// - Parameter frozenScope: the source epoch the check captured. The request is made under it, so a later change
    ///   of the source's settings or account cannot be mistaken for the one the catalog was read under. Nil reads
    ///   the live scope and returns no catalog observation.
    func fetchUpdate(for item: LibraryItem, operation: PluginNetworkOperation, frozenScope: String?) async throws -> UpdateManager.SuccessfulUpdate
    func pendingTrust(for pluginID: String) -> PendingTrust?
    func clearPendingTrust(for pluginID: String)
}

extension LibraryUpdateSource {
    func pendingTrust(for pluginID: String) -> PendingTrust? { nil }
    func clearPendingTrust(for pluginID: String) {}
}

/// What a library update check needs from a plugin's runner. `PluginLibraryUpdateSource` depends on this, not on the
/// plugin manager, so the one catalog fetch can be tested without a plugin. The runner is an actor, so the protocol
/// names no isolation: its one requirement is asynchronous, and the actor's own isolation satisfies it.
nonisolated protocol MediaUpdateRunning: AnyObject, Sendable {
    func getMediaUpdate(_ entry: MediaEntry, needsDetails: Bool, context: NetworkOperationContext) async throws -> MediaEntry
}

extension ItoRunner: MediaUpdateRunning {
    func getMediaUpdate(_ entry: MediaEntry, needsDetails: Bool, context: NetworkOperationContext) async throws -> MediaEntry {
        try await getMediaUpdate(entry, needsDetails: needsDetails, needsUnits: true, context: context)
    }
}

/// Checks series through their installed plugins.
@MainActor
final class PluginLibraryUpdateSource: LibraryUpdateSource {
    /// A runner and the version of the installed copy that answers through it. Both come from one synchronous read, so
    /// they describe the same copy.
    struct Resolution {
        let runner: any MediaUpdateRunning
        let pluginVersion: String?
    }

    private let resolve: @MainActor (String) async throws -> Resolution
    private let context: @MainActor (String, PluginNetworkOperation, String?) -> NetworkOperationContext
    private let installed: @MainActor () -> Set<String>
    private let trust: PluginTrustStore

    init(
        resolve: @escaping @MainActor (String) async throws -> Resolution,
        context: @escaping @MainActor (String, PluginNetworkOperation, String?) -> NetworkOperationContext,
        installedPluginIDs: @escaping @MainActor () -> Set<String>,
        trust: PluginTrustStore
    ) {
        self.resolve = resolve
        self.context = context
        self.installed = installedPluginIDs
        self.trust = trust
    }

    convenience init(pluginManager: PluginManager) {
        self.init(
            resolve: { pluginID in
                let runner = try await pluginManager.getRunner(for: pluginID)
                // Read with the runner, with no suspension in between: both describe the one installed copy that answers.
                return Resolution(runner: runner, pluginVersion: pluginManager.installedPlugins[pluginID]?.info.version)
            },
            context: { pluginID, operation, frozenScope in
                pluginManager.pluginSettingsStore.networkContexts.context(
                    pluginID: pluginID, operation, frozenScope: frozenScope
                )
            },
            installedPluginIDs: { Set(pluginManager.installedPlugins.keys) },
            trust: pluginManager.pluginSettingsStore.trust
        )
    }

    var installedPluginIDs: Set<String> {
        installed()
    }

    func fetchUpdate(
        for item: LibraryItem,
        operation: PluginNetworkOperation,
        frozenScope: String?
    ) async throws -> UpdateManager.SuccessfulUpdate {
        clearPendingTrust(for: item.pluginId)
        let resolution = try await resolve(item.pluginId)
        let context = context(item.pluginId, operation, frozenScope)
        return try await pluginCall {
            let stored: MediaEntry
            switch item.effectiveType {
            case .manga: stored = .manga(try JSONDecoder().decode(Manga.self, from: item.rawPayload))
            case .anime: stored = .anime(try JSONDecoder().decode(Anime.self, from: item.rawPayload))
            case .novel: stored = .novel(try JSONDecoder().decode(Novel.self, from: item.rawPayload))
            }
            // Details are only needed where the update keeps them (manga and novels show status).
            let updated = try await resolution.runner.getMediaUpdate(
                stored, needsDetails: item.effectiveType != .anime, context: context
            )
            switch updated {
            case .manga(let manga):
                return UpdateManager.SuccessfulUpdate(
                    freshCount: manga.chapters?.distinctChapterCount ?? 0,
                    status: String(describing: manga.status),
                    catalog: Self.observation(
                        of: updated, for: item, pluginVersion: resolution.pluginVersion, frozenScope: frozenScope
                    )
                )
            case .anime(let anime):
                return UpdateManager.SuccessfulUpdate(
                    freshCount: anime.episodes?.distinctChapterCount ?? 0,
                    status: String(describing: anime.status)
                )
            case .novel(let novel):
                return UpdateManager.SuccessfulUpdate(
                    freshCount: novel.chapters?.distinctChapterCount ?? 0,
                    status: String(describing: novel.status),
                    catalog: Self.observation(
                        of: updated, for: item, pluginVersion: resolution.pluginVersion, frozenScope: frozenScope
                    )
                )
            }
        }
    }

    /// The catalog of the answer as an observation, only for a check that froze a scope. It is built from the entry
    /// the source returned and is never fetched again. Without the version of the copy that answered, the scope is unknown.
    static func observation(
        of entry: MediaEntry,
        for item: LibraryItem,
        pluginVersion: String?,
        frozenScope: String?
    ) -> Result<CatalogObservation, SubscriptionCheckOutcome>? {
        guard let frozenScope else { return nil }
        guard let pluginVersion else { return .failure(.unknownScope) }
        return CatalogObservation.make(
            media: item.mediaIdentity, entry: entry, pluginVersion: pluginVersion, sourceEpoch: frozenScope
        )
    }

    func pendingTrust(for pluginID: String) -> PendingTrust? {
        trust.pending(pluginID: pluginID)
    }

    func clearPendingTrust(for pluginID: String) {
        trust.clearPending(pluginID: pluginID)
    }
}

/// Why a library update check did not run.
public enum UpdateRunError: Error, Equatable {
    case alreadyRunning
    case notReady
    case noSources
    case libraryUnreadable
}

/// The kinds of run the manager serializes: a refresh the user asked for, a background refresh, and a pass over the
/// series with an automatic-download rule.
nonisolated enum UpdateRunKind: Sendable, Equatable {
    case manual, background, subscriptions
}

/// What one pass over subscribed series did.
nonisolated struct SubscriptionCheckRunResult: Sendable, Equatable {
    var checked = 0
    var skippedNotInstalled = 0
    /// The network policy stopped the pass before every series was checked; the rest stay due.
    var stoppedByPolicy = false
    var cancelled = false
    /// The series the pass attempted. A series it did not reach (the policy stopped it, its source needs the person,
    /// the pass was cancelled) is not listed and stays due.
    var attempted: [MediaIdentity] = []
    /// The sources whose failure shows they need the person (settings, a sign-in, a trust decision). The rest of their
    /// series were not asked, and asking again changes nothing until the person acts.
    var blockedSources: Set<String> = []
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

    /// User-facing source failures for this run only; never persisted or logged.
    @Published private(set) var sourceFailures: [LibraryUpdateFailure] = []

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
    /// Receives each manga or novel catalog this manager reads for a subscribed series. It never infers an event from
    /// a count: the badge and the count stay this manager's own.
    private var subscriptionSink: (any SubscriptionCatalogSink)?
    /// No new series are started after this, so a background run ends inside its time.
    private var runDeadline: Date?
    /// The one run that holds the manager. A manual or background run, and a subscription pass, never overlap.
    private var activeRun: UpdateRunKind?
    private var subscriptionRun: Task<SubscriptionCheckRunResult, Never>?
    /// A manual or background run is waiting for a cancelled subscription pass to end, so no new pass may start in
    /// between: a person's refresh never fails with `alreadyRunning` because of one.
    private var libraryRunPending = false
    private let runFinishedSubject = PassthroughSubject<UpdateRunKind, Never>()

    /// Emits after every run, of any kind, has fully ended.
    var runFinished: AnyPublisher<UpdateRunKind, Never> {
        runFinishedSubject.eraseToAnyPublisher()
    }

    /// Which sink the manager hands catalogs to, for the composition root's test.
    var subscriptionSinkIdentity: ObjectIdentifier? {
        subscriptionSink.map { ObjectIdentifier($0) }
    }

    /// The sources that can be checked now.
    var installedPluginIDs: Set<String> {
        updateSource?.installedPluginIDs ?? []
    }

    /// The series the last manual or background run attempted, for the scheduler to know which rules it covered.
    private(set) var lastRunAttempted: [MediaIdentity] = []

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

    func configure(subscriptionSink: any SubscriptionCatalogSink) {
        self.subscriptionSink = subscriptionSink
    }

    // MARK: - Core Refresh Flow

    /// Checks every eligible series, for a refresh the user asked for. Runs on any network.
    /// - Throws: ``UpdateRunError`` when the check cannot run.
    public func checkForUpdates() async throws {
        _ = try await runSmartUpdate(isBackground: false, budget: nil)
    }

    /// Checks the series most likely to have new chapters, within `budget` seconds, for a
    /// background refresh. With Wi-Fi only on, it does nothing on cellular or expensive networks.
    ///
    /// - Returns: The series with new chapters and how many are new.
    public func checkForUpdatesInBackground(budget: TimeInterval = 20) async -> [(LibraryItem, Int)] {
        // A background run that cannot start has nothing to report; the reason is logged.
        (try? await runSmartUpdate(isBackground: true, budget: budget)) ?? []
    }

    /// Starts checking these subscribed series under the automatic-metadata policy, in the order given: Wi-Fi only, Low
    /// Data Mode and an unknown path are decided again before every series. Each series goes through the one check every
    /// library run makes (badge, count and the catalog for the ledger), so a pass is never a second fetch.
    ///
    /// A pass is not a library run. It never publishes `isRefreshing` or the progress counters, never lists failures in
    /// `sourceFailures`, skips anime and sources that are not installed, ignores `skipCompleted` (an explicit rule
    /// outranks the Library filter), and does not ask a source again once it needs the person (settings, sign-in, trust).
    ///
    /// - Returns: nil when another run, of any kind, is active or is about to start; the caller starts again when
    ///   `runFinished` emits. A manual or background run cancels a pass that is in flight and waits for it.
    func startSubscriptionChecks(_ media: [MediaIdentity]) -> Task<SubscriptionCheckRunResult, Never>? {
        guard activeRun == nil, !libraryRunPending else { return nil }
        // Before durable bootstrap there is nothing to check with; this is not another run, so nothing waits for one.
        guard settingsStore != nil, updateSource != nil else {
            return Task { SubscriptionCheckRunResult() }
        }
        activeRun = .subscriptions
        let task = Task { await self.runSubscriptionChecks(media) }
        subscriptionRun = task
        return task
    }

    private func runSubscriptionChecks(_ media: [MediaIdentity]) async -> SubscriptionCheckRunResult {
        var result = SubscriptionCheckRunResult()
        defer {
            subscriptionRun = nil
            activeRun = nil
            runFinishedSubject.send(.subscriptions)
        }
        guard let updateSource, !Task.isCancelled else {
            result.cancelled = true
            return result
        }
        let installed = updateSource.installedPluginIDs
        let items: [LibraryItem]
        do {
            items = try await dbPool.read { db in
                var found: [LibraryItem] = []
                for identity in media {
                    let candidates = ImportedMediaIdentity.localItemIDs(
                        pluginId: identity.pluginId, canonicalMediaId: identity.canonicalMediaId, mediaKind: identity.mediaKind
                    )
                    for id in candidates {
                        if let item = try LibraryItem.fetchOne(db, key: id), item.mediaIdentity == identity {
                            found.append(item)
                            break
                        }
                    }
                }
                return found
            }
        } catch {
            AppLogger.update.error("🔄 [UpdateManager] Failed to load the subscribed series.")
            return result
        }
        var batch: [LibraryItem] = []
        for item in items where item.effectiveType != .anime {
            if installed.contains(item.pluginId) {
                batch.append(item)
            } else {
                result.skippedNotInstalled += 1
            }
        }
        let operation = PluginNetworkOperation(purpose: .automaticLibraryUpdate, operationID: UUID())
        let walk = await check(Self.sourceQueues(batch), operation: operation, kind: .subscriptions)
        result.checked = walk.checked
        result.attempted = walk.attempted
        result.blockedSources = walk.blockedSources
        result.stoppedByPolicy = walk.stoppedByPolicy
        result.cancelled = Task.isCancelled
        return result
    }

    private func runSmartUpdate(isBackground: Bool, budget: TimeInterval?) async throws -> [(LibraryItem, Int)] {
        // A pass over subscribed series gives way: it is cancelled and awaited, which is a deterministic wait for that
        // task and not a pause. Nothing may start a new pass in between.
        if let run = subscriptionRun {
            libraryRunPending = true
            run.cancel()
            _ = await run.value
            libraryRunPending = false
        }
        guard activeRun == nil else {
            AppLogger.update.debug("🔄 [UpdateManager] Already refreshing, skipping.")
            throw UpdateRunError.alreadyRunning
        }
        sourceFailures = []
        guard let settingsStore else {
            AppLogger.update.error("🔄 [UpdateManager] Settings unavailable before durable bootstrap.")
            throw UpdateRunError.notReady
        }
        guard let updateSource, case let installed = updateSource.installedPluginIDs, !installed.isEmpty else {
            AppLogger.update.debug("🔄 [UpdateManager] No plugins installed, nothing to check.")
            throw UpdateRunError.noSources
        }
        let kind: UpdateRunKind = isBackground ? .background : .manual
        activeRun = kind
        isRefreshing = true
        let started = now()
        runDeadline = budget.map { started.addingTimeInterval($0) }
        defer {
            isRefreshing = false
            runDeadline = nil
            activeRun = nil
            runFinishedSubject.send(kind)
        }
        if isBackground, await !automaticChecksAdmitted() { return [] }

        let items: [LibraryItem]
        do {
            items = try await dbPool.read { db in try LibraryItem.fetchAll(db) }
        } catch {
            AppLogger.update.error("🔄 [UpdateManager] Failed to load library: \(error)")
            throw UpdateRunError.libraryUnreadable
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

        // One operation per run: every series of the run, on every source, shares its ID.
        let operation = PluginNetworkOperation(
            purpose: isBackground ? .automaticLibraryUpdate : .manualCatalogRefresh,
            operationID: UUID()
        )
        let walk = await check(Self.sourceQueues(batch), operation: operation, kind: kind)
        lastRunAttempted = walk.attempted
        let updated = walk.updated
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

    /// What a walk over source queues did.
    private struct QueueWalk {
        var updated: [(LibraryItem, Int)] = []
        var checked = 0
        var attempted: [MediaIdentity] = []
        var blockedSources: Set<String> = []
        /// The automatic-network rule refused the rest of a queue.
        var stoppedByPolicy = false

        mutating func absorb(_ other: QueueWalk) {
            updated += other.updated
            checked += other.checked
            attempted += other.attempted
            blockedSources.formUnion(other.blockedSources)
            stoppedByPolicy = stoppedByPolicy || other.stoppedByPolicy
        }
    }

    /// Checks up to `maxConcurrentSources` sources at once, each one series at a time.
    private func check(_ queues: [[LibraryItem]], operation: PluginNetworkOperation, kind: UpdateRunKind) async -> QueueWalk {
        await withTaskGroup(of: QueueWalk.self) { group in
            var remaining = queues.makeIterator()
            for _ in 0..<Self.maxConcurrentSources {
                guard let queue = remaining.next() else { break }
                group.addTask { await self.check(queue: queue, operation: operation, kind: kind) }
            }
            var walk = QueueWalk()
            for await result in group {
                walk.absorb(result)
                if let queue = remaining.next() {
                    group.addTask { await self.check(queue: queue, operation: operation, kind: kind) }
                }
            }
            return walk
        }
    }

    /// Re-evaluated before every series, not just once at the beginning of a scheduled run. A path that has not been
    /// reported yet is awaited rather than read as offline, so a cold background launch is not skipped by timing. The
    /// wait ends with the run's task, which the background task's expiration cancels.
    private func automaticChecksAdmitted() async -> Bool {
        guard let settingsStore else { return false }
        let policy = settingsStore.networkPolicy
        let path: NetworkPathSnapshot
        if let observed = policy.observedPath {
            guard observed.status != .unknown else {
                guard let reported = await policy.firstKnownPath() else { return false }
                return policy.decide(.automaticMetadata, path: reported) == .allow
            }
            path = observed
        } else {
            path = NetworkPathSnapshot(status: .satisfied, isExpensive: await !networkConditions.isOnUnmeteredNetwork())
        }
        return policy.decide(.automaticMetadata, path: path) == .allow
    }

    private func check(queue: [LibraryItem], operation: PluginNetworkOperation, kind: UpdateRunKind) async -> QueueWalk {
        var walk = QueueWalk()
        for (index, item) in queue.enumerated() {
            if index > 0, sourcePacingNanoseconds > 0 {
                // Spread requests to one source out; stop when the run is cancelled.
                do {
                    try await Task.sleep(nanoseconds: sourcePacingNanoseconds)
                } catch {
                    break
                }
            }
            // Checked right before each series starts, after any pause.
            if Task.isCancelled { break }
            if let runDeadline, now() >= runDeadline {
                AppLogger.update.debug("🔄 [UpdateManager] Time budget used up, leaving the rest for the next run.")
                break
            }
            if operation.purpose == .automaticLibraryUpdate, await !automaticChecksAdmitted() {
                walk.stoppedByPolicy = true
                break
            }
            let single = await checkSingleItem(item, operation: operation, reportsFailures: kind != .subscriptions)
            if let delta = single.delta, delta > 0 {
                walk.updated.append((item, delta))
            }
            walk.checked += 1
            // A check the run's cancellation cut short committed nothing, so it did not happen as far as the rule goes.
            if !Task.isCancelled { walk.attempted.append(item.mediaIdentity) }
            // A subscription pass keeps to the user-visible counters of a library run: it never lights them up.
            if kind != .subscriptions { itemsCheckedCurrentRun += 1 }
            // A source that needs the person (settings, a sign-in, a trust decision) is not asked again this pass. The
            // rest of its series stay due. A library run keeps going, as it always did.
            if kind == .subscriptions, single.sourceNeedsAttention {
                walk.blockedSources.insert(item.pluginId)
                break
            }
        }
        return walk
    }

    /// The outcome of checking one series: the chapters new in the check, and whether a failure shows the source cannot
    /// answer until the person acts.
    private struct SingleCheck {
        var delta: Int?
        var sourceNeedsAttention = false
    }

    private func checkSingleItem(
        _ item: LibraryItem,
        operation: PluginNetworkOperation,
        reportsFailures: Bool
    ) async -> SingleCheck {
        guard let updateSource else { return SingleCheck() }
        AppLogger.update.debug("🔄 [UpdateManager] Checking a library series.")
        // A subscribed manga or novel gets a check ticket before the fetch, so the one answer is also its catalog.
        let sink = item.effectiveType == .anime ? nil : subscriptionSink
        let ticket = await sink?.begin(media: item.mediaIdentity)
        var observation: Result<CatalogObservation, SubscriptionCheckOutcome>?
        var fetched = false
        var cancelled = false
        var failure: (any Error)?
        let delta = await processUpdate(for: item, checkedAt: now(), reportsFailures: reportsFailures) {
            do {
                let update = try await updateSource.fetchUpdate(for: item, operation: operation, frozenScope: ticket?.sourceEpoch)
                fetched = true
                observation = update.catalog
                return update
            } catch is CancellationError {
                cancelled = true
                throw CancellationError()
            } catch {
                failure = error
                throw error
            }
        }
        // The ledger commits in its own transaction, after the badge and count write above.
        if let sink, let ticket {
            switch observation {
            case .success(let catalog)?: await sink.commit(ticket, catalog)
            case .failure(let outcome)?: await sink.fail(ticket, outcome)
            case nil: if !fetched, !cancelled, !Task.isCancelled { await sink.fail(ticket, .fetchFailed) }
            }
        }
        var single = SingleCheck(delta: delta)
        if let failure, !Task.isCancelled {
            let kind = (failure as? PluginCallError)?.kind
            single.sourceNeedsAttention = kind == .needsSettings || kind == .needsLogin
                || updateSource.pendingTrust(for: item.pluginId) != nil
        }
        return single
    }

    internal struct SuccessfulUpdate: Sendable {
        let freshCount: Int
        let status: String?
        /// The chapter catalog of a manga or novel answer: set when the check froze a source scope for a subscription.
        /// A failure names why the answer is not an observation (oversized, unsupported kind).
        var catalog: Result<CatalogObservation, SubscriptionCheckOutcome>?
    }

    /// Persists a fetched update and derives badge state only from committed database state. New
    /// chapters add to the series' unread badge, which stays until the series is opened or cleared.
    /// A failed fetch records only the attempt time, so the series moves behind others next time.
    /// - Parameter reportsFailures: whether a failed fetch is listed in `sourceFailures`. A subscription pass sets it
    ///   false: its failures are a rule's own, and must not appear on, or replace, the Library refresh's banner.
    /// - Returns: The chapters new in this check, or `nil` when nothing was recorded.
    internal func processUpdate(
        for item: LibraryItem,
        checkedAt: Date = Date(),
        reportsFailures: Bool = true,
        fetchUpdate: () async throws -> SuccessfulUpdate
    ) async -> Int? {
        let update: SuccessfulUpdate
        do {
            update = try await fetchUpdate()
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            if reportsFailures {
                let failure = LibraryUpdateFailure(
                    pluginID: item.pluginId,
                    reason: error.localizedDescription,
                    needsSettings: (error as? PluginCallError)?.kind == .needsSettings,
                    needsLogin: (error as? PluginCallError)?.kind == .needsLogin,
                    pendingTrust: updateSource?.pendingTrust(for: item.pluginId)
                )
                if let index = sourceFailures.firstIndex(where: { $0.pluginID == item.pluginId }) {
                    // Keep one row per source, preferring an actionable failure (settings or sign-in).
                    if failure.isActionable && !sourceFailures[index].isActionable {
                        sourceFailures[index] = failure
                    }
                } else {
                    sourceFailures.append(failure)
                }
            }
            AppLogger.update.error("🔄 [UpdateManager] A source update fetch failed.")
            await recordFailedAttempt(for: item.id, at: checkedAt)
            return nil
        }
        do {
            let media = item.mediaIdentity
            let committed = try await dbPool.write { db -> (
                oldCount: Int?,
                delta: Int,
                unread: Int,
                itemWasMissing: Bool
            ) in
                let badge = UpdateBadgeRecord
                    .filter(Column("pluginId") == media.pluginId)
                    .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                    .filter(Column("mediaKind") == media.mediaKind.rawValue)
                guard var dbItem = try LibraryItem.fetchOne(db, key: item.id) else {
                    _ = try LibraryItem.deleteOne(db, key: item.id)
                    try badge.deleteAll(db)
                    return (nil, 0, 0, true)
                }

                let oldCount = dbItem.knownChapterCount
                // A source that refuses or fails a request can still answer with an empty list.
                // That is not evidence its chapters are gone: it never replaces a known nonempty
                // baseline (or its status) and never establishes the exact-key basis. With no
                // known nonempty baseline an empty answer is recorded as before (count 0, status).
                let refusedEmpty = update.freshCount == 0 && (oldCount ?? 0) > 0
                let matchedBasis = dbItem.effectiveType == .anime
                    || dbItem.knownChapterCountBasis == .exactChapterKeys
                let delta = !refusedEmpty && matchedBasis
                    ? oldCount.map { max(0, update.freshCount - $0) } ?? 0
                    : 0
                if !refusedEmpty {
                    dbItem.knownChapterCount = update.freshCount
                    if dbItem.effectiveType != .anime && update.freshCount > 0 {
                        dbItem.knownChapterCountBasis = .exactChapterKeys
                    }
                    if let status = update.status {
                        dbItem.status = status
                    }
                }
                dbItem.lastCheckedAt = checkedAt
                if delta > 0 {
                    dbItem.lastUpdatedAt = checkedAt
                }
                try dbItem.update(db)
                var unread = try badge.fetchOne(db)?.count ?? 0
                if delta > 0 {
                    unread += delta
                    try UpdateBadgeRecord(
                        pluginId: media.pluginId,
                        canonicalMediaId: media.canonicalMediaId,
                        mediaKind: media.mediaKind,
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
                "🔄 [UpdateManager] \(String(describing: committed.oldCount)) known, \(update.freshCount) fresh/persisted -> \(committed.delta) new, \(committed.unread) unread"
            )
            if committed.unread > 0 {
                newChapterCounts[media] = committed.unread
            } else {
                newChapterCounts.removeValue(forKey: media)
            }
            return committed.delta
        } catch {
            AppLogger.update.error("🔄 [UpdateManager] Failed to save an update check.")
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
            AppLogger.update.error("🔄 [UpdateManager] Failed to record a failed check.")
        }
    }

    // MARK: - State Management

    public func badgeCount(for media: MediaIdentity) -> Int {
        max(0, newChapterCounts[media] ?? 0)
    }

    public var totalBadgeCount: Int {
        newChapterCounts.values.reduce(0, +)
    }

    public func advanceBaseline(media: MediaIdentity, knownChapterCount: Int) async throws {
        guard knownChapterCount > 0 else { return }
        try await dbPool.write { db in
            let candidateIDs = ImportedMediaIdentity.localItemIDs(
                pluginId: media.pluginId,
                canonicalMediaId: media.canonicalMediaId,
                mediaKind: media.mediaKind
            )
            for id in candidateIDs {
                guard var item = try LibraryItem.fetchOne(db, key: id),
                      item.pluginId == media.pluginId,
                      item.effectiveType == media.mediaKind else { continue }
                item.knownChapterCount = knownChapterCount
                if item.effectiveType != .anime {
                    item.knownChapterCountBasis = .exactChapterKeys
                }
                try item.update(db)
                break
            }
            try UpdateBadgeRecord
                .filter(Column("pluginId") == media.pluginId)
                .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                .filter(Column("mediaKind") == media.mediaKind.rawValue)
                .deleteAll(db)
        }
        newChapterCounts.removeValue(forKey: media)
    }

    public func clearBadge(for media: MediaIdentity) async throws {
        _ = try await dbPool.write { db in
            try UpdateBadgeRecord
                .filter(Column("pluginId") == media.pluginId)
                .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                .filter(Column("mediaKind") == media.mediaKind.rawValue)
                .deleteAll(db)
        }
        newChapterCounts.removeValue(forKey: media)
    }

    /// Drops the badges of series removed from the library; their rows were deleted with them.
    func forgetBadges(for media: [MediaIdentity]) {
        for identity in media {
            newChapterCounts.removeValue(forKey: identity)
        }
    }

    /// Publishes the stored badges of series in the library. Rows left by series removed before
    /// removal deleted their badge, or restored without their series, are not counted.
    public func reload() async throws {
        let (records, libraryItems) = try await dbPool.read { db in
            (
                try UpdateBadgeRecord.fetchAll(db),
                try LibraryItem.fetchAll(db)
            )
        }
        let library = Set(libraryItems.map(\.mediaIdentity))
        newChapterCounts = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            let media = MediaIdentity(
                pluginId: record.pluginId,
                canonicalMediaId: record.canonicalMediaId,
                mediaKind: record.mediaKind
            )
            return library.contains(media) ? (media, max(0, record.count)) : nil
        })
    }
}
