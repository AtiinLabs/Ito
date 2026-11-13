import Foundation
import GRDB
import ito_runner

extension OfflineChapterStore {
    func replacementIntent(jobID: String) async throws -> DownloadReplacementIntent? {
        try await database.read { db in try DownloadReplacementIntent.fetchOne(db, key: jobID) }
    }

    /// Queues a manual replacement of one installed copy. The approval names the installed version, its
    /// revision and the source epoch, so a replacement never takes whichever copy exists later. Nothing is
    /// deleted, no suppression is cleared and no network is used. A terminal replacement record of the same
    /// edition is superseded in this transaction; any other job for the edition wins. Suppression tombstones
    /// are never touched.
    func enqueueReplacement(_ request: DownloadReplacementRequest) async throws -> DownloadEnqueueOutcome {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        let target = request.download
        guard target.mediaKind == .manga || target.mediaKind == .novel else { return .refused(.unsupportedKind) }
        guard target.chapter.paywalled != true else { return .refused(.paywalled) }
        guard let epoch = target.sourceEpoch else { return .refused(.unavailable) }
        let entry = try JSONEncoder().encode(target.entry)
        let chapter = try JSONEncoder().encode(target.chapter)
        let batchID = UUID().uuidString
        let jobID = UUID().uuidString
        let now = clock()
        return try await database.write { db -> DownloadEnqueueOutcome in
            guard try PluginCompletionScope.current(pluginID: target.pluginId, in: db) == epoch,
                  let old = try DownloadedChapterRecord.filter(target.edition.predicate).fetchOne(db),
                  old.state == .verified, old.versionId == request.expectedVersionId,
                  old.manifestIdentity == target.edition,
                  old.sourceEpoch == epoch,
                  try Self.installedRevision(old) == request.expectedRevision,
                  try DownloadSuppressionRecord.filter(target.edition.predicate).fetchCount(db) == 0 else {
                return .refused(.unavailable)
            }
            if let existing = try DownloadJobRecord.filter(target.edition.predicate).fetchOne(db) {
                guard existing.failureReason?.endsReplacement == true else { return .alreadyQueued }
                try Self.deleteJob(id: existing.id, batchId: existing.batchId, in: db)
            }
            try DownloadBatchRecord(
                id: batchID, pluginId: target.pluginId, mediaKind: target.mediaKind,
                canonicalMediaId: target.canonicalMediaId, preset: .single,
                selection: DownloadBatchRecord.sourceListSelection, catalogDigest: nil,
                entrySnapshot: entry, createdAt: now
            ).insert(db)
            try DownloadJobRecord(
                id: jobID, batchId: batchID, sequence: 0, pluginId: target.pluginId,
                mediaKind: target.mediaKind, canonicalMediaId: target.canonicalMediaId,
                chapterKey: target.chapter.key, authorityScope: target.edition.authorityScope,
                chapterSnapshot: chapter, seriesTitle: target.seriesTitle, sourceEpoch: epoch,
                state: .queued, waitingReason: nil, failureReason: nil, stagingVersionId: nil,
                attemptCount: 0, createdAt: now, updatedAt: now
            ).insert(db)
            try DownloadReplacementIntent(
                jobId: jobID, expectedVersionId: old.versionId, expectedRevision: request.expectedRevision,
                targetRevision: DownloadReplacementIntent.revision(target.chapter), sourceEpoch: epoch,
                authorizationId: request.authorizationId
            ).insert(db)
            return .queued
        }
    }

    /// Ends a queued or waiting replacement whose confirmation no longer applies. A replacement cannot follow
    /// the source to a new epoch, so it never waits for a Retry that could not revive it. Returns true when the
    /// job ended here.
    func settleStaleReplacement(jobID: String, currentEpoch: String?) async throws -> Bool {
        let now = clock()
        return try await database.write { db -> Bool in
            guard var job = try DownloadJobRecord.fetchOne(db, key: jobID),
                  job.state == .queued || job.state == .waiting,
                  let intent = try DownloadReplacementIntent.fetchOne(db, key: jobID),
                  let reason = try Self.staleReplacementReason(
                      job: job, intent: intent, currentEpoch: currentEpoch, in: db
                  ) else {
                return false
            }
            try Self.endReplacement(&job, reason: reason, now: now, in: db)
            return true
        }
    }

    /// The revision of an installed copy's chapter. A snapshot that cannot be decoded throws, so nothing is
    /// approved on it.
    nonisolated static func installedRevision(_ copy: DownloadedChapterRecord) throws -> String? {
        DownloadReplacementIntent.revision(try JSONDecoder().decode(Chapter.self, from: copy.chapterSnapshot))
    }

    /// Why a confirmed replacement no longer applies, or nil while it still does. It reads the state the calling
    /// transaction is about to change, so no decision rests on an older read.
    nonisolated static func staleReplacementReason(
        job: DownloadJobRecord,
        intent: DownloadReplacementIntent,
        currentEpoch: String?,
        in db: Database
    ) throws -> DownloadFailureReason? {
        guard job.sourceEpoch == intent.sourceEpoch, currentEpoch == intent.sourceEpoch else {
            return .replacementStale
        }
        guard let installed = try DownloadedChapterRecord.filter(job.edition.predicate).fetchOne(db),
              installed.versionId == intent.expectedVersionId,
              installed.state == .verified,
              installed.manifestIdentity == job.edition,
              installed.sourceEpoch == intent.sourceEpoch,
              try installedRevision(installed) == intent.expectedRevision,
              try DownloadSuppressionRecord.filter(job.edition.predicate).fetchCount(db) == 0 else {
            return .replacementStale
        }
        return nil
    }

    /// Ends a replacement: the job becomes a failure that Retry cannot revive, and its intent is removed in the
    /// same transaction. The saved copy is not touched.
    nonisolated static func endReplacement(
        _ job: inout DownloadJobRecord,
        reason: DownloadFailureReason,
        now: Date,
        in db: Database
    ) throws {
        _ = try DownloadReplacementIntent.deleteOne(db, key: job.id)
        job.state = .failed
        job.waitingReason = nil
        job.failureReason = reason
        job.stagingVersionId = nil
        job.updatedAt = now
        try job.update(db)
    }

    /// The bytes a replacement needs on top of the reserve: the installed copy it replaces. Zero for an ordinary
    /// job, and for a replacement whose installed copy no longer matches its approval.
    nonisolated static func replacementBytes(for job: DownloadJobRecord, in db: Database) throws -> Int64 {
        guard let intent = try DownloadReplacementIntent.fetchOne(db, key: job.id),
              let installed = try DownloadedChapterRecord.filter(job.edition.predicate).fetchOne(db),
              installed.versionId == intent.expectedVersionId else {
            return 0
        }
        return installed.byteCount
    }
}
