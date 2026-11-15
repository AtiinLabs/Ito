import Combine
import Foundation
import ito_runner

/// What the reader holds of the chapter it was on before a transition began, so a chapter that turns out to
/// be made for the other reader leaves this one exactly as it was.
struct NovelTransitionSnapshot {
    let chapter: Novel.Chapter
    let loadPhase: NovelReaderLoadPhase
    let loadedChapters: [NovelLoadedChapter]
    let restoreAnchor: NovelReadingAnchor?
    let direction: ReaderHandoffDirection
    let trigger: ReaderHandoffTrigger
    let groupSwitchApproved: Bool
}

/// The text reader's side of the route: its crossings, the chapters it holds for them, and how it is
/// installed and activated as a destination.
extension NovelReaderViewModel: ReaderRouteModel, DownloadedCopyReopening {
    var routeFormat: HistoryReaderFormat { .text }
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
        let origin = atLoadedEdge && direction == .next ? (loadedChapters.last?.chapter ?? currentChapter) : currentChapter
        let token = ChapterToken(origin)
        // The view reporting the same boundary again is one crossing; only a user's own control repeats.
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
    private func emit(_ event: ReaderHandoffEvent, origin: Novel.Chapter) {
        guard let router = handoffRouter else { return }
        let boundary = event.direction == .next ? boundaryAfter(origin) : boundaryBefore(origin)
        if let candidate = boundary.candidate, let held = heldPayloads[ExactChapterKey(candidate.key)] {
            router.requestHandoff(event, prepared: held)
        } else {
            router.requestHandoff(event)
        }
    }

    /// The view left the boundary: reaching it again is a new crossing.
    func releaseHandoffLatch() { handoffLatch = nil }

    /// The row after the last loaded chapter came into view. Reaching it by the user's own scrolling, with
    /// Seamless Reading effectively on, is one crossing; layout, a restored place or a short chapter that fits
    /// the screen is not, and the row's own tap remains the explicit action.
    func continuousHandoffBoundaryAppeared() {
        guard isActive, presentationMode.isLive, !isPaging, userScrolledSinceInstall, !showsManualNextChapter,
              restoreAnchor == nil, let last = loadedChapters.last,
              boundaryAfter(last.chapter).isHandoff else { return }
        requestHandoff(direction: .next, position: .start, trigger: .visibleBoundary, atLoadedEdge: true)
    }

    private func handoffOrigin(for event: ReaderHandoffEvent) -> Novel.Chapter? {
        if ChapterToken(currentChapter).isByteIdentical(to: event.origin) { return currentChapter }
        guard event.direction == .next, let last = loadedChapters.last?.chapter,
              ChapterToken(last).isByteIdentical(to: event.origin) else { return nil }
        return last
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
        objectWillChange.send()
    }

    func retireForHandoff() {
        handoffRetired = true
        disappear()
    }

    // MARK: - Transition rollback

    func beginTransitionSnapshot(
        direction: ReaderHandoffDirection,
        trigger: ReaderHandoffTrigger,
        approved: Bool
    ) {
        transition = NovelTransitionSnapshot(
            chapter: currentChapter, loadPhase: loadPhase, loadedChapters: loadedChapters,
            restoreAnchor: restoreAnchor, direction: direction, trigger: trigger, groupSwitchApproved: approved
        )
    }

    /// The chapter the transition was loading is made for the other reader: put this reader back as it was
    /// and hand off with what was loaded, from the chapter the user actually left.
    func divertTransition(_ prepared: ReaderPreparedChapter) {
        guard let snapshot = transition else { return failDivertedLoad() }
        transition = nil
        currentChapter = snapshot.chapter
        loadedChapters = snapshot.loadedChapters
        restoreAnchor = snapshot.restoreAnchor
        loadPhase = snapshot.loadPhase
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
                position: snapshot.trigger == .chapterControl
                    ? .resume : (snapshot.direction == .next ? .start : .end),
                trigger: snapshot.trigger,
                boundaryEntryID: UUID(),
                groupSwitchApproved: snapshot.groupSwitchApproved
            ),
            prepared: prepared
        )
    }

    /// The first chapter of the route is made for the other reader, or no route can take it.
    func divertOpening(_ prepared: ReaderPreparedChapter) {
        guard let router = handoffRouter else { return failDivertedLoad() }
        router.requestFormatCorrection(visitID: routeVisitID, prepared: prepared)
    }

    private func failDivertedLoad() {
        loadPhase = .failure(ReaderRouteError.otherReader.localizedDescription)
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
        for loaded in loadedChapters { window.insert(ExactChapterKey(loaded.chapter.key)) }
        var neighbors: Set<ExactChapterKey> = []
        for chapter in [currentChapter, loadedChapters.last?.chapter].compactMap({ $0 }) {
            for boundary in [boundaryAfter(chapter), boundaryBefore(chapter)] {
                if let candidate = boundary.candidate { neighbors.insert(ExactChapterKey(candidate.key)) }
            }
        }
        chapterResolvers = chapterResolvers.filter { window.contains($0.key) }
        heldPayloads = heldPayloads.filter { neighbors.contains($0.key) }
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

    func setPresentationMode(_ mode: ReaderPresentationMode) { presentationMode = mode }

    /// Installs pages the route loaded, with the native position `position` names. Nothing it publishes has
    /// an effect: History, position writes, presence and completion wait for `activatePreparedPresentation`.
    func installPreparedChapter(_ pages: [Page], position: ReaderEntryPosition) {
        installMainChapter(pages, chapter: currentChapter, position: position)
        preparedImageKey = preparedInitialImageDescriptor()?.key
    }

    /// The image the destination opens on, when its first position is an illustration.
    func preparedInitialImageDescriptor() -> ReaderPageImageDescriptor? {
        guard let loaded = loadedChapters.first, let anchor = restoreAnchor, anchor.chapterID == loaded.id else {
            return nil
        }
        let block = NovelTextOffsets.blockIndex(containing: anchor.offset, in: loaded.pages)
        guard loaded.pages.indices.contains(block), case .url(let value) = loaded.pages[block].content,
              let url = URL(string: value) else { return nil }
        return ReaderPageImageDescriptor(
            pageID: "novel-paged-\(loaded.id.uuidString)-\(block)",
            request: NukeMangaReaderImagePrefetcher.urlRequest(url: url, headers: loaded.pages[block].headers)
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
    }

    /// Drops a destination that was never shown: its own work and images end, and nothing of the visible
    /// reader (presence included) is touched.
    func discardPreparedPresentation() {
        guard !presentationMode.isLive else { return }
        isActive = false
        invalidateContentOperations()
        imageSession.deactivate()
    }
}
