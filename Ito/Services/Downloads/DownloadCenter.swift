import Combine
import Foundation
import GRDB
import OSLog
import ito_runner

/// What a chapter shows for downloads. It is derived from the inventory and the queue, never from files,
/// so a screen cannot disagree with the store.
nonisolated enum ChapterDownloadState: Equatable, Sendable {
    case queued
    case downloading(completed: Int, total: Int?)
    case waiting(DownloadWaitingReason)
    case failed(DownloadFailureReason)
    case downloaded
    case damaged
}

/// In-memory progress of attempts in flight, keyed by job. Nothing here is persisted.
@MainActor
final class DownloadProgressBoard: ObservableObject {
    @Published private(set) var progress: [String: DownloadProgress] = [:]

    func update(_ report: DownloadProgress) {
        progress[report.jobID] = report
    }

    func clear(_ jobID: String) {
        progress[jobID] = nil
    }
}

/// The rows one observation reads: every inventory copy and every queued job, in queue order.
nonisolated struct DownloadTableSnapshot: Sendable {
    var copies: [DownloadedChapterRecord] = []
    var jobs: [DownloadJobRecord] = []
}

/// The app's download surface: the state of every chapter that has a copy or a job, and the commands a
/// screen sends. It observes the tables with GRDB and merges in the progress board, so detail screens,
/// badges, and the reader all read one source.
@MainActor
final class DownloadCenter: ObservableObject {
    /// The state of each chapter, by media and chapter key. A chapter absent here has no copy and no job.
    @Published private(set) var states: [MediaIdentity: [String: ChapterDownloadState]] = [:]
    /// Volatile page progress keeps the persisted job identity, not merely its chapter edition.
    @Published private(set) var jobProgress: [String: DownloadProgress] = [:]
    /// What the Library shows about downloads. It changes only when the tables do.
    @Published private(set) var librarySummary = LibraryDownloadSummary.empty
    /// Replacement activity over a chapter whose verified copy stays readable: queued, running, waiting or ended.
    /// A chapter absent here has no replacement activity.
    @Published private(set) var chapterReplacementStates: [MediaIdentity: [String: ChapterDownloadState]] = [:]

    private let dbPool: DatabasePool
    private let store: OfflineChapterStore
    private let coordinator: DownloadQueueCoordinator
    private let progress: DownloadProgressBoard
    private let contexts: PluginNetworkContexts
    private let observedPath: @Sendable () -> NetworkPathSnapshot
    private let captureEpoch: @Sendable (String) throws -> String
    private let automaticLimits: @Sendable () -> AutomaticDownloadLimits
    private var snapshot = DownloadTableSnapshot()
    private var observation: DatabaseCancellable?
    private var progressSubscription: AnyCancellable?

    /// - Parameters:
    ///   - captureEpoch: the source's current completion epoch; see `PluginCompletionStore.captureScopeEpoch`.
    ///   - contexts: the host contexts of the sources, whose policy decides consent for a batch.
    ///   - observedPath: the path the policy decides on now.
    ///   - automaticLimits: the queue and disk limits automatic downloads run under, read when they are applied.
    init(
        dbPool: DatabasePool,
        store: OfflineChapterStore,
        coordinator: DownloadQueueCoordinator,
        progress: DownloadProgressBoard,
        contexts: PluginNetworkContexts,
        observedPath: @escaping @Sendable () -> NetworkPathSnapshot,
        captureEpoch: @escaping @Sendable (String) throws -> String,
        automaticLimits: @escaping @Sendable () -> AutomaticDownloadLimits
    ) {
        self.dbPool = dbPool
        self.store = store
        self.coordinator = coordinator
        self.progress = progress
        self.contexts = contexts
        self.observedPath = observedPath
        self.captureEpoch = captureEpoch
        self.automaticLimits = automaticLimits
        progressSubscription = progress.$progress.sink { @MainActor [weak self] value in
            self?.republish(progress: value)
        }
    }

    /// Starts observing the inventory and the queue. The caller picks the scheduler, as the library does.
    func startObserving<Scheduler: ValueObservationMainActorScheduler>(scheduling scheduler: Scheduler) {
        let observation = ValueObservation.tracking { db -> DownloadTableSnapshot in
            DownloadTableSnapshot(
                copies: try DownloadedChapterRecord.fetchAll(db),
                jobs: try DownloadJobRecord.order(DownloadJobRecord.queueOrder).fetchAll(db)
            )
        }
        self.observation = observation.start(
            in: dbPool,
            scheduling: scheduler,
            onError: { _ in
                AppLogger.database.error("Download state observation failed")
            },
            onChange: { [weak self] current in
                self?.apply(current)
            }
        )
    }

