import Foundation
import ito_runner

/// Resume and its optional consent to open another translation group's upload, kept out of the
/// main file. Only Resume consults the setting; tapping an exact row is already explicit.
extension MediaDetailViewModel {
    func resumeReading(continuation: Bool = false) {
        cancelGroupSwitch()
        guard let target = resumeTarget else { return }
        let candidate = continuation ? target.continuationChapter : target.chapter
        guard !candidate.isPaywalled else {
            if continuation { messagePresenter.present(.chapterLocked(isEpisode: media.mediaKind == .anime)) }
            return
        }
        guard media.mediaKind != .anime, dependencies.settings.askBeforeSwitchingGroups else {
            selectChapter(candidate)
            return
        }
        let session = continuationSession
        let identity = mediaIdentity
        let lastKey = dependencies.progress.lastReadChapter(for: identity)
        let settingsRevision = dependencies.settings.readerContinuationSettingsRevision
        let sourceContext = dependencies.progress.captureCompletionContext(media: identity, mediaKey: media.key)
        let recorded = lastKey.flatMap { key in media.chapterList?.first { $0.key == key } }.map(ReaderContinuationGroup.init)
        let incoming = historyScanlator != nil || historyScanlatorID != nil
            ? ReaderContinuationGroup(id: historyScanlatorID, name: historyScanlator) : nil
        let history = dependencies.history
        resumeTask = Task { @MainActor [weak self] in
            let historical: ReaderContinuationGroup?
            if recorded == nil, let lastKey, let history {
                historical = try? await history.recordedGroup(media: identity, chapterKey: lastKey)
            } else { historical = nil }
            guard let self, !Task.isCancelled, self.continuationSession == session,
                  self.mediaIdentity == identity,
                  self.dependencies.progress.lastReadChapter(for: identity) == lastKey,
                  self.dependencies.settings.readerContinuationSettingsRevision == settingsRevision,
                  self.dependencies.progress.captureCompletionContext(media: identity, mediaKey: self.media.key) == sourceContext
            else { return }
            self.resumeTask = nil
            let origin = recorded ?? historical ?? incoming
            let resolvedTarget = historical.flatMap { group in
                MediaDetailResumeTarget(
                    chapters: self.media.chapterList ?? [], lastReadKey: lastKey,
                    fallbackGroup: group.name, fallbackGroupID: group.id, useGroupIDs: true,
                    isCompleted: self.media.isCompleted, isRead: self.isRead
                )
            }
            let candidate = resolvedTarget.map { continuation ? $0.continuationChapter : $0.chapter } ?? candidate
            let isExactLast = lastKey == candidate.key
            if !isExactLast, origin.map({ !$0.matches(ReaderContinuationGroup(candidate)) }) ?? (lastKey != nil || incoming != nil) {
                self.groupSwitchConsent = ReaderGroupSwitchConsent(
                    chapter: candidate, originKey: lastKey, session: session,
                    settingsRevision: settingsRevision, sourceContext: sourceContext
                )
            } else {
                self.selectChapter(candidate)
            }
        }
    }

    func cancelGroupSwitch() {
        groupSwitchConsent = nil
        continuationSession = UUID()
        resumeTask?.cancel()
        resumeTask = nil
    }

    func confirmGroupSwitch(_ consentID: UUID) {
        guard let consent = groupSwitchConsent, consent.id == consentID else { return }
        groupSwitchConsent = nil
        guard consent.session == continuationSession,
              consent.originKey == dependencies.progress.lastReadChapter(for: mediaIdentity),
              consent.sourceContext.originatingEpoch != nil || detailLoadState == .savedOnly,
              consent.settingsRevision == dependencies.settings.readerContinuationSettingsRevision,
              consent.sourceContext == dependencies.progress.captureCompletionContext(media: mediaIdentity, mediaKey: media.key),
              let current = media.chapterList?.first(where: { $0.key == consent.chapter.key }),
              !current.isPaywalled else { return }
        selectChapter(current)
    }

#if DEBUG
    func waitForContinuationForTesting() async { await resumeTask?.value }
    var continuationTaskForTesting: Task<Void, Never>? { resumeTask }
#endif
}
