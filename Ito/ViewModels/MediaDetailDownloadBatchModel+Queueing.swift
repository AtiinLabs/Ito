import Foundation
import ito_runner

/// Admitting a planned batch to the store, and the metered-network decision that may hold it first. The queueing
/// state itself stays in the main declaration, because its setters are private there; these members are internal
/// only so this file can reach it.
extension MediaDetailDownloadBatchModel {
    func enqueueBatch(
        action: DownloadAction,
        selection: EditionSelection,
        chapters: [Chapter],
        alreadyStored: Int,
        scope: BatchScope,
        policy: RememberedEditionChoice
    ) -> Task<Void, Never>? {
        let requestedMore: Int? = if case .more(let count) = action.window { count.value } else { nil }
        return enqueueBatch(
            provenance: action.provenance, requestedMore: requestedMore, selection: selection, chapters: chapters,
            alreadyStored: alreadyStored, scope: scope, policy: policy
        )
    }

    /// Queues `chapters` with the given provenance. Exact uploads chosen from a listing are `single` and record no
    /// catalog digest, because they were not planned from the chapter list.
    func enqueueBatch(
        provenance: DownloadBatchProvenance,
        requestedMore: Int? = nil,
        selection: EditionSelection,
        chapters: [Chapter],
        alreadyStored: Int,
        scope: BatchScope,
        policy: RememberedEditionChoice,
        recordsCatalogDigest: Bool = true
    ) -> Task<Void, Never>? {
        guard !isEnqueuing, isCurrent(scope), let host,
              let entry = host.batchEntry,
              let storedSelection = try? selection.storageData() else {
            if isCurrent(scope) { host?.presentBatchMessage(.downloadRefused) }
            return nil
        }
        let request = DownloadBatchRequest(
            pluginId: scope.identity.pluginId,
            mediaKind: scope.identity.mediaKind,
            canonicalMediaId: scope.identity.canonicalMediaId,
            entry: entry,
            seriesTitle: host.batchSeriesTitle,
            provenance: provenance,
            selection: storedSelection,
            catalogDigest: recordsCatalogDigest && !scope.catalogDigest.isEmpty ? scope.catalogDigest : nil,
            chapters: chapters,
            reviewedSourceEpoch: scope.sourceEpoch,
            reviewedPolicy: reviewedPolicy(of: policy)
        )
        return queueOrHold(request, alreadyStored: alreadyStored, requestedMore: requestedMore, scope: scope)
    }

    /// Queues one chapter the user tapped, as the one-chapter `single` batch the store makes for it. Under
    /// "Ask on Metered Networks" on an expensive path it waits for the same foreground confirmation a batch gets.
    func queueSingleChapter(_ chapter: Chapter) -> Task<Void, Never> {
        if isEnqueuing, isCurrentSeriesSaved {
            host?.presentBatchMessage(.downloadBatchBusy)
            return Task {}
        }
        guard let scope = currentBatchScope(), let host, let entry = host.batchEntry else {
            host?.presentBatchMessage(.downloadRefused)
            return Task {}
        }
        let request = DownloadBatchRequest(
            pluginId: scope.identity.pluginId,
            mediaKind: scope.identity.mediaKind,
            canonicalMediaId: scope.identity.canonicalMediaId,
            entry: entry,
            seriesTitle: host.batchSeriesTitle,
            provenance: .single,
            selection: DownloadBatchRecord.sourceListSelection,
            catalogDigest: nil,
            chapters: [chapter]
        )
        return queueOrHold(request, alreadyStored: 0, requestedMore: nil, scope: scope) ?? Task {}
    }

    /// Queues the request, or holds it for the user's decision when it would use an expensive path under a mode
    /// that asks. The decision is applied to this exact request.
    private func queueOrHold(
        _ request: DownloadBatchRequest,
        alreadyStored: Int,
        requestedMore: Int?,
        scope: BatchScope
    ) -> Task<Void, Never>? {
        guard downloads.meteredUseNeedsConfirmation() else {
            return submitBatch(
                request, confirmedMeteredUse: false, alreadyStored: alreadyStored,
                requestedMore: requestedMore, scope: scope
            )
        }
        pendingMeteredBatch = PendingMeteredBatch(
            id: UUID(), request: request, alreadyStored: alreadyStored, requestedMore: requestedMore, scope: scope
        )
        presentHeldMeteredPrompt()
        return nil
    }

    /// Shows the held batch's prompt unless a sheet is still dismissing or the dialog was already shown for it.
    /// `downloadSheetDidDismiss()` shows it then.
    private func presentHeldMeteredPrompt() {
        guard var pending = pendingMeteredBatch, !pending.wasPresented, !sheetDismissalPending else { return }
        pending.wasPresented = true
        pendingMeteredBatch = pending
        meteredPrompt = MeteredDownloadPrompt(id: pending.id, chapterCount: pending.request.chapters.count)
    }

    /// Called when the screen shows a download sheet. Only a sheet that was shown reports its dismissal.
    func downloadSheetDidAppear() {
        guard sheet != nil else { return }
        sheetIsOnScreen = true
    }

