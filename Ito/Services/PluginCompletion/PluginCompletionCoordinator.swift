import Combine
import Foundation

/// The durable queue could not be read or updated. Fixed text: no SQL, path, remote URL or
/// credential is carried, and an action that throws this changed nothing it claims to have changed.
nonisolated enum PluginCompletionRecoveryError: Error, Equatable, Sendable, LocalizedError {
    case queueUnavailable

    var errorDescription: String? {
        "The queued read progress could not be read or updated."
    }
}

/// Delivers queued read completions to their sources, in the background of the running app.
///
/// Everything is event-driven. The dispatcher evaluates when it is woken (an enqueue, a change to
/// the durable queue or a source's authorization scope, readiness or foreground via `start`, the
/// network coming back, an explicit recovery action, a lane finishing) and when the one durable
/// retry deadline it waits for arrives. It never polls.
///
/// - Per source, intents are delivered strictly one at a time in creation order; the store never
///   offers a later intent while an earlier one is backed off.
/// - At most `maxConcurrentPlugins` sources deliver at once.
/// - Cancellation is real: suspending or cancelling a source cancels its in-flight attempt, which
///   leaves its intent pending with no failure counted against it.
@MainActor
final class PluginCompletionCoordinator: ObservableObject, PluginCompletionRecovering {
    static let maxConcurrentPlugins = 2
    private static let dueBatchLimit = 32
    private static let repassLimit = 2

    /// Pending and paused counts per source, as of the last read of the queue.
    @Published private(set) var summaries: [PluginCompletionSummary] = []
    /// Set while the durable queue cannot be read or updated; cleared by the next successful
    /// evaluation. Nothing is claimed delivered or discarded while it is set.
    @Published private(set) var failure: PluginCompletionRecoveryError?

    var completionSummariesPublisher: AnyPublisher<[PluginCompletionSummary], Never> {
        $summaries.eraseToAnyPublisher()
    }

    /// The durable retry deadline being waited for, if any.
    var scheduledDeadline: Date? { deadline?.date }

    private struct Lane {
        let id: UInt64
        let task: Task<Void, Never>
    }

    private struct Deadline {
        let date: Date
        let task: Task<Void, Never>
    }

    private enum AttemptResult {
        case recorded, cancelled, storeFailed
    }

    private enum Evaluation {
        case settled, dueWithNothingRunning
    }

    private struct SettleWaiter {
        let includesAttempts: Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private let store: PluginCompletionStore
    private let executor: any PluginCompletionExecuting
    private let scheduler: any PluginCompletionScheduling
    private let connectivity: any PluginCompletionConnectivityMonitoring

    private var isStarted = false
    /// Bumped by every start and suspend, so work begun in an earlier run cannot act in a later one.
    private var generation: UInt64 = 0
    private var observation: PluginCompletionObservation?
    private var evaluation: Task<Void, Never>?
    private var wakeRequested = false
    /// One in-flight attempt per source. A suspended lane stays here until it has really
    /// unwound, so a restart cannot run a source twice at once.
    private var lanes: [String: Lane] = [:]
    private var nextLaneID: UInt64 = 0
    private var deadline: Deadline?
    private var summaryTicket: UInt64 = 0
    private var appliedSummaryTicket: UInt64 = 0
    private var settleWaiters: [SettleWaiter] = []

    init(
        store: PluginCompletionStore,
        executor: any PluginCompletionExecuting,
        scheduler: any PluginCompletionScheduling = SystemPluginCompletionScheduler(),
        connectivity: any PluginCompletionConnectivityMonitoring = NetworkPathCompletionMonitor()
    ) {
        self.store = store
        self.executor = executor
        self.scheduler = scheduler
        self.connectivity = connectivity
    }

    // MARK: - Lifecycle

    /// Begins observing the queue and the network, and evaluates. Safe to call repeatedly: each
    /// call after the first is just a wake (for example on returning to the foreground).
    func start() {
        if !isStarted {
            isStarted = true
            generation &+= 1
            // Fired on the database writer thread after a commit: hop to the main actor, read nothing.
            observation = store.observeChanges { [weak self] in
                Task { @MainActor in self?.wake() }
            }
            connectivity.start { [weak self] in self?.wake() }
        }
        wake()
    }

    /// Requests an evaluation. Requests made while one runs are coalesced into a single further pass.
    func wake() {
        guard isStarted else { return }
        wakeRequested = true
        guard evaluation == nil else { return }
        let token = generation
        evaluation = Task { [weak self] in
            await self?.runEvaluations(generation: token)
        }
    }

