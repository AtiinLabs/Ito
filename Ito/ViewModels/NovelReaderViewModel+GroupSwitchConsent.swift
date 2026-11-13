import Combine
import Foundation
import ito_runner

/// Consent to open one neighbor that belongs to another translation group, kept out of the main file.
/// It authorizes one exact transition in the current reader session and writes nothing: the source
/// scope is only read, never captured, and must be the session's verified scope both when asked and
/// when confirmed.
extension NovelReaderViewModel {
    /// Asks to open the one neighbor of another group. The text view's own prompt asks about the
    /// last loaded chapter; every other caller asks about the current one.
    func requestGroupSwitch(
        _ direction: ReaderGroupSwitchConsent<Novel.Chapter>.Direction,
        atLoadedEdge: Bool = false
    ) {
        guard isActive else { return }
        let origin = atLoadedEdge && direction == .next ? (loadedChapters.last?.chapter ?? currentChapter) : currentChapter
        guard let epoch = completionContext.originatingEpoch,
              let candidate = groupConsentCandidate(after: origin, direction: direction) else { return }
        setGroupSwitchConsent(ReaderGroupSwitchConsent(
            chapter: candidate, originKey: origin.key, session: sessionID,
            settingsRevision: dependencies.settings.readerContinuationSettingsRevision,
            sourceContext: PluginCompletionContext(media: mediaIdentity, mediaKey: entry.key, originatingEpoch: epoch),
            direction: direction
        ))
    }

    func cancelGroupSwitch() { setGroupSwitchConsent(nil) }

    func confirmGroupSwitch(_ consentID: UUID) {
        guard let consent = groupSwitchConsent, consent.id == consentID else { return }
        setGroupSwitchConsent(nil)
        guard isActive, consent.session == sessionID,
              consent.settingsRevision == dependencies.settings.readerContinuationSettingsRevision,
              let epoch = consent.sourceContext.originatingEpoch,
              epoch == completionContext.originatingEpoch,
              epoch == currentSourceEpoch,
              let origin = consentOrigin(key: consent.originKey, direction: consent.direction),
              let candidate = groupConsentCandidate(after: origin, direction: consent.direction),
              NovelChapterToken(candidate) == NovelChapterToken(consent.chapter) else { return }
        goToChapter(candidate)
    }

    /// A read of the source's current scope; nil when it cannot be verified.
    private var currentSourceEpoch: String? {
        dependencies.progress.currentCompletionEpoch(media: mediaIdentity, mediaKey: entry.key)
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
        setGroupSwitchConsent(nil)
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
            if value { self.dropLoadedChaptersAcrossGroupBoundary() }
            self.objectWillChange.send()
        }
    }
    #if DEBUG
    func waitForContinuationSettingForTesting() async { await continuationSettingsTask?.value }
    #endif
}
