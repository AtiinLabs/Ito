import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// Records what the update check hands to the subscription ledger, in order, together with what the library row said
/// when each call arrived.
@MainActor
private final class RecordingSink: SubscriptionCatalogSink {
    private let pool: DatabasePool
    var ticket: SubscriptionCheckTicket?
    private(set) var log: [String] = []
    /// The library item's last check time when `commit` arrived: set means the count and badge write came first.
    private(set) var checkedAtWhenCommitted: Date??
    private(set) var committed: CatalogObservation?

    init(pool: DatabasePool, ticket: SubscriptionCheckTicket?) {
        self.pool = pool
        self.ticket = ticket
    }

    func begin(media: MediaIdentity) async -> SubscriptionCheckTicket? {
        log.append("begin")
        return ticket
    }

    func commit(_ ticket: SubscriptionCheckTicket, _ observation: CatalogObservation) async {
        log.append("commit")
        committed = observation
        checkedAtWhenCommitted = try? await pool.read { db in
            try LibraryItem.fetchOne(db, key: "series-1")?.lastCheckedAt
        }
    }

    func fail(_ ticket: SubscriptionCheckTicket, _ outcome: SubscriptionCheckOutcome) async {
        log.append("fail:\(outcome.rawValue)")
    }
}

/// `UpdateManager` shares its one catalog fetch with the subscription ledger and never refetches it. The ticket is taken
/// before the fetch, the observation is committed after the manager's own badge write, and nothing about the badge or the
/// count changes.
@MainActor
struct UpdateManagerCatalogSinkTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private static let epoch = OfflineStoreFixture.epoch

    private func item(anime: Bool = false) -> LibraryItem {
        LibraryItem(
            id: "series-1", title: "Series", coverUrl: nil, pluginId: "plugin.test", isAnime: anime,
            pluginType: anime ? .anime : .manga, rawPayload: Data(), anilistId: nil, status: nil,
            lastCheckedAt: nil, lastUpdatedAt: nil, knownChapterCount: 2, knownChapterCountBasis: .exactChapterKeys
        )
    }

    private func ticket(_ item: LibraryItem) -> SubscriptionCheckTicket {
        SubscriptionCheckTicket(
            subscriptionId: UUID().uuidString, media: item.mediaIdentity, incarnation: 1, ticket: 1,
            sourceEpoch: Self.epoch
        )
    }

    private struct Harness {
        let database: TestDatabase
        let manager: UpdateManager
        let source: FakeLibraryUpdateSource
        let sink: RecordingSink
    }

    private func harness(item: LibraryItem, ticket: SubscriptionCheckTicket?) async throws -> Harness {
        let database = try TestDatabase()
        try await database.dbPool.write { db in try item.insert(db) }
        let source = FakeLibraryUpdateSource(installedPluginIDs: ["plugin.test"])
        let clock = TestClock(start)
        let manager = UpdateManager(
            dbPool: database.dbPool, updateSource: source,
            networkConditions: FakeNetworkConditions(isUnmetered: true), sourcePacingNanoseconds: 0, now: { clock.date }
        )
        let settings = AppSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter())
        try await settings.reload()
        manager.configure(settingsStore: settings)
        let sink = RecordingSink(pool: database.dbPool, ticket: ticket)
        manager.configure(subscriptionSink: sink)
        return Harness(database: database, manager: manager, source: source, sink: sink)
    }

    @Test func aSubscribedCheckTakesItsTicketBeforeTheFetchAndCommitsTheOneObservationAfterTheBadgeWrite() async throws {
        let series = item()
        let ticket = ticket(series)
        let h = try await harness(item: series, ticket: ticket)
        defer { h.database.cleanup() }
        let observation = try SubscriptionLedgerFixture.observation(
            SubscriptionLedgerFixture.numbered(1...3), media: series.mediaIdentity, epoch: ticket.sourceEpoch
        )
        h.source.catalogs[series.id] = .success(observation)
        h.source.freshCounts[series.id] = 3
        h.source.onCheck = { [sink = h.sink] in
            // The fetch happens after `begin` and before `commit`.
            #expect(sink.log == ["begin"])
        }

        try await h.manager.checkForUpdates()

        #expect(h.sink.log == ["begin", "commit"])
        #expect(h.source.checkedItemIDs == [series.id])
        // The fetch froze the epoch of the ticket.
        #expect(h.source.frozenScopes == [ticket.sourceEpoch])
        #expect(h.sink.committed?.catalogDigest == observation.catalogDigest)
        // The manager's own write (check time, count) was already committed when the ledger got the observation.
        let seen = try #require(h.sink.checkedAtWhenCommitted)
        #expect(seen == start)
        // And the count and badge are exactly what they are without a sink: one new chapter.
        let stored = try await h.database.dbPool.read { db in try LibraryItem.fetchOne(db, key: series.id) }
        #expect(stored?.knownChapterCount == 3)
        #expect(h.manager.libraryBadgeCountsSnapshot[series.mediaIdentity] == 1)
    }

    @Test func aFetchThatFailsIsRecordedAsFetchFailedByItsTicket() async throws {
        let series = item()
        let h = try await harness(item: series, ticket: ticket(series))
        defer { h.database.cleanup() }
        h.source.failingItemIDs = [series.id]

        try await h.manager.checkForUpdates()

        #expect(h.sink.log == ["begin", "fail:fetchFailed"])
    }

    @Test func aCancelledFetchIsNotAFailureOfTheCheck() async throws {
        let series = item()
        let h = try await harness(item: series, ticket: ticket(series))
        defer { h.database.cleanup() }
        h.source.cancelledItemIDs = [series.id]

        try await h.manager.checkForUpdates()

        #expect(h.sink.log == ["begin"])
    }

    @Test func anObservationThatCannotBeMadeIsFailedWithItsOwnCode() async throws {
        let series = item()
        let h = try await harness(item: series, ticket: ticket(series))
        defer { h.database.cleanup() }
        h.source.catalogs[series.id] = .failure(.oversizedCatalog)

        try await h.manager.checkForUpdates()

        #expect(h.sink.log == ["begin", "fail:oversizedCatalog"])
    }

    @Test func aSeriesWithoutARuleIsCheckedWithoutAFrozenScopeAndNeverCommitted() async throws {
        let series = item()
        let h = try await harness(item: series, ticket: nil)
        defer { h.database.cleanup() }
        h.source.catalogs[series.id] = .success(
            try SubscriptionLedgerFixture.observation(
                SubscriptionLedgerFixture.numbered(1...3), media: series.mediaIdentity, epoch: Self.epoch
            )
        )

        try await h.manager.checkForUpdates()

        #expect(h.sink.log == ["begin"])
        #expect(h.source.frozenScopes == [nil])
    }

    @Test func animeIsNeverGivenATicket() async throws {
        let series = item(anime: true)
        let h = try await harness(item: series, ticket: ticket(series))
        defer { h.database.cleanup() }

        try await h.manager.checkForUpdates()

        #expect(h.sink.log.isEmpty)
        #expect(h.source.checkedItemIDs == [series.id])
    }
}