    /// Called when a download sheet has finished dismissing. A prompt held behind that sheet is shown now. A sheet
    /// that was replaced rather than cleared is still on screen.
    func downloadSheetDidDismiss() {
        if sheet == nil { sheetIsOnScreen = false }
        sheetDismissalPending = false
        presentHeldMeteredPrompt()
    }

    /// Whether the screen shows this series as a saved one, so a message about its downloads is about it.
    private var isCurrentSeriesSaved: Bool { host?.batchIsSaved == true }

    private func submitBatch(
        _ request: DownloadBatchRequest,
        confirmedMeteredUse: Bool,
        alreadyStored: Int,
        requestedMore: Int?,
        scope: BatchScope
    ) -> Task<Void, Never>? {
        guard !isEnqueuing, isCurrent(scope) else { return nil }
        let downloads = downloads
        let operation = UUID()
        let savedGeneration = savedScopeGeneration
        let identity = scope.identity
        isEnqueuing = true
        enqueueOperationID = operation
        let task = Task { [weak self] in
            let outcome = await downloads.enqueueBatch(request, confirmedMeteredUse: confirmedMeteredUse)
            self?.finishBatch(
                outcome,
                alreadyStored: alreadyStored,
                requestedMore: requestedMore,
                operation: operation,
                identity: identity,
                savedGeneration: savedGeneration
            )
        }
        enqueueTask = task
        return task
    }

    /// Applies the user's decision to the batch held for it. `useMeteredData` queues it with consent to use an
    /// expensive path for this batch alone; otherwise it is queued without one and waits for an unmetered path.
    /// The batch is found by the prompt the dialog presented, so a dialog that already hid itself while dismissing
    /// still resolves it. A decision for a batch no longer held does nothing: its series is no longer shown. A
    /// batch that cannot be submitted now is reported, not dropped silently.
    @discardableResult
    func resolveMeteredPrompt(_ promptID: UUID, useMeteredData: Bool) -> Task<Void, Never> {
        guard let pending = pendingMeteredBatch, pending.id == promptID else { return Task {} }
        pendingMeteredBatch = nil
        meteredPrompt = nil
        if let task = submitBatch(
            pending.request,
            confirmedMeteredUse: useMeteredData,
            alreadyStored: pending.alreadyStored,
            requestedMore: pending.requestedMore,
            scope: pending.scope
        ) {
            return task
        }
        if host?.batchIdentity == pending.scope.identity, isCurrentSeriesSaved {
            host?.presentBatchMessage(isEnqueuing ? .downloadBatchBusy : .editionChoiceChanged)
        }
        return Task {}
    }

    /// Hides the dialog without deciding. The held batch stays, because the dialog hides itself while a button's
    /// action is still to run; only `cancelMeteredPrompt()` drops it.
    func hideMeteredPrompt() {
        meteredPrompt = nil
    }

    /// The user's Cancel, or the series going away: drops the held batch without queueing anything.
    func cancelMeteredPrompt() {
        pendingMeteredBatch = nil
        meteredPrompt = nil
    }

    /// Ends the queueing state of the submission that set it; a reset, a removal, or a later submission owns its own.
    /// The outcome is reported only while the saved series it was admitted for is still the one shown. A catalogue
    /// change does not suppress it, because it changes neither the series nor its saved state.
    private func finishBatch(
        _ outcome: DownloadBatchOutcome,
        alreadyStored: Int,
        requestedMore: Int?,
        operation: UUID,
        identity: MediaIdentity,
        savedGeneration: Int
    ) {
        guard enqueueOperationID == operation else { return }
        releaseEnqueueOwnership()
        guard savedScopeGeneration == savedGeneration,
              host?.batchIsSaved == true,
              host?.batchIdentity == identity else { return }
        if let refusal = outcome.refusal {
            switch refusal {
            case .unavailable:
                host?.presentBatchMessage(.downloadActionFailed)
            case .sourceChanged:
                host?.presentBatchMessage(.editionChoiceChanged)
            case .policyChanged:
                // Another screen changed the series' policy: read it again so the next tap plans with it.
                loadPreference(force: true)
                host?.presentBatchMessage(.editionChoiceChanged)
            default:
                host?.presentBatchMessage(.downloadRefused)
            }
        } else if outcome.queued > 0 {
            if let requestedMore {
                host?.presentBatchMessage(.downloadsQueuedMore(
                    requested: requestedMore,
                    queued: outcome.queued,
                    storedMeanwhile: outcome.alreadySaved + outcome.alreadyQueued
                ))
            } else {
                host?.presentBatchMessage(.downloadsQueued(
                    queued: outcome.queued,
                    alreadyStored: alreadyStored + outcome.alreadySaved + outcome.alreadyQueued
                ))
            }
        } else {
            host?.presentBatchMessage(.nothingToDownload)
        }
    }

    /// Gives up the screen's queueing state. The submitted batch is not cancelled: it finishes and commits under the
    /// series it was admitted for, but no longer reports to this screen.
    func releaseEnqueueOwnership() {
        enqueueTask = nil
        enqueueOperationID = nil
        isEnqueuing = false
    }
}
