import Combine
import Foundation
import ito_runner

// MARK: - Values

/// Logical order, not the physical direction of a page turn.
nonisolated enum ReaderHandoffDirection: Equatable, Sendable {
    case next
    case previous
}

/// Where the destination opens, in its own native coordinates.
nonisolated enum ReaderEntryPosition: Equatable, Sendable {
    /// The destination's own saved position, clamped and finished rules included.
    case resume
    /// The first image, or text offset 0.
    case start
    /// The last image, or the end of the text.
    case end
}

nonisolated enum ReaderHandoffTrigger: Equatable, Sendable {
    case chapterControl
    case pagedEdge
    case visibleBoundary
}

/// A renderer visit is live, or built behind the visible one for one handoff request.
nonisolated enum ReaderPresentationMode: Equatable, Sendable {
    case live
    case staged(requestID: UUID, visitID: UUID)

    var isLive: Bool { self == .live }
}

/// One user-directed crossing of a chapter boundary, as the source reader saw it.
struct ReaderHandoffEvent: Equatable {
    let sourceVisitID: UUID
    let sourceSessionID: UUID
    let sourceContentGeneration: UInt64
    /// The chapter the crossing started from, exactly as it was when the user reached the boundary.
    let origin: ChapterToken
    let direction: ReaderHandoffDirection
    let position: ReaderEntryPosition
    let trigger: ReaderHandoffTrigger
    /// One entry into the boundary; geometry callbacks repeating it coalesce.
    let boundaryEntryID: UUID
    /// The user already confirmed this exact group switch in the reader that is handing off.
    var groupSwitchApproved = false
}

nonisolated enum ReaderHandoffFailure: Equatable, Sendable {
    case unavailableOffline
    case protectedDataUnavailable
    case localCopyUnavailable
    case loadFailed
    case presentationFailed
}

/// Everything one handoff is bound to. Never persisted and never handed to a plugin.
struct ReaderHandoffRequest: Identifiable {
    let id: UUID
    let routeID: UUID
    let routeGeneration: UInt64
    let event: ReaderHandoffEvent
    let chapter: Chapter
    let token: ChapterToken
    let catalogGeneration: UInt64
    let sourceContext: PluginCompletionContext
    let authorizationScope: UUID
    let continuationSettingsRevision: UInt64
    let networkPolicyRevision: UInt64
    let pathGeneration: UInt64
    /// The selected saved copy the opening carries, when the candidate is that exact chapter.
    let selectedLease: OfflineChapterLease?
}

/// The renderer that is on screen. The visit identifies one mounted renderer.
enum ReaderRoutePresentation {
    case pages(visitID: UUID, MangaReaderViewModel)
    case text(visitID: UUID, NovelReaderViewModel)

    var visitID: UUID {
        switch self {
        case .pages(let visitID, _), .text(let visitID, _): visitID
        }
    }

    var model: any ReaderRouteModel {
        switch self {
        case .pages(_, let model): model
        case .text(_, let model): model
        }
    }
}

enum ReaderRoutePhase {
    /// The first chapter has not been installed yet.
    case opening
    case idle
    case awaitingConsent(ReaderHandoffRequest, ReaderGroupSwitchConsent<Chapter>)
    case preparing(ReaderHandoffRequest)
    case staging(ReaderHandoffRequest, ReaderRoutePresentation)
    case failed(ReaderHandoffRequest, ReaderHandoffFailure)
    case closed

    /// The request a pending phase is working on.
    var request: ReaderHandoffRequest? {
        switch self {
        case .awaitingConsent(let request, _), .preparing(let request),
             .staging(let request, _), .failed(let request, _):
            request
        case .opening, .idle, .closed:
            nil
        }
    }

    /// A handoff is waiting on the user or on work, so the source reader must not navigate.
    var isBusy: Bool {
        switch self {
        case .awaitingConsent, .preparing, .staging: true
        case .opening, .idle, .failed, .closed: false
        }
    }
}

