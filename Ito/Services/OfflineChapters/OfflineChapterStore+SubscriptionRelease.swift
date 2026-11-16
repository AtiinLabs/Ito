import Foundation
import GRDB
import ito_runner

/// Releasing a subscription's claim on the queue. Every path that ends or restarts a subscription (disable, delete,
/// removing the series from the Library, moving it to another source, a restored database) runs the same routine in
/// the caller's transaction, so a job never loses its owner without being removed and never keeps an owner that no
/// longer exists. Completed files are never touched: they have no owner.
extension OfflineChapterStore {
    /// Removes this subscription's owner rows and, for every job left with no owner at all, the job and the batch it
    /// leaves empty. A job another owner still holds stays, with that owner. Returns what was removed, so the caller can
    /// end the attempts and clean the staging directories after the transaction.
    @discardableResult
    nonisolated static func releaseOwners(ofSubscription subscriptionId: String, in db: Database) throws -> SubscriptionRelease {
        let jobIds = try String.fetchAll(
            db,
            sql: "SELECT DISTINCT jobId FROM downloadJobOwner WHERE subscriptionId = ?",
            arguments: [subscriptionId]
        )
        try db.execute(sql: "DELETE FROM downloadJobOwner WHERE subscriptionId = ?", arguments: [subscriptionId])
        var release = SubscriptionRelease()
        for jobId in jobIds {
            let remaining = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM downloadJobOwner WHERE jobId = ?", arguments: [jobId]
            ) ?? 0
            guard remaining == 0, let job = try DownloadJobRecord.fetchOne(db, key: jobId) else { continue }
            if let staging = job.stagingVersionId { release.stagingVersionIds.append(staging) }
            try deleteJob(id: job.id, batchId: job.batchId, in: db)
            release.removedJobIds.append(job.id)
        }
        return release
    }

    /// Disables a subscription: its jobs that nobody else asked for are removed, its open events are revoked, its
    /// baseline and seen keys are deleted, and its configuration generation grows so a sheet that was open is stale.
    /// The row stays, disabled, and can be enabled again as a new incarnation.
    @discardableResult
    nonisolated static func disableSubscription(
        _ subscription: SeriesSubscriptionRecord,
        now: Date,
        in db: Database
    ) throws -> SubscriptionRelease {
        let release = try releaseOwners(ofSubscription: subscription.id, in: db)
        try SubscriptionLedger.discardEvidence(of: subscription.id, now: now, in: db)
        var disabled = subscription
        disabled.state = .disabled
        disabled.pauseReason = nil
        disabled.configGeneration += 1
        disabled.updatedAt = now
        try disabled.update(db)
        return release
    }

    /// Deletes a subscription row after releasing its owners. Its events, baseline and seen keys go with it.
    @discardableResult
    nonisolated static func deleteSubscription(
        _ subscription: SeriesSubscriptionRecord,
        in db: Database
    ) throws -> SubscriptionRelease {
        let release = try releaseOwners(ofSubscription: subscription.id, in: db)
        _ = try SeriesSubscriptionRecord.deleteOne(db, key: subscription.id)
        return release
    }

    /// Removing a series from the Library ends its automatic rule, in the same transaction.
    @discardableResult
    nonisolated static func removeSubscription(for media: MediaIdentity, in db: Database) throws -> SubscriptionRelease {
        guard let subscription = try SeriesSubscriptionRecord.forMedia(media).fetchOne(db) else {
            return SubscriptionRelease()
        }
        return try deleteSubscription(subscription, in: db)
    }

    /// A restore can remove series from the Library without going through `removeItemsDurably`. Every rule whose series
    /// no longer has a Library item is released and deleted, so no job it asked for outlives it. The caller runs it
    /// last in the restore transaction, after the Library is final. A running attempt of a removed job ends through the
    /// publication check (`jobGone`) and the center's absence cancel; its unreferenced staging is collected later.
    @discardableResult
    nonisolated static func releaseSubscriptionsOfUnsavedSeries(in db: Database) throws -> SubscriptionRelease {
        var release = SubscriptionRelease()
        for subscription in try SeriesSubscriptionRecord.order(Column("id")).fetchAll(db) {
            guard try !libraryItemExists(for: subscription.media, in: db) else { continue }
            let released = try deleteSubscription(subscription, in: db)
            release.removedJobIds += released.removedJobIds
            release.stagingVersionIds += released.stagingVersionIds
        }
        return release
    }

    /// A database that came from another installation: every rule that was running or paused is quarantined. It is
    /// paused for review as a new incarnation, its baseline, seen keys and open events are gone, its owners are
    /// released and the jobs only it asked for are removed. Runtime baselines and grants are not portable. Disabled
    /// rules have no evidence and stay as they are.
    nonisolated static func quarantineSubscriptionsAfterRestore(now: Date, in db: Database) throws {
        let subscriptions = try SeriesSubscriptionRecord
            .filter(Column("state") != SubscriptionState.disabled.rawValue)
            .fetchAll(db)
        for subscription in subscriptions {
            try releaseOwners(ofSubscription: subscription.id, in: db)
            try SubscriptionLedger.discardEvidence(of: subscription.id, now: now, in: db)
            var quarantined = subscription
            quarantined.state = .paused
            quarantined.pauseReason = .restored
            quarantined.incarnation += 1
            quarantined.configGeneration += 1
            quarantined.updatedAt = now
            try quarantined.update(db)
        }
        try deleteOwnerlessJobs(in: db)
    }

    /// A series that moved from one identity to another. Inside one plugin and kind, with no rule of its own at the
    /// destination, the rule follows it: a new incarnation, paused as remapped, without the evidence of the old
    /// series. Logical IDs and seen keys never transfer. Otherwise the rule is released and deleted. The series' jobs
    /// have already been deleted by the caller, which took their owner rows with them.
    nonisolated static func rekeySubscription(
        from: MediaIdentity,
        to: MediaIdentity,
        now: Date,
        in db: Database
    ) throws {
        guard let subscription = try SeriesSubscriptionRecord.forMedia(from).fetchOne(db) else { return }
        let destinationHasRule = try SeriesSubscriptionRecord.forMedia(to).fetchCount(db) > 0
        guard from.pluginId == to.pluginId, from.mediaKind == to.mediaKind, !destinationHasRule else {
            try deleteSubscription(subscription, in: db)
            return
        }
        try releaseOwners(ofSubscription: subscription.id, in: db)
        try SubscriptionLedger.discardEvidence(of: subscription.id, now: now, in: db)
        var moved = subscription
        moved.canonicalMediaId = to.canonicalMediaId
        moved.incarnation += 1
        moved.configGeneration += 1
        if moved.state != .disabled {
            moved.state = .paused
            moved.pauseReason = .sourceRemapped
        }
        moved.updatedAt = now
        try moved.update(db)
    }
}
