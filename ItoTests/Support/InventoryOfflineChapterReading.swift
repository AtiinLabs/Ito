import Foundation
import ito_runner
@testable import Ito

/// Serves a fixed inventory and never leases a copy. It stands in for the store on screens that only
/// list saved chapters.
final class InventoryOfflineChapterReading: OfflineChapterReading, @unchecked Sendable {
    let leases = OfflineLeaseDirectory()
    let isAvailable: Bool
    private let rows: [DownloadedChapterRecord]

    init(rows: [DownloadedChapterRecord], isAvailable: Bool = true) {
        self.rows = rows
        self.isAvailable = isAvailable
    }

    func verifiedEdition(_ edition: OfflineChapterEdition) async -> Bool {
        rows.contains { $0.edition == edition }
    }

    func openLease(_ edition: OfflineChapterEdition) async throws -> OfflineChapterLease {
        _ = edition
        throw OfflineReadError.notDownloaded
    }

    func readVerifiedPage(_ page: OfflineLeasedPage) throws -> Data {
        _ = page
        throw OfflineReadError.notDownloaded
    }

    func inventoryChapters(
        pluginId: String,
        mediaKind: MediaKind,
        canonicalMediaId: String
    ) async -> [DownloadedChapterRecord] {
        rows.filter {
            $0.pluginId == pluginId && $0.mediaKind == mediaKind && $0.canonicalMediaId == canonicalMediaId
        }
    }
}

extension DownloadedChapterRecord {
    /// A verified inventory row for `chapterKey` of the series `plugin.exact` / `manga`.
    static func verifiedFixture(chapterKey: String) throws -> DownloadedChapterRecord {
        DownloadedChapterRecord(
            pluginId: "plugin.exact",
            mediaKind: .manga,
            canonicalMediaId: "manga",
            chapterKey: chapterKey,
            authorityScope: .publicUnscoped,
            versionId: UUID().uuidString,
            state: .verified,
            damageReason: nil,
            contentKind: .images,
            pageCount: 1,
            byteCount: 1,
            manifestFormatVersion: 1,
            manifestSHA256: String(repeating: "a", count: 64),
            chapterSnapshot: try JSONEncoder().encode(Chapter(key: chapterKey, chapter: 3)),
            seriesTitle: "Manga",
            sourceEpoch: nil,
            verifiedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
