import Combine
import Foundation
import GRDB
import OSLog

/// How much of the room automatic downloads may use is used now.
nonisolated struct AutomaticDownloadUsage: Equatable, Sendable {
    /// Bytes of every stored copy, damaged ones included; nil when they cannot be read.
    var storedBytes: Int64?
    /// Jobs in the queue, of every owner; nil when they cannot be read.
    var queuedJobs: Int?
    /// Free space where downloads are stored; nil when it cannot be read.
    var availableBytes: Int64?
}

/// What a screen asks of automatic downloads. Every command is the store's, through the download center, and returns
/// the store's own outcome: a screen says what happened from it, never from what it asked. Rules are never deleted from
/// here: only removing the series from the Library, moving it to another source, and a restore delete one. The reads
/// are observations of the database; none of them checks a source.
@MainActor
protocol AutomaticDownloadServing: AnyObject {
    /// Whether automatic downloads are composed at all. They are not when there is no offline store.
    var isAvailable: Bool { get }
    /// The queue and disk limits automatic downloads run under now.
    var limits: AutomaticDownloadLimits { get }
    /// How many hours a rule waits at least between two checks: the Library's update interval.
    var checkIntervalHours: Int { get }
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

    /// Every rule that is enabled or paused; a rule that is turned off is not listed.
    func rules() -> AnyPublisher<[SubscriptionRuleRow], Never>
    /// The rule of one series, turned-off rules included, or nil when it has none.
    func rule(for media: MediaIdentity) -> AnyPublisher<SubscriptionRuleRow?, Never>
    /// The open events of one rule that wait for a person.
    func attention(subscriptionId: String) async throws -> SubscriptionAttention
    /// What approving the unread chapters of a rule would queue. Writes nothing.
    func backfillPreview(subscriptionId: String) async throws -> SubscriptionBackfillPreview
    func usage() async -> AutomaticDownloadUsage
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
    let store: OfflineChapterStore
    private let currentLimits: @MainActor () -> AutomaticDownloadLimits
    private let currentIntervalHours: @MainActor () -> Int
    private let installedPluginIDs: AnyPublisher<Set<String>, Never>
    private let limitsChanged: AnyPublisher<Void, Never>

    /// The rows as the observation last read them, before the installed sources are applied.
    private let loaded = CurrentValueSubject<[SubscriptionRuleRow]?, Never>(nil)
    private var observation: DatabaseCancellable?
    private var restartObservation: (@MainActor () -> Void)?
    private var subscriptions = Set<AnyCancellable>()
    private var notifier: SubscriptionAttentionNotifier?
    private var latestRows: [SubscriptionRuleRow] = []
    private var sweepTail: Task<Void, Never>?

    /// - Parameters:
    ///   - limits: the configured queue and disk limits, read when a screen shows them.
    ///   - intervalHours: the Library's update interval in hours, which a rule's checks follow.
    ///   - installedPluginIDs: the sources that are installed; a rule of any other is shown as such.
    ///   - limitsChanged: fires after new limits are stored, which changes what is held back for room.
    init(
        center: DownloadCenter,
        scheduler: SubscriptionCheckScheduler,
        store: OfflineChapterStore,
        limits: @escaping @MainActor () -> AutomaticDownloadLimits,
        intervalHours: @escaping @MainActor () -> Int,
        installedPluginIDs: AnyPublisher<Set<String>, Never>,
        limitsChanged: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    ) {
        self.center = center
        self.scheduler = scheduler
        self.store = store
        self.currentLimits = limits
        self.currentIntervalHours = intervalHours
        self.installedPluginIDs = installedPluginIDs
        self.limitsChanged = limitsChanged
    }

    var isAvailable: Bool { true }
    var limits: AutomaticDownloadLimits { currentLimits() }
    var checkIntervalHours: Int { currentIntervalHours() }

