import Foundation
import GRDB
import ito_runner

/// Batch enqueue and the bulk operations. They run the same transactions as the single-chapter ones, and
/// every transaction that removes jobs also deletes the batch its last job leaves empty.
extension OfflineChapterStore {
    // MARK: - Enqueue

    /// P0 for many chapters of one series, in one write transaction: the batch row (the frozen series
    /// snapshot, preset, selection and catalog digest) and one job per chapter that still needs one, in
    /// the request's order. Each chapter is checked again inside the transaction, so a chapter that was
    /// saved or queued since the plan was made, or that repeats inside the request, is counted and
    /// skipped. Locked chapters are refused. An explicit download clears the chapter's delete
    /// suppression. When no job is inserted, no batch is either. A failure inserts nothing.
    ///
    /// - Parameter sourceEpoch: the source's completion epoch, read once by the caller. Nil refuses the
    ///   request.
    func enqueueBatch(_ request: DownloadBatchRequest, sourceEpoch: String?) async throws -> DownloadBatchOutcome {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        guard request.mediaKind == .manga || request.mediaKind == .novel else {
            return .refused(.unsupportedKind)
        }
        // A single locked chapter keeps its refusal whatever else is missing, as a lone enqueue always did.
        if request.chapters.count == 1, request.chapters[0].paywalled == true {
            return DownloadBatchOutcome(refusedLocked: 1)
        }
        guard let sourceEpoch else { return .refused(.unavailable) }
        guard Self.isJSONObject(request.selection), request.catalogDigest.map({ $0.count == 64 }) ?? true else {
            return .refused(.unavailable)
        }
        guard !request.chapters.isEmpty else { return DownloadBatchOutcome() }

        let encoder = JSONEncoder()
        let entrySnapshot = try encoder.encode(request.entry)
        let chapterSnapshots = try request.chapters.map { try encoder.encode($0) }
        let now = clock()
        let batchId = UUID().uuidString
        let jobIDs = request.chapters.map { _ in UUID().uuidString }

        return try await database.write { db -> DownloadBatchOutcome in
            // A batch reviewed under one source epoch never queues under another.
            if let reviewed = request.reviewedSourceEpoch {
                guard sourceEpoch == reviewed,
                      try PluginCompletionScope.current(pluginID: request.pluginId, in: db) == reviewed else {
                    return .refused(.sourceChanged)
                }
            }
            // A batch planned under one remembered policy never queues under another one.
            if let reviewedPolicy = request.reviewedPolicy {
                let media = MediaIdentity(
                    pluginId: request.pluginId, canonicalMediaId: request.canonicalMediaId, mediaKind: request.mediaKind
                )
                let stored: ReviewedEditionPolicy
                do {
                    if let selection = try SeriesEditionPreferenceRecord.selection(for: media, in: db) {
                        stored = .selection(selection)
                    } else {
                        stored = ReviewedEditionPolicy.none
                    }
                } catch SeriesEditionPreferenceError.unreadable {
                    stored = .unreadable
                }
                guard stored == reviewedPolicy else { return .refused(.policyChanged) }
            }
            var outcome = DownloadBatchOutcome()
            var pending: [Int] = []
            var requestedKeys = Set<String>()
            for (index, chapter) in request.chapters.enumerated() {
                guard chapter.paywalled != true else {
                    outcome.refusedLocked += 1
                    continue
                }
                let edition = OfflineChapterEdition(
                    pluginId: request.pluginId,
                    mediaKind: request.mediaKind,
                    canonicalMediaId: request.canonicalMediaId,
                    chapterKey: chapter.key
                )
                if let existing = try DownloadedChapterRecord.filter(edition.predicate).fetchOne(db) {
                    if existing.state == .verified {
                        outcome.alreadySaved += 1
                    } else {
                        outcome.blockedDamaged += 1
                    }
                    continue
                }
                var isQueued = !requestedKeys.insert(chapter.key).inserted
                if !isQueued {
                    isQueued = try DownloadJobRecord.filter(edition.predicate).fetchCount(db) > 0
                }
                if isQueued {
                    outcome.alreadyQueued += 1
                    continue
                }
                pending.append(index)
            }
            guard !pending.isEmpty else { return outcome }

            try DownloadBatchRecord(
                id: batchId,
                pluginId: request.pluginId,
                mediaKind: request.mediaKind,
                canonicalMediaId: request.canonicalMediaId,
                preset: request.preset,
                selection: request.selection,
                catalogDigest: request.catalogDigest,
                entrySnapshot: entrySnapshot,
                createdAt: now
            ).insert(db)
            for index in pending {
                let chapter = request.chapters[index]
                let edition = OfflineChapterEdition(
                    pluginId: request.pluginId,
                    mediaKind: request.mediaKind,
                    canonicalMediaId: request.canonicalMediaId,
                    chapterKey: chapter.key
                )
                _ = try DownloadSuppressionRecord.filter(edition.predicate).deleteAll(db)
                try DownloadJobRecord(
                    id: jobIDs[index],
                    batchId: batchId,
                    sequence: index,
                    pluginId: edition.pluginId,
                    mediaKind: edition.mediaKind,
                    canonicalMediaId: edition.canonicalMediaId,
                    chapterKey: edition.chapterKey,
                    authorityScope: edition.authorityScope,
                    chapterSnapshot: chapterSnapshots[index],
                    seriesTitle: request.seriesTitle,
                    sourceEpoch: sourceEpoch,
                    state: .queued,
                    waitingReason: nil,
                    failureReason: nil,
                    stagingVersionId: nil,
                    attemptCount: 0,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
            }
            outcome.queued = pending.count
            outcome.batchId = batchId
            return outcome
        }
    }

    nonisolated private static func isJSONObject(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    // MARK: - Bulk cancel and retry

    /// Removes these jobs and every batch they leave empty in one transaction. Jobs that no longer exist
    /// are skipped. Returns the jobs removed, so the caller can clean up their staging directories.
    func removeJobs(ids: [String]) async throws -> [DownloadJobRecord] {
        try await database.write { db -> [DownloadJobRecord] in
            var removed: [DownloadJobRecord] = []
            for id in ids {
                guard let job = try DownloadJobRecord.fetchOne(db, key: id) else { continue }
                _ = try DownloadJobRecord.deleteOne(db, key: id)
                removed.append(job)
            }
            for batchId in Set(removed.map(\.batchId)) {
                try Self.deleteBatchIfOrphaned(batchId, in: db)
            }
            return removed
        }
    }

    /// Re-queues failed and waiting jobs in one transaction, re-freezing each job's source epoch from
    /// `epochs`, which the caller read per plugin. Queued, downloading and missing jobs are skipped. A
    /// job whose plugin has no epoch fails the whole call and changes nothing. Returns the number of
    /// jobs re-queued.
    @discardableResult
    func retry(jobIDs: [String], epochs: [String: String]) async throws -> Int {
        let now = clock()
        return try await database.write { db -> Int in
            var requeued = 0
            for id in jobIDs {
                guard var job = try DownloadJobRecord.fetchOne(db, key: id) else { continue }
                switch job.state {
                case .queued, .downloading:
                    continue
                case .failed, .waiting:
                    break
                }
                guard let epoch = epochs[job.pluginId] else { throw OfflineStoreError.jobUnavailable }
                job.state = .queued
                job.waitingReason = nil
                job.failureReason = nil
                job.sourceEpoch = epoch
                job.updatedAt = now
                try job.update(db)
                requeued += 1
            }
            return requeued
        }
    }

    // MARK: - Queue reads

    /// The jobs with these ids that still exist, in queue order.
    func jobs(ids: [String]) async throws -> [DownloadJobRecord] {
        try await database.read { db in
            try DownloadJobRecord.filter(keys: ids).order(DownloadJobRecord.queueOrder).fetchAll(db)
        }
    }

    /// The job for one edition, by an indexed lookup on the edition's identity.
    func job(for edition: OfflineChapterEdition) async throws -> DownloadJobRecord? {
        try await database.read { db in
            try DownloadJobRecord.filter(edition.predicate).fetchOne(db)
        }
    }

    /// The queued job that runs next, with its batch's frozen series snapshot: the oldest batch first,
    /// then the batch's own order. Jobs that are waiting, downloading or failed are never returned.
    func nextQueuedJob() async throws -> DownloadJobWork? {
        try await database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT downloadJob.*, downloadBatch.entrySnapshot AS entrySnapshot
                    FROM downloadJob
                    JOIN downloadBatch ON downloadBatch.id = downloadJob.batchId
                    WHERE downloadJob.state = ?
                    ORDER BY downloadJob.createdAt, downloadJob.batchId, downloadJob.sequence, downloadJob.id
                    LIMIT 1
                    """,
                arguments: [DownloadJobState.queued.rawValue]
            ) else { return nil }
            let entrySnapshot: Data = row["entrySnapshot"]
            return DownloadJobWork(job: try DownloadJobRecord(row: row), entrySnapshot: entrySnapshot)
        }
    }

    // MARK: - Bulk delete rows

    /// What D1 removed: the versions of the deleted copies and the staging versions of the deleted jobs,
    /// for the file-system steps that follow the transaction.
    nonisolated struct RemovedRows: Sendable {
        var versionIds: [String] = []
        var stagingVersionIds: [String] = []
        var removedJobs = 0
    }

    /// D1: deletes the inventory rows and jobs the scope names, records a suppression for each deleted
    /// copy when asked, and deletes every batch the removed jobs leave empty, in the caller's transaction.
    nonisolated static func removeRows(
        _ scope: OfflineDeleteScope,
        suppress: Bool,
        now: Date,
        in db: Database
    ) throws -> RemovedRows {
        var rows: [DownloadedChapterRecord] = []
        var jobs: [DownloadJobRecord] = []
        switch scope {
        case .editions(let editions):
            for edition in Set(editions) {
                if let row = try DownloadedChapterRecord.filter(edition.predicate).fetchOne(db) {
                    rows.append(row)
                }
                if let job = try DownloadJobRecord.filter(edition.predicate).fetchOne(db) {
                    jobs.append(job)
                }
            }
        case .media(let media):
            let predicate = Column("pluginId") == media.pluginId
                && Column("mediaKind") == media.mediaKind.rawValue
                && Column("canonicalMediaId") == media.canonicalMediaId
            rows = try DownloadedChapterRecord.filter(predicate).fetchAll(db)
            jobs = try DownloadJobRecord.filter(predicate).fetchAll(db)
        }

        for row in rows {
            _ = try DownloadedChapterRecord.filter(row.edition.predicate).deleteAll(db)
            if suppress {
                try DownloadSuppressionRecord(
                    pluginId: row.pluginId,
                    mediaKind: row.mediaKind,
                    canonicalMediaId: row.canonicalMediaId,
                    chapterKey: row.chapterKey,
                    authorityScope: row.authorityScope,
                    suppressedAt: now
                ).insert(db, onConflict: .replace)
            }
        }
        for job in jobs {
            _ = try DownloadJobRecord.deleteOne(db, key: job.id)
        }
        for batchId in Set(jobs.map(\.batchId)) {
            try deleteBatchIfOrphaned(batchId, in: db)
        }
        return RemovedRows(
            versionIds: rows.map(\.versionId),
            stagingVersionIds: jobs.compactMap(\.stagingVersionId),
            removedJobs: jobs.count
        )
    }

    // MARK: - Batch rows

    /// Deletes a job and, when it was the batch's last one, the batch.
    nonisolated static func deleteJob(id: String, batchId: String, in db: Database) throws {
        _ = try DownloadJobRecord.deleteOne(db, key: id)
        try deleteBatchIfOrphaned(batchId, in: db)
    }

    nonisolated static func deleteBatchIfOrphaned(_ batchId: String, in db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM downloadBatch
                WHERE id = ? AND NOT EXISTS (SELECT 1 FROM downloadJob WHERE batchId = ?)
                """,
            arguments: [batchId, batchId]
        )
    }

    /// Removes batches no job references. Every job-removing transaction deletes its own batch when it
    /// was the last job, so a batch only outlives its jobs when something wrote the tables around the
    /// store (a restore, a repair). The batch freezes nothing once it has no jobs.
    func sweepOrphanBatches(_ details: inout OfflineReconcileDetails) async throws {
        details.removedOrphanBatches = try await database.write { db in
            try db.execute(sql: """
                DELETE FROM downloadBatch
                WHERE NOT EXISTS (SELECT 1 FROM downloadJob WHERE downloadJob.batchId = downloadBatch.id)
                """)
            return db.changesCount
        }
    }

    // MARK: - Inventory totals

    nonisolated private struct InventoryAggregate: Decodable, FetchableRecord {
        let pluginId: String
        let mediaKind: MediaKind
        let canonicalMediaId: String
        let state: DownloadedChapterState
        let chapterCount: Int
        let totalBytes: Int64
    }

    /// The bytes one series' stored copies occupy, damaged copies included.
    func inventoryByteCount(for media: MediaIdentity) async throws -> Int64 {
        try await database.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(byteCount), 0) FROM downloadedChapter
                WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?
                """, arguments: [media.pluginId, media.mediaKind.rawValue, media.canonicalMediaId]) ?? 0
        }
    }

    /// Inventory totals include damaged copies: they still occupy storage until explicitly deleted.
    func inventorySummary() async throws -> [OfflineInventorySummary] {
        try await database.read { db in
            try InventoryAggregate.fetchAll(db, sql: """
                SELECT pluginId, mediaKind, canonicalMediaId, state,
                       COUNT(*) AS chapterCount, SUM(byteCount) AS totalBytes
                FROM downloadedChapter
                GROUP BY pluginId, mediaKind, canonicalMediaId, state
                ORDER BY pluginId, mediaKind, canonicalMediaId, state
                """).map { row in
                OfflineInventorySummary(
                    media: MediaIdentity(
                        pluginId: row.pluginId,
                        canonicalMediaId: row.canonicalMediaId,
                        mediaKind: row.mediaKind
                    ),
                    state: row.state,
                    count: row.chapterCount,
                    byteCount: row.totalBytes
                )
            }
        }
    }
}
