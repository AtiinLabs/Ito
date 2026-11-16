import Combine
import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// The read models and the commands of the facade over the real store, and what the scheduler does with them. Rows are
/// read through an observation scheduler the test holds; nothing waits or polls.
@MainActor
struct AutomaticDownloadsFacadeTests {
    private typealias Fixture = SubscriptionLedgerFixture

    /// What the facade's two publishers last said.
    @MainActor
    private final class Listener {
        private(set) var rules: [[SubscriptionRuleRow]] = []
        private(set) var rule: [SubscriptionRuleRow?] = []
        private var subscriptions = Set<AnyCancellable>()

        init(_ facade: AutomaticDownloads, media: MediaIdentity) {
            facade.rules().sink { [weak self] in self?.rules.append($0) }.store(in: &subscriptions)
            facade.rule(for: media).sink { [weak self] in self?.rule.append($0) }.store(in: &subscriptions)
        }
    }

    private func observe(_ h: AutomaticDownloadsHarness) async -> HeldObservationScheduler {
        let held = HeldObservationScheduler()
        h.facade.startObserving(scheduling: held)
        await held.nextPublication().run()
        return held
    }

    private func enableViaFacade(_ h: AutomaticDownloadsHarness) async throws -> String {
        try await h.saveSeries()
        let outcome = try await h.facade.enable(SubscriptionEnableRequest(
            media: h.media, reviewedSourceEpoch: OfflineStoreFixture.epoch, configuration: SubscriptionConfiguration()
        ))
        guard case .enabled(let id, _) = outcome else { throw SubscriptionLedgerFixtureError.notEnabled }
        return id
    }

    // MARK: - Read models

    @Test func theRowsCarryTheLibraryTitleTheStatusFactsAndTheInstalledSources() async throws {
        let h = try await AutomaticDownloadsHarness()
        let listener = Listener(h.facade, media: h.media)
        let held = await observe(h)
        #expect(listener.rules == [[]] && listener.rule == [nil], "Nothing exists yet, and that is said once it is read")

        let id = try await enableViaFacade(h)
        await held.nextPublication().run()
        let row = try #require(listener.rule.last ?? nil)
        #expect(row.id == id && row.title == "Series" && row.media == h.media)
        #expect(row.state == .enabled && !row.hasBaseline && row.lastAttemptAt == nil)
        #expect(row.sourceInstalled)
        #expect(SubscriptionRuleStatus(row) == .waitingForBaseline(.notChecked))
        #expect(row.configuration == SubscriptionConfiguration())
        #expect(listener.rules.last?.map(\.id) == [id])

        // The source is uninstalled: no database change, and the status follows at once.
        h.installed.send([])
        #expect(listener.rule.last??.sourceInstalled == false)
        #expect(SubscriptionRuleStatus(try #require(listener.rule.last ?? nil)) == .sourceNotInstalled)
    }

    @Test func aTurnedOffRuleIsHiddenFromTheListButStillReadForItsSeries() async throws {
        let h = try await AutomaticDownloadsHarness()
        let listener = Listener(h.facade, media: h.media)
        let held = await observe(h)
        let id = try await enableViaFacade(h)
        await held.nextPublication().run()

        try await h.facade.turnOff(id: id)
        await held.nextPublication().run()

        #expect(listener.rules.last?.isEmpty == true)
        #expect(listener.rule.last??.state == .disabled, "The series can turn its rule on again")
    }

    @Test func theReadModelCountsWhatWaitsPendingAndHeldWithoutReadingTheCatalog() async throws {
        let f = try await Fixture()
        let id = try await f.enable().id
        try await f.check(Fixture.numbered(1...2))
        // No room for another job: the new chapter waits for disk space.
        let starved = AutomaticDownloadLimits(queueLimit: 500, quotaBytes: 1)
        try await f.check(Fixture.numbered(1...3), limits: starved)

        var rows = try await f.pool.read { db in try SubscriptionRuleReadModel.read(db, quotaBytes: Int64.max) }
        var row = try #require(rows.first)
        #expect(row.id == id && row.hasBaseline && row.attentionCount == 0)
        #expect(row.pending == [.quota: 1])
        #expect(SubscriptionRuleBadge.badges(for: row) == [.waitingForSpace])

        // Room appears and the job is queued; the rule then pauses, so its job is held and says why.
        _ = try await f.store.drainSubscriptionEvents(subscriptionId: id, limits: Fixture.roomy)
        rows = try await f.pool.read { db in try SubscriptionRuleReadModel.read(db, quotaBytes: Int64.max) }
        row = try #require(rows.first)
        #expect(row.queuedJobs == 1 && row.heldJobs == 0 && row.pending.isEmpty)
        _ = try await f.store.pauseSubscription(id: id)
        rows = try await f.pool.read { db in try SubscriptionRuleReadModel.read(db, quotaBytes: Int64.max) }
        row = try #require(rows.first)
        #expect(row.queuedJobs == 1 && row.heldJobs == 1 && row.heldReason == .automaticRulePaused)
        #expect(SubscriptionRuleBadge.badges(for: row) == [.held(.automaticRulePaused)])
    }

