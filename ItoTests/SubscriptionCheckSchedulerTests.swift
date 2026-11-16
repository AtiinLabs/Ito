import Combine
import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// Hands every call to the download center, and remembers what the update manager asked of the ledger.
@MainActor
private final class SpySink: SubscriptionCatalogSink {
    let center: DownloadCenter
    private(set) var begins: [MediaIdentity] = []

    init(center: DownloadCenter) {
        self.center = center
    }

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

/// The scheduler over the real store, center, worker and update manager, with the source, the network path and the
/// clock scripted. The clock is the store's own, so a check records exactly "now".
@MainActor
private final class SchedulerHarness {
    nonisolated static let otherPlugin = "plugin.other"
    nonisolated static let otherEpoch = String(repeating: "c", count: 32)
    nonisolated static let interval: TimeInterval = 4 * 3_600
    nonisolated static let roomy = AutomaticDownloadLimits(
        queueLimit: 500, quotaBytes: 100 * AutomaticDownloadLimits.bytesPerGiB
    )

    let fixture: DownloadWorkerFixture
    let pool: DatabasePool
    let source = FakeLibraryUpdateSource(installedPluginIDs: ["plugin.test", SchedulerHarness.otherPlugin])
    let clock = TestClock(OfflineStoreFixture.fixedDate)
    let path = ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied))
    let limitsChanged = PassthroughSubject<Void, Never>()
    let settings: AppSettingsStore
    let updates: UpdateManager
    let spy: SpySink
    let scheduler: SubscriptionCheckScheduler
    /// The kind of every run that ended, in order.
    private(set) var finished: [UpdateRunKind] = []
    private var subscriptions = Set<AnyCancellable>()
    /// A second store over the same database, for setting up rules while the harness's own store is not reconciled.
    private let setupStore: OfflineChapterStore

    init(reconcile: Bool = true) async throws {
        fixture = try DownloadWorkerFixture(automaticLimits: { Self.roomy })
        pool = fixture.offline.database.dbPool
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO pluginCompletionScope(pluginId, epoch) VALUES (?, ?)",
                arguments: [Self.otherPlugin, Self.otherEpoch]
            )
        }
        setupStore = fixture.offline.makeStore()
        _ = await setupStore.reconcile()
        if reconcile { await fixture.coordinator.reconcile() }

        settings = AppSettingsStore(dbPool: pool, networkPolicy: NetworkPolicyCenter(path: path))
        try await settings.reload()
        let clock = clock
        updates = UpdateManager(
            dbPool: pool, updateSource: source, networkConditions: FakeNetworkConditions(isUnmetered: true),
            sourcePacingNanoseconds: 0, now: { clock.date }
        )
        updates.configure(settingsStore: settings)
        spy = SpySink(center: fixture.center)
        updates.configure(subscriptionSink: spy)
        scheduler = SubscriptionCheckScheduler(
            store: fixture.store, center: fixture.center, coordinator: fixture.coordinator, updates: updates,
            dbPool: pool, interval: { Self.interval }, limitsChanged: limitsChanged.eraseToAnyPublisher(),
            now: { clock.date }
        )
        updates.runFinished.sink { [weak self] kind in self?.finished.append(kind) }.store(in: &subscriptions)
    }

    func epoch(of plugin: String) -> String {
        plugin == Self.otherPlugin ? Self.otherEpoch : OfflineStoreFixture.epoch
    }

    func media(_ id: String, plugin: String = "plugin.test", kind: MediaKind = .manga) -> MediaIdentity {
        MediaIdentity(pluginId: plugin, canonicalMediaId: id, mediaKind: kind)
    }

    /// Saves the series and enables a rule for it, and scripts the catalog its source answers with.
    @discardableResult
    func subscribe(
        _ id: String,
        plugin: String = "plugin.test",
        configuration: SubscriptionConfiguration = SubscriptionConfiguration(),
        chapters: ClosedRange<Int> = 1...2
    ) async throws -> String {
        try await pool.write { db in
            try LibraryItem(
                id: id, title: id, coverUrl: nil, pluginId: plugin, isAnime: false, pluginType: .manga,
                rawPayload: Data(), anilistId: nil
            ).insert(db)
        }
        let outcome = try await setupStore.enableSubscription(SubscriptionEnableRequest(
            media: media(id, plugin: plugin), reviewedSourceEpoch: epoch(of: plugin), configuration: configuration
        ))
        guard case .enabled(let ruleId, _) = outcome else { throw SubscriptionLedgerFixtureError.notEnabled }
        try script(id, plugin: plugin, chapters: chapters)
        return ruleId
    }

    /// What the source answers for the series from now on.
    func script(_ id: String, plugin: String = "plugin.test", chapters: ClosedRange<Int>) throws {
        source.catalogs[id] = .success(try SubscriptionLedgerFixture.observation(
            SubscriptionLedgerFixture.numbered(chapters), media: media(id, plugin: plugin), epoch: epoch(of: plugin)
        ))
    }

    /// Records a check of the rule `ago` seconds before the clock's time, as the ledger does.
    func markAttempted(_ ruleId: String, _ outcome: SubscriptionCheckOutcome, ago: TimeInterval = 0) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE seriesSubscription SET lastAttemptAt = ?, lastAttemptOutcome = ? WHERE id = ?",
                arguments: [OfflineStoreFixture.fixedDate.addingTimeInterval(-ago), outcome.rawValue, ruleId]
            )
        }
    }

    func rows() async throws -> [SubscriptionScheduleRow] {
        try await fixture.store.subscriptionScheduleRows()
    }

    func row(_ id: String) async throws -> SubscriptionScheduleRow {
        try #require(try await rows().first { $0.media.canonicalMediaId == id })
    }

    /// Writes the read state a maintain rule follows: these chapters read, and this one the last.
    func read(_ keys: [String], last: String, series: String = "series-1") async throws {
        try await pool.write { db in
            for key in keys {
                try ReadProgressKeyRecord(
                    pluginId: "plugin.test", canonicalMediaId: series, mediaKind: .manga,
                    chapterKey: key, markedAt: nil, provenance: nil
                ).save(db)
            }
            try MediaReadProgressRecord(
                pluginId: "plugin.test", canonicalMediaId: series, mediaKind: .manga,
                lastReadChapterKey: last, updatedAt: nil, provenance: nil, lastReadPosition: nil, readerViewer: nil
            ).save(db)
        }
    }

    /// A maintain rule with its first baseline committed through the store: chapters 3 and 4 are queued.
    func subscribeMaintainWithBaseline(_ id: String = "series-1") async throws -> String {
        let ruleId = try await subscribe(
            id, configuration: SubscriptionConfiguration(mode: .maintainNextUnread, windowSize: 2), chapters: 1...6
        )
        try await read(["c1", "c2"], last: "c2", series: id)
        let ticket = try #require(try await fixture.store.beginSubscriptionCheck(
            media: media(id), capturedEpoch: OfflineStoreFixture.epoch
        ))
        _ = try await fixture.store.commitSubscriptionObservation(
            ticket,
            try SubscriptionLedgerFixture.observation(SubscriptionLedgerFixture.numbered(1...6), media: media(id)),
            limits: Self.roomy
        )
        return ruleId
    }

    func jobKeys() async throws -> [String] {
        try await fixture.store.jobs().map(\.chapterKey).sorted()
    }
}

