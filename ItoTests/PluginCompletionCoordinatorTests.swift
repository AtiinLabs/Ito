import Combine
import Foundation
import GRDB
import Testing
@testable import Ito

/// When the oldest queued intents were created.
private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
/// Where the manual clock starts: after every intent queued at `baseDate...`, so those are due.
private let clockStart = baseDate.addingTimeInterval(1_000)

@MainActor
struct PluginCompletionCoordinatorTests {
    // MARK: - Delivery

    @Test func acknowledgedIntentsAreRemovedAndTheQueueSummaryClears() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1")

        fixture.coordinator.start()
        await fixture.coordinator.waitUntilIdle()

        #expect(fixture.executor.calls == [.init(plugin: "plugin.a", unit: "chapter-1")])
        #expect(try fixture.rows().isEmpty)
        #expect(fixture.coordinator.summaries.isEmpty)
        #expect(fixture.coordinator.failure == nil)
        #expect(fixture.coordinator.scheduledDeadline == nil)
    }

    @Test func nothingIsDeliveredUntilTheCoordinatorIsStarted() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1")

        fixture.coordinator.wake()
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.executor.calls.isEmpty)

        fixture.coordinator.start()
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.executor.calls.count == 1)
        #expect(try fixture.rows().isEmpty)
    }

    @Test func intentsOfOneSourceAreDeliveredOneAtATimeInCreationOrder() async throws {
        let gates = GateBook()
        let fixture = try CoordinatorFixture { intent in
            await gates.gate(intent.unitKey).wait()
            return .acknowledged
        }
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1", at: baseDate)
        try fixture.enqueue("plugin.a", "chapter-2", at: baseDate.addingTimeInterval(1))
        try fixture.enqueue("plugin.a", "chapter-3", at: baseDate.addingTimeInterval(2))

        fixture.coordinator.start()
        for (index, unit) in ["chapter-1", "chapter-2", "chapter-3"].enumerated() {
            await fixture.executor.waitForCalls(index + 1)
            // The dispatcher has looked at the queue while this chapter is still in flight, and
            // did not start the next one.
            fixture.coordinator.wake()
            await fixture.coordinator.waitUntilEvaluated()
            #expect(fixture.executor.calls.count == index + 1)
            #expect(fixture.executor.calls.last?.unit == unit)
            gates.gate(unit).open()
        }
        await fixture.coordinator.waitUntilIdle()

        #expect(fixture.executor.peakConcurrentPerSource == 1)
        #expect(try fixture.rows().isEmpty)
    }

    @Test func atMostTwoSourcesDeliverAtOnce() async throws {
        let gates = GateBook()
        let fixture = try CoordinatorFixture { intent in
            await gates.gate(intent.pluginId).wait()
            return .acknowledged
        }
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1", at: baseDate)
        try fixture.enqueue("plugin.b", "chapter-1", at: baseDate.addingTimeInterval(1))
        try fixture.enqueue("plugin.c", "chapter-1", at: baseDate.addingTimeInterval(2))

        fixture.coordinator.start()
        await fixture.executor.waitForCalls(2)
        fixture.coordinator.wake()
        await fixture.coordinator.waitUntilEvaluated()
        // The two oldest run; the third waits for a free slot.
        #expect(Set(fixture.executor.calls.map(\.plugin)) == ["plugin.a", "plugin.b"])

        gates.gate("plugin.a").open()
        await fixture.executor.waitForCalls(3)
        #expect(Set(fixture.executor.calls.map(\.plugin)) == ["plugin.a", "plugin.b", "plugin.c"])

        gates.gate("plugin.b").open()
        gates.gate("plugin.c").open()
        await fixture.coordinator.waitUntilIdle()

        #expect(fixture.executor.peakConcurrentSources == 2)
        #expect(try fixture.rows().isEmpty)
    }

    // MARK: - Retry

    @Test func aTransientFailureBacksOffDurablyAndItsSourceWaitsForTheDeadline() async throws {
        let attempts = AttemptCounter()
        let fixture = try CoordinatorFixture { intent in
            if intent.unitKey == "chapter-1", attempts.next(for: intent.unitKey) == 1 {
                return .retryable(.network)
            }
            return .acknowledged
        }
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1", at: baseDate)
        try fixture.enqueue("plugin.a", "chapter-2", at: baseDate.addingTimeInterval(1))

        fixture.coordinator.start()
        await fixture.coordinator.waitUntilIdle()

        // The later chapter must not overtake the backed-off one.
        #expect(fixture.executor.calls.map(\.unit) == ["chapter-1"])
        let backedOff = try #require(try fixture.rows().first)
        #expect(backedOff.status == .pending)
        #expect(backedOff.attemptCount == 1)
        #expect(backedOff.lastErrorCategory == .network)
        expectDate(backedOff.nextAttemptAt, equals: clockStart.addingTimeInterval(15))
        expectDate(try #require(fixture.coordinator.scheduledDeadline), equals: clockStart.addingTimeInterval(15))

        fixture.scheduler.advance(toAtLeast: try #require(fixture.coordinator.scheduledDeadline))
        await fixture.coordinator.waitUntilIdle()

        #expect(fixture.executor.calls.map(\.unit) == ["chapter-1", "chapter-1", "chapter-2"])
        #expect(try fixture.rows().isEmpty)
        #expect(fixture.coordinator.scheduledDeadline == nil)
    }

    @Test func transientFailuresRetryOnTheBoundedScheduleThenPauseForTheUser() async throws {
        let fixture = try CoordinatorFixture { _ in .retryable(.server) }
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1")

        fixture.coordinator.start()
        for delay in PluginCompletionRetryPolicy.delays {
            await fixture.coordinator.waitUntilIdle()
            let deadline = try #require(fixture.coordinator.scheduledDeadline)
            expectDate(deadline, equals: fixture.scheduler.now().addingTimeInterval(delay))
            fixture.scheduler.advance(toAtLeast: deadline)
        }
        await fixture.coordinator.waitUntilIdle()

        #expect(fixture.executor.calls.count == PluginCompletionRetryPolicy.delays.count + 1)
        let paused = try #require(try fixture.rows().first)
        #expect(paused.status == .paused)
        #expect(paused.pauseReason == .retryLimit)
        #expect(fixture.coordinator.scheduledDeadline == nil)
        #expect(fixture.coordinator.summaries == [
            PluginCompletionSummary(pluginID: "plugin.a", pendingCount: 0, pausedCount: 1, pauseReasons: [.retryLimit])
        ])
    }

    @Test func aPausingOutcomeIsNeverRetriedOnItsOwn() async throws {
        let fixture = try CoordinatorFixture { _ in .paused(.credentials, .credentials) }
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1")

        fixture.coordinator.start()
        await fixture.coordinator.waitUntilIdle()
        fixture.scheduler.advance(by: 86_400)
        fixture.coordinator.wake()
        await fixture.coordinator.waitUntilIdle()

        #expect(fixture.executor.calls.count == 1)
        let paused = try #require(try fixture.rows().first)
        #expect(paused.status == .paused)
        #expect(paused.pauseReason == .credentials)
        #expect(fixture.coordinator.scheduledDeadline == nil)
    }

    @Test func anExecutorThatReportsCancellationItWasNotGivenBacksOffInsteadOfSpinning() async throws {
        let fixture = try CoordinatorFixture { _ in .cancelled }
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1")

        fixture.coordinator.start()
        await fixture.coordinator.waitUntilIdle()

        #expect(fixture.executor.calls.count == 1)
        let row = try #require(try fixture.rows().first)
        #expect(row.status == .pending)
        #expect(row.attemptCount == 1)
        expectDate(try #require(fixture.coordinator.scheduledDeadline), equals: clockStart.addingTimeInterval(15))
    }

    // MARK: - Authorization changes

    @Test func aSettingsChangeDuringAnAttemptDropsItsStaleAcknowledgement() async throws {
        let gate = AsyncGate()
        let fixture = try CoordinatorFixture { _ in
            await gate.wait()
            return .acknowledged
        }
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1")

        fixture.coordinator.start()
        await fixture.executor.waitForCalls(1)
        try fixture.changeSettings(of: "plugin.a")
        gate.open()
        await fixture.coordinator.waitUntilIdle()

        // The server that was contacted is not the one now configured: the row is parked for
        // confirmation, not deleted as delivered, and nothing is sent again.
        let parked = try #require(try fixture.rows().first)
        #expect(parked.status == .paused)
        #expect(parked.pauseReason == .configurationChanged)
        #expect(fixture.executor.calls.count == 1)
        #expect(fixture.coordinator.summaries == [
            PluginCompletionSummary(
                pluginID: "plugin.a", pendingCount: 0, pausedCount: 1, pauseReasons: [.configurationChanged]
            )
        ])
    }

    @Test func reauthorizingSendsParkedProgressToTheAccountConfiguredNow() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1")
        try fixture.changeSettings(of: "plugin.a")

        fixture.coordinator.start()
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.executor.calls.isEmpty)
        #expect(fixture.coordinator.summaries.first?.pausedCount == 1)

        try await fixture.coordinator.reauthorize(pluginID: "plugin.a")
        await fixture.coordinator.waitUntilIdle()

        #expect(fixture.executor.calls == [.init(plugin: "plugin.a", unit: "chapter-1")])
        #expect(try fixture.rows().isEmpty)
        #expect(fixture.coordinator.summaries.isEmpty)
    }

    @Test func discardingDeletesOnlyParkedProgress() async throws {
        let fixture = try CoordinatorFixture()
        try fixture.enqueue("plugin.a", "chapter-1")
        try fixture.changeSettings(of: "plugin.a")
        try fixture.enqueue("plugin.a", "chapter-2")

        try await fixture.coordinator.discard(pluginID: "plugin.a")

        let remaining = try fixture.rows()
        #expect(remaining.map(\.unitKey) == ["chapter-2"])
        #expect(remaining.first?.status == .pending)
        #expect(fixture.coordinator.summaries == [
            PluginCompletionSummary(pluginID: "plugin.a", pendingCount: 1, pausedCount: 0, pauseReasons: [])
        ])
    }

    @Test func aQueueThatCannotBeUpdatedIsReportedNotClaimedDone() async throws {
        let fixture = try CoordinatorFixture()
        try fixture.enqueue("plugin.a", "chapter-1")
        try fixture.changeSettings(of: "plugin.a")
        // Every change to a queued row now fails inside the database.
        try fixture.blockQueueChanges()

        await #expect(throws: PluginCompletionRecoveryError.queueUnavailable) {
            try await fixture.coordinator.discard(pluginID: "plugin.a")
        }
        await #expect(throws: PluginCompletionRecoveryError.queueUnavailable) {
            try await fixture.coordinator.reauthorize(pluginID: "plugin.a")
        }

        #expect(fixture.coordinator.failure == .queueUnavailable)
        let untouched = try #require(try fixture.rows().first)
        #expect(untouched.status == .paused)
        #expect(untouched.pauseReason == .configurationChanged)
    }

    @Test
    func aSettingsChangeThatParksQueuedProgressReachesTheSummariesWithoutAnExplicitWake() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.coordinator.suspend() }
        // Not due for an hour, so nothing is delivered while the scope changes.
        try fixture.enqueue("plugin.a", "chapter-1", at: clockStart.addingTimeInterval(3_600))

        fixture.coordinator.start()
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.coordinator.summaries.first?.pendingCount == 1)

        try fixture.changeSettings(of: "plugin.a")
        // The coordinator hears of the commit from the database itself.
        for await latest in fixture.coordinator.completionSummariesPublisher.values where latest.first?.pausedCount == 1 {
            break
        }

        #expect(fixture.coordinator.summaries == [
            PluginCompletionSummary(
                pluginID: "plugin.a", pendingCount: 0, pausedCount: 1, pauseReasons: [.configurationChanged]
            )
        ])
    }

    // MARK: - Cancellation

    @Test func suspendingCancelsTheAttemptAndLeavesItsIntentUntouched() async throws {
        let gate = AsyncGate()
        let fixture = try CoordinatorFixture { _ in
            await gate.waitUnlessCancelled()
            return Task.isCancelled ? .cancelled : .acknowledged
        }
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1")

        fixture.coordinator.start()
        await fixture.executor.waitForCalls(1)
        fixture.coordinator.suspend()
        await fixture.coordinator.waitUntilIdle()

        let kept = try #require(try fixture.rows().first)
        #expect(kept.status == .pending)
        #expect(kept.attemptCount == 0)
        #expect(kept.revision == 1)
        #expect(fixture.coordinator.scheduledDeadline == nil)

        fixture.coordinator.start()
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.executor.calls.count == 2)
        #expect(try fixture.rows().isEmpty)
    }

    @Test func cancellingOneSourceInterruptsOnlyItsAttemptAndItsIntentIsDeliveredAgain() async throws {
        let gates = GateBook()
        let cancelled = Recorder()
        let fixture = try CoordinatorFixture { intent in
            await gates.gate(intent.pluginId).waitUnlessCancelled()
            if Task.isCancelled {
                cancelled.append(intent.pluginId)
                return .cancelled
            }
            return .acknowledged
        }
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1", at: baseDate)
        try fixture.enqueue("plugin.b", "chapter-1", at: baseDate.addingTimeInterval(1))

        fixture.coordinator.start()
        await fixture.executor.waitForCalls(2)
        fixture.coordinator.cancel(for: "plugin.a")
        await fixture.executor.waitForCalls(3)

        #expect(cancelled.values == ["plugin.a"])
        #expect(fixture.executor.calls.filter { $0.plugin == "plugin.a" }.count == 2)
        #expect(fixture.executor.calls.filter { $0.plugin == "plugin.b" }.count == 1)

        gates.gate("plugin.b").open()
        await fixture.coordinator.waitUntilIdle()
        #expect(try fixture.rows().isEmpty)
        #expect(cancelled.values == ["plugin.a"])
    }

    @Test func aRestartWhileAnAttemptUnwindsNeverRunsItsSourceTwiceAndStillRecordsItsResult() async throws {
        let gate = AsyncGate()
        // Like a plugin call that cannot be interrupted: it finishes whatever it was told.
        let fixture = try CoordinatorFixture { _ in
            await gate.wait()
            return .acknowledged
        }
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1")

        fixture.coordinator.start()
        await fixture.executor.waitForCalls(1)
        fixture.coordinator.suspend()
        fixture.coordinator.start()
        fixture.coordinator.wake()
        await fixture.coordinator.waitUntilEvaluated()
        #expect(fixture.executor.calls.count == 1)

        gate.open()
        await fixture.coordinator.waitUntilIdle()

        // The acknowledgement of the cancelled attempt is recorded, so the completion is not sent again.
        #expect(try fixture.rows().isEmpty)
        #expect(fixture.executor.calls.count == 1)
    }

    // MARK: - Connectivity

    @Test func nothingIsAttemptedOfflineAndTheNetworkReturningWakesDelivery() async throws {
        let fixture = try CoordinatorFixture(reachable: false)
        defer { fixture.coordinator.suspend() }
        try fixture.enqueue("plugin.a", "chapter-1")

        fixture.coordinator.start()
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.executor.calls.isEmpty)
        let waiting = try #require(try fixture.rows().first)
        #expect(waiting.attemptCount == 0)
        #expect(fixture.coordinator.summaries.first?.pendingCount == 1)

        fixture.connectivity.setReachable(true)
        await fixture.coordinator.waitUntilIdle()
        #expect(fixture.executor.calls.count == 1)
        #expect(try fixture.rows().isEmpty)
    }
}

