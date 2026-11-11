import Combine
import Foundation
import ito_runner

/// The attempt in flight, as the coordinator sees it. It exists from the start of a pass over one job, before
/// any await, so a cancel that arrives during setup is recorded and honoured instead of lost. Cancelling it
/// records why, so the outcome written when the attempt is abandoned is that reason rather than a generic
/// cancellation.
@MainActor
private final class RunningAttempt {
    let jobID: String
    let edition: OfflineChapterEdition
    private(set) var versionId: String?
    private var task: Task<DownloadAttemptCompletion, Error>?
    private(set) var isCancelRequested = false
    private(set) var cancelOutcome: DownloadAttemptOutcome?

    init(jobID: String, edition: OfflineChapterEdition) {
        self.jobID = jobID
        self.edition = edition
    }

    /// Binds the store's staging version once `beginAttempt` has reserved it.
    func bind(versionId: String) {
        self.versionId = versionId
    }

    func bind(task: Task<DownloadAttemptCompletion, Error>) {
        self.task = task
    }

    /// The first recorded request wins. Cancelling again only repeats the cancellation of the task.
    func cancel(_ outcome: DownloadAttemptOutcome?) {
        if !isCancelRequested {
            isCancelRequested = true
            cancelOutcome = outcome
        }
        task?.cancel()
    }
}

/// Downloads queued chapters: one worker, first in first out by creation time.
///
/// The worker is event-driven. It wakes for an enqueue or retry, a network path change, a protected-data
/// change, a reconciliation, and a foreground start. Nothing polls. The worker runs only in the foreground:
/// `suspend` cancels the attempt in flight, which the store records as waiting for the foreground.
@MainActor
final class DownloadQueueCoordinator {
    typealias ModulesFactory = @MainActor @Sendable (
        _ pluginID: String,
        _ gate: any DownloadAdmissionGate,
        _ recorder: DownloadPolicyRecorder
    ) -> PluginRunnerHostModules

    /// What one pass over the queue head did. `blocked` stops the pass until the next wake, because a
    /// condition that blocks one chapter blocks the rest too.
    private enum Step: Equatable {
        case proceeded
        case blocked
    }

    private let store: OfflineChapterStore
    private let runtimes: any DownloadRuntimeProviding
    private let makeModules: ModulesFactory
    private let path: any NetworkPathObserving
    private let protectedData: any ProtectedDataAvailability
    private let fetcher: any DirectAssetFetching
    private let contexts: PluginNetworkContexts
    private let progress: DownloadProgressBoard

    private var reconciled = false
    private var loopTask: Task<Void, Never>?
    /// Identifies the loop that may take work. A suspended loop sees a newer generation and stops.
    private var loopGeneration = 0
    /// The loop a suspension ended, still finishing its last attempt.
    private var retiringLoop: Task<Void, Never>?
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    private var running: RunningAttempt?
    private var subscriptions = Set<AnyCancellable>()
    /// A wake has been requested and the worker has not yet taken it up.
    private var wakePending = false
    /// The worker is inside one pass over the queue.
    private var isDraining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - protectedDataBecameAvailable: fires when the device unlocks after a lock.
    ///   - predecessor: what a replaced worker is still finishing. This worker's first pass waits for it.
    init(
        store: OfflineChapterStore,
        runtimes: any DownloadRuntimeProviding,
        makeModules: @escaping ModulesFactory,
        path: any NetworkPathObserving,
        protectedData: any ProtectedDataAvailability,
        protectedDataBecameAvailable: AnyPublisher<Void, Never>,
        fetcher: any DirectAssetFetching,
        contexts: PluginNetworkContexts,
        progress: DownloadProgressBoard,
        predecessor: Task<Void, Never>? = nil
    ) {
        self.store = store
        self.runtimes = runtimes
        self.makeModules = makeModules
        self.path = path
        self.protectedData = protectedData
        self.fetcher = fetcher
        self.contexts = contexts
        self.progress = progress
        retiringLoop = predecessor

        // Path and protected-data events arrive on the system's own queues. `@Sendable` keeps these
        // closures from inheriting the main actor, whose isolation would be asserted at delivery. The
        // path is read again on the main actor, so a reordered update never acts on a stale snapshot.
        path.updates
            .sink { @Sendable [weak self] _ in
                Task { @MainActor in self?.pathChanged() }
            }
            .store(in: &subscriptions)
        protectedDataBecameAvailable
            .sink { @Sendable [weak self] in
                Task { @MainActor in self?.protectedDataChanged() }
            }
            .store(in: &subscriptions)
    }