// MARK: - Seams

/// What the coordinator needs from whichever reader is on screen.
@MainActor
protocol ReaderRouteModel: AnyObject {
    var routeVisitID: UUID { get }
    var routeFormat: HistoryReaderFormat { get }
    /// The entry the reader reads, for preparing a neighbor of it.
    var handoffEntry: MediaEntry { get }
    var imageSession: ReaderPageImageSession { get }
    var handoffRouter: (any ReaderHandoffRouting)? { get set }

    /// Whether `event` still describes the reader's own state: live visit, session, content generation,
    /// and the chapter it left from being current or the edge of what is loaded.
    func isCurrentHandoffSource(_ event: ReaderHandoffEvent) -> Bool
    /// What lies past the event's origin now, resolved by the reader's own ordering and offline rules.
    func handoffBoundary(for event: ReaderHandoffEvent) -> ReaderChapterBoundary<Chapter>?
    func setPresentationMode(_ mode: ReaderPresentationMode)
    /// The image the destination shows first, as its own renderer requests it; nil when it opens on text.
    func preparedInitialImageDescriptor() -> ReaderPageImageDescriptor?
    /// Starts the effects a live reader has: History, position, presence, and what a loaded page implies.
    func activatePreparedPresentation()
    func discardPreparedPresentation()
    /// The reader leaves for the other one: its work stops and its presence goes, but the route continues.
    func retireForHandoff()
    /// The crossing ended without a switch; the reader shows its own position again.
    func handoffDidEnd()
}

/// How a reader reports a crossing to its route.
@MainActor
protocol ReaderHandoffRouting: AnyObject {
    func requestHandoff(_ event: ReaderHandoffEvent)
    /// For an event whose chapter was already loaded by the source reader and turned out to be made for
    /// the other one. Never creates an event by itself.
    func requestHandoff(_ event: ReaderHandoffEvent, prepared: ReaderPreparedChapter)
    /// The first chapter of the route turned out to be made for the other reader. There is no source to
    /// keep, so the right reader replaces the one that found out.
    func requestFormatCorrection(visitID: UUID, prepared: ReaderPreparedChapter)
}

@MainActor
protocol ReaderRoutePresentationMaking {
    func makeInitialPresentation(
        format: HistoryReaderFormat,
        entry: MediaEntry,
        chapter: Chapter,
        session: ReaderRouteSession,
        preparer: any ReaderChapterPreparing,
        visitID: UUID
    ) -> ReaderRoutePresentation

    func makePreparedPresentation(
        _ prepared: ReaderPreparedChapter,
        position: ReaderEntryPosition,
        session: ReaderRouteSession,
        preparer: any ReaderChapterPreparing,
        visitID: UUID,
        mode: ReaderPresentationMode
    ) -> ReaderRoutePresentation
}

/// The network facts a handoff is bound to, read and never captured.
@MainActor
protocol ReaderRouteNetworking: AnyObject {
    func liveScope(pluginID: String) -> UUID
    var policyRevision: UInt64 { get }
    var pathGeneration: UInt64 { get }
    var policyChanges: AnyPublisher<Void, Never> { get }
    var scopeChanges: AnyPublisher<Void, Never> { get }
}

/// A chapter fetched for a reader: its pages, the form it is actually saved or served in, and the pins
/// that keep that form readable for as long as the payload lives.
struct ReaderPreparedChapter {
    let entry: MediaEntry
    let chapter: Chapter
    let pages: [Page]
    let format: HistoryReaderFormat
    let resolver: OfflineChapterSourceResolver
    let content: ReaderContentSource
}

// MARK: - Session

/// Chapter keys compare as bytes: Swift's own equality merges canonically equivalent strings.
nonisolated struct ExactChapterKey: Hashable, Sendable {
    let value: String

    init(_ value: String) { self.value = value }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.value.utf8.elementsEqual(rhs.value.utf8) }

    func hash(into hasher: inout Hasher) {
        for byte in value.utf8 { hasher.combine(byte) }
    }
}