/// The foreground scheduler: its triggers, its coalescing, its lifecycle, and its drains. Every wait is a gate or
/// `untilIdle`; nothing sleeps, polls or yields in a loop.
@MainActor
struct SubscriptionCheckSchedulerTests {
    // MARK: - A12: triggers coalesce into exactly one rerun

    @Test func threeTriggersDuringAGatedPassMakeExactlyOneRerunAndNoSeriesIsFetchedTwiceInAPass() async throws {
        let h = try await SchedulerHarness()
        try await h.subscribe("a")
        let b = try await h.subscribe("b")
        // "b" was checked just now, so it is not due; a change to its rule makes it so.
        try await h.markAttempted(b, .advanced)
        let gate = DownloadTestGate()
        h.source.cancellableGate = gate

        h.scheduler.setActive(true)
        await gate.awaitArrival()
        // The pass is in "a". Three triggers arrive.
        h.scheduler.request(.activation)
        h.scheduler.request(.libraryRunFinished)
        h.scheduler.request(.ruleChanged(b))
        await gate.release()
        await h.scheduler.untilIdle()

        #expect(h.source.checkedItemIDs == ["a", "b"])
        #expect(h.spy.begins.map(\.canonicalMediaId) == ["a", "b"])
        // Exactly one rerun: two runs in all, the second only for the rule that was asked for.
        #expect(h.finished == [.subscriptions, .subscriptions])
        #expect(try await h.row("a").lastAttemptOutcome == .baselineEstablished)
        #expect(try await h.row("b").lastAttemptOutcome == .baselineEstablished)
    }

