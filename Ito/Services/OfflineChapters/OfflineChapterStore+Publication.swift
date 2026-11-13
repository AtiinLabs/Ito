import Foundation
import GRDB
import ito_runner

extension OfflineChapterStore {
    /// P5: inserts or compare-and-swaps the inventory row and deletes the job in one transaction. The source
    /// epoch is read here and must equal the epoch frozen on the job. A replacement is checked against its frozen
    /// intent: a confirmation that is missing or that no longer applies ends the replacement as a failure, keeps
    /// the saved copy and refuses the publish. Nothing is replaced on a copy the intent did not name.
    nonisolated static func commitVerifiedEdition(
        _ db: Database,
        jobID: String,
        versionId: String,
        manifest: OfflineChapterManifest,
        manifestSHA256: String,
        commitGuard: OfflineCommitGuard,
        now: Date,
        replacementConfirmation: DownloadReplacementIntent? = nil
    ) throws -> OfflineCommitDecision {
        guard var job = try DownloadJobRecord.fetchOne(db, key: jobID),
              job.stagingVersionId == versionId else {
            return try refusal(.jobGone, versionId: versionId, in: db)
        }
        let replacement = try DownloadReplacementIntent.fetchOne(db, key: jobID)
        let installed = try DownloadedChapterRecord.filter(job.edition.predicate).fetchOne(db)
        let currentEpoch = try PluginCompletionScope.current(pluginID: job.pluginId, in: db)
        if let replacement {
            guard replacementConfirmation == replacement else {
                // The target was not confirmed for this attempt, so its revision is unknown rather than equal.
                try endReplacement(&job, reason: .replacementContentChanged, now: now, in: db)
                return try refusal(.replacementSettled, versionId: versionId, in: db)
            }
            if let reason = try staleReplacementReason(
                job: job, intent: replacement, currentEpoch: currentEpoch, in: db
            ) {
                try endReplacement(&job, reason: reason, now: now, in: db)
                return try refusal(.replacementSettled, versionId: versionId, in: db)
            }
            let target = DownloadReplacementIntent.revision(
                try JSONDecoder().decode(Chapter.self, from: job.chapterSnapshot)
            )
            guard target == replacement.targetRevision else {
                try endReplacement(&job, reason: .replacementContentChanged, now: now, in: db)
                return try refusal(.replacementSettled, versionId: versionId, in: db)
            }
        } else if installed != nil {
            try Self.deleteJob(id: jobID, batchId: job.batchId, in: db)
            return try refusal(.alreadyVerified, versionId: versionId, in: db)
        }
        guard job.sourceEpoch != nil, currentEpoch == job.sourceEpoch else {
            // The source's settings or credentials changed: the user decides whether to fetch again.
            job.state = .waiting
            job.waitingReason = .sourceConfigurationChanged
            job.stagingVersionId = nil
            job.updatedAt = now
            try job.update(db)
            return try refusal(.configurationChanged, versionId: versionId, in: db)
        }
        guard commitGuard(job) else {
            // The plugin or its trust changed under the attempt. Nothing the user chose changed, so the chapter
            // is fetched again by a fresh runtime under the current trust. A replacement keeps its intent.
            job.state = .queued
            job.waitingReason = nil
            job.stagingVersionId = nil
            job.updatedAt = now
            try job.update(db)
            return try refusal(.staleRuntime, versionId: versionId, in: db)
        }
        let snapshot = try inventorySnapshot(of: job.chapterSnapshot)
        let published = DownloadedChapterRecord(
            pluginId: job.pluginId,
            mediaKind: job.mediaKind,
            canonicalMediaId: job.canonicalMediaId,
            chapterKey: job.chapterKey,
            authorityScope: job.authorityScope,
            versionId: versionId,
            state: .verified,
            damageReason: nil,
            contentKind: manifest.contentKind,
            pageCount: manifest.pages.count,
            byteCount: manifest.totalBytes,
            manifestFormatVersion: manifest.formatVersion,
            manifestSHA256: manifestSHA256,
            chapterSnapshot: snapshot,
            seriesTitle: job.seriesTitle,
            sourceEpoch: job.sourceEpoch,
            verifiedAt: now
        )
        if replacement != nil {
            try published.update(db)
        } else {
            try published.insert(db)
        }
        try deleteJob(id: jobID, batchId: job.batchId, in: db)
        return OfflineCommitDecision(outcome: .published(versionId: versionId), versionIsReferenced: true)
    }

    nonisolated private static func refusal(
        _ reason: OfflinePublishRefusal,
        versionId: String,
        in db: Database
    ) throws -> OfflineCommitDecision {
        OfflineCommitDecision(
            outcome: .refused(reason),
            versionIsReferenced: try isReferenced(versionId: versionId, in: db)
        )
    }

    /// The inventory copy of a chapter: `url` and `paywalled` are dropped, as the queue's copy
    /// needs them only to fetch pages.
    nonisolated private static func inventorySnapshot(of chapterSnapshot: Data) throws -> Data {
        var chapter = try JSONDecoder().decode(Chapter.self, from: chapterSnapshot)
        chapter.url = nil
        chapter.paywalled = nil
        return try JSONEncoder().encode(chapter)
    }
}

/// The result of P5: the outcome, and whether the version is still referenced afterwards.
nonisolated struct OfflineCommitDecision: Sendable {
    let outcome: OfflinePublishOutcome
    let versionIsReferenced: Bool
}
