import Combine
import Foundation
import GRDB
@testable import Ito

/// The review and backfill commands of the facade over a real store, without a worker or a scheduler: what a screen reads
/// and decides is exactly what the ledger holds. The rows are read when a test asks (`refresh`), so no test waits.
@MainActor
final class StoreBackedAutomaticDownloads: AutomaticDownloadServing {
    let fixture: SubscriptionLedgerFixture
    var limits = AutomaticDownloadLimits(
        queueLimit: SubscriptionLedgerFixture.roomy.queueLimit, quotaBytes: SubscriptionLedgerFixture.roomy.quotaBytes
    )
    var checkIntervalHours = 4
    var isAvailable: Bool { true }
    /// Called after every decision, with its outcome.
    var onOutcome: ((SubscriptionCommitOutcome) -> Void)?
    private(set) var previewReads = 0
    private let current = CurrentValueSubject<[SubscriptionRuleRow]?, Never>(nil)

    init(_ fixture: SubscriptionLedgerFixture) { self.fixture = fixture }

    func refresh() async throws {
        let quota = limits.quotaBytes
        current.send(try await fixture.pool.read { db in try SubscriptionRuleReadModel.read(db, quotaBytes: quota) })
    }

    func sourceEpoch(for pluginID: String) throws -> String { OfflineStoreFixture.epoch }
    func enable(_ request: SubscriptionEnableRequest) async throws -> SubscriptionEnableOutcome {
        try await fixture.store.enableSubscription(request)
    }
    func edit(_ edit: SubscriptionEdit) async throws -> SubscriptionEditOutcome {
        try await fixture.store.editSubscription(edit)
    }
    func pause(id: String) async throws { _ = try await fixture.store.pauseSubscription(id: id) }
    func resume(_ request: SubscriptionResumeRequest) async throws -> SubscriptionResumeOutcome {
        try await fixture.store.resumeSubscription(request)
    }
    func turnOff(id: String) async throws { _ = try await fixture.store.disableSubscription(id: id) }

    func resolve(_ resolution: SubscriptionEventResolution) async throws -> SubscriptionCommitOutcome {
        let outcome = try await fixture.store.resolveSubscriptionEvent(resolution, limits: limits)
        onOutcome?(outcome)
        return outcome
    }

    func approveBackfill(_ approval: SubscriptionBackfillApproval) async throws -> SubscriptionCommitOutcome {
        let outcome = try await fixture.store.approveSubscriptionBackfill(approval, limits: limits)
        onOutcome?(outcome)
        return outcome
    }

    func rules() -> AnyPublisher<[SubscriptionRuleRow], Never> {
        current.compactMap { $0 }.map { $0.filter { $0.state != .disabled } }.eraseToAnyPublisher()
    }

    func rule(for media: MediaIdentity) -> AnyPublisher<SubscriptionRuleRow?, Never> {
        current.compactMap { $0 }.map { rows in rows.first { $0.media == media } }.eraseToAnyPublisher()
    }

    func attention(subscriptionId: String) async throws -> SubscriptionAttention {
        try await fixture.store.subscriptionAttention(subscriptionId: subscriptionId)
    }

    func backfillPreview(subscriptionId: String) async throws -> SubscriptionBackfillPreview {
        previewReads += 1
        return try await fixture.store.subscriptionBackfillPreview(subscriptionId: subscriptionId)
    }

    func usage() async -> AutomaticDownloadUsage { AutomaticDownloadUsage() }
}