/// What every renderer visit of one route shares, so swapping renderers cannot repeat a History visit or a
/// completion, and an older position write cannot land after a newer one. Nothing here is durable: History
/// and read progress stay with their managers.
@MainActor
final class ReaderRouteSession {
    let id = UUID()
    /// Captured once for the route, so every chapter of it shares one source scope.
    let completionContext: PluginCompletionContext
    private let scope: any PluginCompletionScopeCapturing
    private(set) var isOpen = true
    private var openedChapters: Set<ExactChapterKey> = []
    private var completedChapters: Set<ExactChapterKey> = []
    private var activatedVisits: Set<UUID> = []
    private var positionTail: Task<Void, Never>?

    init(media: MediaIdentity, mediaKey: String, scope: any PluginCompletionScopeCapturing) {
        self.scope = scope
        completionContext = scope.captureCompletionContext(media: media, mediaKey: mediaKey)
    }

    /// The source scope now, as a read.
    var currentEpoch: String? {
        scope.currentCompletionEpoch(media: completionContext.media, mediaKey: completionContext.mediaKey)
    }

    func claimHistory(_ chapter: Chapter) -> Bool {
        openedChapters.insert(ExactChapterKey(chapter.key)).inserted
    }

    func claimCompletion(_ chapter: Chapter) -> Bool {
        completedChapters.insert(ExactChapterKey(chapter.key)).inserted
    }

    func hasClaimedCompletion(_ key: String) -> Bool {
        completedChapters.contains(ExactChapterKey(key))
    }

    var claimedCompletionKeys: Set<String> { Set(completedChapters.map(\.value)) }

    /// A visit activates once, however often it is told to.
    func claimActivation(of visitID: UUID) -> Bool {
        activatedVisits.insert(visitID).inserted
    }

    /// Position writes run one after another across renderer visits. An admitted write is never cancelled.
    @discardableResult
    func enqueuePositionWrite(_ write: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let preceding = positionTail
        let task = Task { @MainActor in
            await preceding?.value
            await write()
        }
        positionTail = task
        return task
    }

    /// A tracker step may run while the route is open and the source scope it captured is still the
    /// current one. A renderer swap keeps both.
    func allowsTracker(context: PluginCompletionContext) -> Bool {
        isOpen && context.originatingEpoch == currentEpoch
    }

    /// Stops admitting new presentation and tracker work. Already admitted local marks and writes finish.
    func close() { isOpen = false }

#if DEBUG
    func waitForPositionWritesForTesting() async { await positionTail?.value }
#endif
}

// MARK: - Coordinator

/// Owns which reader is on screen for one opening of a series, and moves the route between the page reader
/// and the text reader when the next or previous chapter is made for the other one. The destination is
/// prepared and laid out behind the visible reader, which stays untouched until the destination can be
/// shown; a failed, cancelled or stale handoff changes nothing the user can see.
@MainActor
final class ReaderRouteCoordinator: ObservableObject, ReaderHandoffRouting {
    let rootID: UUID
    let pluginID: String
    let session: ReaderRouteSession

    @Published private(set) var active: ReaderRoutePresentation?
    @Published private(set) var phase: ReaderRoutePhase = .opening

    let preparer: any ReaderChapterPreparing
    private let presentations: any ReaderRoutePresentationMaking
    private let settings: any ReaderContinuationSettingsReading
    private let network: any ReaderRouteNetworking
    private let openingLease: OfflineChapterLease?
    private let openingChapterKey: String

