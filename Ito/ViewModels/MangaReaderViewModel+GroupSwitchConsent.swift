import Foundation
import ito_runner

/// Consent to open one neighbor that belongs to another translation group, kept out of the main file.
/// It authorizes one exact transition in the current reader session and writes nothing.
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
        guard let candidate = groupConsentCandidate(after: origin, direction: direction) else { return }
        groupSwitchConsent = ReaderGroupSwitchConsent(
            chapter: candidate, originKey: origin.key, session: sessionID,
            settingsRevision: dependencies.settings.readerContinuationSettingsRevision,
            sourceContext: dependencies.progress.captureCompletionContext(media: mediaIdentity, mediaKey: entry.key),
            direction: direction, opensAtEnd: opensAtEnd
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
              ChapterToken(candidate) == ChapterToken(consent.chapter) else { return }
        // This exact transition only: subsequent neighbors are checked again.
        switch consent.direction {
        case .next:
            if isPaged { pagedGoToChapter(candidate) } else { continuousGoToChapter(candidate) }
        case .previous:
            if isPaged { pagedGoToChapter(candidate, opensAtEnd: consent.opensAtEnd) } else { continuousGoToChapter(candidate) }
        }
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
