import Foundation

/// What a decision about downloads said, in the store's own words. A screen shows this and nothing it merely asked for:
/// a refusal is never reported as a success, and chapters that wait are never reported as coming.
nonisolated enum SubscriptionCommitReport: Equatable, Sendable {
    /// Jobs were queued.
    case queued(Int)
    /// Nothing new was queued, but the chapters are already queued for another request or rule.
    case alreadyQueued
    /// Nothing was queued yet: the queue or the disk space is full, and the chapters wait for room.
    case waitingForRoom
    /// Nothing was queued: the chapters are saved already, deleted on purpose, locked or damaged.
    case nothingToQueue
    /// A generation, revision or digest the person saw is no longer the stored one.
    case changedSinceOpened
    case notAvailable
    case invalidChoice
    case notSupported
    case sourceChanged
    case selectionUnreadable
    case catalogUnreadable

    init(_ outcome: SubscriptionCommitOutcome) {
        if let refusal = outcome.refusal {
            switch refusal {
            case .stale, .eventNotOpen: self = .changedSinceOpened
            case .invalidKeys: self = .invalidChoice
            case .unavailable: self = .notAvailable
            case .unsupportedMode: self = .notSupported
            }
            return
        }
        switch outcome.outcome {
        case .sourceChanged: self = .sourceChanged
        case .selectionUnreadable: self = .selectionUnreadable
        case .incompleteCatalog, .unknownScope, .emptyCatalog, .oversizedCatalog: self = .catalogUnreadable
        case .paused, .disabled, .seriesNotSaved, .unsupportedKind, .superseded, .fetchFailed: self = .notAvailable
        case .baselineEstablished, .rebaselined, .advanced, .unchanged:
            if outcome.queuedJobs > 0 {
                self = .queued(outcome.queuedJobs)
            } else if outcome.attachedJobs > 0 {
                self = .alreadyQueued
            } else if outcome.pendingCount > 0 {
                self = .waitingForRoom
            } else {
                self = .nothingToQueue
            }
        }
    }

    /// Whether the decision changed anything the person asked for.
    var isRefusal: Bool {
        switch self {
        case .queued, .alreadyQueued, .waitingForRoom, .nothingToQueue: false
        case .changedSinceOpened, .notAvailable, .invalidChoice, .notSupported, .sourceChanged, .selectionUnreadable,
             .catalogUnreadable: true
        }
    }

    /// Whether what was shown is out of date and must be read again.
    var needsReload: Bool {
        switch self {
        case .changedSinceOpened, .invalidChoice, .sourceChanged, .notAvailable: true
        case .queued, .alreadyQueued, .waitingForRoom, .nothingToQueue, .notSupported, .selectionUnreadable,
             .catalogUnreadable: false
        }
    }

    var text: String {
        switch self {
        case .queued(let count):
            String(localized: "\(count) chapters queued.", comment: "Automatic downloads: how many chapters were queued after the person approved them. The placeholder is a count.")
        case .alreadyQueued:
            String(localized: "These chapters are already queued.", comment: "Automatic downloads: the approved chapters were already in the queue")
        case .waitingForRoom:
            String(localized: "Nothing was queued yet. The chapters wait for room in the queue or on the disk.", comment: "Automatic downloads: the queue or the space for automatic downloads is full, so approved chapters wait")
        case .nothingToQueue:
            String(localized: "Nothing was queued. These chapters are saved already, were deleted on purpose, or are locked.", comment: "Automatic downloads: approved chapters needed no download")
        case .changedSinceOpened:
            String(localized: "This changed since you opened it. It was reloaded, so look again.", comment: "Automatic downloads: what the person was reviewing changed, so nothing was done")
        case .notAvailable:
            String(localized: "This is no longer available. It was reloaded.", comment: "Automatic downloads: the rule or event the person was reviewing is gone or paused, so nothing was done")
        case .invalidChoice:
            String(localized: "Those chapters can't be approved any more. It was reloaded, so look again.", comment: "Automatic downloads: chosen chapters are no longer part of the event, so nothing was done")
        case .notSupported:
            String(localized: "This rule does not download unread chapters.", comment: "Automatic downloads: the rule's mode does not support the requested action")
        case .sourceChanged:
            String(localized: "The source's settings changed, so nothing was queued. Check the rule and try again.", comment: "Automatic downloads: the source's settings or account changed, so nothing was done")
        case .selectionUnreadable:
            String(localized: "The group choice of this rule can't be read, so nothing was queued. Edit the rule.", comment: "Automatic downloads: the rule's saved group choice is unreadable, so nothing was done")
        case .catalogUnreadable:
            String(localized: "The saved chapter list can't be used, so nothing was queued. Wait for the next check.", comment: "Automatic downloads: the accepted chapter list cannot be used, so nothing was done")
        }
    }
}

/// Fixed messages about a rule, for what its sheet could not do.
nonisolated enum SubscriptionRuleMessage: Equatable, Sendable {
    case stale
    case sourceChanged
    case seriesNotSaved
    case reviewRequired
    case invalidConfiguration
    case unavailable
    case alreadyExists
    case unsupportedKind
    case failed

    var text: String {
        switch self {
        case .stale:
            String(localized: "This rule changed since you opened it. It was reloaded, so review it again.", comment: "Automatic downloads: the rule changed while its sheet was open, so nothing was saved")
        case .sourceChanged:
            String(localized: "The source's settings changed since you opened this. Review the rule again.", comment: "Automatic downloads: the source's settings or account changed while the sheet was open, so nothing was saved")
        case .seriesNotSaved:
            String(localized: "This series is no longer in your Library.", comment: "Automatic downloads: the series was removed from the Library, so a rule cannot be saved")
        case .reviewRequired:
            String(localized: "Review this rule before turning it on.", comment: "Automatic downloads: a rule that came back from a backup or a source change must be reviewed before it runs")
        case .invalidConfiguration:
            String(localized: "These settings can't be used. Check them and try again.", comment: "Automatic downloads: the rule's settings were refused")
        case .unavailable:
            String(localized: "This rule is no longer available. It was reloaded.", comment: "Automatic downloads: the rule is gone or is not in the state the action needs")
        case .alreadyExists:
            String(localized: "This series already has a rule. It was reloaded.", comment: "Automatic downloads: a rule for the series exists already, so a new one was not made")
        case .unsupportedKind:
            String(localized: "Automatic downloads are not available for this kind of series.", comment: "Automatic downloads: only manga and novels have automatic downloads")
        case .failed:
            String(localized: "The change could not be saved. Try again.", comment: "Automatic downloads: saving a change to a rule failed")
        }
    }
}
