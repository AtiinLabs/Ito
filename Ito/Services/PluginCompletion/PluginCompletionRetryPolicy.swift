import Foundation

/// Bounded automatic retry schedule for transient delivery failures (network or server errors).
///
/// The store applies this when a retryable outcome is recorded, so the schedule is durable: it
/// survives relaunches and is measured from the failure, not from when the app next runs.
nonisolated enum PluginCompletionRetryPolicy {
    /// Seconds to wait after the first, second, ... completed transient failure.
    static let delays: [TimeInterval] = [15, 60, 300, 1_800, 7_200]

    /// The wait before the next automatic attempt after `failures` completed transient failures,
    /// counting the one that just ended, or nil once the budget is spent and the intent must pause
    /// for the user (`retryLimit`). Counts below one are not a completed failure and get no retry.
    static func delay(afterCompletedFailures failures: Int) -> TimeInterval? {
        guard failures >= 1, failures <= delays.count else { return nil }
        return delays[failures - 1]
    }
}
