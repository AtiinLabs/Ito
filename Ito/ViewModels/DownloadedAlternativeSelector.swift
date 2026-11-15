import Combine
import Foundation

/// Owns one choice among the saved uploads of a chapter's reading position, from the lookup until the chosen
/// copy's reader is handed to the screen. It holds the state, the single task and the lease between acquisition
/// and publication; the series screen supplies what is current and publishes the reader.
///
/// A stale completion never publishes: every phase is tied to an operation token, the screen's generation, its
/// media identity and the source epoch, and every invalidation clears that ownership before it cancels a task.
/// A lease is only ever held by the prepared destination or by a task that is about to drop it.
@MainActor
final class DownloadedAlternativeSelector<M: MediaDisplayable>: ObservableObject {
    /// What the screen is showing right now. Read again at every guard.
    struct Screen {
        let media: M
        let identity: MediaIdentity
        /// Whether the screen may still show output.
        let isPresentable: Bool
    }

    /// The screen's side of the selector. Nothing in it is a service.
    struct Host {
        /// nil once the screen is gone.
        let screen: () -> Screen?
        /// Opens the prepared reader. Called once, synchronously, from the sheet's dismissal.
        let publish: (MediaDetailReaderDestination) -> Void
        /// Releases the download sheet's batch content, so the sheet can show this choice.
        let relinquishBatchPresentation: () -> Void
    }

    @Published private(set) var state: DownloadedAlternativeSelectorState = .idle
    var host: Host?

    private let downloads: any MediaDetailDownloadServing
    private let makeDestination: (M, DownloadedChapterAlternative, OfflineChapterLease) throws -> MediaDetailReaderDestination
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var generation: UInt64 = 0
    /// The accepted lease lives inside this destination until the sheet has closed and the reader opens.
    private var pending: (context: DownloadedAlternativeContext, destination: MediaDetailReaderDestination)?

    init(
        downloads: any MediaDetailDownloadServing,
        makeDestination: @escaping (M, DownloadedChapterAlternative, OfflineChapterLease) throws -> MediaDetailReaderDestination
    ) {
        self.downloads = downloads
        self.makeDestination = makeDestination
    }

    deinit {
        task?.cancel()
    }

    // MARK: - Lookup

    /// Lists the saved uploads of the anchor's logical unit in the download sheet. A presentation that is
    /// closing for a hand-off is not replaced.
    @discardableResult
    func show(anchor: OfflineChapterAlternativeAnchor) -> Task<Void, Never> {
        if case .handingOff = state { return Task {} }
        cancel()
        guard let host, let screen = host.screen(), screen.isPresentable else { return Task {} }
        host.relinquishBatchPresentation()
        let epoch: String?
        do {
            epoch = try downloads.downloadedAlternativeEpoch(for: anchor.edition.pluginId)
        } catch {
            let context = makeContext(anchor: anchor, identity: screen.identity, epoch: nil)
            state = .failed(context, Self.failure(from: error, fallback: .selection(.inventoryUnavailable)))
            return Task {}
        }
        let context = makeContext(anchor: anchor, identity: screen.identity, epoch: epoch)
        let operation = UUID()
        operationID = operation
        state = .loading(context)
        let created = Task { [weak self, downloads] in
            let outcome: Result<DownloadedChapterAlternatives, Error>
            do {
                outcome = .success(try await downloads.downloadedAlternatives(for: anchor))
            } catch {
                outcome = .failure(error)
            }
            self?.finishLookup(outcome, context: context, operation: operation)
        }
        task = created
        return created
    }

    private func makeContext(
        anchor: OfflineChapterAlternativeAnchor,
        identity: MediaIdentity,
        epoch: String?
    ) -> DownloadedAlternativeContext {
        DownloadedAlternativeContext(
            id: UUID(),
            anchor: anchor,
            mediaIdentity: identity,
            detailGeneration: generation,
            sourceEpoch: epoch
        )
    }

    private func finishLookup(
        _ outcome: Result<DownloadedChapterAlternatives, Error>,
        context: DownloadedAlternativeContext,
        operation: UUID
    ) {
        guard operationID == operation else { return }
        guard case .loading(let current) = state, current.id == context.id, !Task.isCancelled,
              isCurrent(context) else {
            cancel()
            return
        }
        task = nil
        operationID = nil
        switch outcome {
        case .success(let result):
            if result.sourceEpoch != context.sourceEpoch {
                state = .failed(context, .selection(.sourceChanged))
            } else if let mismatch = epochError(context) {
                state = .failed(context, .selection(mismatch))
            } else {
                state = .choosing(
                    context: context,
                    candidates: result.candidates,
                    selectedCandidateID: nil,
                    failure: nil
                )
            }
        case .failure(let error):
            if error is CancellationError {
                state = .idle
            } else {
                state = .failed(context, Self.failure(from: error, fallback: .selection(.inventoryUnavailable)))
            }
        }
    }

    // MARK: - Choice