    /// Queues one chapter. The source's epoch is read now and frozen with the job, so a later settings or
    /// credential change pauses the queued chapter instead of letting it finish under the new configuration.
    func enqueue(
        pluginID: String,
        mediaKind: MediaKind,
        canonicalMediaId: String,
        entry: MediaEntry,
        chapter: Chapter,
        seriesTitle: String
    ) async -> DownloadEnqueueOutcome {
        guard let epoch = try? captureEpoch(pluginID) else {
            return .refused(.unavailable)
        }
        let request = DownloadEnqueueRequest(
            pluginId: pluginID,
            mediaKind: mediaKind,
            canonicalMediaId: canonicalMediaId,
            entry: entry,
            chapter: chapter,
            seriesTitle: seriesTitle,
            sourceEpoch: epoch
        )
        do {
            let outcome = try await store.enqueue(request)
            if outcome == .queued {
                coordinator.wake()
            }
            return outcome
        } catch {
            return .refused(.unavailable)
        }
    }

    /// What a replacement confirmation may start from. A copy that is not verified, or a locked chapter, is
    /// `.unavailable`. A copy saved under another series or from an older source epoch is `.copyCannotBeReplaced`:
    /// its saved bytes are kept, but the source no longer vouches for them under the current settings.
    func replacementPreview(
        media: MediaIdentity, entry: MediaEntry, chapter: Chapter, seriesTitle: String
    ) async throws -> DownloadReplacementAccess {
        let edition = OfflineChapterEdition(media: media, chapterKey: chapter.key)
        let installed = try await dbPool.read { db in
            try DownloadedChapterRecord.filter(edition.predicate).fetchOne(db)
        }
        guard let installed, installed.state == .verified, chapter.paywalled != true else {
            return .refused(.unavailable)
        }
        guard installed.manifestIdentity == edition else { return .refused(.copyCannotBeReplaced) }
        let epoch = try captureEpoch(media.pluginId)
        guard installed.sourceEpoch == epoch else { return .refused(.copyCannotBeReplaced) }
        return try .preview(DownloadReplacementPreview(
            download: DownloadEnqueueRequest(
                pluginId: media.pluginId, mediaKind: media.mediaKind,
                canonicalMediaId: media.canonicalMediaId, entry: entry, chapter: chapter,
                seriesTitle: seriesTitle, sourceEpoch: epoch
            ),
            installed: JSONDecoder().decode(Chapter.self, from: installed.chapterSnapshot),
            expectedVersionId: installed.versionId,
            downloadMode: contexts.policy.current.downloadMode
        ))
    }

    /// Minted only on confirmation. This UUID identifies the manual decision; it is not a network grant.
    func replace(_ preview: DownloadReplacementPreview) async -> DownloadEnqueueOutcome {
        do {
            let outcome = try await store.enqueueReplacement(DownloadReplacementRequest(
                download: preview.download, expectedVersionId: preview.expectedVersionId,
                expectedRevision: DownloadReplacementIntent.revision(preview.installed),
                authorizationId: UUID().uuidString
            ))
            if outcome == .queued { coordinator.wake() }
            return outcome
        } catch {
            return .refused(.unavailable)
        }
    }

