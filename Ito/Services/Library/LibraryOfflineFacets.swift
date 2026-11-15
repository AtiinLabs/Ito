import Foundation
import ito_runner

/// The Library's offline filters. Each one is ANDed with the search and the list selection. None is persisted.
nonisolated enum LibraryOfflineFacet: String, CaseIterable, Sendable {
    case all
    case anyVerified
    case noneVerified
    case entireKnownSeries
}

/// Whether a series' saved catalog proves that every chapter is saved, and until when that proof holds.
nonisolated enum LibraryEntireSeriesProof: Equatable, Sendable {
    /// Valid while `now <= until`, the moment the saved refresh stops being recent enough.
    case proven(until: Date)
    case notProven
}

/// A saved payload decoded for the entire-series filter. `facts` is nil when the payload no longer has the digest
/// its proof names, so its rows are not read at all.
nonisolated struct LibraryPreparedCatalog: Equatable, Sendable {
    let payload: Data
    let payloadSHA256: String
    let facts: [ChapterFacts]?
}

/// A saved payload to decode off the main actor, with the digest its proof names.
nonisolated struct LibraryCatalogPreparation: Equatable, Sendable {
    let media: MediaIdentity
    let kind: MediaKind
    let payload: Data
    let expectedSHA256: String
}

/// Decodes saved payloads for the entire-series filter. The Library injects it so a test can hold a decode open.
typealias LibraryCatalogPreparer = @Sendable ([LibraryCatalogPreparation]) async -> [MediaIdentity: LibraryPreparedCatalog]

nonisolated enum LibraryOfflineFacetEvaluator {
    /// The entire-series proof of one series. It goes through the same coverage evaluator as the detail screen, so
    /// the two cannot disagree about what a saved series proves.
    static func entireSeriesProof(
        kind: MediaKind,
        proof: LibrarySnapshotStateRecord?,
        preference: Data?,
        catalog: LibraryPreparedCatalog?,
        states: [String: ChapterDownloadState],
        now: Date
    ) -> LibraryEntireSeriesProof {
        guard kind != .anime, let proof, proof.coversEntireSeries else { return .notProven }
        guard let catalog, catalog.payloadSHA256 == proof.payloadSHA256, let facts = catalog.facts else {
            return .notProven
        }
        let selection: EditionSelection
        if let preference {
            // Bytes this build cannot read are neither "no choice" nor the source list, so they prove nothing.
            guard let decoded = try? SeriesEditionPreferenceRecord.decodeSelection(preference) else {
                return .notProven
            }
            selection = decoded
        } else {
            selection = .sourceList
        }
        let result = SeriesOfflineCoverage.evaluate(
            snapshot: proof.offlineSnapshot,
            currentPayloadSHA256: catalog.payloadSHA256,
            selection: selection,
            catalog: facts,
            states: states,
            now: now
        )
        guard result == .entireSeries else { return .notProven }
        return .proven(until: proof.refreshedAt.addingTimeInterval(SeriesOfflineCoverage.freshnessWindow))
    }

    /// Hashes and decodes saved payloads, which only candidates need. A payload whose digest is not the one its
    /// proof names is not decoded. Stops early when the task is cancelled; the caller discards that result.
    static func prepare(_ requests: [LibraryCatalogPreparation]) -> [MediaIdentity: LibraryPreparedCatalog] {
        var prepared: [MediaIdentity: LibraryPreparedCatalog] = [:]
        for request in requests {
            guard !Task.isCancelled else { break }
            let digest = OfflineDigest.sha256Hex(request.payload)
            let facts: [ChapterFacts]? = digest == request.expectedSHA256
                ? LibraryManager.savedCatalog(payload: request.payload, kind: request.kind)
                : nil
            prepared[request.media] = LibraryPreparedCatalog(
                payload: request.payload,
                payloadSHA256: digest,
                facts: facts
            )
        }
        return prepared
    }

    /// The production preparer: decodes on a utility task, and abandons the decode when the caller is cancelled.
    static func prepareInBackground(_ requests: [LibraryCatalogPreparation]) async -> [MediaIdentity: LibraryPreparedCatalog] {
        let work = Task.detached(priority: .utility) {
            LibraryOfflineFacetEvaluator.prepare(requests)
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