    /// Starts observing the rules, their events and their jobs. The caller picks the scheduler, as the download center's
    /// observation does. Nothing here asks a source for anything.
    func startObserving<Scheduler: ValueObservationMainActorScheduler>(scheduling scheduler: Scheduler) {
        let center = center
        let start: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.observation?.cancel()
            let observation = ValueObservation.tracking { db in
                try SubscriptionRuleReadModel.read(db, quotaBytes: center.automaticQuotaBytes)
            }
            self.observation = observation.start(
                in: self.store.database,
                scheduling: scheduler,
                onError: { _ in AppLogger.database.error("Automatic download rule observation failed") },
                onChange: { [weak self] rows in self?.loaded.send(rows) }
            )
        }
        restartObservation = start
        start()
        // A new quota changes what is held back, but it is not in the database: read again.
        limitsChanged
            .sink { @MainActor [weak self] in self?.restartObservation?() }
            .store(in: &subscriptions)
        allRows()
            .sink { @MainActor [weak self] rows in self?.latestRows = rows }
            .store(in: &subscriptions)
        allRows()
            .map { $0.map(\.attentionKey) }
            .removeDuplicates()
            .sink { @MainActor [weak self] _ in self?.sweepAttentionNotifications() }
            .store(in: &subscriptions)
    }

    /// The notifier that claims, posts and sweeps attention notifications; nil posts nothing.
    func configure(notifier: SubscriptionAttentionNotifier?) {
        self.notifier = notifier
    }

    /// Removes attention notifications that are no longer true. Called when a rule's attention changes and when the app
    /// becomes active.
    func sweepAttentionNotifications() {
        guard let notifier else { return }
        let rows = latestRows
        let preceding = sweepTail
        sweepTail = Task { @MainActor in
            await preceding?.value
            await notifier.sweep(rules: rows)
        }
    }

    // MARK: - Reads

    private func allRows() -> AnyPublisher<[SubscriptionRuleRow], Never> {
        loaded
            .compactMap { $0 }
            .combineLatest(installedPluginIDs)
            .map { rows, installed in
                rows.map { row in
                    var row = row
                    row.sourceInstalled = installed.contains(row.media.pluginId)
                    return row
                }
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func rules() -> AnyPublisher<[SubscriptionRuleRow], Never> {
        allRows().map { $0.filter { $0.state != .disabled } }.removeDuplicates().eraseToAnyPublisher()
    }

    func rule(for media: MediaIdentity) -> AnyPublisher<SubscriptionRuleRow?, Never> {
        allRows().map { rows in rows.first { $0.media == media } }.removeDuplicates().eraseToAnyPublisher()
    }

    func attention(subscriptionId: String) async throws -> SubscriptionAttention {
        try await store.subscriptionAttention(subscriptionId: subscriptionId)
    }

    func backfillPreview(subscriptionId: String) async throws -> SubscriptionBackfillPreview {
        try await store.subscriptionBackfillPreview(subscriptionId: subscriptionId)
    }

    func usage() async -> AutomaticDownloadUsage {
        let stored = try? await store.automaticUsage()
        return AutomaticDownloadUsage(
            storedBytes: stored?.storedBytes,
            queuedJobs: stored?.queuedJobs,
            availableBytes: await center.availableCapacity()
        )
    }

    // MARK: - Commands

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
    var limits: AutomaticDownloadLimits { .standard }
    var checkIntervalHours: Int { AppPreferenceCatalog.updateInterval.defaultValue.rawValue }

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
    func rules() -> AnyPublisher<[SubscriptionRuleRow], Never> { Just([]).eraseToAnyPublisher() }
    func rule(for media: MediaIdentity) -> AnyPublisher<SubscriptionRuleRow?, Never> { Just(nil).eraseToAnyPublisher() }
    func attention(subscriptionId: String) async throws -> SubscriptionAttention { throw AutomaticDownloadsError.unavailable }
    func backfillPreview(subscriptionId: String) async throws -> SubscriptionBackfillPreview {
        throw AutomaticDownloadsError.unavailable
    }
    func usage() async -> AutomaticDownloadUsage { AutomaticDownloadUsage() }
}
