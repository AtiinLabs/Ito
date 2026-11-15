import Foundation
import GRDB
import ito_runner

/// Listing and leasing the stored uploads of one logical unit. Reads and leases only: nothing here queues,
/// downloads, writes a preference or asks a plugin.
extension OfflineChapterStore {
    /// The stored copies that are other uploads of the anchor's logical unit. The rows and the source
    /// epoch come from one database read, so they describe the same moment. A read that fails is an error,
    /// never an empty list.
    func downloadedAlternatives(
        for anchor: OfflineChapterAlternativeAnchor
    ) async throws -> DownloadedChapterAlternatives {
        try Task.checkCancellation()
        let edition = anchor.edition
        let snapshot: (rows: [DownloadedChapterRecord], epoch: String?)
        do {
            snapshot = try await database.read { db in
                let rows = try DownloadedChapterRecord
                    .filter(
                        Column("pluginId") == edition.pluginId
                            && Column("mediaKind") == edition.mediaKind.rawValue
                            && Column("canonicalMediaId") == edition.canonicalMediaId
                            && Column("authorityScope") == edition.authorityScope.rawValue
                    )
                    .order(Column("chapterKey"))
                    .fetchAll(db)
                return (rows, try PluginCompletionScope.current(pluginID: edition.pluginId, in: db))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DownloadedAlternativeError.inventoryUnavailable
        }
        try Task.checkCancellation()
        return try OfflineChapterAlternatives.project(anchor: anchor, inventory: snapshot.rows, sourceEpoch: snapshot.epoch)
    }

    /// Leases exactly the copy that was listed. Whatever copy occupies the key now is never opened in its
    /// place: a changed version, manifest, snapshot, form or origin, or a changed source epoch, fails.
    /// The lease is dropped if anything fails after it was acquired, and a Delete after success leaves the
    /// leased bytes readable, as for any reader.
    func openDownloadedAlternative(
        _ candidate: DownloadedChapterAlternative,
        sourceEpoch: String?
    ) async throws -> OfflineChapterLease {
        try await requireFrozen(candidate, sourceEpoch: sourceEpoch)
        let lease: OfflineChapterLease
        do {
            lease = try await openLease(edition: candidate.edition)
        } catch {
            throw OfflineReadError.selectedCopy(from: error)
        }
        try Task.checkCancellation()
        guard lease.versionId == candidate.versionID,
              lease.edition.isByteIdentical(to: candidate.edition),
              lease.manifest.versionId == candidate.versionID,
              lease.manifest.contentKind == candidate.contentKind,
              lease.manifest.identity.chapterKey.utf8.elementsEqual(candidate.edition.chapterKey.utf8),
              lease.manifest.identity.authorityScope == candidate.edition.authorityScope,
              MediaIdentity(
                  pluginId: lease.manifest.identity.pluginId,
                  canonicalMediaId: lease.manifest.identity.canonicalMediaId,
                  mediaKind: lease.manifest.identity.mediaKind
              ).isByteIdentical(to: candidate.metadataOrigin) else {
            throw DownloadedAlternativeError.selectionChanged
        }
        // The row and the epoch can move while the lease was being acquired.
        try await requireFrozen(candidate, sourceEpoch: sourceEpoch)
        return lease
    }

    /// Fails unless the inventory still holds exactly the listed copy under the same source epoch.
    private func requireFrozen(_ candidate: DownloadedChapterAlternative, sourceEpoch: String?) async throws {
        try Task.checkCancellation()
        let edition = candidate.edition
        let current: (row: DownloadedChapterRecord?, epoch: String?)
        do {
            current = try await database.read { db in
                let row = try DownloadedChapterRecord.filter(edition.predicate).fetchOne(db)
                return (row, try PluginCompletionScope.current(pluginID: edition.pluginId, in: db))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DownloadedAlternativeError.inventoryUnavailable
        }
        try Task.checkCancellation()
        guard current.epoch == sourceEpoch else { throw DownloadedAlternativeError.sourceChanged }
        guard let row = current.row else { throw OfflineReadError.selectedCopy(from: OfflineStoreError.notVerified) }
        guard row.state == .verified else {
            throw OfflineReadError.selectedCopy(from: OfflineStoreError.damaged(row.damageReason ?? .manifestUnreadable))
        }
        guard row.edition.isByteIdentical(to: edition),
              row.versionId == candidate.versionID,
              row.manifestSHA256 == candidate.manifestSHA256,
              row.contentKind == candidate.contentKind,
              OfflineDigest.sha256Hex(row.chapterSnapshot) == candidate.chapterSnapshotSHA256,
              let origin = OfflineChapterAlternatives.metadataOrigin(of: row),
              origin.isByteIdentical(to: candidate.metadataOrigin),
              OfflineChapterAlternatives.savedChapter(of: row) != nil else {
            throw DownloadedAlternativeError.selectionChanged
        }
    }
}