    /// Stops observing, cancels in-flight attempts and the deadline wait, and starts nothing
    /// until `start()`. No intent is deleted or altered: cancelled attempts leave their rows pending
    /// with no failure counted.
    func suspend() {
        isStarted = false
        generation &+= 1
        wakeRequested = false
        observation = nil
        connectivity.stop()
        evaluation?.cancel()
        evaluation = nil
        cancelDeadline()
        for lane in lanes.values { lane.task.cancel() }
        notifySettled()
    }

    /// Cancels the in-flight attempt of one source, or of every source for nil, without touching
    /// any intent. This interrupts delivery; it is not a pause: use `suspend()` for that. A
    /// source whose intents were deleted first (removal) has nothing left to deliver.
    func cancel(for pluginID: String?) {
        if let pluginID {
            lanes[pluginID]?.task.cancel()
        } else {
            for lane in lanes.values { lane.task.cancel() }
        }
    }

    // MARK: - Recovery

    /// The user's confirmation to send a source's paused progress to the server and account
    /// configured now. Throws `CancellationError` only when nothing changed.
    func reauthorize(pluginID: String) async throws {
        try await applyRecovery { store, now in
            try await store.reauthorizePaused(pluginID: pluginID, now: now)
        }
    }

    /// Deletes a source's paused progress without sending it. Pending rows are never touched.
    func discard(pluginID: String) async throws {
        try await applyRecovery { store, _ in
            try await store.discardPaused(pluginID: pluginID)
        }
    }

    private func applyRecovery(_ change: (PluginCompletionStore, Date) async throws -> Void) async throws {
        do {
            try await change(store, scheduler.now())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            setFailure(.queueUnavailable)
            throw PluginCompletionRecoveryError.queueUnavailable
        }
        // Committed. Reflect it even if the caller is cancelled from here on.
        wake()
        await Task { await self.refreshSummariesAfterRecovery() }.value
    }

    private func refreshSummariesAfterRecovery() async {
        do {
            try await refreshSummaries()
        } catch {
            setFailure(.queueUnavailable)
        }
    }

    // MARK: - Quiescence

    /// Returns once nothing is running, queued for evaluation, or due. A deadline still in the
    /// future does not count as work. Lets callers and tests wait for the dispatcher to settle
    /// without sleeping.
    func waitUntilIdle() async {
        await wait(includingAttempts: true)
    }

    /// Like `waitUntilIdle()`, but attempts that are still running do not hold it: it returns
    /// once every requested evaluation has finished, so a caller can know the dispatcher has
    /// looked at the queue while an attempt was in flight.
    func waitUntilEvaluated() async {
        await wait(includingAttempts: false)
    }

    private func wait(includingAttempts: Bool) async {
        guard !isSettled(includingAttempts: includingAttempts) else { return }
        await withCheckedContinuation {
            settleWaiters.append(SettleWaiter(includesAttempts: includingAttempts, continuation: $0))
        }
    }

    private func isSettled(includingAttempts: Bool) -> Bool {
        evaluation == nil && !wakeRequested && !deadlineIsDue && (!includingAttempts || lanes.isEmpty)
    }

    private var deadlineIsDue: Bool {
        guard let deadline else { return false }
        return deadline.date <= scheduler.now()
    }

    private func notifySettled() {
        guard !settleWaiters.isEmpty else { return }
        let ready = settleWaiters.filter { isSettled(includingAttempts: $0.includesAttempts) }
        guard !ready.isEmpty else { return }
        settleWaiters.removeAll { isSettled(includingAttempts: $0.includesAttempts) }
        for waiter in ready { waiter.continuation.resume() }
    }

    // MARK: - Evaluation

    private func isCurrent(_ token: UInt64) -> Bool {
        isStarted && generation == token
    }

    /// Publishes only a change, so observers are not notified by every unchanged evaluation.
    private func setFailure(_ newValue: PluginCompletionRecoveryError?) {
        if failure != newValue { failure = newValue }
    }

    private func runEvaluations(generation token: UInt64) async {
        var repasses = 0
        while wakeRequested, isCurrent(token) {
            wakeRequested = false
            let result = await evaluate(generation: token)
            guard isCurrent(token) else { return }
            if result == .dueWithNothingRunning, repasses < Self.repassLimit {
                repasses += 1
                wakeRequested = true
            } else if result == .settled {
                repasses = 0
            }
        }
        guard isCurrent(token) else { return }
        evaluation = nil
        notifySettled()
    }

