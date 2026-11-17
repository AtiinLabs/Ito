import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// What the notifier asks of the app: whether it is in the foreground and whether the person turned the setting on.
@MainActor
private final class NotifierSwitches {
    var isForeground = false
    var isEnabled = false
}

/// V9 to V12: attention notifications are claimed once per event whether or not they can be posted, posted only when the
/// person opted in, the system allows it and the app is not open, one per rule, and removed once they are no longer true.
@MainActor
struct SubscriptionAttentionNotifierTests {
    private typealias Fixture = SubscriptionLedgerFixture
    private let groupA = (id: "ga", name: "A")
    private let groupB = (id: "gb", name: "B")

    private struct Scenario {
        let f: Fixture
        let ruleId: String
        let system: FakeNotificationSystem
        let switches: NotifierSwitches
        let notifier: SubscriptionAttentionNotifier
        /// The outcome of the check that raised the first event that waits for a choice.
        let first: SubscriptionCommitOutcome
    }

    /// A rule that asks before switching groups, whose first new chapter exists only from the other group: one event
    /// waits for a choice.
    private func scenario(authorized: Bool = true) async throws -> Scenario {
        let f = try await Fixture()
        let askA = EditionSelection.preferred(primary: ScanlatorRef(id: "ga", name: "A"), fallback: .ask)
        let ruleId = try await f.enable(SubscriptionConfiguration(selection: askA)).id
        try await f.check(Fixture.numbered(1...3, scanlator: groupA))
        let first = try await f.check(base + [Fixture.chapter("c4b", unit: "u4", order: 40, group: groupB)])
        let system = FakeNotificationSystem(authorized: authorized)
        let switches = NotifierSwitches()
        let store = f.store
        let notifier = SubscriptionAttentionNotifier(
            system: system,
            claim: { now in try await store.claimSubscriptionAttention(now: now) },
            readStates: { try await store.subscriptionAttentionStates() },
            isForeground: { switches.isForeground },
            isEnabled: { switches.isEnabled },
            now: { OfflineStoreFixture.fixedDate }
        )
        return Scenario(f: f, ruleId: ruleId, system: system, switches: switches, notifier: notifier, first: first)
    }

    private var base: [Chapter] { Fixture.numbered(1...3, scanlator: groupA) }

    private func notifiedAt(_ f: Fixture) async throws -> [Date?] {
        try await f.pool.read { db in
            try SubscriptionEventRecord.filter(Column("kind") == "newPosition").order(Column("ordinal"), Column("id"))
                .fetchAll(db).map(\.notifiedAt)
        }
    }

    // MARK: - V9: opted out

    @Test func v9_aCommitWhileNotOptedInClaimsTheEventAndPostsNothingAndTurningItOnLaterNeverFloods() async throws {
        let s = try await scenario()
        #expect(s.first.needsAttentionEventIds.count == 1)
        #expect(try await notifiedAt(s.f) == [nil])

        await s.notifier.didCommit(s.first)

        #expect(try await notifiedAt(s.f) == [OfflineStoreFixture.fixedDate], "The decision to notify was taken")
        #expect(s.system.posts.isEmpty)

        // The person turns the setting on; the same event is not announced.
        s.switches.isEnabled = true
        await s.notifier.didCommit(s.first)
        #expect(s.system.posts.isEmpty)
    }

    @Test func aCommitWithNothingThatWaitsForAPersonClaimsNothing() async throws {
        let s = try await scenario()
        await s.notifier.didCommit(SubscriptionCommitOutcome(.advanced))
        #expect(try await notifiedAt(s.f) == [nil], "No claim is made for an outcome that raised nothing")
        #expect(s.system.posts.isEmpty)
    }

    // MARK: - V10: opted in, authorized, in the background

