import Foundation

/// What a screen asks of automatic downloads. Every command is the store's, through the download center, and returns
/// the store's own outcome: a screen says what happened from it, never from what it asked. Rules are never deleted from
/// here: only removing the series from the Library, moving it to another source, and a restore delete one.
@MainActor
protocol AutomaticDownloadServing: AnyObject {
    /// Whether automatic downloads are composed at all. They are not when there is no offline store.
    var isAvailable: Bool { get }
    /// The source's current epoch. A rule is stored only while the epoch it was reviewed under is still current.
    func sourceEpoch(for pluginID: String) throws -> String
    func enable(_ request: SubscriptionEnableRequest) async throws -> SubscriptionEnableOutcome
    func edit(_ edit: SubscriptionEdit) async throws -> SubscriptionEditOutcome
    func pause(id: String) async throws
    func resume(_ request: SubscriptionResumeRequest) async throws -> SubscriptionResumeOutcome
    /// Turns the rule off: jobs only it asked for are removed, files are kept.
    func turnOff(id: String) async throws
    func resolve(_ resolution: SubscriptionEventResolution) async throws -> SubscriptionCommitOutcome
    func approveBackfill(_ approval: SubscriptionBackfillApproval) async throws -> SubscriptionCommitOutcome
}

nonisolated enum AutomaticDownloadsError: Error, Equatable, Sendable {
    case unavailable
}

/// The live service. After a rule is enabled, edited or resumed it tells the scheduler, which checks that one rule at
/// its next pass whatever its due time. A decision about an event goes through the center, which wakes the worker.
@MainActor
final class AutomaticDownloads: AutomaticDownloadServing {
    private let center: DownloadCenter
    private let scheduler: SubscriptionCheckScheduler

    init(center: DownloadCenter, scheduler: SubscriptionCheckScheduler) {
        self.center = center
        self.scheduler = scheduler
    }

    var isAvailable: Bool { true }

    func sourceEpoch(for pluginID: String) throws -> String {
        try center.editionPreferenceEpoch(for: pluginID)
    }

    func enable(_ request: SubscriptionEnableRequest) async throws -> SubscriptionEnableOutcome {
        let outcome = try await center.enableSubscription(request)
        if case .enabled(let id, _) = outcome { scheduler.request(.ruleChanged(id)) }
        return outcome
    }

    func edit(_ edit: SubscriptionEdit) async throws -> SubscriptionEditOutcome {
        let outcome = try await center.editSubscription(edit)
        if case .applied = outcome { scheduler.request(.ruleChanged(edit.subscriptionId)) }
        return outcome
    }

    func pause(id: String) async throws {
        try await center.pauseSubscription(id: id)
    }

    func resume(_ request: SubscriptionResumeRequest) async throws -> SubscriptionResumeOutcome {
        let outcome = try await center.resumeSubscription(request)
        if case .resumed = outcome { scheduler.request(.ruleChanged(request.subscriptionId)) }
        return outcome
    }

    func turnOff(id: String) async throws {
        _ = try await center.disableSubscription(id: id)
    }

    func resolve(_ resolution: SubscriptionEventResolution) async throws -> SubscriptionCommitOutcome {
        try await center.resolveSubscriptionEvent(resolution)
    }

    func approveBackfill(_ approval: SubscriptionBackfillApproval) async throws -> SubscriptionCommitOutcome {
        try await center.approveSubscriptionBackfill(approval)
    }
}

/// What screens get when there is no offline store: nothing is available, and every command throws.
@MainActor
final class UnavailableAutomaticDownloads: AutomaticDownloadServing {
    var isAvailable: Bool { false }

    func sourceEpoch(for pluginID: String) throws -> String { throw AutomaticDownloadsError.unavailable }
    func enable(_ request: SubscriptionEnableRequest) async throws -> SubscriptionEnableOutcome {
        throw AutomaticDownloadsError.unavailable
    }
    func edit(_ edit: SubscriptionEdit) async throws -> SubscriptionEditOutcome { throw AutomaticDownloadsError.unavailable }
    func pause(id: String) async throws { throw AutomaticDownloadsError.unavailable }
    func resume(_ request: SubscriptionResumeRequest) async throws -> SubscriptionResumeOutcome {
        throw AutomaticDownloadsError.unavailable
    }
    func turnOff(id: String) async throws { throw AutomaticDownloadsError.unavailable }
    func resolve(_ resolution: SubscriptionEventResolution) async throws -> SubscriptionCommitOutcome {
        throw AutomaticDownloadsError.unavailable
    }
    func approveBackfill(_ approval: SubscriptionBackfillApproval) async throws -> SubscriptionCommitOutcome {
        throw AutomaticDownloadsError.unavailable
    }
}