    /// Marks one listed copy. A presentation or copy that is not the one on screen does nothing.
    func select(_ candidateID: String, presentationID: UUID) {
        guard case .choosing(let context, let candidates, _, _) = state, context.id == presentationID,
              candidates.contains(where: { $0.id == candidateID }) else { return }
        state = .choosing(context: context, candidates: candidates, selectedCandidateID: candidateID, failure: nil)
    }

    /// Leases the selected copy and prepares its reader. Asking again while it is acquired or handed off
    /// does nothing, so one confirmation is one lease request.
    @discardableResult
    func confirm(presentationID: UUID) -> Task<Void, Never> {
        guard case .choosing(let context, let candidates, let selectedID?, _) = state,
              context.id == presentationID,
              let candidate = candidates.first(where: { $0.id == selectedID }) else { return Task {} }
        guard isCurrent(context) else {
            cancel()
            return Task {}
        }
        if let mismatch = epochError(context) {
            state = .failed(context, .selection(mismatch))
            return Task {}
        }
        let operation = UUID()
        operationID = operation
        state = .acquiring(context: context, candidates: candidates, selectedCandidateID: selectedID)
        let created = Task { [weak self, downloads] in
            let outcome: Result<OfflineChapterLease, Error>
            do {
                outcome = .success(try await downloads.openDownloadedAlternative(candidate, sourceEpoch: context.sourceEpoch))
            } catch {
                outcome = .failure(error)
            }
            self?.finishAcquisition(outcome, context: context, candidate: candidate, operation: operation)
        }
        task = created
        return created
    }

    private func finishAcquisition(
        _ outcome: Result<OfflineChapterLease, Error>,
        context: DownloadedAlternativeContext,
        candidate: DownloadedChapterAlternative,
        operation: UUID
    ) {
        // A completion that no longer owns the selector returns here, and its lease dies with `outcome`.
        guard operationID == operation else { return }
        guard case .acquiring(let current, let candidates, let selectedID) = state, current.id == context.id,
              !Task.isCancelled, isCurrent(context) else {
            cancel()
            return
        }
        task = nil
        operationID = nil
        do {
            let lease = try outcome.get()
            if let mismatch = epochError(context) { throw mismatch }
            guard let media = host?.screen()?.media else { throw DownloadedAlternativeError.selectionChanged }
            let destination = try makeDestination(media, candidate, lease)
            pending = (context, destination)
            state = .handingOff(context)
        } catch is CancellationError {
            state = .idle
        } catch {
            let failure = Self.failure(from: error, fallback: .read(.localCopyUnavailable))
            switch failure {
            case .selection:
                state = .failed(context, failure)
            case .read(let read):
                // A locked device may be retried; another copy may be chosen after any read failure.
                let keepsSelection = read == .protectedDataUnavailable
                state = .choosing(
                    context: context,
                    candidates: candidates,
                    selectedCandidateID: keepsSelection ? selectedID : nil,
                    failure: failure
                )
            }
        }
    }

    // MARK: - Hand-off

    /// The sheet that showed `presentationID` has closed. Only the matching hand-off with its prepared reader
    /// opens it, and only while the screen is still the one it was prepared for. Nothing is awaited between the
    /// last check and the publication.
    func sheetDidDismiss(presentationID: UUID) {
        guard case .handingOff(let context) = state, context.id == presentationID,
              let pending, pending.context.id == context.id else { return }
        guard let host, let screen = host.screen(), screen.isPresentable, isCurrent(context),
              epochError(context) == nil else {
            cancel()
            return
        }
        let destination = pending.destination
        self.pending = nil
        state = .idle
        host.publish(destination)
    }

    // MARK: - Ownership

    /// Ends whatever the selector owns: the state, the token, a prepared reader and its lease first, then the
    /// task. A task that ignores cancellation can finish, but it no longer owns anything to publish.
    func cancel() {
        generation &+= 1
        let running = task
        operationID = nil
        pending = nil
        task = nil
        if !isIdle { state = .idle }
        running?.cancel()
    }

    /// Ends the presentation `presentationID` names. A different or later presentation is left alone.
    func cancel(presentationID: UUID) {
        guard state.context?.id == presentationID else { return }
        cancel()
    }

    private func isCurrent(_ context: DownloadedAlternativeContext) -> Bool {
        guard context.detailGeneration == generation, let screen = host?.screen() else { return false }
        return screen.identity.isByteIdentical(to: context.mediaIdentity)
    }

    /// Why the source's epoch no longer allows this choice, or nil while it is the one the list was read
    /// under. A read that fails is never "the same".
    private func epochError(_ context: DownloadedAlternativeContext) -> DownloadedAlternativeError? {
        do {
            let current = try downloads.downloadedAlternativeEpoch(for: context.anchor.edition.pluginId)
            return current == context.sourceEpoch ? nil : .sourceChanged
        } catch {
            return .inventoryUnavailable
        }
    }

    private var isIdle: Bool {
        if case .idle = state { true } else { false }
    }

    private static func failure(from error: Error, fallback: DownloadedAlternativeFailure) -> DownloadedAlternativeFailure {
        switch error {
        case let selection as DownloadedAlternativeError: .selection(selection)
        case let read as OfflineReadError: .read(read)
        default: fallback
        }
    }
}