    /// The route's pinned catalog. A replacement advances `catalogGeneration`.
    private var catalogGeneration: UInt64 = 0
    private var routeGeneration: UInt64 = 0
    private var operationTask: Task<Void, Never>?
    /// Boundary entries that already produced a request, until the reader leaves and re-enters them.
    private var consumedBoundaryEntries: Set<UUID> = []
    private var readiness: StagedReadiness?
    private var imageHold: ReaderPreparationImageHold?
    private var pendingPrepared: (requestID: UUID, payload: ReaderPreparedChapter)?
    private var networkSubscription: AnyCancellable?
    private var scopeSubscription: AnyCancellable?
    private var openingSubscription: AnyCancellable?

    /// What a staged destination still has to show before it replaces the visible reader.
    private struct StagedReadiness {
        let requestID: UUID
        let visitID: UUID
        var layoutApplied = false
        var imageNeeded: Bool
        var imageReady = false

        var isComplete: Bool { layoutApplied && (!imageNeeded || imageReady) }
    }

    init(
        rootID: UUID,
        pluginID: String,
        entry: MediaEntry,
        chapter: Chapter,
        format: HistoryReaderFormat,
        content: ReaderContentSource,
        session: ReaderRouteSession,
        preparer: any ReaderChapterPreparing,
        presentations: any ReaderRoutePresentationMaking,
        settings: any ReaderContinuationSettingsReading,
        network: any ReaderRouteNetworking
    ) {
        self.rootID = rootID
        self.pluginID = pluginID
        self.session = session
        self.preparer = preparer
        self.presentations = presentations
        self.settings = settings
        self.network = network
        openingLease = content.preference.localOnlySeed?.lease
        openingChapterKey = chapter.key
        let presentation = presentations.makeInitialPresentation(
            format: format, entry: entry, chapter: chapter, session: session,
            preparer: preparer, visitID: UUID()
        )
        presentation.model.handoffRouter = self
        active = presentation
        observeOpening(presentation)
        networkSubscription = network.policyChanges.sink { @Sendable [weak self] in
            Task { @MainActor in self?.networkDidChange() }
        }
        scopeSubscription = network.scopeChanges.sink { @Sendable [weak self] in
            Task { @MainActor in self?.scopeDidChange() }
        }
    }

    /// The route is open for handoffs once the first chapter is on screen.
    private func observeOpening(_ presentation: ReaderRoutePresentation) {
        switch presentation {
        case .pages(_, let model):
            openingSubscription = model.$loadPhase.sink { [weak self] phase in
                if case .content = phase { MainActor.assumeIsolated { self?.openingFinished() } }
            }
        case .text(_, let model):
            openingSubscription = model.$loadPhase.sink { [weak self] phase in
                if case .content = phase { MainActor.assumeIsolated { self?.openingFinished() } }
            }
        }
    }

    private func openingFinished() {
        if case .opening = phase { phase = .idle }
        openingSubscription = nil
    }

    // MARK: Requests

    func requestHandoff(_ event: ReaderHandoffEvent) {
        admit(event, prepared: nil)
    }

    func requestHandoff(_ event: ReaderHandoffEvent, prepared: ReaderPreparedChapter) {
        admit(event, prepared: prepared)
    }

    private func admit(_ event: ReaderHandoffEvent, prepared: ReaderPreparedChapter?) {
        guard session.isOpen, case .idle = phase,
              !consumedBoundaryEntries.contains(event.boundaryEntryID),
              let source = active?.model,
              source.isCurrentHandoffSource(event),
              let boundary = source.handoffBoundary(for: event) else { return }
        guard let candidate = acceptedCandidate(boundary, prepared: prepared, event: event) else { return }
        consumedBoundaryEntries.insert(event.boundaryEntryID)
        if let prepared, !ChapterToken(prepared.chapter).isByteIdentical(to: ChapterToken(candidate.chapter)) { return }
        let request = makeRequest(event: event, chapter: candidate.chapter)
        if candidate.requiresConsent, !event.groupSwitchApproved {
            guard let consent = makeConsent(for: request) else {
                source.handoffDidEnd()
                return
            }
            phase = .awaitingConsent(request, consent)
            return
        }
        if let prepared {
            stage(request, prepared: prepared)
        } else {
            beginPreparation(request)
        }
    }