    /// Brings the store into agreement with the offline directory, once. A deferred run is retried when
    /// the worker next wakes and when protected data returns. Launch never waits for this.
    func reconcile() async {
        guard !reconciled else { return }
        // The store's default refuses a roll-forward: a version renamed into place before a crash has no
        // trust or publication baseline after the relaunch, so the chapter is requeued and fetched again.
        let report = await store.reconcile()
        if case .completed = report {
            reconciled = true
            wake()
        }
    }

    /// Starts the worker in the foreground. Calling it again while running changes nothing. A loop left
    /// over from a suspension finishes its last attempt's bookkeeping before the new one looks at the queue.
    func start() {
        guard loopTask == nil else { return }
        loopGeneration += 1
        let generation = loopGeneration
        let previous = retiringLoop
        retiringLoop = nil
        var continuation: AsyncStream<Void>.Continuation?
        let wakes = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        wakeContinuation = continuation
        loopTask = Task { [weak self] in
            await previous?.value
            for await _ in wakes {
                guard let self, self.isCurrent(generation) else { return }
                // The flag is the authority: a buffered element whose wake was already taken up by the
                // previous pass is skipped, so `untilIdle` never reports idle with a pass still to run.
                guard self.wakePending else { continue }
                self.wakePending = false
                self.isDraining = true
                await self.drain(generation: generation)
                self.isDraining = false
                self.settleIfIdle()
            }
        }
        wake()
    }

    /// Stops the worker and cancels the attempt in flight. The chapter waits until the next foreground start.
    /// The loop itself is not cancelled: the attempt's store writes run in it, and a cancelled task's database
    /// writes fail, which would leave the chapter marked as downloading.
    func suspend() {
        if let loopTask {
            retiringLoop = loopTask
        }
        loopTask = nil
        wakeContinuation?.finish()
        wakeContinuation = nil
        wakePending = false
        running?.cancel(.waiting(.appInBackground))
        settleIfIdle()
    }

    /// Suspends this worker for good, as a runtime that is being replaced does, and returns the work it
    /// is still finishing. The replacing worker passes it as `predecessor`, so the two never overlap.
    func retire() -> Task<Void, Never>? {
        suspend()
        return retiringLoop
    }

    /// Asks the worker to look at the queue again. Wakes that arrive while it is busy are coalesced.
    func wake() {
        guard let wakeContinuation else { return }
        wakePending = true
        wakeContinuation.yield(())
    }

