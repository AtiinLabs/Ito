import Combine
import Foundation
import ito_runner

/// The series screen's side of choosing among saved uploads of a chapter's reading position. The selector owns
/// the state, the task and the lease; the screen supplies what is current and opens the reader.
extension MediaDetailViewModel {
    var downloadedAlternativeState: DownloadedAlternativeSelectorState { downloadedAlternatives.state }

    /// Connects the selector to this screen. The returned subscription forwards its changes to observers.
    func wireDownloadedAlternatives() -> AnyCancellable {
        downloadedAlternatives.host = DownloadedAlternativeSelector<M>.Host(
            screen: { [weak self] in
                self.map {
                    DownloadedAlternativeSelector<M>.Screen(
                        media: $0.media,
                        identity: $0.mediaIdentity,
                        isPresentable: $0.mayPresentUserOutput
                    )
                }
            },
            publish: { [weak self] in self?.publishPreparedReader($0) },
            relinquishBatchPresentation: { [weak self] in
                self?.downloadBatch.relinquishPresentationForLocalReading()
            }
        )
        return downloadedAlternatives.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    /// Whether the chapter's menu offers the chooser: a manga or novel row the account can open whose source
    /// named its reading position. On a saved-only route or for a saved-only row the list is the saved Library
    /// catalog or the stored copies, so the row must also be downloaded: another row has no stored copy to
    /// anchor on. Every row asks, so this reads the row and its state alone; the tap looks the row up again.
    func offersDownloadedAlternatives(for chapter: M.Chapter) -> Bool {
        guard showsDownloadControls, chapter is ito_runner.Chapter, !chapter.isPaywalled,
              let logicalUnitID = chapter.logicalUnitID, !logicalUnitID.isEmpty else { return false }
        if detailLoadState == .savedOnly || isSavedOnlyRow(chapter) { return downloadState(for: chapter) == .downloaded }
        return true
    }

    /// What the chapter's lookup is anchored on, or nil when the chapter has nothing to look up: a series
    /// without chapter readers, a locked row, a row neither list has, or a row whose source named no logical
    /// unit. The row is found again by its exact key in the list shown now, then among the saved-only rows.
    /// A saved-only row or route is anchored on its own stored copy, which knows where its metadata came from;
    /// any other row is anchored on the catalog the source just supplied.
    func downloadedAlternativeAnchor(for chapter: M.Chapter) -> OfflineChapterAlternativeAnchor? {
        let isMatch: (M.Chapter) -> Bool = { $0.key.utf8.elementsEqual(chapter.key.utf8) }
        let listed = media.chapterList?.first(where: isMatch)
        let savedOnly = listed == nil
            ? downloadBatch.savedOnlyChapters.lazy.compactMap { $0 as? M.Chapter }.first(where: isMatch) : nil
        guard let row = listed ?? savedOnly, offersDownloadedAlternatives(for: row),
              let logicalUnitID = row.logicalUnitID else { return nil }
        let edition = OfflineChapterEdition(media: mediaIdentity, chapterKey: row.key)
        if savedOnly != nil || detailLoadState == .savedOnly { return .saved(edition: edition) }
        return .catalog(edition: edition, logicalUnitID: logicalUnitID)
    }

    /// Lists the saved uploads of the chapter's reading position in the download sheet. Reads only: nothing
    /// is queued, remembered or recorded. A Resume or a saved-route copy check still waiting is cancelled, so
    /// that a late completion cannot open a reader or ask for consent over the closing sheet.
    @discardableResult
    func showDownloadedAlternatives(for chapter: M.Chapter) -> Task<Void, Never> {
        guard let anchor = downloadedAlternativeAnchor(for: chapter) else { return Task {} }
        cancelGroupSwitch()
        cancelSavedChapterOpening()
        return downloadedAlternatives.show(anchor: anchor)
    }

    func selectDownloadedAlternative(_ candidateID: String, presentationID: UUID) {
        downloadedAlternatives.select(candidateID, presentationID: presentationID)
    }

    @discardableResult
    func confirmDownloadedAlternative(presentationID: UUID) -> Task<Void, Never> {
        downloadedAlternatives.confirm(presentationID: presentationID)
    }

    func cancelDownloadedAlternatives() {
        downloadedAlternatives.cancel()
    }

    /// The download sheet that showed `presentationID` has closed.
    func downloadedAlternativeSheetDidDismiss(presentationID: UUID) {
        downloadedAlternatives.sheetDidDismiss(presentationID: presentationID)
    }

    /// Closes the download sheet. A choice among saved copies is cancelled; one that is already closing for
    /// its hand-off is left to finish.
    func dismissDownloadSheet() {
        switch downloadedAlternatives.state {
        case .idle: downloadBatch.dismissDownloadSheet()
        case .handingOff: break
        default: downloadedAlternatives.cancel()
        }
    }

    /// A preset takes the download sheet from any saved-copy choice first.
    @discardableResult
    func startDownload(_ preset: DownloadPreset) -> Task<Void, Never> {
        downloadedAlternatives.cancel()
        return downloadBatch.startDownload(preset)
    }

    @discardableResult
    func openEditionChooser() -> Task<Void, Never> {
        downloadedAlternatives.cancel()
        return downloadBatch.openEditionChooser()
    }
}
