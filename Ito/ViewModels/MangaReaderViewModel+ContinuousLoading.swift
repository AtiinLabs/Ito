import Foundation
import ito_runner

/// Loading chapters above and below the continuous reader's window, kept out of the main file. A neighbor
/// that turns out to be made for the other reader is never appended: it stays a handoff boundary, with the
/// payload that was already loaded kept for the crossing.
extension MangaReaderViewModel {
    // MARK: - Continuous chapter loading

    /// Retries the next-chapter append after `appendFailed`.
    func retryAppendNextChapter() {
        guard appendFailed else { return }
        appendFailed = false
        appendNextChapter()
    }

    func appendNextChapter(trigger: ChapterAppendTrigger = .reader) {
        guard trigger == .reader || dependencies.settings.mangaReaderAdjacentPrefetchCount > 0 else { return }
        guard isActive,
              presentationMode.isLive,
              !loadingNextChapter,
              !appendFailed,
              appendOperationID == nil,
              !isPaged,
              let last = segments.last,
              let chapter = boundaryAfter(last.chapter).chapter else { return }

        loadingNextChapter = true
        let boundary = ChapterToken(last.chapter)
        let operationID = UUID()
        let session = sessionID
        let generation = contentGeneration
        let preparer = chapterPreparer
        let entry = entry
        appendOperationID = operationID
        appendPrefetchEpoch = trigger == .speculative ? dependencies.settings.mangaReaderPrefetchEpoch : nil
        appendBoundary = boundary
        appendSession = session
        appendGeneration = generation
        logStarted(kind: .chapterAppend, operationID: operationID)
        let operation = PluginNetworkOperation(
            purpose: trigger == .speculative ? .prefetch : .foregroundReading, operationID: operationID
        )

        appendTask = Task { @MainActor [weak self, preparer, entry] in
            guard self?.isCurrentAppend(
                boundary: boundary, operationID: operationID, session: session, generation: generation
            ) == true else {
                if self?.retireStaleSpeculativeAppend(
                    operationID: operationID, boundary: boundary, session: session, generation: generation
                ) != true {
                    self?.finishAppend(operationID: operationID, outcome: .ignoredStale)
                }
                return
            }
            do {
                let prepared = try await preparer.prepareChapter(entry: entry, chapter: chapter, operation: operation)
                self?.completeAppend(
                    prepared,
                    boundary: boundary,
                    operationID: operationID,
                    session: session,
                    generation: generation
                )
            } catch {
                self?.finishAppendFailure(
                    operationID: operationID,
                    boundary: boundary,
                    session: session,
                    generation: generation
                )
            }
        }
    }

    private func completeAppend(
        _ prepared: ReaderPreparedChapter,
        boundary: ChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) {
        guard isCurrentAppend(
            boundary: boundary,
            operationID: operationID,
            session: session,
            generation: generation
        ) else {
            logFinished(kind: .chapterAppend, operationID: operationID, outcome: .ignoredStale)
            if !retireStaleSpeculativeAppend(
                operationID: operationID, boundary: boundary, session: session, generation: generation
            ) {
                finishAppend(operationID: operationID, outcome: .ignoredStale)
            }
            return
        }
        beginContinuousMutation()
        defer { endContinuousMutation() }
        guard prepared.format == .pages else {
            // Made for the other reader: stop here and keep the payload for the crossing.
            holdForHandoff(prepared)
            finishAppend(operationID: operationID, outcome: .succeeded)
            return
        }
        let sorted = prepared.pages
        // An empty chapter is a failure: appending it would make the next one due at once.
        guard !sorted.isEmpty else {
            finishAppend(operationID: operationID, outcome: .failed(.pluginExecution))
            return
        }
        retain(prepared)
        segments.append(ChapterSegment(chapter: prepared.chapter, pages: sorted))
        finishAppend(operationID: operationID, outcome: .succeeded)
        trimLoadedSegments(awayFrom: .bottom)
    }

    func finishAppend(operationID: UUID, outcome: PresentationEventOutcome) {
        guard appendOperationID == operationID else { return }
        if case .failed = outcome { appendFailed = true }
        appendTask = nil
        appendOperationID = nil
        appendPrefetchEpoch = nil
        appendBoundary = nil
        appendSession = nil
        appendGeneration = nil
        loadingNextChapter = false
        logFinished(kind: .chapterAppend, operationID: operationID, outcome: outcome)
    }

