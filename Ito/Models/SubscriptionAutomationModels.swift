import Foundation

// What the screens of automatic downloads read. Every value is plain data, built from the ledger's tables by a read
// that writes nothing and asks no source for anything.

/// Why a job that waits in the queue does not start, as the rule behind it explains it.
nonisolated enum DownloadHoldReason: Equatable, Hashable, Sendable {
    /// Every rule that asked for the job is paused, turned off or replaced.
    case automaticRulePaused
    /// The stored bytes reached the space automatic downloads may fill.
    case automaticSpaceFull
    /// The path is metered, and automatic downloads use it only when Settings allows that.
    case automaticMeteredNotAllowed
}

/// One automatic rule of one series with what a screen says about it: the rule, the outcome of its last check, and
/// what its events and jobs are doing now.
nonisolated struct SubscriptionRuleRow: Identifiable, Equatable, Sendable {
    let id: String
    let media: MediaIdentity
    /// The Library item's title, which is source content and is shown as it is.
    let title: String?
    let state: SubscriptionState
    let pauseReason: SubscriptionPauseReason?
    /// Nil when the stored choice of groups cannot be read by this build.
    let configuration: SubscriptionConfiguration?
    let incarnation: Int64
    let configGeneration: Int64
    let hasBaseline: Bool
    let baselineAcceptedAt: Date?
    let lastAttemptAt: Date?
    let lastAttemptOutcome: SubscriptionCheckOutcome?
    let lastSuccessAt: Date?
    /// Open events that wait for a person: `needsChoice` and `needsReview`.
    let attentionCount: Int
    /// Open events that wait, by why.
    let pending: [SubscriptionPendingReason: Int]
    /// Jobs of this rule that wait, run or are queued. A failed job is not counted.
    let queuedJobs: Int
    /// Queued jobs only automatic work asked for that the queue holds back.
    let heldJobs: Int
    let heldReason: DownloadHoldReason?
    /// Whether the rule's source is installed. The read of the tables cannot know it; the facade sets it.
    var sourceInstalled: Bool

    /// The key the attention notification of this rule is valid for: it changes with every edit, replacement and
    /// resolution that changes what a notification would say.
    var attentionKey: SubscriptionAttentionKey {
        SubscriptionAttentionKey(
            subscriptionId: id, incarnation: incarnation, configGeneration: configGeneration,
            isEnabled: state == .enabled, attentionCount: attentionCount
        )
    }
}

/// What decides whether a delivered attention notification is still true.
nonisolated struct SubscriptionAttentionKey: Equatable, Hashable, Sendable {
    let subscriptionId: String
    let incarnation: Int64
    let configGeneration: Int64
    let isEnabled: Bool
    let attentionCount: Int
}

/// One chapter row a review shows. Group, number and title are source content.
nonisolated struct SubscriptionCandidateRow: Identifiable, Equatable, Sendable {
    let key: String
    let title: String?
    let number: Float?
    let volume: Float?
    let scanlator: String?
    let isLocked: Bool

    var id: String { key }
}

/// One open event of a rule that waits for a person, with the rows it is about.
nonisolated struct SubscriptionEventReview: Identifiable, Equatable, Sendable {
    let eventId: String
    let kind: SubscriptionEventKind
    let identityKind: SubscriptionIdentityKind
    let decision: SubscriptionDecision
    let reviewReason: SubscriptionReviewReason?
    let candidates: [SubscriptionCandidateRow]
    let incarnation: Int64
    let configGeneration: Int64
    let candidateRevision: Int64

    var id: String { eventId }

    /// Whether the person may approve rows of this event. A catalog anomaly, a review of the whole window (its
    /// identity is the catalog, not a position) and an alternate are only dismissed: the store refuses to approve them.
    var canApprove: Bool {
        guard identityKind != .catalog, !candidates.isEmpty else { return false }
        switch kind {
        case .catalogAnomaly, .newAlternate: return false
        case .newPosition, .revisionChanged, .unplacedKey, .backfill, .window: return true
        }
    }
}

/// The open events of one rule, at most `limit` of them, with how many there are in all.
nonisolated struct SubscriptionAttention: Equatable, Sendable {
    static let limit = 200

    let events: [SubscriptionEventReview]
    let totalCount: Int
}

/// What approving unread chapters would queue, read without writing anything. The approval checks every binding
/// again, so a preview that has gone stale queues nothing.
nonisolated struct SubscriptionBackfillPreview: Equatable, Sendable {
    static let positionLimit = 500

    let subscriptionId: String
    let incarnation: Int64
    let configGeneration: Int64
    let baselineRevision: Int64
    let catalogDigest: String
    /// Exact keys of each position, in reading order. At most `positionLimit`.
    let positions: [[String]]
    /// Positions past the limit; approving again after these are queued shows the next ones.
    let truncatedCount: Int
    let issues: Set<DownloadPlanIssue>
    /// What the sheet shows of each key.
    let rows: [String: SubscriptionCandidateRow]
}

nonisolated enum SubscriptionBackfillRefusal: Error, Equatable, Sendable {
    /// The rule is missing, is not enabled or has no accepted catalog yet.
    case unavailable
    /// The rule does not fill unread chapters.
    case unsupportedMode
    /// The series' read markers are chapter numbers only, which never say which exact row was read.
    case numberOnlyReadState
    /// The accepted catalog cannot be read back.
    case catalogUnreadable
    /// The rule's choice of groups cannot be read by this build.
    case selectionUnreadable
}

/// An open attention event after the notification decision: how many of a rule's events were claimed now and how many
/// wait in all.
nonisolated struct SubscriptionAttentionClaim: Equatable, Sendable {
    let subscriptionId: String
    let title: String?
    let incarnation: Int64
    let configGeneration: Int64
    let newlyClaimed: Int
    let openAttention: Int
}
