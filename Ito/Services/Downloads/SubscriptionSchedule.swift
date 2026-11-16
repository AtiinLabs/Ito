import Foundation

/// What the scheduler reads about one rule to decide whether it is due: no evidence table, no baseline.
nonisolated struct SubscriptionScheduleRow: Sendable, Equatable {
    let id: String
    let media: MediaIdentity
    let state: SubscriptionState
    let lastAttemptAt: Date?
    let lastAttemptOutcome: SubscriptionCheckOutcome?
}

/// When a rule is next due, and which rules one pass takes. Pure: the clock is an argument, nothing is read or written.
///
/// The due time comes from the configured interval and the last attempt the ledger recorded. A check of any kind moves
/// the last attempt, so a series a person refreshed in the Library counts as checked, and a series that was just
/// checked goes behind the rest.
nonisolated enum SubscriptionSchedule {
    /// The most rules one pass checks. The pass that follows takes the next ones: oldest due first is the round robin.
    static let passLimit = 20
    /// The longest a failing or incomplete rule waits, whatever the interval.
    static let maximumBackoff: TimeInterval = 24 * 3_600

    /// When the rule is next due, or nil when it is not due until its configuration changes (an outcome that more
    /// checking cannot fix) or it is not enabled.
    ///
    /// - A rule never attempted (new, re-enabled, resumed after review, restored) is due now.
    /// - A rule the ledger cannot act on (unsupported kind, series not saved, unreadable selection) waits for an edit,
    ///   whatever its last attempt's time says.
    /// - Otherwise a last attempt in the future (the clock moved back) is due now.
    /// - A check that read a catalog waits one interval.
    /// - A failure, or a catalog the ledger could not accept, waits twice the interval, at most a day and at least
    ///   one interval, so a source that keeps failing is asked less often.
    static func dueDate(_ row: SubscriptionScheduleRow, interval: TimeInterval, now: Date) -> Date? {
        guard row.state == .enabled else { return nil }
        guard let last = row.lastAttemptAt, let outcome = row.lastAttemptOutcome else { return now }
        if blockedOutcomes.contains(outcome) { return nil }
        guard last <= now else { return now }
        switch outcome {
        case .unsupportedKind, .seriesNotSaved, .selectionUnreadable:
            return nil
        case .fetchFailed, .incompleteCatalog, .unknownScope, .emptyCatalog, .oversizedCatalog:
            return last.addingTimeInterval(max(interval, min(2 * interval, maximumBackoff)))
        case .baselineEstablished, .rebaselined, .advanced, .unchanged, .sourceChanged,
             .superseded, .paused, .disabled:
            return last.addingTimeInterval(interval)
        }
    }

    /// The outcomes more checking cannot fix: the rule waits for an edit.
    static let blockedOutcomes: Set<SubscriptionCheckOutcome> = [.unsupportedKind, .seriesNotSaved, .selectionUnreadable]

    /// The rules one pass checks: those due now and those a rule change `forced`, forced ones first, then the oldest due,
    /// ties by id, at most `passLimit`. A forced rule is taken even when it is not due, or is blocked. A rule the pass
    /// cannot check (`isEligible` false: its source is not installed, or needs the person) is left out before the limit
    /// is applied, so it never takes the place of one that can be checked.
    static func duePass(
        _ rows: [SubscriptionScheduleRow],
        forced: Set<String>,
        interval: TimeInterval,
        now: Date,
        isEligible: (SubscriptionScheduleRow) -> Bool = { _ in true }
    ) -> [SubscriptionScheduleRow] {
        struct Candidate {
            let row: SubscriptionScheduleRow
            let isForced: Bool
            let due: Date
        }
        var candidates: [Candidate] = []
        for row in rows where row.state == .enabled && isEligible(row) {
            let isForced = forced.contains(row.id)
            let due = dueDate(row, interval: interval, now: now)
            if let due, due <= now {
                candidates.append(Candidate(row: row, isForced: isForced, due: due))
            } else if isForced {
                // A rule the person just changed is checked now, however long it would otherwise wait.
                candidates.append(Candidate(row: row, isForced: true, due: min(due ?? now, now)))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.isForced != rhs.isForced { return lhs.isForced }
            if lhs.due != rhs.due { return lhs.due < rhs.due }
            return lhs.row.id < rhs.row.id
        }
        return candidates.prefix(passLimit).map(\.row)
    }
}