    /// One pass: start a lane for every source that has a due intent and a free slot, publish the
    /// queue's counts, and wait for the earliest future retry deadline.
    private func evaluate(generation token: UInt64) async -> Evaluation {
        do {
            guard connectivity.isReachable else {
                // Offline attempts would only spend the bounded retry budget; the network
                // returning wakes the dispatcher.
                try await refreshSummaries()
                cancelDeadline()
                setFailure(nil)
                return .settled
            }
            let due = try await store.dueIntents(now: scheduler.now(), limit: Self.dueBatchLimit)
            guard isCurrent(token) else { return .settled }
            var started = false
            for intent in due where lanes.count < Self.maxConcurrentPlugins && lanes[intent.pluginId] == nil {
                startLane(for: intent)
                started = true
            }
            try await refreshSummaries()
            let next = try await store.nextAttemptDate()
            guard isCurrent(token) else { return .settled }
            setFailure(nil)
            return arm(next, started: started)
        } catch is CancellationError {
            return .settled
        } catch {
            if isCurrent(token) { setFailure(.queueUnavailable) }
            return .settled
        }
    }

    private func arm(_ next: Date?, started: Bool) -> Evaluation {
        guard let next else {
            cancelDeadline()
            return .settled
        }
        if next > scheduler.now() {
            scheduleDeadline(at: next)
            return .settled
        }
        // Something is due right now. A lane that is running, or just started, evaluates again
        // when it finishes; with none, evaluate once more rather than leave it waiting.
        return started || !lanes.isEmpty ? .settled : .dueWithNothingRunning
    }

    private func refreshSummaries() async throws {
        summaryTicket &+= 1
        let ticket = summaryTicket
        let latest = try await store.summaries()
        // Reads that began later saw at least as much; never let an earlier read overwrite one.
        guard ticket > appliedSummaryTicket else { return }
        appliedSummaryTicket = ticket
        if latest != summaries { summaries = latest }
    }

    // MARK: - Deadline

    private func scheduleDeadline(at date: Date) {
        if deadline?.date == date { return }
        cancelDeadline()
        let scheduler = scheduler
        let token = generation
        let task = Task { [weak self] in
            do {
                try await scheduler.sleep(until: date)
            } catch {
                return
            }
            self?.deadlineElapsed(generation: token, date: date)
        }
        deadline = Deadline(date: date, task: task)
    }

    private func cancelDeadline() {
        deadline?.task.cancel()
        deadline = nil
    }

    private func deadlineElapsed(generation token: UInt64, date: Date) {
        guard isCurrent(token), deadline?.date == date else { return }
        deadline = nil
        wake()
    }

    // MARK: - Lanes

    private func startLane(for intent: PluginCompletionIntent) {
        nextLaneID &+= 1
        let laneID = nextLaneID
        let task = Task<Void, Never> { [weak self] in
            await self?.runLane(intent, laneID: laneID)
        }
        lanes[intent.pluginId] = Lane(id: laneID, task: task)
    }

    private func runLane(_ intent: PluginCompletionIntent, laneID: UInt64) async {
        let result = await deliver(intent)
        if lanes[intent.pluginId]?.id == laneID { lanes[intent.pluginId] = nil }
        if result == .storeFailed {
            // Evaluating again would only fail again; the next event retries.
            setFailure(.queueUnavailable)
        } else {
            wake()
        }
        notifySettled()
    }

    private func deliver(_ intent: PluginCompletionIntent) async -> AttemptResult {
        let begun: PluginCompletionAttempt?
        do {
            begun = try await store.beginAttempt(intent, now: scheduler.now())
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .storeFailed
        }
        // Superseded between being listed and being started: nothing to deliver.
        guard let attempt = begun else { return .recorded }
        if Task.isCancelled { return .cancelled }

        var outcome = await executor.execute(intent: intent)
        if case .cancelled = outcome {
            if Task.isCancelled { return .cancelled }
            // An executor must not report cancellation it was not given. Back off instead of
            // retrying at once, so a misbehaving executor cannot spin the dispatcher.
            outcome = .retryable(.sourceError)
        }

        // A delivery outcome is recorded even if this lane was cancelled meanwhile: a source that
        // already acknowledged must not be sent the same completion again.
        let recorded = outcome
        let queue = store
        let clock = scheduler
        do {
            try await Task { try await queue.finish(attempt, outcome: recorded, now: clock.now()) }.value
            return .recorded
        } catch {
            return .storeFailed
        }
    }
}