    /// The candidate a crossing may hand off to. A `.chapter` or consent boundary is accepted only when the
    /// payload the source already loaded proves it is made for the other reader.
    private func acceptedCandidate(
        _ boundary: ReaderChapterBoundary<Chapter>,
        prepared: ReaderPreparedChapter?,
        event: ReaderHandoffEvent
    ) -> (chapter: Chapter, requiresConsent: Bool)? {
        switch boundary {
        case .handoff(let chapter, let requiresConsent):
            return (chapter, requiresConsent)
        case .chapter(let chapter):
            guard prepared != nil else { return nil }
            return (chapter, false)
        case .groupConsent(let chapter):
            guard prepared != nil else { return nil }
            return (chapter, !event.groupSwitchApproved)
        case .end, .locked, .notAvailableOffline:
            return nil
        }
    }

    private func makeRequest(event: ReaderHandoffEvent, chapter: Chapter) -> ReaderHandoffRequest {
        ReaderHandoffRequest(
            id: UUID(),
            routeID: rootID,
            routeGeneration: routeGeneration,
            event: event,
            chapter: chapter,
            token: ChapterToken(chapter),
            catalogGeneration: catalogGeneration,
            sourceContext: session.completionContext,
            authorizationScope: network.liveScope(pluginID: pluginID),
            continuationSettingsRevision: settings.readerContinuationSettingsRevision,
            networkPolicyRevision: network.policyRevision,
            pathGeneration: network.pathGeneration,
            selectedLease: chapter.key.utf8.elementsEqual(openingChapterKey.utf8) ? openingLease : nil
        )
    }

    /// An unverifiable source scope cannot authorize a group switch.
    private func makeConsent(for request: ReaderHandoffRequest) -> ReaderGroupSwitchConsent<Chapter>? {
        guard request.sourceContext.originatingEpoch != nil else { return nil }
        return ReaderGroupSwitchConsent(
            chapter: request.chapter,
            originKey: request.event.origin.key,
            session: request.event.sourceSessionID,
            settingsRevision: request.continuationSettingsRevision,
            sourceContext: request.sourceContext,
            direction: request.event.direction == .next ? .next : .previous,
            opensAtEnd: request.event.position == .end
        )
    }

    // MARK: Consent, retry and cancel

    func confirmHandoff(consentID: UUID) {
        guard case .awaitingConsent(let request, let consent) = phase, consent.id == consentID else { return }
        // The same scope, setting and candidate that were asked about, now read again.
        guard revalidate(request, requiringCandidate: true), request.sourceContext.originatingEpoch != nil else {
            invalidate()
            return
        }
        beginPreparation(request)
    }

    func cancelHandoff() {
        guard phase.request != nil else { return }
        let source = active?.model
        invalidate()
        source?.handoffDidEnd()
    }

    func retryHandoff(requestID: UUID) {
        guard case .failed(let failed, _) = phase, failed.id == requestID else { return }
        guard revalidate(failed, requiringCandidate: true) else {
            cancelHandoff()
            return
        }
        let request = makeRequest(event: failed.event, chapter: failed.chapter)
        if request.event.groupSwitchApproved == false, let candidate = candidateConsent(for: request), candidate {
            guard let consent = makeConsent(for: request) else { cancelHandoff(); return }
            phase = .awaitingConsent(request, consent)
            return
        }
        beginPreparation(request)
    }

    /// Whether the candidate still asks for a group switch, read from the source.
    private func candidateConsent(for request: ReaderHandoffRequest) -> Bool? {
        guard case .handoff(_, let requires)? = active?.model.handoffBoundary(for: request.event) else { return nil }
        return requires
    }

    // MARK: Preparation

