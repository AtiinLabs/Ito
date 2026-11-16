import Foundation
import ito_runner

/// What an alternative lookup is anchored on: the chapter the user asked about, and where its metadata
/// (the logical unit it belongs to) comes from.
nonisolated enum OfflineChapterAlternativeAnchor: Sendable {
    /// A row of the current catalog. The source supplied `logicalUnitID` in this payload, so its metadata
    /// origin is the supplied edition's own series.
    case catalog(edition: OfflineChapterEdition, logicalUnitID: String)
    /// A stored copy. Its own inventory row supplies the logical unit and the metadata origin, which the
    /// merged chapter the screen shows has lost.
    case saved(edition: OfflineChapterEdition)

    var edition: OfflineChapterEdition {
        switch self {
        case .catalog(let edition, _), .saved(let edition):
            edition
        }
    }
}

/// One verified stored upload of the same logical unit as the anchor, frozen when it was listed. Every
/// field is what the inventory held at that moment; confirming compares them all again before any lease
/// is accepted. `id` finds the row in a list and is not authority.
nonisolated struct DownloadedChapterAlternative: Identifiable, Sendable {
    /// The copy's current lookup identity.
    let edition: OfflineChapterEdition
    /// The series the copy's chapter metadata was written under.
    let metadataOrigin: MediaIdentity
    let versionID: String
    let manifestSHA256: String
    /// The digest of the inventory's chapter snapshot bytes, so a changed snapshot is noticed.
    let chapterSnapshotSHA256: String
    /// The form the copy is actually saved in.
    let contentKind: OfflineContentKind
    /// The saved chapter descriptor, without request material.
    let chapter: Chapter

    var id: String { versionID }
}

nonisolated struct DownloadedChapterAlternatives: Sendable {
    let anchor: OfflineChapterAlternativeAnchor
    let metadataOrigin: MediaIdentity
    /// The logical unit the anchor names; nil when it has none.
    let logicalUnitID: String?
    /// The source epoch the inventory was read under; nil is an observed absent epoch.
    let sourceEpoch: String?
    let candidates: [DownloadedChapterAlternative]
}

nonisolated enum DownloadedAlternativeError: Error, Equatable, Sendable {
    /// No offline store is composed.
    case unavailable
    /// The inventory or the source epoch could not be read. This is not an empty result.
    case inventoryUnavailable
    /// The anchor or the chosen copy is no longer what was listed.
    case selectionChanged
    /// The source's configuration changed since the list was read.
    case sourceChanged
    /// The series has no chapter reader (anime).
    case unsupportedMediaKind
}

