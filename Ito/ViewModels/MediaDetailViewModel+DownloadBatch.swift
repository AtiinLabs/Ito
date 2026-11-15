import Foundation
import ito_runner

/// The series screen as the batch download controls see it.
extension MediaDetailViewModel: MediaDetailDownloadBatchHost {
    var batchIdentity: MediaIdentity { mediaIdentity }

    var batchChapters: [Chapter] {
        // Only manga and novel chapters have a stored form; an episode list yields none.
        (media.chapterList as? [Chapter]) ?? []
    }

    var batchEntry: MediaEntry? {
        if let manga = media as? Manga { return .manga(manga) }
        if let novel = media as? Novel { return .novel(novel) }
        return nil
    }

    var batchSeriesTitle: String { media.title }
    var batchIsSaved: Bool { isSaved }
    var batchIsSavedOnlyRoute: Bool { detailLoadState == .savedOnly }

    func presentBatchMessage(_ message: MediaDetailMessage) {
        presentDownloadMessage(message)
    }

    /// Whether the series offers presets and the scanlator choice.
    var showsBatchDownloadControls: Bool { downloadBatch.showsControls }

    /// The digest of the chapter list the presets plan from.
    var catalogDigest: String { downloadBatch.catalogDigest }

    /// The one sheet the download controls present: a saved-copy choice while one is loading, open or failed,
    /// nothing while one is closing for its hand-off, and otherwise the batch's chooser or preview.
    var downloadSheet: DownloadSheet? {
        switch downloadedAlternatives.state {
        case .idle: downloadBatch.sheet
        case .handingOff: nil
        case .loading(let context), .failed(let context, _),
             .choosing(let context, _, _, _), .acquiring(let context, _, _):
            .downloadedAlternatives(id: context.id)
        }
    }

    /// "Entire series offline" or the saved count, from the catalog saved with the Library item.
    func offlineCoverage(now: Date = Date()) -> SeriesOfflineCoverage.Result? {
        downloadBatch.coverage(now: now)
    }

    /// Whether the row is a saved edition the source's current list does not have.
    func isSavedOnlyRow(_ chapter: M.Chapter) -> Bool {
        downloadBatch.isSavedOnly(key: chapter.key)
    }
}
