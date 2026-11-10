import Foundation

extension MediaDetailViewModel {
    /// What to tell the user after a relink cancelled queued downloads. Stored copies moved with the series,
    /// so this is only about downloads that had not finished; nil when the relink cancelled none.
    var relinkDownloadsNotice: String? {
        let count = relinkCancelledDownloadCount
        guard count > 0 else { return nil }
        return String(
            localized: "\(count) queued downloads were cancelled. Download them again from the new source.",
            comment: "Notice on a series after it was linked to another source. The number of downloads that were still waiting to download when the link was made; they were cancelled, and chapters already saved on this device were kept. Plural-ready."
        )
    }
}
