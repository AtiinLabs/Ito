import Combine
import Foundation
import ito_runner

/// What the reader holds of the chapter it was on before a transition began, so a chapter that turns out to
/// be made for the other reader leaves this one exactly as it was.
struct MangaTransitionSnapshot {
    let chapter: Manga.Chapter
    let loadPhase: MangaReaderLoadPhase
    let pagedPages: [Page]
    let pagedIndex: Int
    let segments: [ChapterSegment]
    let continuousPageIndex: Int
    let scrollTarget: MangaScrollRequest?
    let direction: ReaderHandoffDirection
    let trigger: ReaderHandoffTrigger
    let groupSwitchApproved: Bool
}

/// The crossing a reader already started, until it leaves the boundary or retries it.
struct ReaderHandoffLatch {
    let origin: ChapterToken
    let direction: ReaderHandoffDirection
}

/// The page reader's side of the route: its crossings, the chapters it holds for them, and how it is
/// installed and activated as a destination.
extension MangaReaderViewModel: ReaderRouteModel, DownloadedCopyReopening {
    var routeFormat: HistoryReaderFormat { .pages }
    var handoffEntry: MediaEntry { entry }

    // MARK: - Source

    /// Asks the route to continue in the other reader. The reader changes nothing about itself: its chapter,
    /// pages, position and progress stay as they are until the route swaps it.
    func requestHandoff(
        direction: ReaderHandoffDirection,
        position: ReaderEntryPosition,
        trigger: ReaderHandoffTrigger,
        atLoadedEdge: Bool
    ) {
        guard isActive, presentationMode.isLive, loadPhase == .content else { return }
        let edge = direction == .next ? segments.last?.chapter : segments.first?.chapter
        let origin = atLoadedEdge && !isPaged ? (edge ?? currentChapter) : currentChapter
        let token = ChapterToken(origin)
        // The viewport reporting the same boundary again is one crossing; only a user's own control repeats.
        if trigger != .chapterControl, let latch = handoffLatch,
           latch.direction == direction, latch.origin.isByteIdentical(to: token) { return }
        handoffLatch = ReaderHandoffLatch(origin: token, direction: direction)
        emit(
            ReaderHandoffEvent(
                sourceVisitID: routeVisitID,
                sourceSessionID: sessionID,
                sourceContentGeneration: contentGeneration,
                origin: token,
                direction: direction,
                position: position,
                trigger: trigger,
                boundaryEntryID: UUID()
            ),
            origin: origin
        )
    }

    /// Sends the event with the payload this reader already loaded for the candidate, if it has one.
    private func emit(_ event: ReaderHandoffEvent, origin: Manga.Chapter) {
        guard let router = handoffRouter else { return }
        let boundary = event.direction == .next ? boundaryAfter(origin) : boundaryBefore(origin)
        if let candidate = boundary.candidate, let held = heldPayloads[ExactChapterKey(candidate.key)] {
            router.requestHandoff(event, prepared: held)
        } else {
            router.requestHandoff(event)
        }
    }

    /// The viewport left the boundary: reaching it again is a new crossing.
    func releaseHandoffLatch() { endHandoffCrossing() }

    /// Ends the crossing the reader started, and tells the route so a failure shown for it goes away.
    func endHandoffCrossing() {
        guard handoffLatch != nil else { return }
        handoffLatch = nil
        handoffRouter?.handoffBoundaryLeft(visitID: routeVisitID)
    }

    var routeHasContent: Bool { loadPhase == .content }

    private func handoffOrigin(for event: ReaderHandoffEvent) -> Manga.Chapter? {
        if ChapterToken(currentChapter).isByteIdentical(to: event.origin) { return currentChapter }
        guard !isPaged else { return nil }
        let edge = event.direction == .next ? segments.last?.chapter : segments.first?.chapter
        guard let edge, ChapterToken(edge).isByteIdentical(to: event.origin) else { return nil }
        return edge
    }

    /// Scrolling off the edge a crossing started from ends it, so the next arrival at that edge is new.
    func releaseHandoffLatchIfViewportLeftEdge() {
        guard let latch = handoffLatch else { return }
        let edge = latch.direction == .next ? flatPages.last : flatPages.first
        if let edge, !visiblePageIDs.contains(edge.id) { endHandoffCrossing() }
    }