    // MARK: - A13: a library refresh gives way to nobody and waits for nobody

    @Test func aLibraryRefreshCancelsAndAwaitsAPassInFlightAndNeverFailsAsAlreadyRunning() async throws {
        let h = try await SchedulerHarness()
        try await h.subscribe("a")
        try await h.subscribe("b")
        let gate = DownloadTestGate()
        h.source.cancellableGate = gate

        h.scheduler.setActive(true)
        await gate.awaitArrival()
        // A pass is not a library refresh: nothing the refresh UI shows is lit.
        #expect(!h.updates.isRefreshing)
        #expect(h.updates.totalItemsToCheck == 0 && h.updates.itemsCheckedCurrentRun == 0)
        #expect(h.updates.sourceFailures.isEmpty)

        let manual = Task { try await h.updates.checkForUpdates() }
        // The refresh cancelled the pass's fetch, and starts only once the pass has ended.
        await gate.awaitCancellation()
        await gate.release()
        try await manual.value
        await h.scheduler.untilIdle()

        // The pass's check of "a" was cut short; the refresh then checked both, one at a time, and counted as the check.
        #expect(h.source.checkedItemIDs.count == 3)
        #expect(Set(h.source.checkedItemIDs.dropFirst()) == ["a", "b"])
        #expect(!h.updates.isRefreshing && h.updates.sourceFailures.isEmpty)
        #expect(try await h.row("a").lastAttemptOutcome == .baselineEstablished)
        #expect(try await h.row("b").lastAttemptOutcome == .baselineEstablished)
        // After the refresh ended nothing was due, so the scheduler started no second fetch of either.
        #expect(h.finished == [.subscriptions, .manual])
        #expect(h.source.checkedItemIDs.count == 3)
    }

    @Test func aSubscriptionPassNeverPublishesTheRefreshCountersOrItsFailuresAndIsExclusive() async throws {
        let h = try await SchedulerHarness()
        try await h.subscribe("a")
        h.source.failingItemIDs = ["a"]

        let run = try #require(h.updates.startSubscriptionChecks([h.media("a")]))
        // While it runs nothing else may start, of any kind.
        #expect(h.updates.startSubscriptionChecks([h.media("a")]) == nil)
        #expect(!h.updates.isRefreshing)
        let result = await run.value

        #expect(result.checked == 1 && result.attempted == [h.media("a")])
        #expect(!result.cancelled && !result.stoppedByPolicy)
        #expect(h.updates.sourceFailures.isEmpty)
        #expect(!h.updates.isRefreshing && h.updates.totalItemsToCheck == 0 && h.updates.itemsCheckedCurrentRun == 0)
        // The failure is the rule's: recorded by its ticket, so the series moves behind the others.
        #expect(try await h.row("a").lastAttemptOutcome == .fetchFailed)
        #expect(h.finished == [.subscriptions])
    }