    @Test func anEnabledRuleWhoseQuotaIsUsedUpHoldsItsQueuedJobForSpace() async throws {
        let f = try await Fixture()
        try await f.enable()
        try await f.check(Fixture.numbered(1...2))
        try await f.check(Fixture.numbered(1...3))
        try await f.publishedCopy(Fixture.chapter("saved", unit: "usaved", order: 5))

        let open = try await f.pool.read { db in try SubscriptionRuleReadModel.read(db, quotaBytes: Int64.max) }
        #expect(open.first?.heldJobs == 0)
        let full = try await f.pool.read { db in try SubscriptionRuleReadModel.read(db, quotaBytes: 1) }
        #expect(full.first?.heldJobs == 1 && full.first?.heldReason == .automaticSpaceFull)
    }

    @Test func aWaitingEventCountsAsAttentionAndAnOldIncarnationsEventsAreNotCounted() async throws {
        let f = try await Fixture()
        let askA = EditionSelection.preferred(primary: ScanlatorRef(id: "ga", name: "A"), fallback: .ask)
        let id = try await f.enable(SubscriptionConfiguration(selection: askA)).id
        let base = Fixture.numbered(1...3, scanlator: (id: "ga", name: "A"))
        try await f.check(base)
        try await f.check(base + [Fixture.chapter("c4b", unit: "u4", order: 40, group: (id: "gb", name: "B"))])

        var row = try #require(try await f.pool.read { db in try SubscriptionRuleReadModel.read(db, quotaBytes: .max) }.first)
        #expect(row.attentionCount == 1)
        #expect(SubscriptionRuleBadge.badges(for: row) == [.attention(1)])

        // Turn it off and on again: the new incarnation owns none of the old events.
        _ = try await f.store.disableSubscription(id: id)
        _ = try await f.enable(askASelection(askA), saveSeries: false)
        row = try #require(try await f.pool.read { db in try SubscriptionRuleReadModel.read(db, quotaBytes: .max) }.first)
        #expect(row.attentionCount == 0 && !row.hasBaseline && row.incarnation == 2)
    }

    private func askASelection(_ selection: EditionSelection) -> SubscriptionConfiguration {
        SubscriptionConfiguration(selection: selection)
    }

    // MARK: - Triggers

    @Test func v5_aRuleThatIsEditedIsCheckedAtOnceWhateverItsDueTimeAndNeverBeforeThen() async throws {
        let h = try await AutomaticDownloadsHarness()
        let id = try await enableViaFacade(h)
        try h.script(1...2)
        // It was checked just now, so it is not due.
        try await h.pool.write { db in
            try db.execute(
                sql: "UPDATE seriesSubscription SET lastAttemptAt = ?, lastAttemptOutcome = 'advanced' WHERE id = ?",
                arguments: [OfflineStoreFixture.fixedDate, id]
            )
        }
        h.scheduler.setActive(true)
        await h.scheduler.untilIdle()
        #expect(h.spy.begins.isEmpty, "Activation does not check a rule that is not due")

        let outcome = try await h.facade.edit(SubscriptionEdit(
            subscriptionId: id, expectedConfigGeneration: 1,
            configuration: SubscriptionConfiguration(perRunPositionCap: 2)
        ))
        await h.scheduler.untilIdle()

        #expect(outcome == .applied(configGeneration: 2))
        #expect(h.spy.begins == [h.media], "The edit made the scheduler check that rule")
    }

    @Test func v5_aReviewedRuleThatIsResumedIsCheckedAtOnceAndAnEnableTooAndAStaleEditIsNot() async throws {
        let h = try await AutomaticDownloadsHarness()
        let id = try await enableViaFacade(h)
        try h.script(1...2)
        try await h.pool.write { db in
            try db.execute(
                sql: "UPDATE seriesSubscription SET state = 'paused', pauseReason = 'restored', configGeneration = 2 WHERE id = ?",
                arguments: [id]
            )
        }
        h.scheduler.setActive(true)
        await h.scheduler.untilIdle()
        #expect(h.spy.begins.isEmpty, "A paused rule is not checked")

        let stale = try await h.facade.edit(SubscriptionEdit(
            subscriptionId: id, expectedConfigGeneration: 1, configuration: SubscriptionConfiguration()
        ))
        #expect(stale == .stale)
        await h.scheduler.untilIdle()
        #expect(h.spy.begins.isEmpty, "A refused change triggers nothing")

        let resumed = try await h.facade.resume(SubscriptionResumeRequest(
            subscriptionId: id, expectedConfigGeneration: 2, reviewedSourceEpoch: OfflineStoreFixture.epoch,
            configuration: SubscriptionConfiguration()
        ))
        await h.scheduler.untilIdle()

        #expect(resumed == .resumed(configGeneration: 3))
        #expect(h.spy.begins == [h.media])
        let rule = try await h.fixture.store.subscription(for: h.media)
        #expect(rule?.state == .enabled && rule?.lastAttemptAt != nil, "Its first chapter list was taken")
        #expect(try await h.fixture.store.jobs().isEmpty, "Resuming and the first check queue nothing")
    }
}
