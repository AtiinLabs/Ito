import Foundation
import GRDB
import ito_runner

/// Who asked for a job. Every request path inserts its jobs through `insertBatch` or `insertReplacementJob` with one
/// of these, so a job always has at least one owner (invariant J1) and a deduplicated request still attaches.
nonisolated enum DownloadRequestOwner: Sendable, Equatable {
    /// One explicit request; its batch is the request. It clears the deletion record of every key it inserts.
    case manual(requestId: String)
    /// One event of one subscription incarnation. It never clears a deletion record: a key the user deleted on
    /// purpose is skipped.
    case subscription(id: String, incarnation: Int64, eventId: String)
}

/// A batch whose identifiers were allocated before the write: the one input of `insertBatch`.
nonisolated struct PreparedDownloadBatch: Sendable {
    let pluginId: String
    let mediaKind: MediaKind
    let canonicalMediaId: String
    /// `JSONEncoder().encode(MediaEntry)`, frozen on the batch.
    let entrySnapshot: Data
    let seriesTitle: String
    let provenance: DownloadBatchProvenance
    let selection: Data
    let catalogDigest: String?
    let chapters: [Chapter]
    /// `JSONEncoder().encode(chapter)` for each chapter, in the same order.
    let chapterSnapshots: [Data]
    /// For a manual request this is also the request identity.
    let batchId: String
    /// One identifier per chapter, in the same order. A chapter that already has a job does not use its own.
    let jobIds: [String]
    let sourceEpoch: String
    /// The position of this call's first chapter inside the batch, when several calls share one batch row.
    var sequenceOffset = 0
}

/// What became of one requested chapter.
nonisolated enum DownloadChapterDisposition: Sendable, Equatable {
    case inserted(jobId: String)
    /// A job existed; this owner was added to it.
    case attached(jobId: String)
    /// A job existed and this owner already had it.
    case alreadyOwned(jobId: String)
    case alreadySaved
    case blockedDamaged
    case locked
    case suppressed
    case repeatedInRequest
}

extension OfflineChapterStore {
    // MARK: - Shared enqueue core