    private func beginPreparation(_ request: ReaderHandoffRequest) {
        guard let source = active?.model else { return }
        releaseStaged()
        phase = .preparing(request)
        let operation = PluginNetworkOperation(
            purpose: .foregroundReading,
            operationID: request.id,
            batchID: nil,
            scopedGrant: nil,
            policyRevision: request.networkPolicyRevision
        )
        let preparer = preparer
        let entry = source.handoffEntry
        let chapter = request.chapter
        operationTask = Task { @MainActor [weak self] in
            do {
                let prepared = try await preparer.prepareChapter(entry: entry, chapter: chapter, operation: operation)
                self?.preparationFinished(requestID: request.id, prepared: prepared)
            } catch {
                self?.preparationFailed(requestID: request.id, error: error)
            }
        }
    }

    private func preparationFinished(requestID: UUID, prepared: ReaderPreparedChapter) {
        guard case .preparing(let request) = phase, request.id == requestID, !Task.isCancelled else { return }
        // A result that no longer matches the route is dropped, and the source shows its own position again.
        guard revalidate(request, requiringCandidate: true) else {
            cancelHandoff()
            return
        }
        stage(request, prepared: prepared)
    }

    private func preparationFailed(requestID: UUID, error: any Error) {
        guard case .preparing(let request) = phase, request.id == requestID, !Task.isCancelled,
              !(error is CancellationError) else { return }
        phase = .failed(request, Self.failure(for: error))
    }

    static func failure(for error: any Error) -> ReaderHandoffFailure {
        switch error as? OfflineReadError {
        case .notDownloaded?: .unavailableOffline
        case .protectedDataUnavailable?: .protectedDataUnavailable
        case .localCopyUnavailable?, .localCopyDamaged?: .localCopyUnavailable
        case nil: .loadFailed
        }
    }

    // MARK: Staging and commit

    /// Builds the destination behind the visible reader. Nothing it does yet has an effect.
    private func stage(_ request: ReaderHandoffRequest, prepared: ReaderPreparedChapter) {
        guard active != nil else { return }
        let visitID = UUID()
        let presentation = presentations.makePreparedPresentation(
            prepared, position: request.event.position, session: session, preparer: preparer,
            visitID: visitID, mode: .staged(requestID: request.id, visitID: visitID)
        )
        presentation.model.handoffRouter = self
        pendingPrepared = (request.id, prepared)
        let descriptor = presentation.model.preparedInitialImageDescriptor()
        readiness = StagedReadiness(requestID: request.id, visitID: visitID, imageNeeded: descriptor != nil)
        phase = .staging(request, presentation)
        // Staged readers are mounted underneath the visible one by the route view.
        if let descriptor {
            let hold = ReaderPreparationImageHold(
                requestID: request.id, visitID: visitID,
                session: presentation.model.imageSession, descriptor: descriptor
            ) { [weak self] succeeded in
                self?.imageSettled(requestID: request.id, visitID: visitID, succeeded: succeeded)
            }
            imageHold = hold
            hold.begin()
        }
    }

    private func imageSettled(requestID: UUID, visitID: UUID, succeeded: Bool) {
        guard case .staging(let request, let staged) = phase, request.id == requestID,
              staged.visitID == visitID, readiness?.requestID == requestID else { return }
        guard succeeded else {
            failStaging(request, .presentationFailed)
            return
        }
        readiness?.imageReady = true
        commitIfReady()
    }

    /// The destination laid out its initial content at the requested position.
    func presentationReady(requestID: UUID, visitID: UUID) {
        guard case .staging(let request, let staged) = phase, request.id == requestID,
              staged.visitID == visitID, readiness?.requestID == requestID else { return }
        readiness?.layoutApplied = true
        commitIfReady()
    }

    func presentationFailed(requestID: UUID, visitID: UUID) {
        guard case .staging(let request, let staged) = phase, request.id == requestID,
              staged.visitID == visitID else { return }
        failStaging(request, .presentationFailed)
    }

