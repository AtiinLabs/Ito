import Foundation
import ito_runner

/// The explicit "Find All Uploads" action of the scanlator chooser.
///
/// Only `findAllUploads` asks the source, and only the user's tap on that button reaches it: detail loads and
/// refreshes, presets, readers, subscriptions and local alternatives never do. What comes back is an ephemeral
/// catalog of exact uploads for the open chooser. It is not the series' chapter list: it never reaches the
/// Library item, the saved snapshot, the chapter counts, History or any baseline, and it is dropped with the
/// chooser, a media change, a source epoch change or a failed listing.
extension MediaDetailDownloadBatchModel {
    /// Whether the open chooser may offer "Find All Uploads": a saved manga or novel with a source that can be asked.
    var canFindAllUploads: Bool {
        enumerateEditions != nil && showsControls && host?.batchEntry != nil
    }

    /// Asks the source for every exact upload of the series, once per tap. The call runs under the source epoch
    /// the chooser was reviewed under, so a settings or account change of the source ends it. A second tap while
    /// one listing is running is not acted on.
    @discardableResult
    func findAllUploads(chooserID: UUID) -> Task<Void, Never> {
        guard case .chooser(let presentation)? = sheet, presentation.id == chooserID,
              canFindAllUploads, !isApplyingChoice, !isEnqueuing, enumeration != .loading,
              let enumerateEditions, let entry = host?.batchEntry,
              let scope = currentBatchScope() else { return Task {} }
        guard presentation.identity == scope.identity,
              presentation.scopeGeneration == scope.generation,
              presentation.catalogDigest == scope.catalogDigest else { return Task {} }
        guard presentation.sourceEpoch == scope.sourceEpoch, presentation.policy == remembered else {
            closeStaleConsent()
            return Task {}
        }
        let token = UUID()
        cancelEnumeration()
        enumerationToken = token
        enumerationScope = scope
        enumeration = .loading
        // The user's tap started this multi-page traversal of the series' catalogue, so it is a manual
        // refresh of it, not a search.
        let operation = PluginNetworkOperation(purpose: .manualCatalogRefresh, operationID: UUID())
        let task = Task { [weak self] in
            let outcome: Result<EnumeratedChapterEditions?, any Error>
            do {
                outcome = .success(try await enumerateEditions(entry, operation, scope.sourceEpoch))
            } catch {
                outcome = .failure(error)
            }
            self?.finishEnumeration(outcome, token: token, scope: scope, chooserID: chooserID)
        }
        enumerationTask = task
        return task
    }

    /// Ends the open listing, running or finished, and forgets everything it found. Whatever the source still
    /// answers afterwards finds no matching token and is dropped, even from a runner that ignores cancellation.
    func cancelEnumeration() {
        enumerationTask?.cancel()
        enumerationTask = nil
        enumerationToken = nil
        enumerationScope = nil
        enumeratedChapters = []
        if enumeration != .idle { enumeration = .idle }
    }

    /// Queues the ticked uploads of the open listing as one batch of exact, frozen chapters. Each is exactly the
    /// chapter the source listed; no group policy applies, and a locked upload is never queued. The batch is
    /// reviewed under the source epoch and remembered policy of the chooser, so it is refused after either
    /// changes. Nothing is remembered: the series' choice changes only through the chooser's own Remember flow.
    @discardableResult
    func downloadEnumeratedUploads(keys: Set<String>, chooserID: UUID) -> Task<Void, Never> {
        guard case .chooser(let presentation)? = sheet, presentation.id == chooserID,
              case .loaded = enumeration, !isEnqueuing, !isApplyingChoice,
              let listed = enumerationScope, let live = currentBatchScope() else { return Task {} }
        guard presentation.identity == live.identity,
              presentation.scopeGeneration == live.generation,
              presentation.catalogDigest == live.catalogDigest,
              listed.generation == live.generation, listed.catalogDigest == live.catalogDigest else { return Task {} }
        guard listed.sourceEpoch == live.sourceEpoch,
              presentation.sourceEpoch == live.sourceEpoch,
              presentation.policy == remembered else {
            closeStaleConsent()
            return Task {}
        }
        let chapters = frozenEnumeratedChapters(keys: keys)
        // The listing ends with the sheet; the chapters were taken from it first.
        dismissDownloadSheet()
        guard !chapters.isEmpty else {
            host?.presentBatchMessage(.nothingToDownload)
            return Task {}
        }
        return enqueueBatch(
            preset: .single,
            selection: .sourceList,
            chapters: chapters,
            alreadyStored: 0,
            scope: live,
            policy: remembered,
            recordsCatalogDigest: false
        ) ?? Task {}
    }