    /// Queues many chapters of one series as one frozen batch. A reviewed batch freezes the epoch it was
    /// reviewed under, which the store verifies in its write transaction; any other reads the epoch once, here.
    /// The outcome counts how each chapter was settled; a refusal means the request as a whole was not queued.
    ///
    /// `confirmedMeteredUse` says the user directly confirmed, just now and in the foreground, that this exact
    /// batch may use an expensive path. The consent is minted for the batch's stored ID only after the batch is
    /// queued, so it can never name a different batch, and before the worker is woken for it. The policy mints
    /// nothing unless the mode asks, the app is in the foreground and the path is expensive and unconstrained.
    func enqueueBatch(_ request: DownloadBatchRequest, confirmedMeteredUse: Bool = false) async -> DownloadBatchOutcome {
        let epoch: String
        if let reviewed = request.reviewedSourceEpoch {
            epoch = reviewed
        } else if let captured = try? captureEpoch(request.pluginId) {
            epoch = captured
        } else {
            return .refused(.unavailable)
        }
        let confirmation = confirmedMeteredUse ? contexts.policy.captureConfirmation() : nil
        do {
            let outcome = try await store.enqueueBatch(request, sourceEpoch: epoch)
            if let confirmation, outcome.queued > 0, let batchID = outcome.batchId.flatMap(UUID.init(uuidString:)),
               PluginNetworkScopeID.uuid(epoch: epoch) == contexts.liveScope(pluginID: request.pluginId) {
                contexts.policy.mintBatchConsent(
                    contexts.consentBinding(batchID: batchID, pluginID: request.pluginId), confirmation: confirmation
                )
            }
            if outcome.queued > 0 {
                coordinator.wake()
            }
            return outcome
        } catch {
            return .refused(.unavailable)
        }
    }

    /// Whether queueing a batch now needs the user's direct confirmation to use an expensive path: the mode asks,
    /// the path is satisfied, expensive and unconstrained, and the app is in the foreground.
    func meteredUseNeedsConfirmation() -> Bool {
        let configuration = contexts.policy.current
        guard configuration.downloadMode == .askMetered, contexts.policy.isForeground else { return false }
        let path = observedPath()
        return path.status == .satisfied && path.isExpensive && !path.isConstrained
    }

    /// Removes a chapter's queue entry and stops its attempt. A verified copy is kept. Throws when the
    /// queue could not be read or changed, so the caller can say the chapter is still queued.
    func cancel(_ edition: OfflineChapterEdition) async throws {
        guard let job = try await queuedJob(for: edition) else { return }
        try await store.cancel(jobID: job.id)
        await revokeConsentOfFinishedBatches([job.batchId])
        coordinator.cancelAttempt(jobID: job.id)
    }

    /// Queues a failed or waiting chapter again, re-freezing the source's current epoch. Throws when the
    /// source's scope or the queue could not be read or changed.
    func retry(_ edition: OfflineChapterEdition) async throws {
        guard let job = try await queuedJob(for: edition) else { return }
        let epoch = try captureEpoch(job.pluginId)
        try await store.retry(jobID: job.id, currentEpoch: epoch)
        coordinator.wake()
    }

    /// Removes the queue entries with these ids in one transaction and stops the attempt among them. Copies
    /// are kept. Ids that no longer exist are skipped. Throws when the queue could not be changed, so the
    /// caller can say the chapters are still queued.
    func cancel(jobIDs: [String]) async throws {
        let jobs = try await store.jobs(ids: jobIDs)
        let removed = try await store.cancel(jobIDs: jobIDs)
        await revokeConsentOfFinishedBatches(jobs.filter { removed.contains($0.id) }.map(\.batchId))
        for jobID in removed {
            coordinator.cancelAttempt(jobID: jobID)
        }
    }

    /// A batch's metered consent ends only when the batch has no job left. Cancelling one chapter leaves the
    /// approved siblings queued under the same consent. An unreadable count keeps the consent: the observed
    /// snapshot ends it once the batch really disappears.
    private func revokeConsentOfFinishedBatches(_ batchIDs: [String]) async {
        for batchID in Set(batchIDs) {
            guard let id = UUID(uuidString: batchID) else { continue }
            if (try? await store.batchHasJobs(batchID)) == false {
                contexts.policy.revokeConsent(forBatch: id)
            }
        }
    }

    /// Queues the failed and waiting chapters among these jobs again, re-freezing each source's current
    /// epoch, in one transaction. Throws, changing nothing, when a source's scope could not be read.
    func retry(jobIDs: [String]) async throws {
        let jobs = try await store.jobs(ids: jobIDs)
        var epochs: [String: String] = [:]
        for pluginId in Set(jobs.map(\.pluginId)) {
            epochs[pluginId] = try captureEpoch(pluginId)
        }
        if try await store.retry(jobIDs: jobIDs, epochs: epochs) > 0 {
            coordinator.wake()
        }
    }

    /// Removes a chapter's copy and queue entry, and stops its attempt. Bytes a reader still holds stay
    /// until that reader lets go. Throws when the copy could not be removed.
    func delete(_ edition: OfflineChapterEdition) async throws {
        try await store.delete(edition)
        coordinator.cancelAttempt(for: edition)
    }

