import Foundation
import Testing
import ito_runner
@testable import Ito

/// The pure due-time rules of the foreground scheduler: no database, no clock read, no network.
struct SubscriptionScheduleTests {
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private static let hour: TimeInterval = 3_600
    private static let day: TimeInterval = 86_400

    private static func row(
        _ id: String,
        source: String = "p",
        state: SubscriptionState = .enabled,
        last: Date? = nil,
        outcome: SubscriptionCheckOutcome? = nil
    ) -> SubscriptionScheduleRow {
        SubscriptionScheduleRow(
            id: id,
            media: MediaIdentity(pluginId: source, canonicalMediaId: id, mediaKind: .manga),
            state: state,
            lastAttemptAt: last,
            lastAttemptOutcome: outcome
        )
    }

    // MARK: - dueDate

    /// A check that read a catalog waits one interval; a failure or an unacceptable catalog waits twice the interval,
    /// at most a day and at least one interval; a rule the ledger cannot act on waits for an edit.
    @Test(arguments: [3_600.0, 86_400.0])
    func everyOutcomeHasItsExactDueDateForAnOldAndARecentLastAttempt(interval: TimeInterval) {
        let old = Self.now.addingTimeInterval(-100 * Self.day)
        let recent = Self.now.addingTimeInterval(-10)
        let failureWait = interval == Self.hour ? 2 * Self.hour : Self.day

        let readCatalog: Set<SubscriptionCheckOutcome> = [
            .baselineEstablished, .rebaselined, .advanced, .unchanged, .sourceChanged
        ]
        let failed: Set<SubscriptionCheckOutcome> = [
            .fetchFailed, .incompleteCatalog, .unknownScope, .emptyCatalog, .oversizedCatalog
        ]
        let blocked: Set<SubscriptionCheckOutcome> = [.unsupportedKind, .seriesNotSaved, .selectionUnreadable]
        let other: Set<SubscriptionCheckOutcome> = [.superseded, .paused, .disabled]
        // Every recorded value is classified exactly once.
        #expect(readCatalog.union(failed).union(blocked).union(other) == Set(SubscriptionCheckOutcome.allCases))

        for outcome in SubscriptionCheckOutcome.allCases {
            for last in [old, recent] {
                let due = SubscriptionSchedule.dueDate(
                    Self.row("a", last: last, outcome: outcome), interval: interval, now: Self.now
                )
                if blocked.contains(outcome) {
                    #expect(due == nil)
                } else if failed.contains(outcome) {
                    #expect(due == last.addingTimeInterval(failureWait))
                } else {
                    #expect(due == last.addingTimeInterval(interval))
                }
            }
        }
    }

    @Test(arguments: [3_600.0, 86_400.0])
    func aRuleNeverAttemptedIsDueNowAndAClockMovedBackDoesNotDelayIt(interval: TimeInterval) {
        #expect(SubscriptionSchedule.dueDate(Self.row("a"), interval: interval, now: Self.now) == Self.now)
        let future = Self.now.addingTimeInterval(5_000)
        for outcome in SubscriptionCheckOutcome.allCases {
            let due = SubscriptionSchedule.dueDate(
                Self.row("a", last: future, outcome: outcome), interval: interval, now: Self.now
            )
            // A rule the ledger cannot act on waits for an edit, whatever the clock says.
            #expect(due == (SubscriptionSchedule.blockedOutcomes.contains(outcome) ? nil : Self.now))
        }
    }

    @Test func aRuleThePassCannotCheckNeverTakesThePlaceOfOneItCan() {
        let interval = 4 * Self.hour
        var rows = (0..<25).map { index in
            Self.row(String(format: "gone%02d", index), source: "gone", last: Self.now.addingTimeInterval(-50 * Self.day), outcome: .advanced)
        }
        let healthy = (0..<5).map { Self.row("ok\($0)", source: "p", last: Self.now.addingTimeInterval(-Self.day), outcome: .advanced) }
        rows += healthy

        #expect(SubscriptionSchedule.duePass(rows, forced: [], interval: interval, now: Self.now).allSatisfy { $0.media.pluginId == "gone" })
        let taken = SubscriptionSchedule.duePass(rows, forced: ["gone00"], interval: interval, now: Self.now) {
            $0.media.pluginId != "gone"
        }
        #expect(Set(taken.map(\.id)) == Set(healthy.map(\.id)))
    }

