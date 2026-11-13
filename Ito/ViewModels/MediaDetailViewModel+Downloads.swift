import Foundation
import ito_runner

extension MediaDetailViewModel {
    /// Whether this series shows download controls: offline chapters exist on this build and the series is
    /// a manga or a novel. Anime episodes are never stored.
    var showsDownloadControls: Bool {
        downloads.isAvailable && media.mediaKind != .anime
    }

    /// The chapter's download state, or nil when it has none or controls are hidden. This is the saved copy's
    /// own state; a replacement's activity over that copy is read with `replacementState(for:)`.
    func downloadState(for chapter: M.Chapter) -> ChapterDownloadState? {
        guard showsDownloadControls else { return nil }
        return chapterDownloadStates[chapter.key]
    }

    /// A replacement's activity over this chapter's saved copy, or nil when none is in progress or ended.
    func replacementState(for chapter: M.Chapter) -> ChapterDownloadState? {
        guard showsDownloadControls else { return nil }
        return chapterReplacementStates[chapter.key]
    }

    /// What the chapter's menu offers. Download needs a saved series whose source can fetch it, so a
    /// locked chapter and a saved-only series offer none. Reading a downloaded chapter online this time
    /// needs the same source and an unlocked chapter. A Retry is offered only where an event cannot
    /// clear the wait.
    func downloadActions(for chapter: M.Chapter) -> [ChapterDownloadAction] {
        guard showsDownloadControls else { return [] }
        if let activity = replacementState(for: chapter) {
            return replacementActions(for: chapter, activity: activity)
        }
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
            return [.readOnlineThisTime, .replace, .delete]
        case .damaged:
            return [.delete]
        }
    }

    /// The menu while a replacement has activity over the saved copy. Replace is offered directly once the record
    /// has ended, because a fresh confirmation supersedes that record. While the replacement is queued, running or
    /// waiting, the menu offers only what can move it. Cancelling a replacement leaves the saved copy. Reading the
    /// copy and deleting it stay available beside any activity.
    private func replacementActions(for chapter: M.Chapter, activity: ChapterDownloadState) -> [ChapterDownloadAction] {
        var actions: [ChapterDownloadAction]
        switch activity {
        case .queued, .downloading:
            actions = [.cancelReplacement]
        case .waiting(let reason):
            actions = reason.requiresRetry ? [.retry, .cancelReplacement] : [.cancelReplacement]
        case .failed(let reason):
            actions = reason.endsReplacement ? [.replace, .cancelReplacement] : [.retry, .cancelReplacement]
        case .downloaded, .damaged:
            actions = []
        }
        if detailLoadState != .savedOnly, !chapter.isPaywalled, !isSavedOnlyRow(chapter) {
            actions.append(.readOnlineThisTime)
        }
        actions.append(.delete)
        return actions
    }

    /// Runs one download action. The store's state reaches the row through observation; only a refusal or
    /// a failed write is reported. The returned task lets a caller wait for the action to finish.
    @discardableResult
    func performDownloadAction(_ action: ChapterDownloadAction, for chapter: M.Chapter) -> Task<Void, Never> {
        let downloads = downloads
        let edition = OfflineChapterEdition(media: mediaIdentity, chapterKey: chapter.key)
        switch action {
        case .replace:
            // Replacement requires the view's explicit confirmation, never direct menu execution.
            return Task {}
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
        case .cancel, .cancelReplacement, .retry, .delete:
            return Task { [weak self] in
                do {
                    switch action {
                    case .cancel, .cancelReplacement: try await downloads.cancel(edition)
                    case .retry: try await downloads.retry(edition)
                    case .delete: try await downloads.delete(edition)
                    case .download, .replace, .readOnlineThisTime: break
                    }
                } catch {
                    self?.presentDownloadMessage(.downloadActionFailed)
                }
            }
        }
    }

    /// The frozen preview for a confirmation, or nil when the copy cannot be replaced. The reason is told apart:
    /// a copy whose source settings changed or that was saved under another series gets its own explanation;
    /// anything else (unlisted, locked, in progress, missing) gets the generic refusal and no delete advice.
    func replacementPreview(for chapter: M.Chapter) async -> DownloadReplacementPreview? {
        guard let current = media.chapterList?.first(where: { $0.key == chapter.key }),
              downloadActions(for: current).contains(.replace),
              let request = downloadRequest(for: current) else {
            presentDownloadMessage(.downloadRefused)
            return nil
        }
        do {
            let access = try await downloads.replacementPreview(
                media: mediaIdentity, entry: request.entry, chapter: request.chapter, seriesTitle: media.title
            )
            switch access {
            case .preview(let preview):
                return preview
            case .refused(.copyCannotBeReplaced):
                presentDownloadMessage(.replacementUnavailable)
            case .refused(.unavailable):
                presentDownloadMessage(.downloadRefused)
            }
        } catch {
            presentDownloadMessage(.downloadActionFailed)
        }
        return nil
    }

    func confirmReplacement(_ preview: DownloadReplacementPreview) {
        Task { [weak self, downloads] in
            switch await downloads.replace(preview) {
            case .queued:
                self?.presentDownloadMessage(.downloadsQueued(queued: 1, alreadyStored: 0))
            case .alreadyQueued:
                self?.presentDownloadMessage(.downloadsQueued(queued: 0, alreadyStored: 1))
            case .alreadyDownloaded, .refused:
                self?.presentDownloadMessage(.downloadRefused)
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
