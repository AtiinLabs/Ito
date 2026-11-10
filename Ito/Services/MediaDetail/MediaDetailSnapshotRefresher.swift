import Foundation
import OSLog

/// Reads and refreshes the details the Library saved for one series, for the detail screen. Every failure
/// is absorbed: saved details are a convenience, and a screen never fails or waits because of them.
@MainActor
struct MediaDetailSnapshotRefresher {
    let library: any MediaDetailLibraryServing

    /// Names the saved details, to be read before the source is asked. Nil when there is nothing to refresh
    /// or the token cannot be read.
    func token(for media: MediaIdentity) async -> LibrarySnapshotToken? {
        try? await library.snapshotToken(for: media)
    }

    /// When the saved details were last refreshed; nil when that is unknown.
    func refreshDate(for media: MediaIdentity) async -> Date? {
        try? await library.snapshotRefreshDate(for: media)
    }

    /// What the saved details say about the series' catalog; nil when that is unknown.
    func basis(for media: MediaIdentity) async -> LibrarySnapshotBasis? {
        try? await library.snapshotBasis(for: media)
    }

    /// Saves a successfully loaded series as the Library's details for it, if they are still the ones
    /// `token` named. A list without chapters is never saved: it is not evidence that the series has none.
    /// Downloaded chapters are not touched, whichever chapters the new list leaves out.
    ///
    /// - Returns: When the details were refreshed; nil when they were not.
    func replace<M: MediaDisplayable>(
        _ token: LibrarySnapshotToken,
        with updated: M,
        refreshedAt: Date = Date()
    ) async -> Date? {
        guard let chapters = updated.chapterList, !chapters.isEmpty, !Task.isCancelled else { return nil }
        do {
            // Sorted keys: the same content is the same bytes, so an unchanged series is recognised as such.
            // Encoding a long chapter list is not main-actor work.
            let payload = try await Task.detached(priority: .utility) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                return try encoder.encode(updated)
            }.value
            let outcome = try await library.replaceSnapshot(
                token,
                payload: payload,
                coverURL: updated.cover,
                chapterRowCount: chapters.count,
                // No source reports a catalog scope yet.
                catalog: .unknown,
                refreshedAt: refreshedAt
            )
            return outcome == .replaced ? refreshedAt : nil
        } catch {
            AppLogger.database.error("Saved series details could not be refreshed.")
            return nil
        }
    }
}