/// Which stored copies are other uploads of the anchor's logical unit.
nonisolated enum OfflineChapterAlternatives {
    /// - Parameter inventory: the rows of the anchor's current series. No other fact is consulted: not a
    ///   plugin, a file, a lease or the network.
    static func project(
        anchor: OfflineChapterAlternativeAnchor,
        inventory: [DownloadedChapterRecord],
        sourceEpoch: String?
    ) throws -> DownloadedChapterAlternatives {
        let edition = anchor.edition
        let origin: MediaIdentity
        let logicalUnitID: String?
        switch anchor {
        case .catalog(_, let supplied):
            origin = MediaIdentity(
                pluginId: edition.pluginId,
                canonicalMediaId: edition.canonicalMediaId,
                mediaKind: edition.mediaKind
            )
            logicalUnitID = supplied
        case .saved:
            guard let row = inventory.first(where: { $0.state == .verified && $0.edition.isByteIdentical(to: edition) }),
                  let chapter = savedChapter(of: row),
                  let rowOrigin = metadataOrigin(of: row) else {
                throw DownloadedAlternativeError.selectionChanged
            }
            origin = rowOrigin
            logicalUnitID = chapter.logicalUnitID
        }
        func result(_ candidates: [DownloadedChapterAlternative]) -> DownloadedChapterAlternatives {
            DownloadedChapterAlternatives(
                anchor: anchor,
                metadataOrigin: origin,
                logicalUnitID: logicalUnitID,
                sourceEpoch: sourceEpoch,
                candidates: candidates
            )
        }
        // A missing or empty logical unit identifies nothing: numbers, titles and groups never stand in.
        guard let logicalUnitID, !logicalUnitID.isEmpty else { return result([]) }

        var candidates: [DownloadedChapterAlternative] = []
        for row in inventory where row.state == .verified {
            let rowEdition = row.edition
            guard rowEdition.isInSameSeries(as: edition),
                  !row.chapterKey.utf8.elementsEqual(edition.chapterKey.utf8),
                  let chapter = savedChapter(of: row),
                  let rowOrigin = metadataOrigin(of: row),
                  rowOrigin.isByteIdentical(to: origin),
                  let rowLogicalUnitID = chapter.logicalUnitID,
                  rowLogicalUnitID.utf8.elementsEqual(logicalUnitID.utf8) else { continue }
            candidates.append(
                DownloadedChapterAlternative(
                    edition: rowEdition,
                    metadataOrigin: rowOrigin,
                    versionID: row.versionId,
                    manifestSHA256: row.manifestSHA256,
                    chapterSnapshotSHA256: OfflineDigest.sha256Hex(row.chapterSnapshot),
                    contentKind: row.contentKind,
                    chapter: chapter
                )
            )
        }
        candidates.sort { lhs, rhs in
            let lhsKey = lhs.edition.chapterKey.utf8
            let rhsKey = rhs.edition.chapterKey.utf8
            if !lhsKey.elementsEqual(rhsKey) { return lhsKey.lexicographicallyPrecedes(rhsKey) }
            return lhs.versionID.utf8.lexicographicallyPrecedes(rhs.versionID.utf8)
        }
        return result(candidates)
    }

    /// The row's chapter descriptor, only when it decodes and names exactly the row's own chapter key.
    static func savedChapter(of row: DownloadedChapterRecord) -> Chapter? {
        guard let chapter = try? JSONDecoder().decode(Chapter.self, from: row.chapterSnapshot),
              chapter.key.utf8.elementsEqual(row.chapterKey.utf8) else { return nil }
        return chapter
    }

    /// The series the row's chapter metadata was written under. No origin means the row's own series; an
    /// origin that cannot be decoded establishes nothing, so it is not read as "no origin".
    static func metadataOrigin(of row: DownloadedChapterRecord) -> MediaIdentity? {
        guard let data = row.originIdentity else {
            return MediaIdentity(
                pluginId: row.pluginId,
                canonicalMediaId: row.canonicalMediaId,
                mediaKind: row.mediaKind
            )
        }
        guard let origin = try? JSONDecoder().decode(OfflineOriginIdentity.self, from: data) else { return nil }
        return MediaIdentity(pluginId: origin.pluginId, canonicalMediaId: origin.canonicalMediaId, mediaKind: row.mediaKind)
    }
}

/// Source keys that differ only by Unicode canonical equivalence are different keys. These checks compare
/// bytes where an identity decides what may be substituted.
nonisolated extension MediaIdentity {
    func isByteIdentical(to other: MediaIdentity) -> Bool {
        mediaKind == other.mediaKind
            && pluginId.utf8.elementsEqual(other.pluginId.utf8)
            && canonicalMediaId.utf8.elementsEqual(other.canonicalMediaId.utf8)
    }
}

nonisolated extension OfflineChapterEdition {
    func isInSameSeries(as other: OfflineChapterEdition) -> Bool {
        mediaKind == other.mediaKind
            && authorityScope == other.authorityScope
            && pluginId.utf8.elementsEqual(other.pluginId.utf8)
            && canonicalMediaId.utf8.elementsEqual(other.canonicalMediaId.utf8)
    }

    func isByteIdentical(to other: OfflineChapterEdition) -> Bool {
        isInSameSeries(as: other) && chapterKey.utf8.elementsEqual(other.chapterKey.utf8)
    }
}