    // MARK: - Finishing

    private func finishEnumeration(
        _ outcome: Result<EnumeratedChapterEditions?, any Error>,
        token: UUID,
        scope: BatchScope,
        chooserID: UUID
    ) {
        // A listing that was cancelled, replaced or closed finds another token and publishes nothing.
        guard enumerationToken == token else { return }
        enumerationTask = nil
        guard sheet?.chooserID == chooserID, isCurrent(scope) else {
            cancelEnumeration()
            return
        }
        // The listing was asked under the epoch the chooser was reviewed under. Another epoch is another
        // source authorization: nothing the old one found is shown.
        guard isCurrentEpoch(scope.sourceEpoch, for: scope.identity) else {
            closeStaleConsent()
            return
        }
        enumerationToken = nil
        switch outcome {
        case .failure(let error):
            // Nothing of a failed listing is kept.
            enumerationScope = nil
            enumeratedChapters = []
            enumeration = error is CancellationError ? .idle : .failed(message: Self.message(for: error))
        case .success(nil):
            enumerationScope = nil
            enumeratedChapters = []
            enumeration = .unsupported
        case .success(let found?):
            enumeratedChapters = found.editions
            enumeration = .loaded(makeEnumerationResult(found))
        }
    }

    private static func message(for error: any Error) -> String {
        if let error = error as? PluginCallError { return error.message }
        return String(localized: "The source couldn't complete this request.")
    }

    // MARK: - Presentation

    /// The listed uploads the series' current chapter list does not have, grouped by reading position: uploads
    /// the source gives one logical unit ID share a group, and an upload without one stands alone. The
    /// uploads the list already has stay where they are.
    private func makeEnumerationResult(_ found: EnumeratedChapterEditions) -> EditionEnumerationResult {
        let listedKeys = Set((host?.batchChapters ?? []).map(\.key))
        let additional = found.editions.filter { !listedKeys.contains($0.key) }
        let positions = EditionPositionResolver.positions(of: additional.map { ChapterFacts($0) })
        let groups = positions.compactMap { position -> EnumeratedEditionGroup? in
            guard let first = position.members.first else { return nil }
            let identifier: String
            switch position.key {
            case .logical(let unit): identifier = "logical:\(unit.value)"
            case .exact(let key): identifier = "exact:\(key.value)"
            }
            return EnumeratedEditionGroup(
                id: identifier,
                title: ReaderChapterTitle.text(title: additional[first].title, number: additional[first].chapterNumber),
                rows: position.members.map { enumeratedRow(additional[$0]) }
            )
        }
        return EditionEnumerationResult(
            totalCount: found.editions.count,
            additionalCount: additional.count,
            groups: groups,
            disclosure: EditionEnumerationDisclosure(
                scope: found.scope,
                completeness: found.completeness,
                termination: found.termination,
                listedCount: found.editions.count
            )
        )
    }

    private func enumeratedRow(_ chapter: Chapter) -> EnumeratedEditionRow {
        let current = currentStatus(of: chapter.key)
        return EnumeratedEditionRow(
            key: chapter.key,
            title: ReaderChapterTitle.text(title: chapter.title, number: chapter.chapterNumber),
            scanlator: chapter.scanlator,
            stored: current.stored,
            isFailed: current.isFailed,
            isLocked: chapter.isPaywalled
        )
    }

    private func currentStatus(of key: String) -> (stored: StoredEditionState, isFailed: Bool) {
        (StoredEditionState(states[key]), isFailed(key))
    }

    /// Reads every row's saved, queued and failed status again from the live download states, so a job that
    /// finishes or fails while the sheet is open is shown as it is. Called whenever the states change.
    func refreshEnumerationStatuses() {
        guard case .loaded(let result) = enumeration else { return }
        let updated = result.updatingStatus(currentStatus(of:))
        if updated != result { enumeration = .loaded(updated) }
    }

    /// The listed chapters for `keys`, exactly as the source returned them, in reading order. A locked upload and
    /// one that already has a copy or a job are left out; the store settles both again when it queues.
    private func frozenEnumeratedChapters(keys: Set<String>) -> [Chapter] {
        let chosen = enumeratedChapters.filter {
            keys.contains($0.key) && !$0.isPaywalled && StoredEditionState(states[$0.key]) == .none
        }
        let order = ChapterReadingOrder.order(chosen.map { ChapterFacts($0) }).order
        return order.map { chosen[$0] }
    }
}