    /// Removes the copies and queue entries of these chapters in one transaction and stops their attempt.
    /// With `suppress`, each removed copy is also recorded as deliberately deleted. Bytes a reader still
    /// holds stay until that reader lets go. Throws when the copies could not be removed.
    @discardableResult
    func delete(_ editions: [OfflineChapterEdition], suppress: Bool) async throws -> DownloadDeleteSummary {
        let summary = try await store.delete(editions, suppress: suppress)
        for edition in editions {
            coordinator.cancelAttempt(for: edition)
        }
        return summary
    }

    /// `delete(_:suppress:)` for every copy and queue entry of one series.
    @discardableResult
    func deleteMedia(_ media: MediaIdentity, suppress: Bool) async throws -> DownloadDeleteSummary {
        let summary = try await store.deleteMedia(media, suppress: suppress)
        coordinator.cancelAttempt(for: media)
        return summary
    }

    // MARK: - Automatic downloads

    /// Creates the rule for a series, waiting for its first baseline. Nothing is queued.
    func enableSubscription(_ request: SubscriptionEnableRequest) async throws -> SubscriptionEnableOutcome {
        try await store.enableSubscription(request)
    }

    /// Pauses the rule and returns its running attempts to the queue; a job with no enabled owner is not dequeued.
    func pauseSubscription(id: String) async throws {
        for jobID in try await store.pauseSubscription(id: id) {
            coordinator.cancelAttempt(jobID: jobID)
        }
    }

    func resumeSubscription(id: String) async throws {
        try await store.resumeSubscription(id: id)
        coordinator.wake()
    }

    /// Applies an edit. Events that waited are decided again at once under the new configuration.
    func editSubscription(_ edit: SubscriptionEdit) async throws -> SubscriptionEditOutcome {
        let outcome = try await store.editSubscription(edit)
        if case .applied = outcome {
            _ = try? await drainSubscriptionEvents(subscriptionId: edit.subscriptionId)
        }
        return outcome
    }

    /// Disables the rule: jobs only it asked for are removed, and their attempts stop. Files are kept.
    func disableSubscription(id: String) async throws -> SubscriptionRelease {
        let release = try await store.disableSubscription(id: id)
        for jobID in release.removedJobIds { coordinator.cancelAttempt(jobID: jobID) }
        return release
    }

    func deleteSubscription(id: String) async throws -> SubscriptionRelease {
        let release = try await store.deleteSubscription(id: id)
        for jobID in release.removedJobIds { coordinator.cancelAttempt(jobID: jobID) }
        return release
    }

    func resolveSubscriptionEvent(_ resolution: SubscriptionEventResolution) async throws -> SubscriptionCommitOutcome {
        let outcome = try await store.resolveSubscriptionEvent(resolution, limits: automaticLimits())
        if outcome.queuedJobs > 0 { coordinator.wake() }
        return outcome
    }

    func approveSubscriptionBackfill(_ approval: SubscriptionBackfillApproval) async throws -> SubscriptionCommitOutcome {
        let outcome = try await store.approveSubscriptionBackfill(approval, limits: automaticLimits())
        if outcome.queuedJobs > 0 { coordinator.wake() }
        return outcome
    }

    @discardableResult
    func drainSubscriptionEvents(subscriptionId: String) async throws -> SubscriptionCommitOutcome {
        let outcome = try await store.drainSubscriptionEvents(subscriptionId: subscriptionId, limits: automaticLimits())
        if outcome.queuedJobs > 0 { coordinator.wake() }
        return outcome
    }

    /// The scanlators the user asked to remember for a series; nil when none were. Throws when the stored
    /// choice could not be read, which is not the same as having none.
    func editionPreference(for media: MediaIdentity) async throws -> EditionSelection? {
        try await dbPool.read { db in try SeriesEditionPreferenceRecord.selection(for: media, in: db) }
    }

    /// The source's current epoch: a settings or credential change rotates it. A reviewed policy choice or
    /// batch is stored only while the epoch it was reviewed under is still current, which the stores verify
    /// inside their write transactions. This is a plain read; only a source with no epoch yet captures one.
    func editionPreferenceEpoch(for pluginID: String) throws -> String {
        if let epoch = try dbPool.read({ db in try PluginCompletionScope.current(pluginID: pluginID, in: db) }) {
            return epoch
        }
        return try captureEpoch(pluginID)
    }