    /// The destination's own renderer holds a visible lease on the first image now, so the one that
    /// proved the image can go.
    func initialImageVisibleLeaseAcquired(requestID: UUID, visitID: UUID) {
        guard let hold = imageHold, hold.requestID == requestID, hold.visitID == visitID else { return }
        hold.release()
        imageHold = nil
    }

    private func failStaging(_ request: ReaderHandoffRequest, _ failure: ReaderHandoffFailure) {
        releaseStaged()
        phase = .failed(request, failure)
    }

    private func commitIfReady() {
        guard case .staging(let request, let staged) = phase, let readiness, readiness.isComplete,
              readiness.requestID == request.id, readiness.visitID == staged.visitID else { return }
        // Final revalidation and the swap are one main-actor section: nothing can interleave.
        guard revalidate(request, requiringCandidate: true), let source = active?.model else {
            invalidate()
            return
        }
        pendingPrepared = nil
        self.readiness = nil
        // Presence and image work of the old reader end before the new one starts its own.
        source.retireForHandoff()
        active = staged
        phase = .idle
        staged.model.setPresentationMode(.live)
        staged.model.activatePreparedPresentation()
    }

    // MARK: Format correction

    func requestFormatCorrection(visitID: UUID, prepared: ReaderPreparedChapter) {
        guard session.isOpen, case .opening = phase, let source = active, source.visitID == visitID else { return }
        let newVisit = UUID()
        let presentation = presentations.makePreparedPresentation(
            prepared, position: .resume, session: session, preparer: preparer,
            visitID: newVisit, mode: .live
        )
        presentation.model.handoffRouter = self
        source.model.retireForHandoff()
        active = presentation
        phase = .idle
        observeOpening(presentation)
        presentation.model.activatePreparedPresentation()
    }

    // MARK: Validity

    /// Whether `request` still describes the route. Scope checks are reads, never captures.
    private func revalidate(
        _ request: ReaderHandoffRequest,
        requiringCandidate: Bool
    ) -> Bool {
        guard session.isOpen, request.routeID == rootID, request.routeGeneration == routeGeneration,
              request.catalogGeneration == catalogGeneration,
              request.continuationSettingsRevision == settings.readerContinuationSettingsRevision,
              request.authorizationScope == network.liveScope(pluginID: pluginID),
              request.sourceContext.originatingEpoch == session.currentEpoch,
              let source = active?.model, source.routeVisitID == request.event.sourceVisitID,
              source.isCurrentHandoffSource(request.event) else { return false }
        guard requiringCandidate else { return true }
        guard let boundary = source.handoffBoundary(for: request.event),
              let candidate = boundary.candidate,
              ChapterToken(candidate).isByteIdentical(to: request.token) else { return false }
        switch boundary {
        case .handoff, .groupConsent, .chapter: return true
        case .end, .locked, .notAvailableOffline: return false
        }
    }

    /// The route no longer matches what a pending handoff was started for. Invalidates first, so a late
    /// result of the cancelled work finds nothing to publish into.
    func invalidate() {
        routeGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
        releaseStaged()
        if case .closed = phase { return }
        if case .opening = phase { return }
        phase = .idle
    }

    private func releaseStaged() {
        if case .staging(_, let staged) = phase { staged.model.discardPreparedPresentation() }
        imageHold?.release()
        imageHold = nil
        readiness = nil
        pendingPrepared = nil
    }

    /// A policy or path change moves what a pending remote preparation was admitted under; it is prepared
    /// again under the policy now in force, and a refusal fails it instead of presenting. A staged
    /// destination keeps its payload: its image requests are admitted by the transport as they start.
    func networkDidChange() {
        guard case .preparing(let request) = phase,
              request.networkPolicyRevision != network.policyRevision
                || request.pathGeneration != network.pathGeneration else { return }
        operationTask?.cancel()
        operationTask = nil
        let renewed = makeRequest(event: request.event, chapter: request.chapter)
        guard revalidate(renewed, requiringCandidate: true) else {
            cancelHandoff()
            return
        }
        beginPreparation(renewed)
    }