    /// Suspends until no wake is pending and no pass over the queue is running. Diagnostics and tests use
    /// it to observe the end of the work they started; the app never waits on it.
    func untilIdle() async {
        guard wakePending || isDraining else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func settleIfIdle() {
        guard !wakePending, !isDraining else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// The job the attempt in flight belongs to, if any.
    var runningJobID: String? {
        running?.jobID
    }

    /// Stops the attempt for a job the caller has just removed from the queue.
    func cancelAttempt(jobID: String) {
        guard running?.jobID == jobID else { return }
        running?.cancel(nil)
    }

    /// Stops the attempt for an edition the caller has just deleted.
    func cancelAttempt(for edition: OfflineChapterEdition) {
        guard running?.edition == edition else { return }
        running?.cancel(nil)
    }

    /// Stops the attempt for a series whose copies and jobs the caller has just deleted.
    func cancelAttempt(for media: MediaIdentity) {
        guard let edition = running?.edition,
              edition.pluginId == media.pluginId,
              edition.mediaKind == media.mediaKind,
              edition.canonicalMediaId == media.canonicalMediaId else { return }
        running?.cancel(nil)
    }

    private var isRunning: Bool {
        loopTask != nil
    }

    private func isCurrent(_ generation: Int) -> Bool {
        isRunning && loopGeneration == generation
    }

    /// A path that stops admitting bulk work cancels the attempt. The path is read now, not taken from the
    /// delivered snapshot, because updates reach the main actor through separate tasks and may reorder.
    private func pathChanged() {
        if case .wait(let wait) = BulkDownloadPolicy.admit(path.current) {
            running?.cancel(.waiting(wait.waitingReason))
        }
        wake()
    }

    private func protectedDataChanged() {
        if !reconciled {
            Task { await self.reconcile() }
        }
        wake()
    }

    private func drain(generation: Int) async {
        if !reconciled {
            await reconcile()
        }
        guard reconciled else { return }
        await readmitClearedWaits()
        while isCurrent(generation) {
            guard let work = await nextQueuedJob() else { return }
            guard await runOne(work, generation: generation) == .proceeded else { return }
        }
    }

    /// Moves waiting chapters back to the queue when the condition that paused them has cleared. Reasons
    /// that need an explicit Retry are never listed here.
    private func readmitClearedWaits() async {
        var cleared: Set<DownloadWaitingReason> = [.appInBackground]
        if case .allow = BulkDownloadPolicy.admit(path.current) {
            cleared.formUnion(BulkDownloadWait.allCases.map(\.waitingReason))
        }
        if await protectedData.isProtectedDataAvailable() {
            cleared.insert(.protectedDataUnavailable)
        }
        if (try? await store.ensureCapacityForNextAsset()) != nil {
            cleared.insert(.insufficientStorage)
        }
        try? await store.readmitWaiting(cleared)
    }

    private func nextQueuedJob() async -> DownloadJobWork? {
        try? await store.nextQueuedJob()
    }

    /// Runs the checks that come before network work, in order, and then one attempt. The first failing
    /// check records its reason on the job and starts no network request. The attempt is registered before
    /// the first await, so a suspension or cancel during setup is honoured at the next step.
    private func runOne(_ work: DownloadJobWork, generation: Int) async -> Step {
        let job = work.job
        guard isCurrent(generation) else { return .blocked }
        let current = RunningAttempt(jobID: job.id, edition: job.edition)
        running = current
        defer {
            if running === current {
                running = nil
            }
            progress.clear(job.id)
        }

        let recorder = DownloadPolicyRecorder()
        let gate = NetworkPathAdmissionGate(observer: path)

        let currentEpoch = try? await store.currentSourceEpoch(pluginId: job.pluginId)
        if let step = await stopBeforeAttempt(current, job: job, generation: generation) { return step }
        guard let frozenEpoch = job.sourceEpoch, let currentEpoch, currentEpoch == frozenEpoch else {
            return await setWaiting(job.id, .sourceConfigurationChanged) ? .proceeded : .blocked
        }

        if case .wait(let wait) = gate.admission() {
            _ = await setWaiting(job.id, wait.waitingReason)
            return .blocked
        }

        // One operation per attempt: the runner loads and every export of the attempt share its ID and batch.
        let operation = PluginNetworkOperation(
            purpose: .manualBulkDownload,
            operationID: UUID(),
            batchID: UUID(uuidString: job.batchId)
        )
        let runtime: DownloadPluginRuntime
        do {
            runtime = try await runtimes.makeDownloadRuntime(
                for: job.pluginId,
                modules: makeModules(job.pluginId, gate, recorder),
                operation: operation,
                frozenScope: frozenEpoch
            )
        } catch PluginRunnerAuthorityError.changedDuringLoad {
            // The plugins were republished while this one loaded. The job is still queued, and the next
            // pass loads it again under the new publication.
            if let step = await stopBeforeAttempt(current, job: job, generation: generation) { return step }
            return .proceeded
        } catch {
            if let step = await stopBeforeAttempt(current, job: job, generation: generation) { return step }
            return await setWaiting(job.id, .sourceUnavailable) ? .proceeded : .blocked
        }
        if let step = await stopBeforeAttempt(current, job: job, generation: generation) { return step }

        let staging: OfflineStagingAttempt
        do {
            staging = try await store.beginAttempt(jobID: job.id)
        } catch OfflineStoreError.jobUnavailable {
            return .proceeded
        } catch {
            return .blocked
        }
        current.bind(versionId: staging.versionId)
        if current.isCancelRequested || !isCurrent(generation) {
            await abandon(current, outcome: current.cancelOutcome ?? .queued)
            return .proceeded
        }

        let board = progress
        let attempt = DownloadAttempt(
            work: work,
            staging: staging,
            store: store,
            runtime: runtime,
            fetcher: fetcher,
            recorder: recorder,
            admission: gate,
            contexts: contexts,
            operation: operation,
            progress: { report in board.update(report) }
        )
        let task = Task { try await attempt.run() }
        current.bind(task: task)
        recorder.onFirstDenial { task.cancel() }

        let result = await task.result
        switch result {
        case .failure(let error):
            await abandon(current, outcome: Self.abandonmentOutcome(for: error, current: current))
        case .success(let completion):
            // Publishing runs here, in the loop, which is never cancelled: a cancelled task's database
            // reads and writes throw. A cancel recorded before this point abandons the finished stream. One
            // that arrives during the publish lets it finish; a Delete is caught by the commit's job check.
            if current.isCancelRequested {
                await abandon(current, outcome: current.cancelOutcome ?? .queued)
            } else {
                // The store records every publish outcome on the job itself. It throws only when that
                // write failed too; the job then keeps its staging intent, and reconciliation at the
                // next launch settles it, so there is nothing more to write here.
                _ = try? await store.publish(completion.staging, commitGuard: completion.commitGuard)
            }
        }
        return .proceeded
    }

    /// Honours a cancel recorded, or a loop retired, while setup was awaiting, and returns where the pass
    /// goes next, or nil when setup goes on. The job has no attempt in the store yet: a waiting reason is
    /// written on the job, and no reason leaves it as it is. A cancel with no reason removed the job, so the
    /// pass may move on to the next one; every other stop ends the pass.
    private func stopBeforeAttempt(_ current: RunningAttempt, job: DownloadJobRecord, generation: Int) async -> Step? {
        guard current.isCancelRequested || !isCurrent(generation) else { return nil }
        if case .waiting(let reason)? = current.cancelOutcome {
            _ = await setWaiting(job.id, reason)
        }
        return current.isCancelRequested && current.cancelOutcome == nil ? .proceeded : .blocked
    }

    private func abandon(_ current: RunningAttempt, outcome: DownloadAttemptOutcome) async {
        guard let versionId = current.versionId else { return }
        try? await store.abandonAttempt(jobID: current.jobID, versionId: versionId, outcome: outcome)
    }

    private func setWaiting(_ jobID: String, _ reason: DownloadWaitingReason) async -> Bool {
        (try? await store.setWaiting(jobID: jobID, reason: reason)) != nil
    }

    /// A requested cancel decides the outcome whatever error the cancelled work surfaced: a transfer's
    /// cancellation is a URL error and a plugin may report it as its own error, and neither is a failure.
    private static func abandonmentOutcome(for error: Error, current: RunningAttempt) -> DownloadAttemptOutcome {
        if current.isCancelRequested {
            return current.cancelOutcome ?? .queued
        }
        if let failure = error as? DownloadAttemptFailure {
            return failure.outcome
        }
        if error is CancellationError {
            return .queued
        }
        return .failed(.sourceError)
    }
}