    func isCurrentHandoffSource(_ event: ReaderHandoffEvent) -> Bool {
        isActive
            && presentationMode.isLive
            && loadPhase == .content
            && event.sourceVisitID == routeVisitID
            && event.sourceSessionID == sessionID
            && event.sourceContentGeneration == contentGeneration
            && handoffOrigin(for: event) != nil
    }

    func handoffBoundary(for event: ReaderHandoffEvent) -> ReaderChapterBoundary<Chapter>? {
        guard let origin = handoffOrigin(for: event) else { return nil }
        return event.direction == .next ? boundaryAfter(origin) : boundaryBefore(origin)
    }

    func handoffDidEnd() {
        // A pager that rested on the neighbor's page goes back to its own last page.
        objectWillChange.send()
    }

    func retireForHandoff() {
        handoffRetired = true
        disappear()
    }

    // MARK: - Transition rollback

    /// Remembers what is on screen before a chapter is loaded in its place, so one that turns out to be made
    /// for the other reader leaves this one where it was. Nothing is remembered when there is no loaded
    /// chapter to go back to: a load already under way (the user pressed Next twice) has nothing to restore.
    func beginTransitionSnapshot(
        direction: ReaderHandoffDirection,
        trigger: ReaderHandoffTrigger,
        approved: Bool
    ) {
        guard loadPhase == .content, !currentChapterHasNothingToRestore else {
            transition = nil
            return
        }
        // The page the reader is really on: a pager resting on the notice past its last page is on that page.
        let page = pagedPages.isEmpty ? 0 : min(max(pagedIndex, 0), pagedPages.count - 1)
        let target = isPaged || !flatPages.indices.contains(continuousPageIndex)
            ? nil
            : MangaScrollRequest(pageID: flatPages[continuousPageIndex].id, animated: false)
        transition = MangaTransitionSnapshot(
            chapter: currentChapter, loadPhase: loadPhase, pagedPages: pagedPages, pagedIndex: page,
            segments: segments, continuousPageIndex: continuousPageIndex, scrollTarget: target,
            direction: direction, trigger: trigger, groupSwitchApproved: approved
        )
    }

    private var currentChapterHasNothingToRestore: Bool {
        isPaged ? pagedPages.isEmpty : segments.isEmpty
    }

    /// The chapter the transition was loading is made for the other reader: put this reader back as it was
    /// and hand off with what was loaded, from the chapter the user actually left.
    func divertTransition(_ prepared: ReaderPreparedChapter, opensAtEnd: Bool) {
        guard let snapshot = transition else { return failDivertedLoad() }
        transition = nil
        restoreTransition(snapshot)
        if hasPresentedPresence { presentPresence(for: currentChapter, resetTimer: false) }
        holdForHandoff(prepared)
        guard let router = handoffRouter else { return }
        let token = ChapterToken(snapshot.chapter)
        handoffLatch = ReaderHandoffLatch(origin: token, direction: snapshot.direction)
        router.requestHandoff(
            ReaderHandoffEvent(
                sourceVisitID: routeVisitID,
                sourceSessionID: sessionID,
                sourceContentGeneration: contentGeneration,
                origin: token,
                direction: snapshot.direction,
                position: snapshot.trigger == .chapterControl ? .resume : (opensAtEnd ? .end : .start),
                trigger: snapshot.trigger,
                boundaryEntryID: UUID(),
                groupSwitchApproved: snapshot.groupSwitchApproved
            ),
            prepared: prepared
        )
    }

    /// The chapter the reader was loading, with nothing on screen, is made for the other reader. Where it
    /// opens is the start (or the end, coming back from the next chapter): the saved position is one number
    /// that may belong to the other form of this chapter.
    func divertOpening(_ prepared: ReaderPreparedChapter, opensAtEnd: Bool) {
        guard let router = handoffRouter,
              router.requestFormatCorrection(
                  visitID: routeVisitID, prepared: prepared, position: opensAtEnd ? .end : .start
              ) else { return failDivertedLoad() }
    }

    // MARK: - Held chapters

    /// Keeps what a loaded chapter pins readable for as long as the chapter is in this reader's window.
    func retain(_ prepared: ReaderPreparedChapter) {
        chapterResolvers[ExactChapterKey(prepared.chapter.key)] = prepared.resolver
        pruneRetainedChapters()
    }

