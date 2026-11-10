import Foundation
import ito_runner

extension MediaDetailViewModel {
    /// Whether this series shows download controls: offline chapters exist on this build and the series is
    /// a manga or a novel. Anime episodes are never stored.
    var showsDownloadControls: Bool {
        downloads.isAvailable && media.mediaKind != .anime
    }

    /// The chapter's download state, or nil when it has none or controls are hidden.
    func downloadState(for chapter: M.Chapter) -> ChapterDownloadState? {
        guard showsDownloadControls else { return nil }
        return chapterDownloadStates[chapter.key]
    }

    /// What the chapter's menu offers. Download needs a saved series whose source can fetch it, so a
    /// locked chapter and a saved-only series offer none. Reading a downloaded chapter online this time
    /// needs the same source and an unlocked chapter. A Retry is offered only where an event cannot
    /// clear the wait.
    func downloadActions(for chapter: M.Chapter) -> [ChapterDownloadAction] {
        guard showsDownloadControls else { return [] }
        switch downloadState(for: chapter) {
        case nil:
            guard isSaved, !chapter.isPaywalled, detailLoadState != .savedOnly else { return [] }
            return [.download]
        case .queued, .downloading:
            return [.cancel]
        case .waiting(let reason):
            return reason.requiresRetry ? [.retry, .cancel] : [.cancel]
        case .failed:
            return [.retry, .cancel]
        case .downloaded:
            // Reading online needs a source to read from, a chapter the account can open and a chapter
            // the source still lists: a saved-only edition has no online copy to read.
            guard detailLoadState != .savedOnly, !chapter.isPaywalled, !isSavedOnlyRow(chapter) else { return [.delete] }
            return [.readOnlineThisTime, .delete]
        case .damaged:
            return [.delete]
        }
    }

    /// Runs one download action. The store's state reaches the row through observation; only a refusal or
    /// a failed write is reported. The returned task lets a caller wait for the action to finish.
    @discardableResult
    func performDownloadAction(_ action: ChapterDownloadAction, for chapter: M.Chapter) -> Task<Void, Never> {
        let downloads = downloads
        let edition = OfflineChapterEdition(media: mediaIdentity, chapterKey: chapter.key)
        switch action {
        case .download:
            // A row can retain a chapter value from before a refresh. The current value decides, under
            // the same rule that offered the action; a chapter the source no longer lists is refused.
            let current = media.chapterList.map { list in list.first { $0.key == chapter.key } } ?? chapter
            guard let current else {
                presentDownloadMessage(.downloadRefused)
                return Task {}
            }
            // Queued or saved since the menu opened, from this screen or another: nothing to do.
            if downloadState(for: current) != nil {
                return Task {}
            }
            guard downloadActions(for: current).contains(.download),
                  let request = downloadRequest(for: current) else {
                presentDownloadMessage(.downloadRefused)
                return Task {}
            }
            let identity = mediaIdentity
            let title = media.title
            return Task { [weak self] in
                let outcome = await downloads.download(
                    media: identity,
                    entry: request.entry,
                    chapter: request.chapter,
                    seriesTitle: title
                )
                switch outcome {
                case .queued, .alreadyQueued, .alreadyDownloaded:
                    break
                case .refused(.unavailable):
                    self?.presentDownloadMessage(.downloadActionFailed)
                case .refused:
                    self?.presentDownloadMessage(.downloadRefused)
                }
            }
        case .readOnlineThisTime:
            // The row's state and the lock are read again at the tap, under the rule that offered the action.
            let current = media.chapterList.map { list in list.first { $0.key == chapter.key } } ?? chapter
            if let current, downloadActions(for: current).contains(.readOnlineThisTime) {
                readOnlineThisTime(current)
            }
            return Task {}
        case .cancel, .retry, .delete:
            return Task { [weak self] in
                do {
                    switch action {
                    case .cancel: try await downloads.cancel(edition)
                    case .retry: try await downloads.retry(edition)
                    case .delete: try await downloads.delete(edition)
                    case .download, .readOnlineThisTime: break
                    }
                } catch {
                    self?.presentDownloadMessage(.downloadActionFailed)
                }
            }
        }
    }

    /// The entry and chapter a download stores. Only manga and novel chapters have a stored form.
    private func downloadRequest(for chapter: M.Chapter) -> (entry: MediaEntry, chapter: ito_runner.Chapter)? {
        guard let sourceChapter = chapter as? ito_runner.Chapter else { return nil }
        if let manga = media as? Manga {
            return (.manga(manga), sourceChapter)
        }
        if let novel = media as? Novel {
            return (.novel(novel), sourceChapter)
        }
        return nil
    }
}
