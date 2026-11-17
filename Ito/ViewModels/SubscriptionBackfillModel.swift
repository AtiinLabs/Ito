import Combine
import Foundation

/// Review of the unread chapters a rule that fills unread chapters would download. The preview is read from the stored
/// catalog and the exact read state, writes nothing and asks no source. Approving sends the preview's bindings, so a
/// catalog or a rule that changed meanwhile is refused and the preview is read again.
@MainActor
final class SubscriptionBackfillModel: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case loading
        case loaded
        /// The preview cannot be made, and why.
        case refused(SubscriptionBackfillRefusal)
        case failed
    }

    @Published private(set) var phase = Phase.loading
    @Published private(set) var preview: SubscriptionBackfillPreview?
    /// Indices of the positions that are ticked. All are ticked when a preview loads.
    @Published private(set) var selected: Set<Int> = []
    @Published private(set) var report: SubscriptionCommitReport?
    @Published private(set) var failedToApprove = false
    @Published private(set) var isApproving = false

    let subscriptionId: String
    var id: String { subscriptionId }
    private let service: any AutomaticDownloadServing
    private var loadGeneration = 0

    init(subscriptionId: String, service: any AutomaticDownloadServing) {
        self.subscriptionId = subscriptionId
        self.service = service
    }

    @discardableResult
    func load() -> Task<Void, Never> {
        loadGeneration += 1
        let generation = loadGeneration
        return Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.service.backfillPreview(subscriptionId: self.subscriptionId)
                guard self.loadGeneration == generation else { return }
                self.preview = loaded
                self.selected = Set(loaded.positions.indices)
                self.phase = .loaded
            } catch let refusal as SubscriptionBackfillRefusal {
                guard self.loadGeneration == generation else { return }
                self.preview = nil
                self.selected = []
                self.phase = .refused(refusal)
            } catch {
                guard self.loadGeneration == generation else { return }
                self.phase = .failed
            }
        }
    }

    func isSelected(_ index: Int) -> Bool { selected.contains(index) }

    func toggle(_ index: Int) {
        guard let preview, preview.positions.indices.contains(index) else { return }
        if !selected.insert(index).inserted { selected.remove(index) }
    }

    var canApprove: Bool { phase == .loaded && !selected.isEmpty && !isApproving }

    /// Approves the ticked positions in reading order. The returned task lets a caller wait for it.
    @discardableResult
    func approve() -> Task<Void, Never> {
        guard canApprove, let preview else { return Task {} }
        isApproving = true
        report = nil
        failedToApprove = false
        let approval = SubscriptionBackfillApproval(
            subscriptionId: preview.subscriptionId,
            incarnation: preview.incarnation,
            configGeneration: preview.configGeneration,
            baselineRevision: preview.baselineRevision,
            catalogDigest: preview.catalogDigest,
            positions: selected.sorted().map { preview.positions[$0] }
        )
        return Task { [weak self] in
            guard let self else { return }
            do {
                let result = SubscriptionCommitReport(try await self.service.approveBackfill(approval))
                self.report = result
                self.isApproving = false
                // A refusal means the preview is out of date; so is one that queued the first 500 of more.
                if result.needsReload || !result.isRefusal { await self.load().value }
            } catch {
                self.failedToApprove = true
                self.isApproving = false
            }
        }
    }
}

nonisolated extension SubscriptionBackfillRefusal {
    var localizedExplanation: String {
        switch self {
        case .unavailable:
            String(localized: "This rule has no accepted chapter list yet, or it is not turned on.", comment: "Automatic downloads: why unread chapters cannot be listed")
        case .unsupportedMode:
            String(localized: "This rule does not download unread chapters.", comment: "Automatic downloads: why unread chapters cannot be listed")
        case .numberOnlyReadState:
            String(localized: "Your read marks only record chapter numbers, so Ito can't tell which exact chapters you have read. Nothing can be listed safely.", comment: "Automatic downloads: why unread chapters cannot be listed")
        case .catalogUnreadable:
            String(localized: "The saved chapter list can't be used. Wait for the next check.", comment: "Automatic downloads: why unread chapters cannot be listed")
        case .selectionUnreadable:
            String(localized: "The group choice of this rule can't be read. Edit the rule first.", comment: "Automatic downloads: why unread chapters cannot be listed")
        }
    }
}
