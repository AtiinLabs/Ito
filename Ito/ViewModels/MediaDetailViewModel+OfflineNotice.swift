import Foundation

extension MediaDetailViewModel {
    /// The notice for a screen that shows saved details instead of fresh ones: a saved series that opened
    /// without a source to refresh it, or one whose load failed while the device is offline.
    var offlineNotice: MediaDetailOfflineNotice? {
        switch detailLoadState {
        case .savedOnly:
            return MediaDetailOfflineNotice(kind: .savedOnly, refreshedAt: snapshotRefreshedAt)
        case .failure where isOffline && isSaved:
            return MediaDetailOfflineNotice(kind: .offline, refreshedAt: snapshotRefreshedAt)
        default:
            return nil
        }
    }

    /// Reads when the saved details were last refreshed, for the notices that show them.
    func loadSnapshotRefreshDate() {
        snapshotDateTask?.cancel()
        guard isSaved else {
            snapshotRefreshedAt = nil
            return
        }
        let identity = mediaIdentity
        let snapshots = snapshots
        snapshotDateTask = Task { [weak self] in
            let date = await snapshots.refreshDate(for: identity)
            guard let self, !Task.isCancelled, self.mediaIdentity == identity else { return }
            self.snapshotRefreshedAt = date
        }
    }

    /// Saves a successfully loaded series as the Library's details for it, if they are still the ones the load
    /// started from, and shows the new refresh time. A read of the older date that is still running is
    /// cancelled first, so it cannot overwrite the new one.
    func refreshSavedSnapshot(_ token: LibrarySnapshotToken, with updated: M, requestedKey: String) async {
        guard updated.key == requestedKey,
              let refreshedAt = await snapshots.replace(token, with: updated),
              !Task.isCancelled,
              media.key == requestedKey else { return }
        snapshotDateTask?.cancel()
        snapshotDateTask = nil
        snapshotRefreshedAt = refreshedAt
        downloadBatch.loadCoverageBasis()
    }

#if DEBUG
    func waitForSnapshotRefreshDateForTesting() async {
        await snapshotDateTask?.value
    }
#endif
}
