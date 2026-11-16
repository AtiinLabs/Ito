import Combine
import Foundation
import GRDB
import OSLog

/// What Maintain Next N reads of a series: the last chapter read and how many exact chapters are marked read. A change
/// moves the window, so the rule is decided again. A page position does not change either value.
nonisolated struct MaintainReadState: Equatable, Sendable {
    let subscriptionId: String
    let lastReadChapterKey: String?
    let readKeyCount: Int

    static func fetchAll(in db: Database) throws -> [MaintainReadState] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT s.id AS subscriptionId,
                       p.lastReadChapterKey AS lastReadChapterKey,
                       (SELECT COUNT(*) FROM readProgressKey k
                        WHERE k.pluginId = s.pluginId AND k.mediaKind = s.mediaKind
                          AND k.canonicalMediaId = s.canonicalMediaId) AS readKeyCount
                FROM seriesSubscription s
                LEFT JOIN mediaReadProgress p
                  ON p.pluginId = s.pluginId AND p.mediaKind = s.mediaKind AND p.canonicalMediaId = s.canonicalMediaId
                WHERE s.state = 'enabled' AND s.mode = 'maintainNextUnread'
                ORDER BY s.id
                """
        ).map { row in
            MaintainReadState(
                subscriptionId: row["subscriptionId"],
                lastReadChapterKey: row["lastReadChapterKey"],
                readKeyCount: row["readKeyCount"]
            )
        }
    }
}

/// The foreground scheduler of automatic downloads. It decides when a check of subscribed series runs and when local
/// drains do, and owns nothing else: the fetch is the update manager's, every ledger write is the store's.
///
/// Triggers are exactly these: becoming active (bootstrap and every return to the foreground), a Library refresh that
/// ended, and a rule the person enabled, edited or resumed. Nothing is a timer, and nothing calls it from a view. A
/// request while inactive is dropped: activation plans again from durable state. One pass runs at a time; requests that
/// arrive during it make one more pass at its end. A pass waits until the store is reconciled, and never runs while a
/// library refresh does: a refresh cancels it and its own checks count for due scheduling.
///
/// Drains are local database work, never network. They run while active, one at a time, with a dirty flag.
@MainActor
final class SubscriptionCheckScheduler {
    enum Trigger: Sendable, Equatable {
        case activation
        case ruleChanged(String)
        case libraryRunFinished
    }

    enum DrainScope: Sendable, Equatable {
        /// Every rule that can have work: waiting events and the windows of Maintain Next N. Activation drains this.
        case all
        /// The rules whose events wait for queue or disk room, after room came free. Maintain Next N follows the reader.
        case room
        case subscription(String)
    }

    private let store: OfflineChapterStore
    private let center: DownloadCenter
    private let updates: UpdateManager
    private let dbPool: DatabasePool
    private let interval: @MainActor () -> TimeInterval
    private let now: () -> Date
    private let readRows: @MainActor () async throws -> [SubscriptionScheduleRow]

    private(set) var isActive = false
    private var isReconciled: Bool
    /// Rules a person just changed, checked in the next pass whatever their due time. In memory only.
    private var forced = Set<String>()
    /// How many times each rule was forced. A refresh covers a forced rule only if it was not forced again since the
    /// refresh began: a rule changed after its series was fetched keeps its immediate check.
    private var forceGeneration: [String: Int] = [:]
    private var passTask: Task<Void, Never>?
    private var runTask: Task<SubscriptionCheckRunResult, Never>?
    /// A request arrived during the pass: one more pass runs when it ends.
    private var rerunRequested = false
    /// A pass wanted to start while another run held the update manager; it starts when that run ends.
    private var waitingForRun = false
    /// A request arrived before the store was reconciled; the pass starts when it is.
    private var pendingAfterReconcile = false
    /// Sources that need the person (a sign-in, settings, a trust decision). They are left out of every pass until the
    /// scheduler becomes active again: asking again changes nothing, and their rules must not hold back the others.
    private var blockedSources = Set<String>()
    /// What a manual refresh covered: the generation of each rule forced when it began, and the series it attempted.
    private(set) var manualCover: (forced: [String: Int], media: Set<MediaIdentity>)?
    /// The forced rules, as they were when the running manual refresh began.
    private(set) var manualStartForced: [String: Int]?

    private var drainTask: Task<Void, Never>?
    /// How many coalesced drain batches have started: one however many requests were merged into it. For tests.
    private(set) var drainBatches = 0
    private var drainAll = false
    private var drainRoom = false
    private var drainIds = Set<String>()

    private var readStateObservation: DatabaseCancellable?
    private var lastReadStates: [String: MaintainReadState]?
    private var subscriptions = Set<AnyCancellable>()
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - interval: how long a checked rule waits, from the configured update interval.
    ///   - limitsChanged: fires after the settings store has stored new automatic limits, which may make room.
    ///   - now: the clock due times are judged by.
    init(
        store: OfflineChapterStore,
        center: DownloadCenter,
        coordinator: DownloadQueueCoordinator,
        updates: UpdateManager,
        dbPool: DatabasePool,
        interval: @escaping @MainActor () -> TimeInterval,
        limitsChanged: AnyPublisher<Void, Never>,
        now: @escaping () -> Date,
        scheduleRows: (@MainActor () async throws -> [SubscriptionScheduleRow])? = nil
    ) {
        self.store = store
        self.center = center
        self.updates = updates
        self.dbPool = dbPool
        self.interval = interval
        self.now = now
        self.readRows = scheduleRows ?? { try await store.subscriptionScheduleRows() }
        isReconciled = coordinator.isReconciled

        coordinator.reconciled
            .sink { @MainActor [weak self] in self?.didReconcile() }
            .store(in: &subscriptions)
        updates.runStarted
            .sink { @MainActor [weak self] kind in self?.runStarted(kind) }
            .store(in: &subscriptions)
        updates.runFinished
            .sink { @MainActor [weak self] kind in self?.runFinished(kind) }
            .store(in: &subscriptions)
        limitsChanged
            .sink { @MainActor [weak self] in self?.requestDrain(.room) }
            .store(in: &subscriptions)
        center.onAutomaticCapacityChanged = { [weak self] in self?.requestDrain(.room) }
    }

    // MARK: - Lifecycle

    /// The scheduler runs only in the foreground, after bootstrap. Becoming active plans from durable state: one pass
    /// and one drain of every rule that can have work. Becoming inactive cancels the pass's checks, and forgets what
    /// was waiting. The pass itself ends at its next look at `isActive`.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            blockedSources = []
            request(.activation)
            requestDrain(.all)
        } else {
            forced = []
            manualCover = nil
            manualStartForced = nil
            rerunRequested = false
            waitingForRun = false
            pendingAfterReconcile = false
            drainAll = false
            drainRoom = false
            drainIds = []
            runTask?.cancel()
        }
    }

    /// Asks for a pass over the rules that are due. Dropped while inactive.
    func request(_ trigger: Trigger) {
        guard isActive else { return }
        if case .ruleChanged(let id) = trigger {
            forced.insert(id)
            forceGeneration[id, default: 0] += 1
        }
        guard isReconciled else {
            pendingAfterReconcile = true
            return
        }
        if passTask != nil {
            rerunRequested = true
        } else {
            startPass()
        }
    }

    /// Asks for a drain of the events that wait for room or follow the reader. Dropped while inactive.
    func requestDrain(_ scope: DrainScope) {
        guard isActive else { return }
        switch scope {
        case .all: drainAll = true
        case .room: drainRoom = true
        case .subscription(let id): drainIds.insert(id)
        }
        startDrainIfNeeded()
    }

    /// Suspends until no pass and no drain is running. Tests use it to observe the end of the work they started; the
    /// app never waits on it.
    func untilIdle() async {
        guard passTask != nil || drainTask != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - Observation

    /// Observes what Maintain Next N reads of each series, and drains the rule whose window moved. The first value only
    /// sets the baseline: activation drains every such rule once.
    func startObservingReadState<Scheduler: ValueObservationMainActorScheduler>(scheduling scheduler: Scheduler) {
        let observation = ValueObservation
            .tracking { db in try MaintainReadState.fetchAll(in: db) }
            .removeDuplicates()
        readStateObservation = observation.start(
            in: dbPool,
            scheduling: scheduler,
            onError: { _ in AppLogger.database.error("Maintain read state observation failed") },
            onChange: { [weak self] states in self?.readStatesChanged(states) }
        )
    }

    private func readStatesChanged(_ states: [MaintainReadState]) {
        let current = Dictionary(uniqueKeysWithValues: states.map { ($0.subscriptionId, $0) })
        let previous = lastReadStates
        lastReadStates = current
        guard let previous else { return }
        for id in current.keys.sorted() where previous[id] != current[id] {
            requestDrain(.subscription(id))
        }
    }

    // MARK: - Reactions

    private func didReconcile() {
        isReconciled = true
        guard isActive else { return }
        if pendingAfterReconcile {
            pendingAfterReconcile = false
            request(.libraryRunFinished)
        }
        startDrainIfNeeded()
    }

    private func runStarted(_ kind: UpdateRunKind) {
        guard kind == .manual else { return }
        manualStartForced = Dictionary(uniqueKeysWithValues: forced.map { ($0, forceGeneration[$0] ?? 0) })
    }

    private func runFinished(_ kind: UpdateRunKind) {
        // A refresh the person asked for counts as a check, so what it left due is checked now. A pass that could not
        // start because a run held the manager starts when that run ends, whichever kind it was.
        if kind == .manual {
            // A refresh that checked a source successfully shows it no longer needs the person.
            blockedSources.subtract(updates.lastRunSucceeded.map(\.pluginId))
            if let start = manualStartForced {
                manualCover = (start, Set(updates.lastRunAttempted))
            }
            manualStartForced = nil
        }
        guard kind == .manual || waitingForRun else { return }
        waitingForRun = false
        request(.libraryRunFinished)
    }

    // MARK: - The pass

    private func startPass() {
        passTask = Task { [weak self] in await self?.runPass() }
    }

    /// Whether the pass goes on after a run. A run the policy refused would be refused again at once, unless it was
    /// refused only because it was cancelled: then a request made meanwhile (a reactivation) must not be lost. A source
    /// that needed the person ended its queue early, so the other rules still due are checked now; each such round
    /// blocks one more source, so the rounds are bounded by the number of sources.
    nonisolated static func goesOn(after result: SubscriptionCheckRunResult, rerunRequested: Bool) -> Bool {
        if result.stoppedByPolicy && !result.cancelled { return false }
        if rerunRequested { return true }
        return !result.cancelled && !result.blockedSources.isEmpty
    }

    private func runPass() async {
        defer {
            passTask = nil
            runTask = nil
            settleIfIdle()
        }
        while isActive {
            rerunRequested = false
            // A read that fails is a pass with nothing due; a request that arrived during it still gets its look.
            let rows = (try? await readRows()) ?? []
            guard isActive else { return }
            if let cover = manualCover {
                manualCover = nil
                let covered = rows.filter { row in
                    guard let generation = cover.forced[row.id] else { return false }
                    return cover.media.contains(row.media) && forceGeneration[row.id] == generation
                }
                forced.subtract(covered.map(\.id))
            }
            // A rule that was changed is a reason to ask its source again, whatever it said before.
            for row in rows where forced.contains(row.id) { blockedSources.remove(row.media.pluginId) }
            let installed = updates.installedPluginIDs
            let blocked = blockedSources
            let due = SubscriptionSchedule.duePass(rows, forced: forced, interval: interval(), now: now()) { row in
                installed.contains(row.media.pluginId) && !blocked.contains(row.media.pluginId)
            }
            guard !due.isEmpty else {
                if rerunRequested { continue }
                return
            }
            guard let run = updates.startSubscriptionChecks(due.map(\.media)) else {
                waitingForRun = true
                return
            }
            runTask = run
            let result = await run.value
            runTask = nil
            // A forced rule is forgotten once it was attempted; one the pass did not reach is still due.
            let attempted = Set(result.attempted)
            forced.subtract(due.filter { attempted.contains($0.media) }.map(\.id))
            blockedSources.formUnion(result.blockedSources)
            guard isActive, Self.goesOn(after: result, rerunRequested: rerunRequested) else { return }
        }
    }

    // MARK: - Drains

    private func startDrainIfNeeded() {
        guard isActive, isReconciled, drainTask == nil, drainAll || drainRoom || !drainIds.isEmpty else { return }
        drainTask = Task { [weak self] in await self?.runDrains() }
    }

    private func runDrains() async {
        defer {
            drainTask = nil
            settleIfIdle()
        }
        while isActive, drainAll || drainRoom || !drainIds.isEmpty {
            drainBatches += 1
            var ids = drainIds
            let all = drainAll
            let room = drainRoom
            drainAll = false
            drainRoom = false
            drainIds = []
            if all || room, let drainable = try? await store.drainableSubscriptionIds(includingMaintain: all) {
                ids.formUnion(drainable)
            }
            for id in ids.sorted() {
                guard isActive else { return }
                _ = try? await center.drainSubscriptionEvents(subscriptionId: id)
            }
        }
    }

    private func settleIfIdle() {
        guard passTask == nil, drainTask == nil else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
