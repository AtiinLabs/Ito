import Foundation
import ito_runner

/// Why a chapter could not be read from this device's offline copies. Localized for the reader's
/// load-failure text.
nonisolated enum OfflineReadError: Error, Equatable, LocalizedError, Sendable {
    /// No verified copy exists and no installed source can supply the chapter.
    case notDownloaded
    /// The copy exists but the device's data is locked, so its bytes cannot be read yet.
    case protectedDataUnavailable

    var errorDescription: String? {
        switch self {
        case .notDownloaded:
            String(
                localized: "This chapter isn't downloaded.",
                comment: "Shown when a chapter has no offline copy and no installed source can load it. Used as the reader's load-failure text and as a notice on the series details screen."
            )
        case .protectedDataUnavailable:
            String(
                localized: "Unlock your device to read this chapter.",
                comment: "Reader failure: the offline copy is stored under data protection and the device is locked."
            )
        }
    }
}

/// Read-side access to verified offline copies. The store conforms; previews and tests that have no
/// store use `UnavailableOfflineChapterReading`. Nonisolated: the offline image loader calls it from
/// its own queue.
nonisolated protocol OfflineChapterReading: Sendable {
    /// The lease table that `ito-offline://` locators resolve through.
    var leases: OfflineLeaseDirectory { get }

    /// Whether verified offline copies can exist on this build. False hides saved-only routes.
    var isAvailable: Bool { get }

    /// Whether a verified copy exists for exactly this edition. Never matches by number or scanlator.
    func verifiedEdition(_ edition: OfflineChapterEdition) async -> Bool

    /// Pins a verified copy for reading. Throws when the copy is missing, damaged, or locked.
    func openLease(_ edition: OfflineChapterEdition) async throws -> OfflineChapterLease

    /// The bytes of one leased page, verified against the manifest before they are returned.
    func readVerifiedPage(_ page: OfflineLeasedPage) throws -> Data

    /// The verified copies of one media item, for saved-only details.
    func inventoryChapters(
        pluginId: String,
        mediaKind: MediaKind,
        canonicalMediaId: String
    ) async -> [DownloadedChapterRecord]
}

extension OfflineChapterStore: OfflineChapterReading {
    nonisolated var isAvailable: Bool { true }

    func verifiedEdition(_ edition: OfflineChapterEdition) async -> Bool {
        (try? await verifiedEdition(for: edition)) != nil
    }

    func openLease(_ edition: OfflineChapterEdition) async throws -> OfflineChapterLease {
        try await openLease(edition: edition)
    }

    func inventoryChapters(
        pluginId: String,
        mediaKind: MediaKind,
        canonicalMediaId: String
    ) async -> [DownloadedChapterRecord] {
        (try? await verifiedChapters(
            pluginId: pluginId,
            mediaKind: mediaKind,
            canonicalMediaId: canonicalMediaId
        )) ?? []
    }
}

/// The reading seam when no offline store is composed: nothing is downloaded and nothing can be leased.
nonisolated struct UnavailableOfflineChapterReading: OfflineChapterReading {
    let leases = OfflineLeaseDirectory()
    let isAvailable = false

    func verifiedEdition(_ edition: OfflineChapterEdition) async -> Bool {
        _ = edition
        return false
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
        _ = (pluginId, mediaKind, canonicalMediaId)
        return []
    }
}