    /// The per-chapter loop of every batch, in the caller's transaction: locked, then a stored copy (verified
    /// is saved, damaged is blocked), then (for a subscription) a deletion record, then a repeat inside the
    /// request, then an existing job, which gains this owner. Whatever is left becomes a job, in request order.
    /// The batch row is inserted when a job is, unless an earlier call of the same transaction already
    /// inserted it. A manual job clears the edition's deletion record; a subscription's job never does.
    nonisolated static func insertBatch(
        _ batch: PreparedDownloadBatch,
        owner: DownloadRequestOwner,
        now: Date,
        in db: Database
    ) throws -> (outcome: DownloadBatchOutcome, dispositions: [DownloadChapterDisposition]) {
        var outcome = DownloadBatchOutcome()
        var dispositions: [DownloadChapterDisposition] = []
        var pending: [Int] = []
        var requestedKeys = Set<String>()
        let isAutomatic: Bool
        if case .subscription = owner { isAutomatic = true } else { isAutomatic = false }

        for (index, chapter) in batch.chapters.enumerated() {
            guard chapter.paywalled != true else {
                outcome.refusedLocked += 1
                dispositions.append(.locked)
                continue
            }
            let edition = OfflineChapterEdition(
                pluginId: batch.pluginId, mediaKind: batch.mediaKind,
                canonicalMediaId: batch.canonicalMediaId, chapterKey: chapter.key
            )
            if let existing = try DownloadedChapterRecord.filter(edition.predicate).fetchOne(db) {
                if existing.state == .verified {
                    outcome.alreadySaved += 1
                    dispositions.append(.alreadySaved)
                } else {
                    outcome.blockedDamaged += 1
                    dispositions.append(.blockedDamaged)
                }
                continue
            }
            if isAutomatic, try DownloadSuppressionRecord.filter(edition.predicate).fetchCount(db) > 0 {
                outcome.suppressed += 1
                dispositions.append(.suppressed)
                continue
            }
            guard requestedKeys.insert(chapter.key).inserted else {
                outcome.alreadyQueued += 1
                dispositions.append(.repeatedInRequest)
                continue
            }
            if let job = try DownloadJobRecord.filter(edition.predicate).fetchOne(db) {
                let attached = try attachOwner(owner, toJob: job.id, now: now, in: db)
                outcome.alreadyQueued += 1
                dispositions.append(attached ? .attached(jobId: job.id) : .alreadyOwned(jobId: job.id))
                continue
            }
            pending.append(index)
            dispositions.append(.inserted(jobId: batch.jobIds[index]))
        }
        outcome.requestId = batch.batchId
        guard !pending.isEmpty else { return (outcome, dispositions) }

        if try !DownloadBatchRecord.exists(db, key: batch.batchId) {
            try DownloadBatchRecord(
                id: batch.batchId,
                pluginId: batch.pluginId,
                mediaKind: batch.mediaKind,
                canonicalMediaId: batch.canonicalMediaId,
                preset: batch.provenance.preset,
                selection: batch.selection,
                catalogDigest: batch.catalogDigest,
                entrySnapshot: batch.entrySnapshot,
                createdAt: now,
                windowKind: batch.provenance.windowKind,
                positionCount: batch.provenance.positionCount,
                customPresetId: batch.provenance.customPresetId
            ).insert(db)
        }
        for index in pending {
            let edition = OfflineChapterEdition(
                pluginId: batch.pluginId, mediaKind: batch.mediaKind,
                canonicalMediaId: batch.canonicalMediaId, chapterKey: batch.chapters[index].key
            )
            if !isAutomatic {
                _ = try DownloadSuppressionRecord.filter(edition.predicate).deleteAll(db)
            }
            try DownloadJobRecord(
                id: batch.jobIds[index],
                batchId: batch.batchId,
                sequence: batch.sequenceOffset + index,
                pluginId: edition.pluginId,
                mediaKind: edition.mediaKind,
                canonicalMediaId: edition.canonicalMediaId,
                chapterKey: edition.chapterKey,
                authorityScope: edition.authorityScope,
                chapterSnapshot: batch.chapterSnapshots[index],
                seriesTitle: batch.seriesTitle,
                sourceEpoch: batch.sourceEpoch,
                state: .queued,
                waitingReason: nil,
                failureReason: nil,
                stagingVersionId: nil,
                attemptCount: 0,
                createdAt: now,
                updatedAt: now
            ).insert(db)
            _ = try attachOwner(owner, toJob: batch.jobIds[index], now: now, in: db)
        }
        outcome.queued = pending.count
        outcome.batchId = batch.batchId
        return (outcome, dispositions)
    }

    // MARK: - Owner rows

    /// Gives `owner` its row on a job. Returns false when the owner already had one: a manual owner is one
    /// explicit request, a subscription owner is one subscription.
    @discardableResult
    nonisolated static func attachOwner(
        _ owner: DownloadRequestOwner,
        toJob jobId: String,
        now: Date,
        in db: Database
    ) throws -> Bool {
        let row: DownloadJobOwnerRecord
        switch owner {
        case .manual(let requestId):
            let exists = try DownloadJobOwnerRecord
                .filter(Column("jobId") == jobId && Column("ownerKind") == DownloadOwnerKind.manual.rawValue
                        && Column("manualRequestId") == requestId)
                .fetchCount(db) > 0
            guard !exists else { return false }
            row = DownloadJobOwnerRecord(
                jobId: jobId, ownerKind: .manual, manualRequestId: requestId,
                subscriptionId: nil, subscriptionIncarnation: nil, eventId: nil, attachedAt: now
            )
        case .subscription(let id, let incarnation, let eventId):
            let exists = try DownloadJobOwnerRecord
                .filter(Column("jobId") == jobId && Column("ownerKind") == DownloadOwnerKind.subscription.rawValue
                        && Column("subscriptionId") == id)
                .fetchCount(db) > 0
            guard !exists else { return false }
            row = DownloadJobOwnerRecord(
                jobId: jobId, ownerKind: .subscription, manualRequestId: nil,
                subscriptionId: id, subscriptionIncarnation: incarnation, eventId: eventId, attachedAt: now
            )
        }
        try row.insert(db)
        return true
    }

