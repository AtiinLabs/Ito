import Combine
import Foundation
import ito_runner

/// Consent to open one neighbor that belongs to another translation group, kept out of the main file.
/// It authorizes one exact transition in the current reader session and writes nothing.
extension NovelReaderViewModel {
    /// Asks to open the one neighbor of another group. The text view's own prompt asks about the
    /// last loaded chapter; every other caller asks about the current one.
    func requestGroupSwitch(
        _ direction: ReaderGroupSwitchConsent<Novel.Chapter>.Direction,
        atLoadedEdge: Bool = false
    ) {
        guard isActive else { return }
        let origin = atLoadedEdge && direction == .next ? (loadedChapters.last?.chapter ?? currentChapter) : currentChapter
        guard let candidate = groupConsentCandidate(after: origin, direction: direction) else { return }
        groupSwitchConsent = ReaderGroupSwitchConsent(
            chapter: candidate, originKey: origin.key, session: sessionID,
            settingsRevision: dependencies.settings.readerContinuationSettingsRevision,
            sourceContext: dependencies.progress.captureCompletionContext(media: mediaIdentity, mediaKey: entry.key),
            direction: direction
        )
    }

    func cancelGroupSwitch() { groupSwitchConsent = nil }

    func confirmGroupSwitch(_ consentID: UUID) {
        guard let consent = groupSwitchConsent, consent.id == consentID else { return }
        groupSwitchConsent = nil
        guard isActive, consent.session == sessionID,
              consent.settingsRevision == dependencies.settings.readerContinuationSettingsRevision,
              consent.sourceContext.originatingEpoch != nil || offline.isLocalOnly,
              consent.sourceContext == dependencies.progress.captureCompletionContext(media: mediaIdentity, mediaKey: entry.key),
              let origin = consentOrigin(key: consent.originKey, direction: consent.direction),
              let candidate = groupConsentCandidate(after: origin, direction: consent.direction),
              NovelChapterToken(candidate) == NovelChapterToken(consent.chapter) else { return }
        goToChapter(candidate)
    }

    private func groupConsentCandidate(
        after origin: Novel.Chapter,
        direction: ReaderGroupSwitchConsent<Novel.Chapter>.Direction
    ) -> Novel.Chapter? {
        let boundary = direction == .next ? boundaryAfter(origin) : boundaryBefore(origin)
        guard case .groupConsent(let candidate) = boundary else { return nil }
        return candidate
    }

    /// The chapter a prompt was shown for: still the current one, or still the last loaded one.
    private func consentOrigin(
        key: String?,
        direction: ReaderGroupSwitchConsent<Novel.Chapter>.Direction
    ) -> Novel.Chapter? {
        if currentChapter.key == key { return currentChapter }
        guard direction == .next, let last = loadedChapters.last?.chapter, last.key == key else { return nil }
        return last
    }

    func setAskBeforeSwitchingGroups(_ value: Bool) {
        groupSwitchConsent = nil
        let settings = dependencies.settings
        let session = sessionID
        let preceding = continuationSettingsTask
        continuationSettingsTask = Task { @MainActor [weak self] in
            await preceding?.value
            guard let self, self.isActive, self.sessionID == session, !Task.isCancelled else { return }
            do {
                try await settings.setAskBeforeSwitchingGroups(value)
            } catch {
                self.objectWillChange.send()
                return
            }
            guard self.isActive, self.sessionID == session, !Task.isCancelled else { return }
            self.appendTask?.cancel()
            if let operationID = self.appendOperationID {
                self.finishAppend(operationID: operationID, outcome: .cancelled)
            }
            if value, let index = self.loadedChapters.firstIndex(where: { $0.chapter.key == self.currentChapter.key }),
               let boundary = self.loadedChapters.indices.dropFirst(index + 1).first(where: {
                   !ReaderContinuationGroup(self.loadedChapters[$0 - 1].chapter).matches(ReaderContinuationGroup(self.loadedChapters[$0].chapter))
               }) {
                self.loadedChapters.removeSubrange(boundary...)
            }
            self.objectWillChange.send()
        }
    }
}