// MARK: - Retry schedule

struct PluginCompletionRetryPolicyTests {
    @Test func theScheduleIsFifteenSecondsOneFiveThirtyMinutesTwoHoursThenPause() {
        let delays = (1...5).map { PluginCompletionRetryPolicy.delay(afterCompletedFailures: $0) }
        #expect(delays == [15, 60, 300, 1_800, 7_200])
        #expect(PluginCompletionRetryPolicy.delay(afterCompletedFailures: 6) == nil)
        #expect(PluginCompletionRetryPolicy.delay(afterCompletedFailures: 100) == nil)
        #expect(PluginCompletionRetryPolicy.delay(afterCompletedFailures: 0) == nil)
    }
}

// MARK: - Fixtures

@MainActor
private final class CoordinatorFixture {
    let database: TestDatabase
    let store: PluginCompletionStore
    let scheduler: ManualCompletionScheduler
    let connectivity: FakeCompletionConnectivity
    let executor: ScriptedCompletionExecutor
    let coordinator: PluginCompletionCoordinator

    init(
        reachable: Bool = true,
        behavior: @escaping @Sendable (PluginCompletionIntent) async -> PluginCompletionOutcome = { _ in .acknowledged }
    ) throws {
        database = try TestDatabase()
        store = PluginCompletionStore(
            dbPool: database.dbPool,
            secrets: PluginSecretStore(keychain: InMemoryPluginSecretKeychain())
        )
        scheduler = ManualCompletionScheduler(start: clockStart)
        connectivity = FakeCompletionConnectivity(isReachable: reachable)
        executor = ScriptedCompletionExecutor(behavior: behavior)
        coordinator = PluginCompletionCoordinator(
            store: store,
            executor: executor,
            scheduler: scheduler,
            connectivity: connectivity
        )
    }