    /// The owners of a job, for the policy that decides its attempt.
    nonisolated static func ownership(ofJob jobId: String, in db: Database) throws -> DownloadJobOwnership {
        var ownership = DownloadJobOwnership()
        for owner in try DownloadJobOwnerRecord.filter(Column("jobId") == jobId).order(Column("attachedAt"), Column("rowid")).fetchAll(db) {
            if let request = owner.manualRequestId { ownership.manualRequestIds.append(request) }
            if let subscription = owner.subscriptionId { ownership.subscriptionIds.append(subscription) }
        }
        return ownership
    }

    /// SQL that is true when `jobColumn` names a job with an owner that may start it now: a manual owner, or (with
    /// the single `?` argument set to 1) an enabled subscription of the incarnation that asked. Paused and
    /// quota-blocked automatic work stays queued and is simply not started.
    nonisolated static func eligibleOwnerSQL(jobColumn: String) -> String {
        """
        EXISTS (
            SELECT 1 FROM downloadJobOwner o LEFT JOIN seriesSubscription s ON s.id = o.subscriptionId
            WHERE o.jobId = \(jobColumn)
              AND (o.ownerKind = 'manual'
                   OR (? = 1 AND s.state = 'enabled' AND s.incarnation = o.subscriptionIncarnation))
        )
        """
    }

    /// Whether a job has an owner that may start it. Read in the transaction that starts the attempt.
    nonisolated static func hasEligibleOwner(jobId: String, automaticAdmitted: Bool, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT \(eligibleOwnerSQL(jobColumn: "?"))",
            arguments: [jobId, automaticAdmitted ? 1 : 0]
        ) ?? false
    }

    /// Whether a job's request still stands: a manual owner, or a subscription that is enabled or paused under
    /// the incarnation that asked. Pause keeps the intent, so a paused owner's attempt may still publish; disable
    /// has already removed the job.
    nonisolated static func hasLiveOwner(jobId: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (
                    SELECT 1 FROM downloadJobOwner o LEFT JOIN seriesSubscription s ON s.id = o.subscriptionId
                    WHERE o.jobId = ?
                      AND (o.ownerKind = 'manual'
                           OR (s.state IN ('enabled', 'paused') AND s.incarnation = o.subscriptionIncarnation))
                )
                """,
            arguments: [jobId]
        ) ?? false
    }

    // MARK: - Ownerless jobs

    /// J1 for writes that happened around the store (a restore, a repair): deletes every job without an owner and
    /// the batch it leaves empty. A job nobody asked for is not a transfer to resume.
    func sweepOwnerlessJobs(_ details: inout OfflineReconcileDetails) async throws {
        details.removedOwnerlessJobs = try await database.write { db in
            try Self.deleteOwnerlessJobs(in: db).count
        }
    }

    /// Deletes the jobs that have no owner row, and their emptied batches. Returns them.
    @discardableResult
    nonisolated static func deleteOwnerlessJobs(in db: Database) throws -> [DownloadJobRecord] {
        let jobs = try DownloadJobRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM downloadJob
                WHERE NOT EXISTS (SELECT 1 FROM downloadJobOwner WHERE downloadJobOwner.jobId = downloadJob.id)
                """
        )
        for job in jobs {
            try deleteJob(id: job.id, batchId: job.batchId, in: db)
        }
        return jobs
    }
}