    @Test func aRuleThatIsNotEnabledIsNeverDue() {
        for state in [SubscriptionState.paused, .disabled] {
            let row = Self.row("a", state: state, last: Self.now.addingTimeInterval(-Self.day), outcome: .advanced)
            #expect(SubscriptionSchedule.dueDate(row, interval: Self.hour, now: Self.now) == nil)
            #expect(SubscriptionSchedule.duePass([row], forced: ["a"], interval: Self.hour, now: Self.now).isEmpty)
        }
    }

    @Test func aBlockedRuleIsOnlyTakenWhenAChangeForcedIt() {
        let blocked = Self.row("blocked", last: Self.now.addingTimeInterval(-Self.day), outcome: .selectionUnreadable)
        #expect(SubscriptionSchedule.duePass([blocked], forced: [], interval: Self.hour, now: Self.now).isEmpty)
        #expect(SubscriptionSchedule.duePass([blocked], forced: ["blocked"], interval: Self.hour, now: Self.now) == [blocked])
    }

    // MARK: - duePass

    @Test func aPassTakesTwentyOfThirtyDueRulesOldestFirstWithTiesByIdAndRepeatedPassesVisitAllThirty() {
        let interval = 4 * Self.hour
        // Four sources, thirty rules. Ten share the oldest attempt, so ties are decided by id; the rest are staggered.
        var rows: [SubscriptionScheduleRow] = (0..<30).map { index in
            let id = String(format: "r%02d", index)
            let age = index < 10 ? 50 * Self.day : Double(40 - index) * Self.day
            return Self.row(id, source: "source-\(index % 4)", last: Self.now.addingTimeInterval(-age), outcome: .advanced)
        }
        rows.shuffle()

        let first = SubscriptionSchedule.duePass(rows, forced: [], interval: interval, now: Self.now)
        #expect(first.count == SubscriptionSchedule.passLimit)
        // The ten oldest (equal age) come first, in id order; then the staggered ones, oldest first.
        #expect(first.prefix(10).map(\.id) == (0..<10).map { String(format: "r%02d", $0) })
        let ages = first.dropFirst(10).map { $0.lastAttemptAt }
        #expect(ages == ages.sorted { ($0 ?? .distantPast) < ($1 ?? .distantPast) })

        // A check moves the last attempt, so the checked rules go to the back and the next pass takes the others.
        var visited = Set(first.map(\.id))
        rows = rows.map { row in
            first.contains(where: { $0.id == row.id })
                ? Self.row(row.id, source: row.media.pluginId, last: Self.now, outcome: .advanced)
                : row
        }
        let second = SubscriptionSchedule.duePass(rows, forced: [], interval: interval, now: Self.now)
        #expect(second.count == 10)
        #expect(visited.isDisjoint(with: second.map(\.id)))
        visited.formUnion(second.map(\.id))
        #expect(visited.count == 30)

        rows = rows.map { row in
            second.contains(where: { $0.id == row.id })
                ? Self.row(row.id, source: row.media.pluginId, last: Self.now, outcome: .advanced)
                : row
        }
        #expect(SubscriptionSchedule.duePass(rows, forced: [], interval: interval, now: Self.now).isEmpty)
    }

    @Test func aRuleThatIsNotYetDueWaitsAndAForcedOneGoesFirstEvenBehindAFullPass() {
        let interval = 4 * Self.hour
        var rows = (0..<25).map { index in
            Self.row(String(format: "d%02d", index), last: Self.now.addingTimeInterval(-Self.day), outcome: .advanced)
        }
        let notDue = Self.row("zz", last: Self.now.addingTimeInterval(-60), outcome: .advanced)
        rows.append(notDue)

        let plain = SubscriptionSchedule.duePass(rows, forced: [], interval: interval, now: Self.now)
        #expect(!plain.contains(notDue))
        #expect(plain.count == SubscriptionSchedule.passLimit)

        let forced = SubscriptionSchedule.duePass(rows, forced: ["zz"], interval: interval, now: Self.now)
        #expect(forced.first == notDue)
        #expect(forced.count == SubscriptionSchedule.passLimit)
    }

    @Test func aFailingRuleIsAskedLessOftenThanAHealthyOne() {
        let interval = 4 * Self.hour
        let last = Self.now.addingTimeInterval(-5 * Self.hour)
        let healthy = Self.row("a", last: last, outcome: .advanced)
        let failing = Self.row("b", last: last, outcome: .fetchFailed)
        // Five hours ago: one interval has passed, twice the interval has not.
        #expect(SubscriptionSchedule.duePass([healthy, failing], forced: [], interval: interval, now: Self.now) == [healthy])
    }
}