    // MARK: - A14: Wi-Fi only stops the pass before the first series

    @Test func wifiOnlyOnAnExpensivePathStopsThePassBeforeTheFirstSeriesAndNoTicketIsBegun() async throws {
        let h = try await SchedulerHarness()
        try await h.subscribe("a")
        try await h.subscribe("b")
        try await h.settings.set(true, for: AppPreferenceCatalog.wifiOnlyUpdates)
        h.path.set(NetworkPathSnapshot(status: .satisfied, isExpensive: true))

        h.scheduler.setActive(true)
        await h.scheduler.untilIdle()

        #expect(h.spy.begins.isEmpty)
        #expect(h.source.checkedItemIDs.isEmpty)
        #expect(h.finished == [.subscriptions])

        let result = await h.updates.startSubscriptionChecks([h.media("a"), h.media("b")])?.value
        #expect(result?.stoppedByPolicy == true)
        #expect(result?.checked == 0 && result?.attempted.isEmpty == true)
        #expect(h.spy.begins.isEmpty)
        // Nothing was recorded: both rules are as due as before, for the next trigger.
        #expect(try await h.row("a").lastAttemptAt == nil)
    }

    // MARK: - A15: a source that needs the person is not asked again this pass

    @Test func aSourceThatNeedsASignInIsNotAskedForTheRestOfItsSeriesWhileOtherSourcesAre() async throws {
        let h = try await SchedulerHarness()
        // The oldest check goes first, so "x1" is the first series of its source in the pass.
        let x1 = try await h.subscribe("x1")
        let x2 = try await h.subscribe("x2")
        try await h.markAttempted(x1, .advanced, ago: 10 * 86_400)
        try await h.markAttempted(x2, .advanced, ago: 5 * 86_400)
        try await h.subscribe("y1", plugin: SchedulerHarness.otherPlugin)
        h.source.errorsByItemID["x1"] = PluginCallError(kind: .needsLogin, message: "Sign in")

        h.scheduler.setActive(true)
        await h.scheduler.untilIdle()

        #expect(Set(h.source.checkedItemIDs) == ["x1", "y1"])
        #expect(!h.source.checkedItemIDs.contains("x2"))
        // The failed rule is recorded as a failure and waits twice the interval; the unattempted one is still due.
        let failed = try await h.row("x1")
        #expect(failed.lastAttemptOutcome == .fetchFailed)
        #expect(
            SubscriptionSchedule.dueDate(failed, interval: SchedulerHarness.interval, now: h.clock.date)
                == OfflineStoreFixture.fixedDate.addingTimeInterval(2 * SchedulerHarness.interval)
        )
        let untouched = try await h.row("x2")
        #expect(untouched.lastAttemptAt == OfflineStoreFixture.fixedDate.addingTimeInterval(-5 * 86_400))
        let due = SubscriptionSchedule.duePass(
            try await h.rows(), forced: [], interval: SchedulerHarness.interval, now: h.clock.date
        )
        #expect(due.map { $0.media.canonicalMediaId } == ["x2"])
        #expect(try await h.row("y1").lastAttemptOutcome == .baselineEstablished)
        // Its failure is its own: the refresh banner is untouched.
        #expect(h.updates.sourceFailures.isEmpty)
    }

    // MARK: - A16: nothing runs before the store is reconciled

    @Test func aPassRequestedBeforeReconciliationBeginsNothingAndRunsOnceWhenReconciled() async throws {
        let h = try await SchedulerHarness(reconcile: false)
        try await h.subscribe("a")

        h.scheduler.setActive(true)
        await h.scheduler.untilIdle()
        #expect(h.spy.begins.isEmpty)
        #expect(h.finished.isEmpty)

        await h.fixture.coordinator.reconcile()
        await h.scheduler.untilIdle()

        #expect(h.spy.begins.map(\.canonicalMediaId) == ["a"])
        #expect(h.finished == [.subscriptions])
        #expect(try await h.row("a").lastAttemptOutcome == .baselineEstablished)
    }

    // MARK: - A17: an inactive scheduler does nothing, and activation plans from durable state

    @Test func anInactiveSchedulerDropsEveryRequestAndActivationRunsOnePassAndDrainsTheMaintainRules() async throws {
        let h = try await SchedulerHarness()
        let maintain = try await h.subscribeMaintainWithBaseline("series-1")
        #expect(try await h.jobKeys() == ["c3", "c4"])
        let idle = try await h.subscribe("idle")
        // The reader moved on while the app was away: the window should now include chapter 5.
        try await h.read(["c1", "c2", "c3"], last: "c3")

        h.scheduler.request(.activation)
        h.scheduler.request(.ruleChanged(idle))
        h.scheduler.request(.libraryRunFinished)
        h.scheduler.requestDrain(.all)
        h.scheduler.requestDrain(.subscription(maintain))
        await h.scheduler.untilIdle()

        #expect(h.spy.begins.isEmpty)
        #expect(h.finished.isEmpty)
        #expect(h.scheduler.drainBatches == 0)
        #expect(try await h.jobKeys() == ["c3", "c4"])

        h.scheduler.setActive(true)
        await h.scheduler.untilIdle()

        // One pass, over the rule that was never checked; one drain, which followed the reader.
        #expect(h.spy.begins.map(\.canonicalMediaId) == ["idle"])
        #expect(h.finished == [.subscriptions])
        #expect(h.scheduler.drainBatches == 1)
        #expect(try await h.jobKeys() == ["c3", "c4", "c5"])
    }

    @Test func deactivatingCancelsThePassInFlightAndForgetsWhatWasWaiting() async throws {
        let h = try await SchedulerHarness()
        try await h.subscribe("a")
        let gate = DownloadTestGate()
        h.source.cancellableGate = gate

        h.scheduler.setActive(true)
        await gate.awaitArrival()
        h.scheduler.request(.activation)
        h.scheduler.setActive(false)
        await gate.awaitCancellation()
        await gate.release()
        await h.scheduler.untilIdle()

        // The check was cut short and committed nothing; the request made during the pass did not outlive it.
        #expect(h.source.checkedItemIDs == ["a"])
        #expect(h.finished == [.subscriptions])
        #expect(try await h.row("a").lastAttemptAt == nil)
        #expect(!h.scheduler.isActive)
    }

    // MARK: - A18: drain triggers

    @Test func removingAJobFreesRoomAndDrainsOnce() async throws {
        let h = try await SchedulerHarness()
        _ = try await h.subscribeMaintainWithBaseline()
        h.scheduler.setActive(true)
        await h.scheduler.untilIdle()
        let held = HeldObservationScheduler()
        h.fixture.center.startObserving(scheduling: held)
        await held.nextPublication().run()
        let before = h.scheduler.drainBatches

        let job = try #require(try await h.fixture.store.jobs().first)
        try await h.fixture.store.cancel(jobID: job.id)
        await held.nextPublication().run()
        await h.scheduler.untilIdle()

        #expect(h.scheduler.drainBatches == before + 1)
    }

    @Test func deletingACopyFreesRoomAndDrainsOnce() async throws {
        let h = try await SchedulerHarness()
        h.scheduler.setActive(true)
        await h.scheduler.untilIdle()
        _ = await h.fixture.enqueue(chapterKey: "saved")
        await h.fixture.startWorker()
        await h.fixture.coordinator.untilIdle()
        #expect(try await h.fixture.copy(chapterKey: "saved") != nil)
        let held = HeldObservationScheduler()
        h.fixture.center.startObserving(scheduling: held)
        await held.nextPublication().run()
        let before = h.scheduler.drainBatches

        try await h.fixture.center.delete([h.fixture.edition(chapterKey: "saved")], suppress: false)
        await held.nextPublication().run()
        await h.scheduler.untilIdle()

        #expect(h.scheduler.drainBatches == before + 1)
    }

    @Test func raisingALimitDrainsAndConcurrentTriggersCoalesceIntoOneBatch() async throws {
        let h = try await SchedulerHarness()
        h.scheduler.setActive(true)
        await h.scheduler.untilIdle()
        let before = h.scheduler.drainBatches

        // Three triggers in the same turn: one batch.
        h.limitsChanged.send(())
        h.limitsChanged.send(())
        h.scheduler.requestDrain(.all)
        await h.scheduler.untilIdle()
        #expect(h.scheduler.drainBatches == before + 1)

        h.limitsChanged.send(())
        await h.scheduler.untilIdle()
        #expect(h.scheduler.drainBatches == before + 2)
    }

    @Test func anExactReadKeyOfAMaintainRuleDrainsItAndMovesItsWindow() async throws {
        let h = try await SchedulerHarness()
        _ = try await h.subscribeMaintainWithBaseline()
        h.scheduler.setActive(true)
        await h.scheduler.untilIdle()
        let held = HeldObservationScheduler()
        h.scheduler.startObservingReadState(scheduling: held)
        // The first value is only the baseline: activation already drained every maintain rule.
        await held.nextPublication().run()
        await h.scheduler.untilIdle()
        let before = h.scheduler.drainBatches
        #expect(try await h.jobKeys() == ["c3", "c4"])

        try await h.read(["c3"], last: "c3")
        await held.nextPublication().run()
        await h.scheduler.untilIdle()

        #expect(h.scheduler.drainBatches == before + 1)
        #expect(try await h.jobKeys() == ["c3", "c4", "c5"])
    }

    @Test func aPagePositionSaveDoesNotChangeWhatMaintainNextNReads() async throws {
        let h = try await SchedulerHarness()
        _ = try await h.subscribeMaintainWithBaseline()
        let before = try await h.pool.read { db in try MaintainReadState.fetchAll(in: db) }
        #expect(before.count == 1 && before.first?.readKeyCount == 2 && before.first?.lastReadChapterKey == "c2")

        // The reader saves its page position inside the same chapter.
        try await h.pool.write { db in
            try MediaReadProgressRecord(
                pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga,
                lastReadChapterKey: "c2", updatedAt: Date(), provenance: nil, lastReadPosition: 7, readerViewer: nil
            ).save(db)
        }
        #expect(try await h.pool.read { db in try MaintainReadState.fetchAll(in: db) } == before)

        // Marking a chapter read, or moving to another, does change it.
        try await h.read(["c3"], last: "c2")
        #expect(try await h.pool.read { db in try MaintainReadState.fetchAll(in: db) } != before)
    }

    // MARK: - A19: a background run is not the scheduler's

    @Test func aBackgroundRunFeedsTheLedgerThroughTheSameFetchWithoutInvolvingTheScheduler() async throws {
        let h = try await SchedulerHarness()
        try await h.subscribe("a")
        h.scheduler.setActive(true)
        await h.scheduler.untilIdle()
        #expect(try await h.row("a").lastAttemptOutcome == .baselineEstablished)
        let begun = h.spy.begins.count
        let fetched = h.source.checkedItemIDs.count
        let finished = h.finished.count
        // A new chapter appears at the source.
        try h.script("a", chapters: 1...3)

        _ = await h.updates.checkForUpdatesInBackground()

        // One fetch, one ticket, one commit: the rule saw the chapter. The scheduler ran nothing of its own.
        #expect(h.source.checkedItemIDs.count == fetched + 1)
        #expect(h.spy.begins.count == begun + 1)
        #expect(Array(h.finished.dropFirst(finished)) == [.background])
        #expect(try await h.row("a").lastAttemptOutcome == .advanced)
        #expect(try await h.jobKeys() == ["c3"])
        // The worker is not running, so waking it was a no-op: the chapter waits queued.
        #expect(try await h.fixture.store.jobs().first?.state == .queued)
        await h.fixture.coordinator.untilIdle()
    }

    // MARK: - A20: reading the facade checks nothing

    @Test func theFacadesReadsNeverBeginATicketOrFetch() async throws {
        let h = try await SchedulerHarness()
        try await h.subscribe("a")
        let facade = AutomaticDownloads(center: h.fixture.center, scheduler: h.scheduler)

        #expect(facade.isAvailable)
        #expect(try facade.sourceEpoch(for: "plugin.test") == OfflineStoreFixture.epoch)
        await h.scheduler.untilIdle()

        #expect(h.spy.begins.isEmpty)
        #expect(h.source.checkedItemIDs.isEmpty)
        #expect(h.finished.isEmpty)
        #expect(h.scheduler.drainBatches == 0)
        let unavailable = UnavailableAutomaticDownloads()
        #expect(!unavailable.isAvailable)
        #expect(throws: AutomaticDownloadsError.unavailable) { try unavailable.sourceEpoch(for: "plugin.test") }
    }

    // MARK: - The facade tells the scheduler about an acknowledged change

    @Test func anAcknowledgedEnableAsksForACheckOfThatRuleAndARefusedOneDoesNot() async throws {
        let h = try await SchedulerHarness()
        let facade = AutomaticDownloads(center: h.fixture.center, scheduler: h.scheduler)
        h.scheduler.setActive(true)
        await h.scheduler.untilIdle()
        #expect(h.spy.begins.isEmpty)

        // The series is not saved: the store refuses, and nothing is asked of the scheduler.
        let refused = try await facade.enable(SubscriptionEnableRequest(
            media: h.media("nowhere"), reviewedSourceEpoch: OfflineStoreFixture.epoch, configuration: SubscriptionConfiguration()
        ))
        #expect(refused == .refused(.seriesNotSaved))
        await h.scheduler.untilIdle()
        #expect(h.spy.begins.isEmpty)

        try await h.pool.write { db in
            try LibraryItem(
                id: "fresh", title: "Fresh", coverUrl: nil, pluginId: "plugin.test", isAnime: false, pluginType: .manga,
                rawPayload: Data(), anilistId: nil
            ).insert(db)
        }
        try h.script("fresh", chapters: 1...2)
        let enabled = try await facade.enable(SubscriptionEnableRequest(
            media: h.media("fresh"), reviewedSourceEpoch: OfflineStoreFixture.epoch, configuration: SubscriptionConfiguration()
        ))
        guard case .enabled(let ruleId, _) = enabled else {
            Issue.record("the enable must be acknowledged")
            return
        }
        await h.scheduler.untilIdle()
        #expect(h.spy.begins.map(\.canonicalMediaId) == ["fresh"])
        #expect(try await h.row("fresh").lastAttemptOutcome == .baselineEstablished)

        // The rule was just checked, so it is not due. An acknowledged edit asks for it anyway; a stale one does not.
        let generation = try #require(try await h.fixture.store.subscription(for: h.media("fresh"))).configGeneration
        let stale = try await facade.edit(SubscriptionEdit(
            subscriptionId: ruleId, expectedConfigGeneration: generation + 1,
            configuration: SubscriptionConfiguration(perRunPositionCap: 6)
        ))
        #expect(stale == .stale)
        await h.scheduler.untilIdle()
        #expect(h.spy.begins.count == 1)
        let applied = try await facade.edit(SubscriptionEdit(
            subscriptionId: ruleId, expectedConfigGeneration: generation,
            configuration: SubscriptionConfiguration(perRunPositionCap: 6)
        ))
        #expect(applied == .applied(configGeneration: generation + 1))
        await h.scheduler.untilIdle()
        #expect(h.spy.begins.map(\.canonicalMediaId) == ["fresh", "fresh"])
    }
}
