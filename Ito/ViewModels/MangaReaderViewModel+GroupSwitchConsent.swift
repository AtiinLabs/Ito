import Foundation
import ito_runner

/// Consent to open one neighbor that belongs to another translation group, kept out of the main file.
/// It authorizes one exact transition in the current reader session and writes nothing: the source
/// scope is only read, never captured, and must be the session's verified scope both when asked and
/// when confirmed.
extension MangaReaderViewModel {
    /// Asks to open the one neighbor of another group. The continuous reader's own prompt asks
    /// about the edge of what is loaded; every other caller asks about the current chapter.
    func requestGroupSwitch(
        _ direction: ReaderGroupSwitchConsent<Manga.Chapter>.Direction,
        opensAtEnd: Bool = false,
        atLoadedEdge: Bool = false
    ) {
        guard isActive else { return }
        let edge = direction == .next ? segments.last?.chapter : segments.first?.chapter
        let origin = atLoadedEdge && !isPaged ? (edge ?? currentChapter) : currentChapter
        guard let epoch = completionContext.originatingEpoch,
              let candidate = groupConsentCandidate(after: origin, direction: direction) else { return }
        setGroupSwitchConsent(ReaderGroupSwitchConsent(
            chapter: candidate, originKey: origin.key, session: sessionID,
            settingsRevision: dependencies.settings.readerContinuationSettingsRevision,
            sourceContext: PluginCompletionContext(media: mediaIdentity, mediaKey: entry.key, originatingEpoch: epoch),
            direction: direction, opensAtEnd: opensAtEnd
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
              ChapterToken(candidate) == ChapterToken(consent.chapter) else { return }
        // This exact transition only: subsequent neighbors are checked again.
        openApprovedGroupSwitch(candidate, opensAtEnd: consent.direction == .previous && consent.opensAtEnd)
    }

    /// A read of the source's current scope; nil when it cannot be verified.
    private var currentSourceEpoch: String? {
        dependencies.progress.currentCompletionEpoch(media: mediaIdentity, mediaKey: entry.key)
    }

    private func groupConsentCandidate(
        after origin: Manga.Chapter,
        direction: ReaderGroupSwitchConsent<Manga.Chapter>.Direction
    ) -> Manga.Chapter? {
        let boundary = direction == .next ? boundaryAfter(origin) : boundaryBefore(origin)
        guard case .groupConsent(let candidate) = boundary else { return nil }
        return candidate
    }

    /// The chapter a prompt was shown for: still the current one, or still the edge of the loaded run.
    private func consentOrigin(
        key: String?,
        direction: ReaderGroupSwitchConsent<Manga.Chapter>.Direction
    ) -> Manga.Chapter? {
        if currentChapter.key == key { return currentChapter }
        guard !isPaged else { return nil }
        let edge = direction == .next ? segments.last?.chapter : segments.first?.chapter
        return edge?.key == key ? edge : nil
    }
}
