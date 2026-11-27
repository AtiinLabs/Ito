import Foundation
import ito_runner

extension NovelReaderViewModel {
    /// What opening `chapter` from the chapter list does in this reader: a chapter it opens, one the other
    /// reader opens, or why it cannot open. Like a row on the series page, it asks nothing about the group.
    func jumpBoundary(to chapter: Novel.Chapter) -> ReaderChapterBoundary<Novel.Chapter> {
        offline.resolving(chapter.isPaywalled ? .locked(chapter) : .chapter(chapter), opensHere: { opensHere($0) })
    }

    /// Whether the series has another chapter to go to.
    var canShowChapterList: Bool { (entry.chapters?.count ?? 0) > 1 }

    /// The chapter list, as the reader would open each row now.
    var chapterListRows: [ReaderChapterListRow] {
        ReaderChapterList.rows(
            chapters: entry.chapters ?? [currentChapter],
            current: currentChapter,
            isRead: { chapter in
                routeSession.hasClaimedCompletion(chapter.key)
                    || dependencies.progress.isChapterRead(
                        media: mediaIdentity, chapterID: chapter.key, chapterNumber: chapter.chapterNumber
                    )
            },
            boundary: { jumpBoundary(to: $0) }
        )
    }

    /// Opens `chapter`, picked from the chapter list, in place of the current one: here when it reads here,
    /// else in the other reader through the route. As on the series page, the pick is the consent: no group
    /// question is asked, and Next and Previous then follow the picked chapter's group.
    /// Returns whether the pick was taken; a refused pick changes nothing.
    @discardableResult
    func jump(to chapter: Novel.Chapter) -> Bool {
        guard isActive, presentationMode.isLive, handoffRouter?.isHandoffPending != true,
              let target = entry.listedChapter(identicalTo: ChapterToken(chapter)) else { return false }
        if ChapterToken(target).isByteIdentical(to: ChapterToken(currentChapter)) {
            if case .failure = loadPhase { retry() }
            return true
        }
        switch jumpBoundary(to: target) {
        case .chapter:
            break
        case .handoff where loadPhase == .content:
            setGroupSwitchConsent(nil)
            routeSession.reopenHistory(for: target)
            return requestChosenHandoff(to: target)
        case .handoff:
            // Nothing on screen to keep: this reader loads it, and the route corrects the format.
            break
        case .locked, .notAvailableOffline, .end, .groupConsent:
            return false
        }
        setGroupSwitchConsent(nil)
        endCrossingForJump()
        routeSession.reopenHistory(for: target)
        let direction = ReaderChapterOrdering.direction(from: currentChapter, to: target, in: entry.chapters)
        goToChapter(
            target, direction: direction, trigger: .chapterControl, approved: false,
            target: .chosen(ChapterToken(target))
        )
        return true
    }
}
