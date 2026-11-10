import Foundation
import GRDB
import ito_runner

extension OfflineChapterStore {
    /// Fails closed when moving `from` onto `to` would put two stored copies of one chapter under the same
    /// key. Never overwrites a stored copy, and changes nothing. Runs inside the caller's transaction.
    nonisolated static func preflightRekey(in db: Database, from: MediaIdentity, to: MediaIdentity) throws {
        guard from != to else { return }
        let collision = try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM downloadedChapter source
                    JOIN downloadedChapter destination
                      ON destination.chapterKey = source.chapterKey
                     AND destination.authorityScope = source.authorityScope
                    WHERE source.pluginId = ? AND source.mediaKind = ? AND source.canonicalMediaId = ?
                      AND destination.pluginId = ? AND destination.mediaKind = ? AND destination.canonicalMediaId = ?
                )
                """,
            arguments: [
                from.pluginId, from.mediaKind.rawValue, from.canonicalMediaId,
                to.pluginId, to.mediaKind.rawValue, to.canonicalMediaId
            ]
        ) ?? false
        if collision {
            throw LibrarySourceRemapper.RemapError.mediaStateDestinationCollision(
                table: "downloadedChapter",
                canonicalMediaId: to.canonicalMediaId
            )
        }
    }

    /// Moves a series' offline state from `from` to `to`, inside the caller's write transaction:
    ///
    /// - Stored copies and deletion records move. A copy keeps the identity its manifest was written under
    ///   in `originIdentity`, and a second move keeps the first one, so the manifest still validates.
    /// - The remembered scanlator choice moves only inside one plugin, and the destination's own choice wins.
    ///   Scanlator names do not bind across plugins, so a choice never crosses one.
    /// - Jobs are deleted, with the batches they leave empty. An attempt that is running for one is refused
    ///   at its commit because its job is gone.
    /// - The Library snapshot state is deleted: it describes the old Library item's payload.
    ///
    /// `libraryCoverThumbnail` is not touched here: it cascades with the old Library item.
    /// Call `preflightRekey` first. Moving a series onto its own identity changes nothing. Returns the ids
    /// of the deleted jobs.
    @discardableResult
    nonisolated static func rekeyMedia(in db: Database, from: MediaIdentity, to: MediaIdentity) throws -> [String] {
        guard from != to else { return [] }
        let fromArguments: StatementArguments = [from.pluginId, from.mediaKind.rawValue, from.canonicalMediaId]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originOfFrom = try encoder.encode(
            OfflineOriginIdentity(pluginId: from.pluginId, canonicalMediaId: from.canonicalMediaId)
        )
        let originOfTo = try encoder.encode(
            OfflineOriginIdentity(pluginId: to.pluginId, canonicalMediaId: to.canonicalMediaId)
        )

        try db.execute(
            sql: """
                UPDATE downloadedChapter
                SET pluginId = ?, canonicalMediaId = ?, originIdentity = COALESCE(originIdentity, ?)
                WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?
                """,
            arguments: [
                to.pluginId, to.canonicalMediaId, originOfFrom,
                from.pluginId, from.mediaKind.rawValue, from.canonicalMediaId
            ]
        )
        // A copy that came back to the identity its manifest was written under needs no origin.
        try db.execute(
            sql: """
                UPDATE downloadedChapter SET originIdentity = NULL
                WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ? AND originIdentity = ?
                """,
            arguments: [to.pluginId, to.mediaKind.rawValue, to.canonicalMediaId, originOfTo]
        )

        // A deletion record the destination already has says the same thing, so the destination's stays.
        try db.execute(
            sql: """
                UPDATE OR IGNORE downloadSuppression SET pluginId = ?, canonicalMediaId = ?
                WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?
                """,
            arguments: [
                to.pluginId, to.canonicalMediaId,
                from.pluginId, from.mediaKind.rawValue, from.canonicalMediaId
            ]
        )
        try db.execute(
            sql: "DELETE FROM downloadSuppression WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?",
            arguments: fromArguments
        )

        if from.pluginId == to.pluginId {
            try db.execute(
                sql: """
                    UPDATE OR IGNORE seriesEditionPreference SET canonicalMediaId = ?
                    WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?
                    """,
                arguments: [to.canonicalMediaId, from.pluginId, from.mediaKind.rawValue, from.canonicalMediaId]
            )
        }
        // What is left is the source's choice: dropped when the destination has its own, and always
        // dropped across plugins.
        try db.execute(
            sql: "DELETE FROM seriesEditionPreference WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?",
            arguments: fromArguments
        )

        let jobs = try Row.fetchAll(
            db,
            sql: "SELECT id, batchId FROM downloadJob WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?",
            arguments: fromArguments
        )
        let jobIDs: [String] = jobs.map { $0["id"] }
        try db.execute(
            sql: "DELETE FROM downloadJob WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?",
            arguments: fromArguments
        )
        let batchIDs: Set<String> = Set(jobs.map { $0["batchId"] })
        for batchID in batchIDs {
            try deleteBatchIfOrphaned(batchID, in: db)
        }

        try db.execute(
            sql: "DELETE FROM librarySnapshotState WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?",
            arguments: fromArguments
        )

        // A deletion record says "do not bring this chapter back". Once the destination has the chapter,
        // stored or queued, the record is stale: it came from the other side of the move.
        try db.execute(
            sql: """
                DELETE FROM downloadSuppression
                WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?
                  AND (
                    EXISTS (
                        SELECT 1 FROM downloadedChapter copy
                        WHERE copy.pluginId = downloadSuppression.pluginId
                          AND copy.mediaKind = downloadSuppression.mediaKind
                          AND copy.canonicalMediaId = downloadSuppression.canonicalMediaId
                          AND copy.chapterKey = downloadSuppression.chapterKey
                          AND copy.authorityScope = downloadSuppression.authorityScope
                    )
                    OR EXISTS (
                        SELECT 1 FROM downloadJob job
                        WHERE job.pluginId = downloadSuppression.pluginId
                          AND job.mediaKind = downloadSuppression.mediaKind
                          AND job.canonicalMediaId = downloadSuppression.canonicalMediaId
                          AND job.chapterKey = downloadSuppression.chapterKey
                          AND job.authorityScope = downloadSuppression.authorityScope
                    )
                  )
                """,
            arguments: [to.pluginId, to.mediaKind.rawValue, to.canonicalMediaId]
        )
        return jobIDs
    }
}
