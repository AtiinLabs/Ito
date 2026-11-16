import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// A reconciled store over a migrated database, with a saved series and an enabled-or-not rule, and the helpers the
/// ledger tests share: catalogs of numbered chapters, tickets and commits, and SQL readbacks. The clock is fixed, so
/// no test depends on time passing.
final class SubscriptionLedgerFixture {
    let base: OfflineStoreFixture
    let store: OfflineChapterStore
    let media = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)

    /// Large limits, so a test only meets a cap it sets up.
    static let roomy = AutomaticDownloadLimits(queueLimit: 500, quotaBytes: 100 * AutomaticDownloadLimits.bytesPerGiB)

    var pool: DatabasePool { base.database.dbPool }

    init() async throws {
        base = try OfflineStoreFixture()
        store = base.makeStore()
        _ = await store.reconcile()
    }

    // MARK: - Library and rules

    func saveSeries(_ media: MediaIdentity? = nil, kind: MediaKind = .manga) async throws {
        let target = media ?? self.media
        try await pool.write { db in
            try LibraryItem(
                id: target.canonicalMediaId, title: "Series", coverUrl: nil, pluginId: target.pluginId,
                isAnime: false, pluginType: kind, rawPayload: Data(), anilistId: nil
            ).insert(db)
        }
    }

    /// Saves the series and enables a rule under the fixture's current epoch.
    @discardableResult
    func enable(
        _ configuration: SubscriptionConfiguration = SubscriptionConfiguration(),
        media: MediaIdentity? = nil,
        saveSeries shouldSave: Bool = true
    ) async throws -> (id: String, incarnation: Int64) {
        let target = media ?? self.media
        if shouldSave { try await saveSeries(target) }
        let outcome = try await store.enableSubscription(SubscriptionEnableRequest(
            media: target, reviewedSourceEpoch: OfflineStoreFixture.epoch, configuration: configuration
        ))
        guard case .enabled(let id, let incarnation) = outcome else { throw SubscriptionLedgerFixtureError.notEnabled }
        return (id, incarnation)
    }

    // MARK: - Catalogs

    /// Chapter `c<n>` in logical unit `u<n>` at reading order `n * 10`, listed newest first.
    static func numbered(
        _ numbers: some Sequence<Int>,
        units: Bool = true,
        revision: String? = nil,
        scanlator: (id: String, name: String)? = nil
    ) -> [Chapter] {
        numbers.sorted(by: >).map { number in
            Chapter(
                key: "c\(number)",
                scanlator: scanlator?.name,
                scanlatorID: scanlator?.id,
                logicalUnitID: units ? "u\(number)" : nil,
                readingOrder: Int64(number) * 10,
                revision: revision
            )
        }
    }

    /// One chapter with the evidence a test cares about; everything else is absent.
    static func chapter(
        _ key: String,
        unit: String? = nil,
        order: Int64? = nil,
        group: (id: String, name: String)? = nil,
        revision: String? = nil,
        date: Double? = nil,
        locked: Bool = false,
        volume: Double? = nil,
        number: Double? = nil
    ) -> Chapter {
        Chapter(
            key: key,
            volume: volume,
            chapter: number,
            dateUpdated: date,
            scanlator: group?.name,
            scanlatorID: group?.id,
            paywalled: locked ? true : nil,
            logicalUnitID: unit,
            readingOrder: order,
            revision: revision
        )
    }

    /// Queues the chapter as a manual request and publishes it, so the inventory holds a verified copy of it.
    @discardableResult
    func publishedCopy(_ chapter: Chapter) async throws -> String {
        let outcome = try await store.enqueueBatch(
            DownloadBatchRequest(
                pluginId: media.pluginId, mediaKind: media.mediaKind, canonicalMediaId: media.canonicalMediaId,
                entry: .manga(Manga(key: media.canonicalMediaId, title: "Series")), seriesTitle: "Series",
                provenance: .single, selection: DownloadBatchRecord.sourceListSelection, catalogDigest: nil,
                chapters: [chapter]
            ),
            sourceEpoch: OfflineStoreFixture.epoch
        )
        guard outcome.queued == 1, let job = try await store.job(for: OfflineChapterEdition(media: media, chapterKey: chapter.key)) else {
            throw OfflineStoreFixtureError.notQueued
        }
        let published = try await store.perform(
            .publish(jobID: job.id, pages: [OfflineStoreFixture.imagePage(0)], commitGuard: { _ in true }),
            through: .all
        )
        guard case .published(let versionId)? = published else { throw OfflineStoreFixtureError.notPublished }
        return versionId
    }

    static func observation(
        _ chapters: [Chapter],
        media: MediaIdentity = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga),
        scope: CatalogScope = .allEligible,
        completeness: CatalogCompleteness = .complete,
        epoch: String = OfflineStoreFixture.epoch,
        version: String = "1.0.0"
    ) throws -> CatalogObservation {
        let catalog = ChapterCatalog(scope: scope, completeness: completeness)
        let entry: MediaEntry = media.mediaKind == .novel
            ? .novel(Novel(key: media.canonicalMediaId, title: "Series", chapters: chapters, catalog: catalog))
            : .manga(Manga(key: media.canonicalMediaId, title: "Series", chapters: chapters, catalog: catalog))
        return try CatalogObservation.make(media: media, entry: entry, pluginVersion: version, sourceEpoch: epoch).get()
    }

    // MARK: - Checks

    func begin(media: MediaIdentity? = nil, epoch: String = OfflineStoreFixture.epoch) async throws -> SubscriptionCheckTicket {
        let ticket = try await store.beginSubscriptionCheck(media: media ?? self.media, capturedEpoch: epoch)
        return try #require(ticket)
    }

    /// One whole check: a ticket, then the observation of `chapters` committed under it.
    @discardableResult
    func check(
        _ chapters: [Chapter],
        scope: CatalogScope = .allEligible,
        completeness: CatalogCompleteness = .complete,
        version: String = "1.0.0",
        limits: AutomaticDownloadLimits = SubscriptionLedgerFixture.roomy
    ) async throws -> SubscriptionCommitOutcome {
        let ticket = try await begin()
        let observation = try Self.observation(
            chapters, media: ticket.media, scope: scope, completeness: completeness,
            epoch: ticket.sourceEpoch, version: version
        )
        return try await store.commitSubscriptionObservation(ticket, observation, limits: limits)
    }

    // MARK: - Readbacks

    func subscription() async throws -> SeriesSubscriptionRecord {
        try #require(try await store.subscription(for: media))
    }

    func baseline() async throws -> SubscriptionBaselineRecord? {
        try await pool.read { db in try SubscriptionBaselineRecord.fetchOne(db) }
    }

    func events(_ kind: SubscriptionEventKind? = nil) async throws -> [SubscriptionEventRecord] {
        try await pool.read { db in
            var request = SubscriptionEventRecord.all()
            if let kind { request = request.filter(Column("kind") == kind.rawValue) }
            return try request.order(Column("createdAt"), Column("ordinal"), Column("id")).fetchAll(db)
        }
    }

    func seenCount(present: Bool? = nil) async throws -> Int {
        try await pool.read { db in
            var request = SubscriptionSeenKeyRecord.all()
            if let present { request = request.filter(Column("presentInAccepted") == present) }
            return try request.fetchCount(db)
        }
    }

    func jobs() async throws -> [DownloadJobRecord] {
        try await store.jobs()
    }

    /// Everything about a job a test compares to say it did not change: a job record has no value equality.
    static func signature(_ job: DownloadJobRecord) -> [String] {
        [
            job.id, job.batchId, "\(job.sequence)", job.chapterKey, job.state.rawValue, job.waitingReason?.rawValue ?? "",
            job.sourceEpoch ?? "", "\(job.attemptCount)", "\(job.createdAt.timeIntervalSince1970)",
            "\(job.updatedAt.timeIntervalSince1970)", job.chapterSnapshot.base64EncodedString()
        ]
    }

    func jobSignatures() async throws -> [[String]] {
        try await store.jobs().map(Self.signature)
    }

    func owners(of jobId: String) async throws -> [DownloadJobOwnerRecord] {
        try await pool.read { db in
            try DownloadJobOwnerRecord.filter(Column("jobId") == jobId).order(Column("rowid")).fetchAll(db)
        }
    }

    func batchPresets() async throws -> [DownloadBatchPreset] {
        try await pool.read { db in try DownloadBatchRecord.fetchAll(db).map(\.preset) }
    }

    /// J1: every job has at least one owner after every committed transaction.
    func expectEveryJobHasAnOwner(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let ownerless = try await pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM downloadJob
                    WHERE NOT EXISTS (SELECT 1 FROM downloadJobOwner WHERE downloadJobOwner.jobId = downloadJob.id)
                    """
            ) ?? -1
        }
        #expect(ownerless == 0, sourceLocation: sourceLocation)
    }

    /// Runs a closure in a write transaction, for tests that set state around the store.
    func write(_ body: @escaping @Sendable (Database) throws -> Void) async throws {
        try await pool.write { db in try body(db) }
    }
}

enum SubscriptionLedgerFixtureError: Error {
    case notEnabled
}