    /// The stored uploads of the anchor's logical unit, read from the store's inventory. Reads only: nothing is
    /// queued, and no preference, plugin or network is touched.
    func downloadedAlternatives(
        for anchor: OfflineChapterAlternativeAnchor
    ) async throws -> DownloadedChapterAlternatives {
        try await store.downloadedAlternatives(for: anchor)
    }

    /// The source's epoch as stored, nil when it has none. Unlike `editionPreferenceEpoch` it never captures
    /// one, and a read that fails throws rather than reading as an absent epoch.
    func downloadedAlternativeEpoch(for pluginID: String) throws -> String? {
        do {
            return try dbPool.read { db in try PluginCompletionScope.current(pluginID: pluginID, in: db) }
        } catch {
            throw DownloadedAlternativeError.inventoryUnavailable
        }
    }

    /// Leases exactly the listed copy, or fails; see `OfflineChapterStore.openDownloadedAlternative`.
    func openDownloadedAlternative(
        _ candidate: DownloadedChapterAlternative,
        sourceEpoch: String?
    ) async throws -> OfflineChapterLease {
        try await store.openDownloadedAlternative(candidate, sourceEpoch: sourceEpoch)
    }

    /// Remembers the scanlators chosen for a series, replacing an earlier choice. Throws when it could not
    /// be written, when the series is no longer saved, or when `sourceEpoch` is no longer the source's.
    func setEditionPreference(
        _ selection: EditionSelection,
        for media: MediaIdentity,
        sourceEpoch: String
    ) async throws {
        let now = Date()
        try await dbPool.write { db in
            guard try PluginCompletionScope.current(pluginID: media.pluginId, in: db) == sourceEpoch else {
                throw SeriesEditionPreferenceError.sourceChanged
            }
            let candidates = ImportedMediaIdentity.localItemIDs(
                pluginId: media.pluginId,
                canonicalMediaId: media.canonicalMediaId,
                mediaKind: media.mediaKind
            )
            let exists = try candidates.contains { id in
                guard let item = try LibraryItem.fetchOne(db, key: id) else { return false }
                return item.mediaIdentity == media
            }
            guard exists else { throw SeriesEditionPreferenceError.seriesNotSaved }
            try SeriesEditionPreferenceRecord.save(selection, for: media, at: now, in: db)
        }
    }

    /// The free space where downloads are stored; nil when it cannot be read.
    func availableCapacity() async -> Int64? {
        try? await store.availableDownloadCapacity()
    }

    /// The bytes one series' stored copies occupy, damaged copies included; nil when they cannot be read.
    func storedByteCount(for media: MediaIdentity) async -> Int64? {
        try? await store.inventoryByteCount(for: media)
    }

    private func queuedJob(for edition: OfflineChapterEdition) async throws -> DownloadJobRecord? {
        try await store.job(for: edition)
    }

    private func apply(_ current: DownloadTableSnapshot) {
        // A batch that was listed and no longer is finished or was cancelled, so its metered-data consent ends. A
        // batch never listed keeps its consent: a snapshot older than the enqueue must not take back a grant that
        // was minted right after it.
        let before = Set(snapshot.jobs.compactMap { UUID(uuidString: $0.batchId) })
        let after = Set(current.jobs.compactMap { UUID(uuidString: $0.batchId) })
        for batchID in before.subtracting(after) {
            contexts.policy.revokeConsent(forBatch: batchID)
        }
        snapshot = current
        // A running job the observation does not list was cancelled, deleted or moved away: stop its attempt
        // now instead of at the next gate. The commit's job check still decides correctness.
        if let runningID = coordinator.runningJobID, !current.jobs.contains(where: { $0.id == runningID }) {
            Task { await self.cancelAttemptIfJobIsGone(runningID) }
        }
        // Derived from the tables, not from `states`, which page progress republishes many times a second.
        let summary = LibraryDownloadSummary(copies: current.copies, jobs: current.jobs)
        if summary != librarySummary { librarySummary = summary }
        republish(progress: progress.progress)
    }

