import Foundation

// What a caller asks of the subscription entry points of `OfflineChapterStore`, and what it gets back. The store
// never fetches anything: every observation, epoch and limit is handed in.

/// The most automatic work one subscription may add to the queue and the disk. The queue limit counts jobs of every
/// owner; the quota counts stored bytes plus an estimate for each outstanding automatic-only job.
nonisolated struct AutomaticDownloadLimits: Sendable, Equatable {
    /// What one job is assumed to need until it is stored. A fixed constant, not a setting.
    static let estimatedJobBytes: Int64 = 32 * 1024 * 1024
    static let bytesPerGiB: Int64 = 1 << 30

    let queueLimit: Int
    let quotaBytes: Int64
    let estimatedJobBytes: Int64

    init(queueLimit: Int, quotaBytes: Int64, estimatedJobBytes: Int64 = Self.estimatedJobBytes) {
        self.queueLimit = queueLimit
        self.quotaBytes = quotaBytes
        self.estimatedJobBytes = estimatedJobBytes
    }

    init(queueLimit: Int, quotaGiB: Int) {
        self.init(queueLimit: queueLimit, quotaBytes: Int64(quotaGiB) * Self.bytesPerGiB)
    }

    /// The limits of a fresh installation.
    static let standard = AutomaticDownloadLimits(
        queueLimit: AppPreferenceCatalog.automaticDownloadQueueLimit.defaultValue,
        quotaGiB: AppPreferenceCatalog.automaticDownloadQuotaGiB.defaultValue
    )
}

/// The user-chosen behaviour of one subscription.
nonisolated struct SubscriptionConfiguration: Sendable, Equatable {
    static let defaultPerRunPositionCap = 5
    static let perRunPositionCapRange = 1...20
    static let windowSizeRange = 1...100

    var mode: SubscriptionMode
    /// Required exactly in `maintainNextUnread`.
    var windowSize: Int?
    var perRunPositionCap: Int
    var selection: EditionSelection
    var replacementRule: SubscriptionReplacementRule

    init(
        mode: SubscriptionMode = .newReleases,
        windowSize: Int? = nil,
        perRunPositionCap: Int = SubscriptionConfiguration.defaultPerRunPositionCap,
        selection: EditionSelection = .sourceList,
        replacementRule: SubscriptionReplacementRule = .off
    ) {
        self.mode = mode
        self.windowSize = windowSize
        self.perRunPositionCap = perRunPositionCap
        self.selection = selection
        self.replacementRule = replacementRule
    }

    /// Whether the database would accept it: the window size and the mode agree, and the limits are in range.
    var isValid: Bool {
        guard Self.perRunPositionCapRange.contains(perRunPositionCap) else { return false }
        switch mode {
        case .maintainNextUnread: return windowSize.map { Self.windowSizeRange.contains($0) } ?? false
        case .newReleases, .newAndFillUnread: return windowSize == nil
        }
    }
}

nonisolated enum SubscriptionRefusal: Equatable, Sendable {
    case unsupportedKind
    /// The source's settings or account changed after the rule was reviewed.
    case sourceChanged
    case seriesNotSaved
    case invalidConfiguration
}

nonisolated struct SubscriptionEnableRequest: Sendable {
    let media: MediaIdentity
    /// The source epoch the rule was reviewed under; the store verifies it in its write transaction.
    let reviewedSourceEpoch: String
    let configuration: SubscriptionConfiguration
}

nonisolated enum SubscriptionEnableOutcome: Equatable, Sendable {
    /// The rule exists, waiting for its first baseline. No event and no job was created.
    case enabled(id: String, incarnation: Int64)
    case alreadyExists(id: String)
    case refused(SubscriptionRefusal)
}

/// One scheduled check of one subscription. Only the check that holds the newest ticket can move the baseline.
nonisolated struct SubscriptionCheckTicket: Sendable, Equatable {
    let subscriptionId: String
    let media: MediaIdentity
    let incarnation: Int64
    let ticket: Int64
    /// The source epoch captured before the fetch; the fetch freezes it and the commit verifies it.
    let sourceEpoch: String
}

