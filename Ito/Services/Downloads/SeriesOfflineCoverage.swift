import Foundation

/// How much of a series' catalog the source said it returned. Under ABI 2 it is always `.unknown`; a
/// later ABI supplies the other cases.
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
    ///   - selection: The editions the user follows; only rows it admits must be saved.
    ///   - catalog: The rows of the saved catalog.
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

        let eligible = catalog.filter {
            $0.isStorable && !$0.isLocked && selection.admits(scanlator: $0.scanlator, groupID: $0.scanlatorID)
        }
        // A series with nothing to download has no "entire series" to speak of.
        guard !eligible.isEmpty else { return .saved(savedCount) }
        let allSaved = eligible.allSatisfy { row in
            if case .downloaded = states[row.key] { return true }
            return false
        }
        return allSaved ? .entireSeries : .saved(savedCount)
    }
}