    /// An observed snapshot can predate a job that has just started running, so absence from it is
    /// confirmed against the store first. A removed job never comes back under the same id.
    private func cancelAttemptIfJobIsGone(_ jobID: String) async {
        do {
            guard try await store.job(id: jobID) == nil else { return }
        } catch {
            return
        }
        coordinator.cancelAttempt(jobID: jobID)
    }

    private func republish(progress current: [String: DownloadProgress]) {
        // A database change republishes the same progress; observers hear only real changes.
        if jobProgress != current { jobProgress = current }
        states = Self.states(copies: snapshot.copies, jobs: snapshot.jobs, progress: current)
        let activity = Self.replacementStates(copies: snapshot.copies, jobs: snapshot.jobs, progress: current)
        if chapterReplacementStates != activity { chapterReplacementStates = activity }
    }

    /// The per-media state map. A verified copy wins over a queued job for the same chapter.
    nonisolated static func states(
        copies: [DownloadedChapterRecord],
        jobs: [DownloadJobRecord],
        progress: [String: DownloadProgress]
    ) -> [MediaIdentity: [String: ChapterDownloadState]] {
        var result: [MediaIdentity: [String: ChapterDownloadState]] = [:]
        for copy in copies {
            let identity = MediaIdentity(
                pluginId: copy.pluginId,
                canonicalMediaId: copy.canonicalMediaId,
                mediaKind: copy.mediaKind
            )
            result[identity, default: [:]][copy.chapterKey] = copy.state == .verified ? .downloaded : .damaged
        }
        for job in jobs {
            let identity = MediaIdentity(
                pluginId: job.pluginId,
                canonicalMediaId: job.canonicalMediaId,
                mediaKind: job.mediaKind
            )
            if result[identity]?[job.chapterKey] != nil {
                continue
            }
            result[identity, default: [:]][job.chapterKey] = state(of: job, progress: progress[job.id])
        }
        return result
    }

    /// The replacement activity over each chapter whose verified copy stays readable. A job for an edition that has
    /// a verified copy can only be a replacement, because an ordinary enqueue refuses a saved chapter. Keyed like
    /// `states`.
    nonisolated static func replacementStates(
        copies: [DownloadedChapterRecord],
        jobs: [DownloadJobRecord],
        progress: [String: DownloadProgress]
    ) -> [MediaIdentity: [String: ChapterDownloadState]] {
        let verified = Set(copies.filter { $0.state == .verified }.map(\.edition))
        var result: [MediaIdentity: [String: ChapterDownloadState]] = [:]
        for job in jobs where verified.contains(job.edition) {
            let identity = MediaIdentity(
                pluginId: job.pluginId,
                canonicalMediaId: job.canonicalMediaId,
                mediaKind: job.mediaKind
            )
            result[identity, default: [:]][job.chapterKey] = state(of: job, progress: progress[job.id])
        }
        return result
    }

    nonisolated static func state(of job: DownloadJobRecord, progress: DownloadProgress?) -> ChapterDownloadState {
        switch job.state {
        case .queued:
            return .queued
        case .downloading:
            return .downloading(completed: progress?.completedPages ?? 0, total: progress?.totalPages)
        case .waiting:
            return .waiting(job.waitingReason ?? .networkUnknown)
        case .failed:
            return .failed(job.failureReason ?? .sourceError)
        }
    }
}

/// The subscription ledger's side of a catalog check: `UpdateManager` hands over the one fetch's observation and the
/// center commits it through the store, then wakes the worker when the commit queued jobs.
extension DownloadCenter: SubscriptionCatalogSink {
    func begin(media: MediaIdentity) async -> SubscriptionCheckTicket? {
        guard let epoch = try? captureEpoch(media.pluginId) else { return nil }
        return try? await store.beginSubscriptionCheck(media: media, capturedEpoch: epoch)
    }

    func commit(_ ticket: SubscriptionCheckTicket, _ observation: CatalogObservation) async {
        guard let outcome = try? await store.commitSubscriptionObservation(
            ticket, observation, limits: automaticLimits()
        ) else {
            AppLogger.database.error("A subscription catalog commit failed")
            return
        }
        if outcome.queuedJobs > 0 { coordinator.wake() }
    }

    func fail(_ ticket: SubscriptionCheckTicket, _ outcome: SubscriptionCheckOutcome) async {
        do {
            try await store.recordSubscriptionCheckFailure(ticket, outcome)
        } catch {
            AppLogger.database.error("A subscription check failure could not be recorded")
        }
    }
}