    @Test func v10_oneNotificationPerRuleWithTheRulesIdentifierAReplayPostsNothingAndASecondEventReplacesIt() async throws {
        let s = try await scenario()
        s.switches.isEnabled = true

        await s.notifier.didCommit(s.first)
        #expect(s.system.posts.count == 1)
        let post = try #require(s.system.posts.first)
        #expect(post.identifier == "ito.subscription.attention.\(s.ruleId)")
        #expect(post.threadIdentifier == "AutomaticDownloads")
        #expect(post.payload == SubscriptionAttentionPayload(subscriptionId: s.ruleId, incarnation: 1, configGeneration: 1))
        #expect(post.body.contains("Series"), "The body names the series")
        #expect(post.body.contains("1 item that needs your decision"))

        // The same commit again: the event was claimed, so nothing is posted.
        await s.notifier.didCommit(s.first)
        #expect(s.system.posts.count == 1)

        // A second event of the same rule: one more post with the same identifier, which replaces the first.
        let second = try await s.f.check(
            base + [Fixture.chapter("c4b", unit: "u4", order: 40, group: groupB), Fixture.chapter("c5b", unit: "u5", order: 50, group: groupB)]
        )
        #expect(second.needsAttentionEventIds.count == 1)
        await s.notifier.didCommit(second)
        #expect(s.system.posts.count == 2)
        #expect(s.system.posts[1].identifier == post.identifier)
        #expect(s.system.posts[1].body.contains("2 items that need your decision"))
        #expect(s.system.shown.count == 1, "The second notification replaced the first")
    }

    @Test func aSystemThatDoesNotAllowNotificationsStillGetsTheClaimButNoPost() async throws {
        let s = try await scenario(authorized: false)
        s.switches.isEnabled = true

        await s.notifier.didCommit(s.first)

        #expect(s.system.posts.isEmpty)
        #expect(try await notifiedAt(s.f) == [OfflineStoreFixture.fixedDate])
    }

    // MARK: - V11: in the foreground

    @Test func v11_aForegroundCommitClaimsTheEventAndPostsNothingBecauseTheScreensShowIt() async throws {
        let s = try await scenario()
        s.switches.isEnabled = true
        s.switches.isForeground = true

        await s.notifier.didCommit(s.first)

        #expect(try await notifiedAt(s.f) == [OfflineStoreFixture.fixedDate])
        #expect(s.system.posts.isEmpty)
    }

    // MARK: - V12: the sweep

    private func rows(_ f: Fixture) async throws -> [SubscriptionRuleRow] {
        try await f.pool.read { db in try SubscriptionRuleReadModel.read(db, quotaBytes: Int64.max) }
    }

    private func deliveredScenario() async throws -> Scenario {
        let s = try await scenario()
        s.switches.isEnabled = true
        await s.notifier.didCommit(s.first)
        #expect(s.system.shown.count == 1)
        return s
    }

    @Test func v12_aRuleThatStillMatchesKeepsItsNotification() async throws {
        let s = try await deliveredScenario()
        await s.notifier.sweep()
        #expect(s.system.shown.count == 1)
        #expect(s.system.removals.isEmpty)
    }

    @Test func v12_resolvingTheLastWaitingEventRemovesTheNotification() async throws {
        let s = try await deliveredScenario()
        let event = try #require(try await s.f.events(.newPosition).first)
        let rule = try await s.f.subscription()
        _ = try await s.f.store.resolveSubscriptionEvent(
            SubscriptionEventResolution(
                eventId: event.id, incarnation: rule.incarnation, configGeneration: rule.configGeneration,
                candidateRevision: event.candidateRevision, action: .dismiss
            ),
            limits: Fixture.roomy
        )

        let current = try await rows(s.f)
        #expect(current.first?.attentionCount == 0)
        await s.notifier.sweep()

        #expect(s.system.shown.isEmpty)
        #expect(s.system.removals == [["ito.subscription.attention.\(s.ruleId)"]])
        #expect(s.system.pendingRemovals == s.system.removals, "A pending request for it goes too")
    }

    @Test func v12_anEditThatChangesTheGenerationRemovesTheNotification() async throws {
        let s = try await deliveredScenario()
        let rule = try await s.f.subscription()
        let outcome = try await s.f.store.editSubscription(SubscriptionEdit(
            subscriptionId: rule.id, expectedConfigGeneration: rule.configGeneration,
            configuration: SubscriptionConfiguration(perRunPositionCap: 3, selection: rule.decodedSelection ?? .sourceList)
        ))
        #expect(outcome == .applied(configGeneration: rule.configGeneration + 1))

        let current = try await rows(s.f)
        #expect(current.first?.configGeneration == rule.configGeneration + 1)
        await s.notifier.sweep()

        #expect(s.system.shown.isEmpty)
    }

