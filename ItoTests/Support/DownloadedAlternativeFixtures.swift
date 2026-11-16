import Foundation
import ito_runner
@testable import Ito

/// What a test that never opens a saved alternative gives the route context: opening one fails loudly.
struct UnexpectedDownloadedAlternativeOpening: Error {}

extension DownloadedChapterRecord {
    /// An inventory row for an upload carrying the given descriptor, as the store would publish it. The
    /// snapshot is the descriptor as encoded; `origin` is the raw `originIdentity` column.
    static func alternativeFixture(
        _ chapter: Chapter,
        pluginId: String = "plugin.test",
        mediaKind: MediaKind = .manga,
        canonicalMediaId: String = "series-1",
        authorityScope: OfflineAuthorityScope = .publicUnscoped,
        chapterKey: String? = nil,
        versionId: String? = nil,
        state: DownloadedChapterState = .verified,
        contentKind: OfflineContentKind = .images,
        snapshot: Data? = nil,
        origin: Data? = nil
    ) throws -> DownloadedChapterRecord {
        DownloadedChapterRecord(
            pluginId: pluginId,
            mediaKind: mediaKind,
            canonicalMediaId: canonicalMediaId,
            chapterKey: chapterKey ?? chapter.key,
            authorityScope: authorityScope,
            versionId: versionId ?? "version-\(chapter.key)",
            state: state,
            damageReason: state == .damaged ? .pageMismatch : nil,
            contentKind: contentKind,
            pageCount: 1,
            byteCount: 1,
            manifestFormatVersion: 1,
            manifestSHA256: String(repeating: "a", count: 64),
            chapterSnapshot: try snapshot ?? JSONEncoder().encode(chapter),
            seriesTitle: "Series One",
            sourceEpoch: nil,
            verifiedAt: Date(timeIntervalSince1970: 0),
            originIdentity: origin
        )
    }

    /// The JSON an origin column holds.
    static func originData(pluginId: String, canonicalMediaId: String) throws -> Data {
        try JSONEncoder().encode(OfflineOriginIdentity(pluginId: pluginId, canonicalMediaId: canonicalMediaId))
    }
}

extension Chapter {
    /// One upload of a logical unit, as a source lists it.
    static func upload(
        _ key: String,
        unit: String? = "unit-1",
        group: String? = nil,
        groupID: String? = nil,
        kind: ContentKind? = nil,
        revision: String? = nil
    ) -> Chapter {
        Chapter(
            key: key,
            title: "Title \(key)",
            chapter: 5,
            scanlator: group,
            scanlatorID: groupID,
            kind: kind,
            logicalUnitID: unit,
            revision: revision
        )
    }
}

extension OfflineStoreFixture {
    /// Reconciles, queues the chapter with its full descriptor and publishes the pages through the whole
    /// protocol. Returns the version id.
    @discardableResult
    func publishUpload(
        _ store: OfflineChapterStore,
        _ chapter: Chapter,
        pages: [OfflinePageInput] = [OfflineStoreFixture.imagePage(0), OfflineStoreFixture.imagePage(1)],
        mediaKind: MediaKind = .manga,
        canonicalMediaId: String = "series-1"
    ) async throws -> String {
        _ = await store.reconcile()
        let entry: MediaEntry = mediaKind == .novel
            ? .novel(Novel(key: canonicalMediaId, title: "Series One"))
            : .manga(Manga(key: canonicalMediaId, title: "Series One"))
        let request = DownloadEnqueueRequest(
            pluginId: "plugin.test",
            mediaKind: mediaKind,
            canonicalMediaId: canonicalMediaId,
            entry: entry,
            chapter: chapter,
            seriesTitle: "Series One",
            sourceEpoch: Self.epoch
        )
        guard try await store.enqueue(request) == .queued else { throw OfflineStoreFixtureError.notQueued }
        guard let job = try await store.jobs().last(where: {
            $0.chapterKey == chapter.key && $0.canonicalMediaId == canonicalMediaId
        }) else { throw OfflineStoreFixtureError.notQueued }
        let outcome = try await store.perform(
            .publish(jobID: job.id, pages: pages, commitGuard: { _ in true }),
            through: .all
        )
        guard case .published(let versionId)? = outcome else { throw OfflineStoreFixtureError.notPublished }
        return versionId
    }

    /// The edition of one chapter of the fixture's series.
    func edition(_ chapterKey: String, mediaKind: MediaKind = .manga, canonicalMediaId: String = "series-1") -> OfflineChapterEdition {
        OfflineChapterEdition(
            pluginId: "plugin.test",
            mediaKind: mediaKind,
            canonicalMediaId: canonicalMediaId,
            chapterKey: chapterKey
        )
    }
}

/// A real store holding upload `a` and upload `b` of one logical unit, with `b` listed as an alternative of `a`.
/// Leases come from the store's own directory, as in production.
@MainActor
final class RealAlternativeFixture {
    let fixture: OfflineStoreFixture
    let store: OfflineChapterStore
    let versionB: String
    let listing: DownloadedChapterAlternatives
    let candidate: DownloadedChapterAlternative

    private init(
        fixture: OfflineStoreFixture,
        store: OfflineChapterStore,
        versionB: String,
        listing: DownloadedChapterAlternatives,
        candidate: DownloadedChapterAlternative
    ) {
        self.fixture = fixture
        self.store = store
        self.versionB = versionB
        self.listing = listing
        self.candidate = candidate
    }

    static func make(
        mediaKind: MediaKind = .manga,
        upload: Chapter = .upload("b", group: "Other", groupID: "g-b"),
        pages: [OfflinePageInput] = [OfflineStoreFixture.imagePage(0), OfflineStoreFixture.imagePage(1)]
    ) async throws -> RealAlternativeFixture {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        try await fixture.publishUpload(store, .upload("a"), mediaKind: mediaKind)
        let versionB = try await fixture.publishUpload(store, upload, pages: pages, mediaKind: mediaKind)
        let anchor = OfflineChapterAlternativeAnchor.catalog(
            edition: fixture.edition("a", mediaKind: mediaKind),
            logicalUnitID: "unit-1"
        )
        let listing = try await store.downloadedAlternatives(for: anchor)
        guard let candidate = listing.candidates.first else { throw OfflineStoreFixtureError.notPublished }
        return RealAlternativeFixture(
            fixture: fixture,
            store: store,
            versionB: versionB,
            listing: listing,
            candidate: candidate
        )
    }

    /// The anchor's lookup result as a download service would answer it.
    var lookupResult: DownloadedChapterAlternatives { listing }

    func openLease() async throws -> OfflineChapterLease {
        try await store.openDownloadedAlternative(candidate, sourceEpoch: listing.sourceEpoch)
    }
}
