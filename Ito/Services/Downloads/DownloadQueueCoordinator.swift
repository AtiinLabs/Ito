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
    /// The gate that decides this attempt's transfers, so a policy or path change can ask it again.
    let gate: NetworkPathAdmissionGate
    private(set) var versionId: String?
    private var task: Task<DownloadAttemptCompletion, Error>?
    private(set) var isCancelRequested = false
    private(set) var cancelOutcome: DownloadAttemptOutcome?

    init(jobID: String, edition: OfflineChapterEdition, gate: NetworkPathAdmissionGate) {
        self.jobID = jobID
        self.edition = edition
        self.gate = gate
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
/// change, a reconciliation, and a foreground start. Nothing polls. The worker runs in the foreground. When the app
/// backgrounds, `suspend(allowingInFlightCompletion:)` lets the attempt in flight finish under a background grant.
/// If the grant expires or is refused, that attempt is cancelled and recorded as waiting for the foreground.
/// `suspend()` cancels it at once.
@MainActor
final class DownloadQueueCoordinator {
    typealias ModulesFactory = @MainActor @Sendable (
        _ pluginID: String,
        _ gate: any DownloadAdmissionGate,
        _ recorder: DownloadPolicyRecorder
    ) -> PluginRunnerHostModules

    /// What one pass over the queue head did. `blocked` stops the pass until the next wake: the worker was stopped,
    /// a store write failed, or a network condition marked the queue. A cleared path wakes the worker again.
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
        contexts.policy.changes
            .merge(with: contexts.scopeChanges)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor in self?.policyChanged() }
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
        contexts.policy.enterForeground()
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
        contexts.policy.enterBackground()
        stopLoop()
        running?.cancel(.waiting(.appInBackground))
        settleIfIdle()
    }

    private static let inFlightCompletionGrantName = "moe.itoapp.offline-chapters.finish-in-flight"

    /// Stops the worker for a background transition and lets the attempt in flight finish under a background grant.
    /// No new attempt starts. The grant covers the stopped loop until it settles, which is when that attempt has been
    /// published or abandoned. With no attempt in flight there is nothing to finish, so no grant is asked for. If the
    /// system refuses the grant or reclaims its time, the attempt is cancelled as waiting for the foreground, and the
    /// grant ends at once, because UIKit requires that inside the handler.
    func suspend(allowingInFlightCompletion granting: any BackgroundExecutionGranting) {
        // Every metered-data consent was minted in the foreground, so leaving it ends them all, whether or not an
        // attempt is still finishing.
        contexts.policy.enterBackground()
        // Revoking foreground consent is not extended by an OS execution-time grant.
        // Re-evaluate synchronously before any continuation can resume on the main actor.
        cancelRunningIfNotAdmitted()
        guard let retired = loopTask else { return }
        guard running != nil else {
            suspend()
            return
        }
        // The loop is stopped before the grant is asked for, so an expiration the grant delivers at once finds it gone.
        stopLoop()
        let grant = granting.beginGrant(named: Self.inFlightCompletionGrantName) { [weak self] in
            // A foreground start after the suspension owns the queue, so nothing is cancelled for it.
            guard let self, self.loopTask == nil else { return }
            self.running?.cancel(.waiting(.appInBackground))
        }
        settleIfIdle()
        Task { @MainActor in
            await retired.value
            grant.end()
        }
    }

    /// Ends the loop that takes work and keeps it as the retiring loop, so the next start waits for it.
    private func stopLoop() {
        if let loopTask {
            retiringLoop = loopTask
        }
        loopTask = nil
        wakeContinuation?.finish()
        wakeContinuation = nil
        wakePending = false
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

    /// A path that stops admitting this attempt's work cancels it. The path is read now, not taken from the
    /// delivered snapshot, because updates reach the main actor through separate tasks and may reorder.
    private func pathChanged() {
        cancelRunningIfNotAdmitted()
        wake()
    }

    /// A changed policy, acknowledged by the settings store, cancels the attempt in flight when it no longer admits it,
    /// and wakes the worker either way: waiting chapters may be admitted now. An attempt the new policy still admits
    /// carries a context from the earlier revision, which its transport refuses as `policyChanged`; it is queued
    /// again and rebuilt under the revision in force.
    private func policyChanged() {
        cancelRunningIfNotAdmitted()
        wake()
    }

    private func cancelRunningIfNotAdmitted() {
        guard let running else { return }
        if case .wait(let wait) = running.gate.admission() {
            running.cancel(.waiting(wait.waitingReason))
        } else if !running.gate.authorityIsCurrent {
            running.cancel(.queued)
        }
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

    /// The gate that decides one job's transfers: the live policy, the observed path and, for the job's batch, its
    /// consent. Every admission reads the consent again, so one that expired stops the next transfer.
    private func admissionGate(for job: DownloadJobRecord, operation: PluginNetworkOperation) -> NetworkPathAdmissionGate {
        NetworkPathAdmissionGate(
            observer: path,
            policy: contexts.policy,
            intent: .manualBulkDownload,
            consent: UUID(uuidString: job.batchId).map { contexts.consentBinding(batchID: $0, pluginID: job.pluginId) },
            operation: operation,
            authorizationScope: job.sourceEpoch.flatMap(PluginNetworkScopeID.uuid(epoch:))
        )
    }

    /// Moves waiting chapters back to the queue when the condition that paused them has cleared. Reasons
    /// that need an explicit Retry are never listed here. A path that waits only for a batch's consent readmits
    /// the metered waits too: each job's own admission then decides whether its batch holds one.
    private func readmitClearedWaits() async {
        var cleared: Set<DownloadWaitingReason> = [.appInBackground]
        switch contexts.policy.decide(.manualBulkDownload, path: path.current) {
        case .allow:
            cleared.formUnion(NetworkDeferral.networkWaitingReasons)
        case .wait(.meteredConsentRequired):
            cleared.insert(.meteredNetwork)
        case .wait:
            break
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
        var operation = PluginNetworkOperation(
            purpose: .manualBulkDownload, operationID: UUID(), batchID: UUID(uuidString: job.batchId),
            policyRevision: contexts.policy.revision
        )
        if let batchID = operation.batchID,
           job.sourceEpoch.flatMap(PluginNetworkScopeID.uuid(epoch:)) == contexts.liveScope(pluginID: job.pluginId) {
            operation.scopedGrant = contexts.policy.authorizeBatchOperation(
                contexts.consentBinding(batchID: batchID, pluginID: job.pluginId), operationID: operation.operationID
            )
        }
        let gate = admissionGate(for: job, operation: operation)
        let current = RunningAttempt(jobID: job.id, edition: job.edition, gate: gate)
        running = current
        defer {
            if running === current {
                running = nil
            }
            progress.clear(job.id)
        }

        let recorder = DownloadPolicyRecorder()

        let currentEpoch = try? await store.currentSourceEpoch(pluginId: job.pluginId)
        if let step = await stopBeforeAttempt(current, job: job, generation: generation) { return step }
        guard let frozenEpoch = job.sourceEpoch, let currentEpoch, currentEpoch == frozenEpoch else {
            return await setWaiting(job.id, .sourceConfigurationChanged) ? .proceeded : .blocked
        }

        // A network condition holds every queued chapter. One write marks them all and the pass stops. A path that
        // clears wakes the worker, and the next pass readmits the chapters in queue order. A condition that is this
        // batch's own, a metered-data consent it lacks, holds only this batch and the pass goes on to the next one.
        if case .wait(let wait) = gate.admission() {
            do {
                try await store.setWaitingForQueuedJobs(
                    reason: wait.waitingReason,
                    batchId: wait.isBatchSpecific ? job.batchId : nil
                )
            } catch {
                return .blocked
            }
            return wait.isBatchSpecific ? .proceeded : .blocked
        }

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
        if let batchID = UUID(uuidString: job.batchId), (try? await store.batchHasJobs(job.batchId)) == false {
            contexts.policy.revokeConsent(forBatch: batchID)
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