    @Test func v12_turningTheRuleOffRemovesTheNotification() async throws {
        let s = try await deliveredScenario()
        _ = try await s.f.store.disableSubscription(id: s.ruleId)

        await s.notifier.sweep()

        #expect(s.system.shown.isEmpty)
    }

    @Test func v12_aRuleThatARestoreReplacedRemovesTheNotification() async throws {
        let s = try await deliveredScenario()
        // A restore re-creates the rule as a new incarnation.
        try await s.f.write { db in
            try db.execute(sql: "UPDATE seriesSubscription SET incarnation = incarnation + 1, configGeneration = configGeneration + 1")
        }
        await s.notifier.sweep()
        #expect(s.system.shown.isEmpty)
    }

    @Test func v12_aRuleThatIsGoneRemovesTheNotification() async throws {
        let s = try await deliveredScenario()
        try await s.f.write { db in
            try db.execute(sql: "DELETE FROM subscriptionEvent")
            try db.execute(sql: "DELETE FROM subscriptionSeenKey")
            try db.execute(sql: "DELETE FROM subscriptionBaseline")
            try db.execute(sql: "DELETE FROM seriesSubscription")
        }
        await s.notifier.sweep()
        #expect(s.system.shown.isEmpty)
    }

    @Test func aSweepJudgesByTheStoreWhenItRunsSoANotificationPostedJustBeforeItStays() async throws {
        let s = try await scenario()
        s.switches.isEnabled = true
        // The sweep reads the rule when it runs, after the claim and the post: it never judges by an older picture.
        await s.notifier.didCommit(s.first)
        await s.notifier.sweep()
        #expect(s.system.shown.count == 1)
        await s.notifier.sweep()
        #expect(s.system.shown.count == 1, "A sweep that reads the same rule again removes nothing valid")
    }

    @Test func aSweepThatCannotReadTheRulesRemovesNothing() async throws {
        let s = try await deliveredScenario()
        let failing = SubscriptionAttentionNotifier(
            system: s.system,
            claim: { _ in [] },
            readStates: { throw CocoaError(.fileReadUnknown) },
            isForeground: { false }, isEnabled: { true }
        )
        await failing.sweep()
        #expect(s.system.shown.count == 1)
        #expect(s.system.removals.isEmpty)
    }

    @Test func theSweepInTheForegroundClaimsWhatWaitsSilentlyAndInTheBackgroundLeavesItForThePost() async throws {
        let s = try await scenario()
        s.switches.isEnabled = true

        // In the background a sweep must not swallow what the commit has yet to post.
        await s.notifier.sweep()
        #expect(try await notifiedAt(s.f) == [nil])

        s.switches.isForeground = true
        await s.notifier.sweep()

        #expect(try await notifiedAt(s.f) == [OfflineStoreFixture.fixedDate])
        #expect(s.system.posts.isEmpty)
    }

    @Test func aClaimMadeForARuleThatIsNoLongerEnabledOrIsPausedIsNeverMade() async throws {
        let s = try await scenario()
        _ = try await s.f.store.pauseSubscription(id: s.ruleId)

        let claims = try await s.f.store.claimSubscriptionAttention(now: OfflineStoreFixture.fixedDate)

        #expect(claims.isEmpty)
        #expect(try await notifiedAt(s.f) == [nil])
    }

    @Test func theClaimReturnsOneEntryPerRuleWithWhatIsNewAndWhatWaits() async throws {
        let s = try await scenario()
        let first = try await s.f.store.claimSubscriptionAttention(now: OfflineStoreFixture.fixedDate)
        #expect(first == [SubscriptionAttentionClaim(
            subscriptionId: s.ruleId, title: "Series", incarnation: 1, configGeneration: 1, newlyClaimed: 1, openAttention: 1
        )])
        #expect(try await s.f.store.claimSubscriptionAttention(now: OfflineStoreFixture.fixedDate).isEmpty)

        _ = try await s.f.check(
            base + [Fixture.chapter("c4b", unit: "u4", order: 40, group: groupB), Fixture.chapter("c5b", unit: "u5", order: 50, group: groupB)]
        )
        let second = try await s.f.store.claimSubscriptionAttention(now: OfflineStoreFixture.fixedDate)
        #expect(second.first?.newlyClaimed == 1 && second.first?.openAttention == 2)
    }
}