/// Why a resolution, approval or edit changed nothing.
nonisolated enum SubscriptionResolutionRefusal: Equatable, Sendable {
    /// A generation, revision or digest the caller held is no longer the stored one.
    case stale
    case eventNotOpen
    /// A key is not one of the event's candidates, or not in the accepted catalog.
    case invalidKeys
    /// The subscription is missing, disabled or paused, or has no accepted baseline.
    case unavailable
    case unsupportedMode
}

nonisolated struct SubscriptionCommitOutcome: Sendable, Equatable {
    var outcome: SubscriptionCheckOutcome
    /// Set when a resolution, approval or drain changed nothing; `outcome` is then `.superseded`.
    var refusal: SubscriptionResolutionRefusal?
    var createdEventIds: [String] = []
    /// Open events that now wait for a person: `needsReview` and `needsChoice`.
    var needsAttentionEventIds: [String] = []
    var queuedJobs = 0
    var attachedJobs = 0
    var pendingCount = 0

    init(_ outcome: SubscriptionCheckOutcome, refusal: SubscriptionResolutionRefusal? = nil) {
        self.outcome = outcome
        self.refusal = refusal
    }
}

nonisolated struct SubscriptionEdit: Sendable {
    let subscriptionId: String
    let expectedConfigGeneration: Int64
    let configuration: SubscriptionConfiguration
}

nonisolated enum SubscriptionEditOutcome: Equatable, Sendable {
    /// The edit is stored. Events that waited are decided again by the next check or drain.
    case applied(configGeneration: Int64)
    case stale
    case unavailable
    case invalidConfiguration
}

/// What resuming a paused rule asks. A rule paused by a restore or a source change has no baseline, no events and no
/// owners: the person reviews it first, so the review (the configuration shown and the source epoch it was shown under)
/// is part of the request. A rule the person paused is resumed as it was.
nonisolated struct SubscriptionResumeRequest: Sendable {
    let subscriptionId: String
    /// The generation the person saw; a restore, an edit or a disable since then makes the request stale.
    let expectedConfigGeneration: Int64
    /// Required for a rule paused by a restore or a source change; the store verifies it in its write transaction.
    let reviewedSourceEpoch: String?
    /// Required for a rule paused by a restore or a source change: the reviewed rule. Nil for a rule the person paused.
    let configuration: SubscriptionConfiguration?
}

nonisolated enum SubscriptionResumeOutcome: Equatable, Sendable {
    /// The rule is enabled. A reviewed rule starts over, waiting for its first baseline, under the new generation.
    case resumed(configGeneration: Int64)
    case stale
    /// A rule paused by a restore or a source change needs the configuration and the epoch of a review; a rule the
    /// person paused is edited by an edit, not by a resume.
    case reviewRequired
    case sourceChanged
    case seriesNotSaved
    case invalidConfiguration
    /// The rule is missing or is not paused.
    case unavailable
}

nonisolated struct SubscriptionEventResolution: Sendable {
    enum Action: Sendable, Equatable {
        case approve(keys: [String])
        case dismiss
    }

    let eventId: String
    let incarnation: Int64
    let configGeneration: Int64
    /// The candidate list revision the reviewer saw; a new alternate invalidates it.
    let candidateRevision: Int64
    let action: Action
}

nonisolated struct SubscriptionBackfillApproval: Sendable {
    let subscriptionId: String
    let incarnation: Int64
    let configGeneration: Int64
    let baselineRevision: Int64
    let catalogDigest: String
    /// The reviewed positions, each as its exact keys in reading order.
    let positions: [[String]]
}

/// What releasing a subscription removed: the jobs that had no other owner left.
nonisolated struct SubscriptionRelease: Sendable, Equatable {
    var removedJobIds: [String] = []
    var stagingVersionIds: [String] = []
}