    func prependPreviousChapter() {
        guard isActive,
              presentationMode.isLive,
              !loadingPrevChapter,
              prependOperationID == nil,
              !isPaged,
              let first = segments.first,
              let chapter = boundaryBefore(first.chapter).chapter else { return }

        loadingPrevChapter = true
        prependFailed = false
        let boundary = ChapterToken(first.chapter)
        let operationID = UUID()
        let session = sessionID
        let generation = contentGeneration
        let preparer = chapterPreparer
        let entry = entry
        prependOperationID = operationID
        logStarted(kind: .chapterPrepend, operationID: operationID)
        let operation = PluginNetworkOperation(purpose: .foregroundReading, operationID: operationID)

        prependTask = Task { @MainActor [weak self, preparer, entry] in
            do {
                let prepared = try await preparer.prepareChapter(entry: entry, chapter: chapter, operation: operation)
                self?.completePrepend(
                    prepared,
                    boundary: boundary,
                    operationID: operationID,
                    session: session,
                    generation: generation
                )
            } catch {
                self?.finishPrependFailure(
                    operationID: operationID,
                    session: session,
                    generation: generation
                )
            }
        }
    }

    private func completePrepend(
        _ prepared: ReaderPreparedChapter,
        boundary: ChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) {
        guard isCurrentPrepend(
            boundary: boundary,
            operationID: operationID,
            session: session,
            generation: generation
        ) else {
            logFinished(kind: .chapterPrepend, operationID: operationID, outcome: .ignoredStale)
            return
        }

        beginContinuousMutation()
        defer { endContinuousMutation() }
        guard prepared.format == .pages else {
            holdForHandoff(prepared)
            finishPrepend(operationID: operationID, outcome: .succeeded)
            return
        }
        let sorted = prepared.pages
        guard !sorted.isEmpty else {
            prependFailed = true
            finishPrepend(operationID: operationID, outcome: .failed(.pluginExecution))
            return
        }
        retain(prepared)
        segments.insert(ChapterSegment(chapter: prepared.chapter, pages: sorted), at: 0)
        finishPrepend(operationID: operationID, outcome: .succeeded)
        trimLoadedSegments(awayFrom: .top)
    }

    /// Drops loaded chapters beyond `maximumLoadedSegments` from the end away from the one
    /// that just grew, keeping one chapter past the current one. Skips an end that is still
    /// loading, whose result is matched against that end.
    private func trimLoadedSegments(awayFrom grownEnd: ContinuousLoadedEnd) {
        guard segments.count > Self.maximumLoadedSegments,
              flatPages.indices.contains(continuousPageIndex) else { return }
        let current = flatPages[continuousPageIndex]
        // Unknown or moving live geometry waits: dropping chapters above the reader then needs
        // a large position correction in the middle of a gesture or a fling.
        guard let protectedIDs = continuousViewportRetention.protectionIDs(
            fallback: visiblePageIDs, validPages: flatPageIndexByID) else { pendingTrim = grownEnd; return }
        pendingTrim = nil
        let excess = segments.count - Self.maximumLoadedSegments
        let visibleSegments = protectedIDs.compactMap { flatPageIndexByID[$0] }.map { flatPages[$0].segmentIndex }
        switch grownEnd {
        case .bottom:
            let removable = min(current.segmentIndex - 1, visibleSegments.min() ?? Int.max)
            guard prependOperationID == nil, removable > 0 else { return }
            segments.removeFirst(min(excess, removable))
        case .top:
            let removable = min(segments.count - 2 - current.segmentIndex, segments.count - 1 - (visibleSegments.max() ?? 0))
            guard appendOperationID == nil, removable > 0 else { return }
            segments.removeLast(min(excess, removable))
        }
    }

    /// The renderer's viewport stopped moving: a trim it held back can drop chapters now.
    func continuousViewportSettled() {
        guard isActive, !isPaged, let end = pendingTrim else { return }
        beginContinuousMutation()
        defer { endContinuousMutation() }
        trimLoadedSegments(awayFrom: end)
    }

    private func finishPrependFailure(
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) {
        guard isActive,
              sessionID == session,
              contentGeneration == generation,
              prependOperationID == operationID else {
            logFinished(kind: .chapterPrepend, operationID: operationID, outcome: .ignoredStale)
            return
        }
        prependFailed = true
        finishPrepend(operationID: operationID, outcome: .failed(.pluginExecution))
    }

    private func finishPrepend(operationID: UUID, outcome: PresentationEventOutcome) {
        guard prependOperationID == operationID else { return }
        prependTask = nil
        prependOperationID = nil
        loadingPrevChapter = false
        logFinished(kind: .chapterPrepend, operationID: operationID, outcome: outcome)
    }

    private func isCurrentPrepend(
        boundary: ChapterToken,
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) -> Bool {
        isActive
            && !isPaged
            && sessionID == session
            && contentGeneration == generation
            && prependOperationID == operationID
            && segments.first.map(ChapterToken.init) == boundary
            && !Task.isCancelled
    }
}