    /// A neighbor found to be made for the other reader stays a handoff boundary, with its payload.
    func holdForHandoff(_ prepared: ReaderPreparedChapter) {
        heldPayloads[ExactChapterKey(prepared.chapter.key)] = prepared
        pruneRetainedChapters()
        objectWillChange.send()
    }

    /// Only the window and its immediate neighbors keep a payload or a pin.
    func pruneRetainedChapters() {
        var window: Set<ExactChapterKey> = [ExactChapterKey(currentChapter.key)]
        for segment in segments { window.insert(ExactChapterKey(segment.chapter.key)) }
        for key in prefetchedChapters.keys { window.insert(ExactChapterKey(key)) }
        var neighbors: Set<ExactChapterKey> = []
        for chapter in [currentChapter, segments.first?.chapter, segments.last?.chapter].compactMap({ $0 }) {
            for boundary in [boundaryAfter(chapter), boundaryBefore(chapter)] {
                if let candidate = boundary.candidate { neighbors.insert(ExactChapterKey(candidate.key)) }
            }
        }
        chapterResolvers = chapterResolvers.filter { window.contains($0.key) }
        heldPayloads = heldPayloads.filter { neighbors.contains($0.key) }
    }

    /// Keeps a prefetched neighbor: its pages for the next transition, or its payload when it is made for
    /// the other reader.
    func storePrefetched(_ prepared: ReaderPreparedChapter) {
        guard prepared.format == .pages else {
            holdForHandoff(prepared)
            return
        }
        cachePrefetchedChapter(prepared.pages, for: prepared.chapter.key)
        retain(prepared)
    }

    // MARK: - Source of downloaded copies

    func isReadingRemoteThisTime(chapterKey: String) -> Bool {
        chapterPreparer.isReadingRemoteThisTime(chapterKey: chapterKey)
    }

    func readsFromSource(chapterKey: String) -> Bool {
        chapterResolvers[ExactChapterKey(chapterKey)]?.readsFromSource(chapterKey: chapterKey)
            ?? isReadingRemoteThisTime(chapterKey: chapterKey)
    }

    func readDownloadedCopy(chapterKey: String) {
        chapterResolvers[ExactChapterKey(chapterKey)]?.readLocalFirst(chapterKey: chapterKey)
        chapterPreparer.readLocalFirst(chapterKey: chapterKey)
    }

    // MARK: - Destination

    /// Installs pages the route loaded, with the native position `position` names. Nothing it publishes has
    /// an effect: History, position writes, presence and completion wait for `activatePreparedPresentation`.
    func installPreparedChapter(_ pages: [Page], position: ReaderEntryPosition) {
        installMainPages(pages, chapter: currentChapter, position: position, paged: isPaged)
        preparedImageKey = preparedInitialImageDescriptor()?.key
    }

    func preparedInitialImageDescriptor() -> ReaderPageImageDescriptor? {
        let pages = isPaged ? pagedPages : (segments.first?.pages ?? [])
        let index = isPaged ? pagedIndex : continuousPageIndex
        guard pages.indices.contains(index), case .url(let value) = pages[index].content,
              let url = URL(string: value) else { return nil }
        return ReaderPageImageDescriptor(
            pageID: FlatPage.id(chapterKey: currentChapter.key, position: index),
            request: NukeMangaReaderImagePrefetcher.urlRequest(url: url, headers: pages[index].headers)
        )
    }

    /// Makes an installed destination live, once: what completing a main load does for a reader that
    /// loaded the chapter itself.
    func activatePreparedPresentation() {
        guard presentationMode.isLive, isActive, loadPhase == .content,
              routeSession.claimActivation(of: routeVisitID) else { return }
        hasPresentedPresence = viewAppeared
        if viewAppeared { presentPresence(for: currentChapter, resetTimer: true) }
        chapterOpened(currentChapter)
        let count = isPaged ? pagedPages.count : (segments.first?.pages.count ?? 0)
        if count > 0 {
            pageShown(in: currentChapter, at: isPaged ? pagedIndex : continuousPageIndex, pageCount: count)
        }
        reconcileCurrentImagePrefetch()
        if isPaged {
            beginAdjacentChapterPrefetch()
        }
    }
}

/// Why a reader cannot take a chapter it was handed.
enum ReaderRouteError: LocalizedError {
    case otherReader

    var errorDescription: String? {
        String(
            localized: "This chapter opens in the other reader.",
            comment: "Reader failure: the chapter is made for the other reader, but this reader has no route to hand it to."
        )
    }
}
