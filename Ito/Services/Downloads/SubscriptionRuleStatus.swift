import Foundation

/// What a screen says about one rule. It is derived from the row alone, in a fixed order where the first match wins,
/// so a screen never claims a check happened or a download is coming when the row does not show it. Every sentence is
/// whole and localized; nothing is joined from fragments.
nonisolated enum SubscriptionRuleStatus: Equatable, Sendable {
    /// Why the first chapter list has not been accepted yet.
    enum WaitingReason: Equatable, Sendable {
        case notChecked
        case incompleteCatalog, unknownScope, emptyCatalog, oversizedCatalog
        case fetchFailed, sourceChanged
        /// The last outcome says nothing a person can act on.
        case other
    }

    /// Why the last check of an active rule judged nothing.
    enum CheckFailure: Equatable, Sendable {
        case fetchFailed, incompleteCatalog, unknownScope, emptyCatalog, oversizedCatalog, sourceChanged
    }

    case off
    case restoredNeedsReview
    case sourceChangedNeedsReview
    case paused
    case sourceNotInstalled
    case selectionUnreadable
    case waitingForBaseline(WaitingReason)
    case active(lastCheckedAt: Date?, failure: CheckFailure?)

    /// The status of a row; the first match wins.
    init(_ row: SubscriptionRuleRow) {
        switch (row.state, row.pauseReason) {
        case (.disabled, _):
            self = .off
        case (.paused, .restored?):
            self = .restoredNeedsReview
        case (.paused, .sourceRemapped?):
            self = .sourceChangedNeedsReview
        case (.paused, _):
            self = .paused
        case (.enabled, _):
            if !row.sourceInstalled {
                self = .sourceNotInstalled
            } else if row.configuration == nil || row.lastAttemptOutcome == .selectionUnreadable {
                self = .selectionUnreadable
            } else if !row.hasBaseline {
                self = .waitingForBaseline(Self.waitingReason(of: row.lastAttemptOutcome))
            } else {
                self = .active(
                    lastCheckedAt: row.lastAttemptAt,
                    failure: row.lastAttemptOutcome.flatMap(Self.failure(of:))
                )
            }
        }
    }

    private static func waitingReason(of outcome: SubscriptionCheckOutcome?) -> WaitingReason {
        guard let outcome else { return .notChecked }
        switch outcome {
        case .incompleteCatalog: return .incompleteCatalog
        case .unknownScope: return .unknownScope
        case .emptyCatalog: return .emptyCatalog
        case .oversizedCatalog: return .oversizedCatalog
        case .fetchFailed: return .fetchFailed
        case .sourceChanged: return .sourceChanged
        case .baselineEstablished, .rebaselined, .advanced, .unchanged, .unsupportedKind, .superseded, .paused,
             .disabled, .seriesNotSaved, .selectionUnreadable:
            return .other
        }
    }

    private static func failure(of outcome: SubscriptionCheckOutcome) -> CheckFailure? {
        switch outcome {
        case .fetchFailed: .fetchFailed
        case .incompleteCatalog: .incompleteCatalog
        case .unknownScope: .unknownScope
        case .emptyCatalog: .emptyCatalog
        case .oversizedCatalog: .oversizedCatalog
        case .sourceChanged: .sourceChanged
        case .baselineEstablished, .rebaselined, .advanced, .unchanged, .unsupportedKind, .superseded, .paused,
             .disabled, .seriesNotSaved, .selectionUnreadable:
            nil
        }
    }

    /// What the status says, as one whole sentence.
    var title: String {
        switch self {
        case .off:
            String(localized: "Off", comment: "Automatic downloads: status of a series whose rule is turned off")
        case .restoredNeedsReview:
            String(localized: "Restored — review to turn on", comment: "Automatic downloads: status of a rule that came back from a backup and stays paused until the person reviews it")
        case .sourceChangedNeedsReview:
            String(localized: "Source changed — review to turn on", comment: "Automatic downloads: status of a rule paused because its series moved to another source, until the person reviews it")
        case .paused:
            String(localized: "Paused", comment: "Automatic downloads: status of a rule the person paused")
        case .sourceNotInstalled:
            String(localized: "Source not installed", comment: "Automatic downloads: status of a rule whose source is not installed, so nothing can be checked")
        case .selectionUnreadable:
            String(localized: "Group choice can't be read — edit the rule", comment: "Automatic downloads: status of a rule whose saved choice of scanlation groups this version of the app cannot read")
        case .waitingForBaseline(let reason):
            switch reason {
            case .notChecked:
                String(localized: "Waiting for a complete chapter list — not checked yet", comment: "Automatic downloads: a new rule that has not been checked yet")
            case .incompleteCatalog:
                String(localized: "Waiting for a complete chapter list — the source returned only part of it", comment: "Automatic downloads: the last check got an incomplete chapter list")
            case .unknownScope:
                String(localized: "Waiting for a complete chapter list — the source did not say which chapters it returned", comment: "Automatic downloads: the last check got a chapter list whose coverage the source did not state")
            case .emptyCatalog:
                String(localized: "Waiting for a complete chapter list — the source returned no chapters", comment: "Automatic downloads: the last check got no chapters")
            case .oversizedCatalog:
                String(localized: "Waiting for a complete chapter list — the list is too large to keep", comment: "Automatic downloads: the chapter list is larger than the app can keep for checking")
            case .fetchFailed:
                String(localized: "Waiting for a complete chapter list — the last check could not reach the source", comment: "Automatic downloads: the last check failed")
            case .sourceChanged:
                String(localized: "Waiting for a complete chapter list — the source's settings changed during the check", comment: "Automatic downloads: the source's settings or account changed while the last check ran")
            case .other:
                String(localized: "Waiting for a complete chapter list", comment: "Automatic downloads: a rule that has no accepted chapter list yet")
            }
        case .active:
            String(localized: "Active", comment: "Automatic downloads: status of a rule that is checking for new chapters")
        }
    }

    /// When the rule was last checked, as a sentence. Only an active rule has one.
    func detail(now: Date, locale: Locale = .current) -> String? {
        guard case .active(let checkedAt, _) = self else { return nil }
        guard let checkedAt else {
            return String(localized: "Not checked yet", comment: "Automatic downloads: an active rule that has not been checked since it was turned on")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        // A check is never in the future: a clock that moved back reads as just now.
        let when = formatter.localizedString(for: min(checkedAt, now), relativeTo: now)
        return String(localized: "Last checked \(when)", comment: "Automatic downloads: when the rule was last checked. The placeholder is a relative time such as '5 minutes ago'.")
    }

    /// What went wrong at the last check of an active rule, when something did.
    var failureNote: String? {
        guard case .active(_, let failure?) = self else { return nil }
        switch failure {
        case .fetchFailed:
            return String(localized: "The last check failed. If the source needs you to sign in or has changed its settings, check them. Ito tries again later.", comment: "Automatic downloads: note on a rule whose last check failed, whatever the reason")
        case .incompleteCatalog:
            return String(localized: "At the last check the source returned only part of the chapter list, so nothing was judged.", comment: "Automatic downloads: note on a rule whose last check got an incomplete chapter list")
        case .unknownScope:
            return String(localized: "At the last check the source did not say which chapters it returned, so nothing was judged.", comment: "Automatic downloads: note on a rule whose last check got a list of unknown coverage")
        case .emptyCatalog:
            return String(localized: "At the last check the source returned no chapters, so nothing was judged.", comment: "Automatic downloads: note on a rule whose last check got no chapters")
        case .oversizedCatalog:
            return String(localized: "At the last check the chapter list was too large to keep, so nothing was judged.", comment: "Automatic downloads: note on a rule whose chapter list is too large")
        case .sourceChanged:
            return String(localized: "The source's settings changed during the last check, so nothing was judged.", comment: "Automatic downloads: note on a rule whose source changed during the last check")
        }
    }

    /// Whether the rule is currently looking for new chapters. Only then may a screen say a check can find something.
    var isChecking: Bool {
        switch self {
        case .waitingForBaseline, .active: true
        case .off, .restoredNeedsReview, .sourceChangedNeedsReview, .paused, .sourceNotInstalled, .selectionUnreadable: false
        }
    }

    var systemImage: String {
        switch self {
        case .off: "poweroff"
        case .restoredNeedsReview, .sourceChangedNeedsReview: "exclamationmark.arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
        case .sourceNotInstalled, .selectionUnreadable: "exclamationmark.triangle"
        case .waitingForBaseline: "hourglass"
        case .active: "arrow.down.circle"
        }
    }
}

/// A fact about a rule that holds beside its status.
nonisolated enum SubscriptionRuleBadge: Equatable, Hashable, Sendable {
    case attention(Int)
    case moreAtNextCheck
    case waitingForQueueRoom
    case waitingForSpace
    case held(DownloadHoldReason)

    /// The badges of a row, in the order a screen shows them.
    static func badges(for row: SubscriptionRuleRow) -> [SubscriptionRuleBadge] {
        var result: [SubscriptionRuleBadge] = []
        if row.attentionCount > 0 { result.append(.attention(row.attentionCount)) }
        guard row.state == .enabled else {
            if row.heldJobs > 0, let reason = row.heldReason { result.append(.held(reason)) }
            return result
        }
        if row.pending[.runCap, default: 0] > 0 { result.append(.moreAtNextCheck) }
        if row.pending[.queueCap, default: 0] > 0 { result.append(.waitingForQueueRoom) }
        if row.pending[.quota, default: 0] > 0 { result.append(.waitingForSpace) }
        if row.heldJobs > 0, let reason = row.heldReason { result.append(.held(reason)) }
        return result
    }

    var title: String {
        switch self {
        case .attention(let count):
            String(localized: "\(count) waiting for your decision", comment: "Automatic downloads: how many new chapters of a rule need the person to decide. The placeholder is a count.")
        case .moreAtNextCheck:
            String(localized: "More new chapters will be queued at the next check", comment: "Automatic downloads: the per-check limit held some new chapters back")
        case .waitingForQueueRoom:
            String(localized: "Waiting for room in the download queue", comment: "Automatic downloads: new chapters wait because the download queue is full")
        case .waitingForSpace:
            String(localized: "Waiting for automatic download space", comment: "Automatic downloads: new chapters wait because the space for automatic downloads is used up")
        case .held(let reason):
            reason.localizedTitle
        }
    }
}

nonisolated extension DownloadHoldReason {
    /// Why queued automatic jobs do not start, as one sentence.
    var localizedTitle: String {
        switch self {
        case .automaticRulePaused:
            String(localized: "Waiting — the rule that queued it is paused", comment: "Download state: an automatic download is queued, but its rule is paused, turned off or being reviewed")
        case .automaticSpaceFull:
            String(localized: "Waiting for automatic download space", comment: "Download state: an automatic download is queued, but the space for automatic downloads is used up")
        case .automaticMeteredNotAllowed:
            String(localized: "Waiting for Wi-Fi — automatic downloads use cellular data only when Settings allows it", comment: "Download state: an automatic download waits because the connection is metered and Settings does not allow automatic downloads on it")
        }
    }
}

nonisolated enum SubscriptionRuleFooter {
    /// The sentence under the rule list: when rules are checked. It promises nothing about background work.
    static func text(intervalHours: Int) -> String {
        String(localized: "Ito checks rules when it opens or when you refresh the Library, at most every \(intervalHours) hours.", comment: "Automatic downloads: footer explaining when rules are checked. The placeholder is the number of hours of the update interval.")
    }
}
