import Combine
import Foundation
import GRDB
import ito_runner
@testable import Ito

/// Hands every call to the download center and remembers which series the update manager asked the ledger about.
@MainActor
final class AutomaticDownloadsSpySink: SubscriptionCatalogSink {
    let center: DownloadCenter
    private(set) var begins: [MediaIdentity] = []

    init(center: DownloadCenter) { self.center = center }

    func begin(media: MediaIdentity) async -> SubscriptionCheckTicket? {
        begins.append(media)
        return await center.begin(media: media)
    }

    func commit(_ ticket: SubscriptionCheckTicket, _ observation: CatalogObservation) async {
        await center.commit(ticket, observation)
    }

    func fail(_ ticket: SubscriptionCheckTicket, _ outcome: SubscriptionCheckOutcome) async {
        await center.fail(ticket, outcome)
    }
}

/// The live facade over the real store, center, worker, scheduler and update manager, with the source and the clock
/// scripted. The facade observes the database through a scheduler the test holds, so a test decides when it sees a change.
@MainActor
final class AutomaticDownloadsHarness {
    nonisolated static let roomy = AutomaticDownloadLimits(
        queueLimit: 500, quotaBytes: 100 * AutomaticDownloadLimits.bytesPerGiB
    )

    let fixture: DownloadWorkerFixture
    let pool: DatabasePool
    let source = FakeLibraryUpdateSource(installedPluginIDs: ["plugin.test"])
    let clock = TestClock(OfflineStoreFixture.fixedDate)
    let installed = CurrentValueSubject<Set<String>, Never>(["plugin.test"])
    let limitsChanged = PassthroughSubject<Void, Never>()
    let updates: UpdateManager
    let spy: AutomaticDownloadsSpySink
    let scheduler: SubscriptionCheckScheduler
    let facade: AutomaticDownloads
    let media = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)

    init(quotaBytes: Int64 = AutomaticDownloadsHarness.roomy.quotaBytes) async throws {
        let limits = AutomaticDownloadLimits(queueLimit: 500, quotaBytes: quotaBytes)
        fixture = try DownloadWorkerFixture(automaticLimits: { limits })
        pool = fixture.offline.database.dbPool
        await fixture.coordinator.reconcile()
        let settings = AppSettingsStore(
            dbPool: pool, networkPolicy: NetworkPolicyCenter(path: ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied)))
        )
        try await settings.reload()
        let clock = clock
        updates = UpdateManager(
            dbPool: pool, updateSource: source, networkConditions: FakeNetworkConditions(isUnmetered: true),
            sourcePacingNanoseconds: 0, now: { clock.date }
        )
        updates.configure(settingsStore: settings)
        spy = AutomaticDownloadsSpySink(center: fixture.center)
        updates.configure(subscriptionSink: spy)
        scheduler = SubscriptionCheckScheduler(
            store: fixture.store, center: fixture.center, coordinator: fixture.coordinator, updates: updates,
            dbPool: pool, interval: { 4 * 3_600 }, limitsChanged: Empty().eraseToAnyPublisher(), now: { clock.date }
        )
        facade = AutomaticDownloads(
            center: fixture.center, scheduler: scheduler, store: fixture.store,
            limits: { limits }, intervalHours: { 4 },
            installedPluginIDs: installed.eraseToAnyPublisher(),
            limitsChanged: limitsChanged.eraseToAnyPublisher()
        )
    }

    func saveSeries(_ media: MediaIdentity? = nil, title: String = "Series") async throws {
        let target = media ?? self.media
        try await pool.write { db in
            try LibraryItem(
                id: target.canonicalMediaId, title: title, coverUrl: nil, pluginId: target.pluginId,
                isAnime: false, pluginType: target.mediaKind, rawPayload: Data(), anilistId: nil
            ).insert(db)
        }
    }

    /// What the source answers for the series from now on.
    func script(_ chapters: ClosedRange<Int>, media: MediaIdentity? = nil) throws {
        let target = media ?? self.media
        source.catalogs[target.canonicalMediaId] = .success(try SubscriptionLedgerFixture.observation(
            SubscriptionLedgerFixture.numbered(chapters), media: target
        ))
    }
}
