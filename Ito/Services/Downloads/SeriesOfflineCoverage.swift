import Foundation

/// How much of a series' catalog the saved details say the source returned. Only `.complete` backs the
/// "entire series" claim, and it is recorded only for a complete catalog of every eligible upload. Future
/// pruning must key on `.complete`, never on completeness alone: a complete list of what is visible is not
/// the whole series.
nonisolated enum SeriesCatalogScope: Equatable, Sendable {
    case unknown
    case visible
    case complete
    case partial
}

/// The persisted freshness of a series' saved details.
nonisolated struct SeriesOfflineSnapshot: Equatable, Sendable {
    let catalogScope: SeriesCatalogScope
    /// The digest of the payload the snapshot was taken from.
    let payloadSHA256: String
    let refreshedAt: Date
}

/// Whether a series is "entirely offline" or only has some chapters saved.
///
/// "Entire series" is a claim about the source's catalog, so it needs a catalog known to be complete,
/// still the one saved with the Library item, and recent. Otherwise the series only has a count of saved
/// chapters; a percentage would imply a catalog nobody has confirmed.
nonisolated enum SeriesOfflineCoverage {
    /// How old a snapshot may be and still back an "entire series" claim.
    static let freshnessWindow: TimeInterval = 7 * 24 * 60 * 60

    enum Result: Equatable, Sendable {
        case entireSeries
        /// The number of verified copies the series has, whether or not the catalog still lists them.
        case saved(Int)
    }

    /// - Parameters:
    ///   - snapshot: The saved freshness, or nil when the series has none.
    ///   - currentPayloadSHA256: The digest of the payload now saved with the Library item. A snapshot
    ///     taken from a different payload (a restore, a relink) proves nothing about this catalog.
    ///   - selection: The editions the user follows. A position the source declared that it cannot supply
    ///     blocks the claim; an undeclared row it excludes does not.
    ///   - catalog: The rows of the saved catalog, with the logical unit IDs the source gave them.
    ///   - states: The download state of each exact key the store knows.
    static func evaluate(
        snapshot: SeriesOfflineSnapshot?,
        currentPayloadSHA256: String?,
        selection: EditionSelection,
        catalog: [ChapterFacts],
        states: [String: ChapterDownloadState],
        now: Date
    ) -> Result {
        let savedCount = states.values.reduce(into: 0) { count, state in
            if case .downloaded = state { count += 1 }
        }
        guard let snapshot,
              snapshot.catalogScope == .complete,
              snapshot.payloadSHA256 == currentPayloadSHA256,
              snapshot.refreshedAt >= now.addingTimeInterval(-freshnessWindow)
        else {
            return .saved(savedCount)
        }

        let resolvedSelection: ResolvedEditionSelection?
        if case .scanlators = selection {
            resolvedSelection = ScanlatorCatalogIndex(
                catalog,
                id: \.scanlatorID,
                name: \.scanlator
            ).resolve(selection)
        } else {
            resolvedSelection = selection.resolve(in: [])
        }
        guard let resolvedSelection else { return .saved(savedCount) }
        // The same positions the download presets plan over: one per source logical unit, one per row
        // without one. Only a verified copy of a permitted row saves a position: a copy outside the
        // permitted groups, a queued job and a damaged copy do not. A position the source declared that no
        // permitted row supplies leaves the series incomplete; a row without a logical unit ID that the
        // selection excludes is simply not followed. Locked rows with no copy hold nothing back.
        var seenKeys = Set<String>()
        let eligible = catalog.filter { $0.isStorable && seenKeys.insert($0.key).inserted }
        let positions = EditionPositionResolver.resolve(
            facts: eligible,
            stored: eligible.map { StoredEditionState(states[$0.key]) },
            selection: resolvedSelection
        )
        let hasUnsuppliedUnit = positions.contains { position in
            guard case .logical = position.key, !position.isOccupied else { return false }
            return position.members.contains { !eligible[$0].isLocked }
        }
        let required = positions.filter(\.isOccupied)
        // A series with nothing to download has no "entire series" to speak of.
        guard !hasUnsuppliedUnit, !required.isEmpty else { return .saved(savedCount) }
        let allSaved = required.allSatisfy { position in
            position.toQueue.isEmpty && position.damaged.isEmpty
                && position.satisfied.allSatisfy { states[eligible[$0].key] == .downloaded }
        }
        return allSaved ? .entireSeries : .saved(savedCount)
    }
}
