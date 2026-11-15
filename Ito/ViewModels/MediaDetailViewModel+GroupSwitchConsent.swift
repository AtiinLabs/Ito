import Foundation
import ito_runner

/// The Resume a series screen has in flight and the token that retires it.
@MainActor
final class ResumeContinuation {
    private(set) var session = UUID()
    private(set) var task: Task<Void, Never>?

    func begin(_ task: Task<Void, Never>) { self.task = task }
    func finish() { task = nil }
    func cancel() {
        session = UUID()
        task?.cancel()
        task = nil
    }
}

/// Resume and its optional consent to open another translation group's upload, kept out of the
/// main file. Only Resume consults the setting; tapping an exact row is already explicit. The
/// source scope is only read, never captured, and must be the same verified scope when asked and
/// when confirmed.
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
        let session = resume.session
        let identity = mediaIdentity
        let mediaKey = media.key
        let progress = dependencies.progress
        let lastKey = progress.lastReadChapter(for: identity)
        let settingsRevision = dependencies.settings.readerContinuationSettingsRevision
        let recorded = lastKey.flatMap { key in media.chapterList?.first { $0.key == key } }.map(ReaderContinuationGroup.init)
        let incoming = historyScanlator != nil || historyScanlatorID != nil
            ? ReaderContinuationGroup(id: historyScanlatorID, name: historyScanlator) : nil
        let history = dependencies.history
        resume.begin(Task { @MainActor [weak self] in
            // Establish the scope once before reading scoped History. Production uses a read if
            // it already exists, and only creates a missing scope off the main actor.
            let epoch = await progress.verifiedCompletionEpoch(media: identity, mediaKey: mediaKey)
            let historical: ReaderContinuationGroup?
            if recorded == nil, let lastKey, let history {
                historical = try? await history.recordedGroup(media: identity, chapterKey: lastKey)
            } else { historical = nil }
            guard let self, self.isCurrentResume(session, identity, lastKey, settingsRevision),
                  self.currentSourceEpoch == epoch else { return }
            let origin = recorded ?? historical ?? incoming
            let resolvedTarget = historical.flatMap { group in
                MediaDetailResumeTarget(
                    chapters: self.media.chapterList ?? [], lastReadKey: lastKey,
                    fallbackGroup: group.name, fallbackGroupID: group.id, useGroupIDs: true,
                    isCompleted: self.media.isCompleted, isRead: self.isRead
                )
            }
            let candidate = resolvedTarget.map { continuation ? $0.continuationChapter : $0.chapter } ?? candidate
            // The recorded group's own upload can be locked even when the earlier candidate was not.
            guard !candidate.isPaywalled else {
                self.resume.finish()
                if continuation { self.messagePresenter.present(.chapterLocked(isEpisode: false)) }
                return
            }
            let isExactLast = lastKey == candidate.key
            guard !isExactLast, origin.map({ !$0.matches(ReaderContinuationGroup(candidate)) }) ?? (lastKey != nil || incoming != nil) else {
                self.resume.finish()
                self.selectChapter(candidate)
                return
            }
            guard let epoch, self.isCurrentResume(session, identity, lastKey, settingsRevision),
                  self.currentSourceEpoch == epoch else { return }
            self.resume.finish()
            self.setGroupSwitchConsent(ReaderGroupSwitchConsent(
                chapter: candidate, originKey: lastKey, session: session,
                settingsRevision: settingsRevision,
                sourceContext: PluginCompletionContext(media: identity, mediaKey: mediaKey, originatingEpoch: epoch)
            ))
        })
    }

    /// Whether nothing the resume started from has changed while it waited.
    private func isCurrentResume(_ session: UUID, _ identity: MediaIdentity, _ lastKey: String?, _ revision: UInt64) -> Bool {
        !Task.isCancelled && resume.session == session && mediaIdentity == identity
            && dependencies.progress.lastReadChapter(for: identity) == lastKey
            && dependencies.settings.readerContinuationSettingsRevision == revision
    }

    func confirmGroupSwitch(_ consentID: UUID) {
        guard let consent = groupSwitchConsent, consent.id == consentID else { return }
        setGroupSwitchConsent(nil)
        guard consent.session == resume.session,
              consent.originKey == dependencies.progress.lastReadChapter(for: mediaIdentity),
              let epoch = consent.sourceContext.originatingEpoch,
              epoch == currentSourceEpoch,
              consent.settingsRevision == dependencies.settings.readerContinuationSettingsRevision,
              let current = media.chapterList?.first(where: { $0.key == consent.chapter.key }),
              !current.isPaywalled else { return }
        selectChapter(current)
    }

    /// A read of the source's current scope; nil when it cannot be verified.
    private var currentSourceEpoch: String? {
        dependencies.progress.currentCompletionEpoch(media: mediaIdentity, mediaKey: media.key)
    }

#if DEBUG
    func waitForContinuationForTesting() async { await resume.task?.value }
    var continuationTaskForTesting: Task<Void, Never>? { resume.task }
#endif
}