    /// Queues a chapter completion for `plugin` under the account it is configured for now.
    func enqueue(_ plugin: String, _ unit: String, at date: Date? = nil) throws {
        let context = store.captureContext(
            media: MediaIdentity(pluginId: plugin, canonicalMediaId: "library-\(plugin)"),
            mediaKey: "media-\(plugin)",
            kind: .manga
        )
        let queuedAt = date ?? scheduler.now()
        try database.dbPool.write { db in
            try PluginCompletionStore.enqueue(context: context, unitKey: unit, now: queuedAt, in: db)
        }
    }

    /// Makes every later change to a queued row fail inside the database.
    func blockQueueChanges() throws {
        try database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER blockQueueDeletes BEFORE DELETE ON pluginCompletionOutbox
                BEGIN SELECT RAISE(ABORT, 'blocked'); END;
                CREATE TRIGGER blockQueueUpdates BEFORE UPDATE ON pluginCompletionOutbox
                BEGIN SELECT RAISE(ABORT, 'blocked'); END;
                """)
        }
    }

    /// What editing the source's server or credentials does to the queue: a new authorization scope.
    func changeSettings(of plugin: String) throws {
        try database.dbPool.write { db in
            try PluginCompletionScope.rotate(pluginID: plugin, in: db)
        }
    }

    func rows() throws -> [PluginCompletionIntent] {
        try database.dbPool.read { db in
            try PluginCompletionIntent.fetchAll(db, sql: "SELECT * FROM pluginCompletionOutbox ORDER BY id")
        }
    }
}

private func expectDate(_ actual: Date, equals expected: Date, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(actual.timeIntervalSince(expected)) < 0.01, sourceLocation: sourceLocation)
}

/// A clock the test moves by hand. `sleep(until:)` suspends until the clock reaches the date, so
/// retry deadlines run without waiting.
private nonisolated final class ManualCompletionScheduler: PluginCompletionScheduling, @unchecked Sendable {
    private struct Waiter {
        let date: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private enum Registration {
        case resume, cancel, wait
    }

    private let lock = NSLock()
    private var current: Date
    private var nextID = 0
    private var waiters: [Int: Waiter] = [:]
    private var cancelled: Set<Int> = []

    init(start: Date) {
        current = start
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func sleep(until date: Date) async throws {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let registration = lock.withLock { () -> Registration in
                    if cancelled.remove(id) != nil { return .cancel }
                    if date <= current { return .resume }
                    waiters[id] = Waiter(date: date, continuation: continuation)
                    return .wait
                }
                switch registration {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> Waiter? in
                if let waiter = waiters.removeValue(forKey: id) { return waiter }
                cancelled.insert(id)
                return nil
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by interval: TimeInterval) {
        advance(to: now().addingTimeInterval(interval))
    }

    /// Moves the clock just past `date`, so a deadline read back from the database (which keeps
    /// millisecond precision) is certain to have been reached.
    func advance(toAtLeast date: Date) {
        advance(to: max(now(), date.addingTimeInterval(0.001)))
    }

    private func advance(to date: Date) {
        let due = lock.withLock { () -> [Waiter] in
            current = date
            let ready = waiters.filter { $0.value.date <= date }
            for id in ready.keys { waiters.removeValue(forKey: id) }
            return Array(ready.values)
        }
        for waiter in due { waiter.continuation.resume() }
    }
}

@MainActor
private final class FakeCompletionConnectivity: PluginCompletionConnectivityMonitoring {
    private(set) var isReachable: Bool
    private var onChange: (@MainActor () -> Void)?

    init(isReachable: Bool) {
        self.isReachable = isReachable
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func stop() {
        onChange = nil
    }

    func setReachable(_ reachable: Bool) {
        guard reachable != isReachable else { return }
        isReachable = reachable
        onChange?()
    }
}

/// Records every delivery attempt and runs the scripted behavior for it.
private nonisolated final class ScriptedCompletionExecutor: PluginCompletionExecuting, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        let plugin: String
        let unit: String
    }

    private struct CallWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private let behavior: @Sendable (PluginCompletionIntent) async -> PluginCompletionOutcome
    private var recorded: [Call] = []
    private var running: [String: Int] = [:]
    private var runningSources = 0
    private var peakSources = 0
    private var peakPerSource = 0
    private var waiters: [CallWaiter] = []

    init(behavior: @escaping @Sendable (PluginCompletionIntent) async -> PluginCompletionOutcome) {
        self.behavior = behavior
    }

    var calls: [Call] { lock.withLock { recorded } }
    var peakConcurrentSources: Int { lock.withLock { peakSources } }
    var peakConcurrentPerSource: Int { lock.withLock { peakPerSource } }

    func execute(intent: PluginCompletionIntent) async -> PluginCompletionOutcome {
        began(intent)
        let outcome = await behavior(intent)
        ended(intent)
        return outcome
    }

    /// Returns once at least `count` attempts have started.
    func waitForCalls(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let satisfied = lock.withLock { () -> Bool in
                if recorded.count >= count { return true }
                waiters.append(CallWaiter(count: count, continuation: continuation))
                return false
            }
            if satisfied { continuation.resume() }
        }
    }

    private func began(_ intent: PluginCompletionIntent) {
        let ready = lock.withLock { () -> [CallWaiter] in
            recorded.append(Call(plugin: intent.pluginId, unit: intent.unitKey))
            running[intent.pluginId, default: 0] += 1
            runningSources += 1
            peakSources = max(peakSources, runningSources)
            peakPerSource = max(peakPerSource, running[intent.pluginId] ?? 0)
            let satisfied = waiters.filter { recorded.count >= $0.count }
            waiters.removeAll { recorded.count >= $0.count }
            return satisfied
        }
        for waiter in ready { waiter.continuation.resume() }
    }

    private func ended(_ intent: PluginCompletionIntent) {
        lock.withLock {
            running[intent.pluginId, default: 0] -= 1
            runningSources -= 1
        }
    }
}

/// A one-shot latch. Waiting after it is open returns at once.
private nonisolated final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if open { continuation.resume() }
        }
    }

    /// Waits until opened, or until the waiting task is cancelled.
    func waitUnlessCancelled() async {
        await withTaskCancellationHandler {
            await wait()
        } onCancel: {
            open()
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            let pending = waiters
            waiters = []
            return pending
        }
        for waiter in pending { waiter.resume() }
    }
}

private nonisolated final class GateBook: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [String: AsyncGate] = [:]

    func gate(_ key: String) -> AsyncGate {
        lock.withLock {
            if let existing = gates[key] { return existing }
            let created = AsyncGate()
            gates[key] = created
            return created
        }
    }
}

private nonisolated final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    /// The number of times `key` has now been attempted, including this call.
    func next(for key: String) -> Int {
        lock.withLock {
            counts[key, default: 0] += 1
            return counts[key] ?? 0
        }
    }
}

private nonisolated final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] { lock.withLock { recorded } }

    func append(_ value: String) {
        lock.withLock { recorded.append(value) }
    }
}