    /// The source's authorization scope was replaced, even if it later returned to what it was: nothing
    /// that was asked or prepared under the old one is used.
    func scopeDidChange() {
        guard phase.request != nil else { return }
        cancelHandoff()
    }

    /// The app left the foreground: nothing pending outlives it, and the source reader stays as it was.
    func sceneDidLeaveActive() {
        guard phase.request != nil else { return }
        cancelHandoff()
    }

    /// An authoritative replacement of the series' chapters invalidates what a handoff was started for.
    func catalogDidChange() {
        catalogGeneration &+= 1
        cancelHandoff()
    }

    /// The route is over. Admitted local marks and position writes still finish.
    func close() {
        if case .closed = phase { return }
        routeGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
        releaseStaged()
        session.close()
        phase = .closed
    }

#if DEBUG
    var stagedImageHoldCountForTesting: Int { imageHold == nil ? 0 : 1 }
    /// Returns once the running preparation has finished and published or dropped its result.
    func waitForPreparationForTesting() async { await operationTask?.value }
#endif
}

// MARK: - Initial image readiness

/// Proves the destination's first image can be drawn before the destination is shown. It holds a visible
/// lease on the destination's own image session, with the descriptor its renderer requests, until the
/// renderer holds one of its own: releasing the last visible ready lease would reset the image to idle.
@MainActor
final class ReaderPreparationImageHold {
    let requestID: UUID
    let visitID: UUID
    private let session: ReaderPageImageSession
    private let descriptor: ReaderPageImageDescriptor
    private var onSettled: ((Bool) -> Void)?
    private var lease: ReaderImageLease?
    private var observation: ReaderImageObservation?

    init(
        requestID: UUID,
        visitID: UUID,
        session: ReaderPageImageSession,
        descriptor: ReaderPageImageDescriptor,
        onSettled: @escaping (Bool) -> Void
    ) {
        self.requestID = requestID
        self.visitID = visitID
        self.session = session
        self.descriptor = descriptor
        self.onSettled = onSettled
    }

    /// Observation first and state second: the session does not replay what already happened.
    func begin() {
        let key = descriptor.key
        observation = session.observe(key) { [weak self] state in self?.deliver(state) }
        lease = session.acquire(descriptor, consumer: .visible)
        deliver(session.state(for: key))
    }

    private func deliver(_ state: ReaderPageImageState) {
        switch state.phase {
        case .ready: settle(true)
        case .failed: settle(false)
        case .idle, .loading: break
        }
    }

    /// Settles once and stops listening; the lease stays until `release()`.
    private func settle(_ succeeded: Bool) {
        guard let onSettled else { return }
        self.onSettled = nil
        observation?.cancel()
        observation = nil
        onSettled(succeeded)
    }

    func release() {
        onSettled = nil
        observation?.cancel()
        observation = nil
        if let lease { session.release(lease) }
        lease = nil
    }
}

// MARK: - Exact chapter identity

extension ChapterToken {
    /// Every identifier and the opaque revision compare as bytes; Swift's string equality alone would
    /// merge canonically equivalent strings.
    func isByteIdentical(to other: ChapterToken) -> Bool {
        func same(_ lhs: String?, _ rhs: String?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): true
            case (let lhs?, let rhs?): lhs.utf8.elementsEqual(rhs.utf8)
            default: false
            }
        }
        return self == other
            && same(key, other.key) && same(title, other.title) && same(scanlator, other.scanlator)
            && same(url, other.url) && same(language, other.language) && same(scanlatorID, other.scanlatorID)
            && same(logicalUnitID, other.logicalUnitID) && same(revision, other.revision)
    }
}
