import Combine
import Foundation
@testable import Ito

/// A scripted `AutomaticDownloadServing`. Every command is recorded and answers what the test set; a command can be held
/// at a gate so a test decides when it finishes. No command checks a source, and the fake counts the reads so a test can
/// say that opening a screen asked for nothing.
@MainActor
final class FakeAutomaticDownloads: AutomaticDownloadServing {
    var isAvailable = true
    var limits = AutomaticDownloadLimits(queueLimit: 100, quotaGiB: 5)
    var checkIntervalHours = 4
    var epoch = "epoch-1"
    var epochFailure = false
    /// Keeps the weakly held host of a model alive for the length of a test.
    var retained: AnyObject?

    var enableOutcome: SubscriptionEnableOutcome = .enabled(id: "rule-1", incarnation: 1)
    var editOutcome: SubscriptionEditOutcome = .applied(configGeneration: 2)
    var resumeOutcome: SubscriptionResumeOutcome = .resumed(configGeneration: 2)
    var resolveOutcome = SubscriptionCommitOutcome(.advanced)
    var approveOutcome = SubscriptionCommitOutcome(.advanced)
    var attentionResult = SubscriptionAttention(events: [], totalCount: 0)
    var previewResult: Result<SubscriptionBackfillPreview, Error> = .failure(AutomaticDownloadsError.unavailable)
    var commandError: Error?

    private(set) var enables: [SubscriptionEnableRequest] = []
    private(set) var edits: [SubscriptionEdit] = []
    private(set) var resumes: [SubscriptionResumeRequest] = []
    private(set) var pauses: [String] = []
    private(set) var turnOffs: [String] = []
    private(set) var resolutions: [SubscriptionEventResolution] = []
    private(set) var approvals: [SubscriptionBackfillApproval] = []
    private(set) var attentionReads = 0
    private(set) var previewReads = 0
    private(set) var epochReads = 0
    /// When set, `enable`, `edit` and `resume` wait for it before they answer.
    var gate: (() async -> Void)?

    private let current = CurrentValueSubject<[SubscriptionRuleRow], Never>([])
    private var hasPublished = false

    func publish(_ rows: [SubscriptionRuleRow]) {
        hasPublished = true
        current.send(rows)
    }

    func sourceEpoch(for pluginID: String) throws -> String {
        epochReads += 1
        if epochFailure { throw AutomaticDownloadsError.unavailable }
        return epoch
    }

    func enable(_ request: SubscriptionEnableRequest) async throws -> SubscriptionEnableOutcome {
        enables.append(request)
        if let commandError { throw commandError }
        await gate?()
        return enableOutcome
    }

    func edit(_ edit: SubscriptionEdit) async throws -> SubscriptionEditOutcome {
        edits.append(edit)
        if let commandError { throw commandError }
        await gate?()
        return editOutcome
    }

    func pause(id: String) async throws {
        pauses.append(id)
        if let commandError { throw commandError }
    }

    func resume(_ request: SubscriptionResumeRequest) async throws -> SubscriptionResumeOutcome {
        resumes.append(request)
        if let commandError { throw commandError }
        await gate?()
        return resumeOutcome
    }

    func turnOff(id: String) async throws {
        turnOffs.append(id)
        if let commandError { throw commandError }
    }

    func resolve(_ resolution: SubscriptionEventResolution) async throws -> SubscriptionCommitOutcome {
        resolutions.append(resolution)
        if let commandError { throw commandError }
        return resolveOutcome
    }

    func approveBackfill(_ approval: SubscriptionBackfillApproval) async throws -> SubscriptionCommitOutcome {
        approvals.append(approval)
        if let commandError { throw commandError }
        return approveOutcome
    }

    func rules() -> AnyPublisher<[SubscriptionRuleRow], Never> {
        current.filter { [unowned self] _ in hasPublished }
            .map { $0.filter { $0.state != .disabled } }
            .eraseToAnyPublisher()
    }

    func rule(for media: MediaIdentity) -> AnyPublisher<SubscriptionRuleRow?, Never> {
        current.filter { [unowned self] _ in hasPublished }
            .map { rows in rows.first { $0.media == media } }
            .eraseToAnyPublisher()
    }

    func attention(subscriptionId: String) async throws -> SubscriptionAttention {
        attentionReads += 1
        return attentionResult
    }

    func backfillPreview(subscriptionId: String) async throws -> SubscriptionBackfillPreview {
        previewReads += 1
        return try previewResult.get()
    }

    func usage() async -> AutomaticDownloadUsage {
        AutomaticDownloadUsage(storedBytes: 1_000, queuedJobs: 2, availableBytes: 9_000)
    }

    /// Every command that writes: none of them may happen because a screen was shown.
    var commandCount: Int {
        enables.count + edits.count + resumes.count + pauses.count + turnOffs.count + resolutions.count + approvals.count
    }
}

/// A host for the rule sheet: a saved series with a chapter list of its own.
@MainActor
final class FakeRuleHost: SubscriptionRuleHost {
    var ruleIsSaved = true
    var ruleScanlatorOptions: [ScanlatorOption] = []
    var ruleDefaultSelection: EditionSelection = .sourceList
    var ruleCatalogDigest = String(repeating: "d", count: 64)
}
