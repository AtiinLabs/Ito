import Combine
import Foundation

/// The events of one rule that wait for a person: choose among uploads, or look at something the ledger would not
/// decide alone. Approving or dismissing goes through the store with the generations and the candidate list the person
/// saw, so what changed meanwhile is refused and reloaded instead of acted on. It reads the stored catalog and writes
/// nothing until the person decides; it never asks a source.
@MainActor
final class SubscriptionEventReviewModel: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed
    }

    @Published private(set) var phase = Phase.loading
    @Published private(set) var attention: SubscriptionAttention?
    /// The keys ticked for each event, by event id.
    @Published private(set) var selection: [String: Set<String>] = [:]
    /// What the last decision did, in the store's words.
    @Published private(set) var report: SubscriptionCommitReport?
    @Published private(set) var failedToDecide = false
    @Published private(set) var busyEventId: String?

    let subscriptionId: String
    var id: String { subscriptionId }
    private let service: any AutomaticDownloadServing
    private var loadGeneration = 0

    init(subscriptionId: String, service: any AutomaticDownloadServing) {
        self.subscriptionId = subscriptionId
        self.service = service
    }

    var events: [SubscriptionEventReview] { attention?.events ?? [] }
    /// Whether the rule is turned on. A paused or turned-off rule's chapters can be dismissed but not approved: the store
    /// refuses an approval for it, so the sheet never offers one.
    var ruleIsEnabled: Bool { attention?.ruleIsEnabled ?? true }

    /// Whether an approval of this event is offered at all.
    func offersApproval(_ event: SubscriptionEventReview) -> Bool { event.canApprove && ruleIsEnabled }
    /// How many events wait beyond the ones listed.
    var hiddenCount: Int { max(0, (attention?.totalCount ?? 0) - events.count) }

    /// Reads the open events again. A newer read replaces an older one that is still running.
    @discardableResult
    func load() -> Task<Void, Never> {
        loadGeneration += 1
        let generation = loadGeneration
        if attention == nil { phase = .loading }
        return Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.service.attention(subscriptionId: self.subscriptionId)
                guard self.loadGeneration == generation else { return }
                self.attention = loaded
                // A selection survives only for rows its event still lists.
                var kept: [String: Set<String>] = [:]
                for event in loaded.events {
                    let candidates = Set(event.candidates.map(\.key))
                    if let chosen = self.selection[event.eventId] { kept[event.eventId] = chosen.intersection(candidates) }
                }
                self.selection = kept
                self.phase = .loaded
            } catch {
                guard self.loadGeneration == generation else { return }
                self.phase = .failed
            }
        }
    }

    func isSelected(_ key: String, in event: SubscriptionEventReview) -> Bool {
        selection[event.eventId]?.contains(key) ?? false
    }

    func toggle(_ key: String, in event: SubscriptionEventReview) {
        guard offersApproval(event), event.candidates.contains(where: { $0.key == key }) else { return }
        var chosen = selection[event.eventId] ?? []
        if !chosen.insert(key).inserted { chosen.remove(key) }
        selection[event.eventId] = chosen
    }

    /// The ticked keys in the order the event lists them.
    func selectedKeys(for event: SubscriptionEventReview) -> [String] {
        let chosen = selection[event.eventId] ?? []
        return event.candidates.map(\.key).filter(chosen.contains)
    }

    func canApprove(_ event: SubscriptionEventReview) -> Bool {
        offersApproval(event) && !selectedKeys(for: event).isEmpty && busyEventId == nil
    }

    /// Approves the ticked rows. The returned task lets a caller wait for it.
    @discardableResult
    func approve(_ event: SubscriptionEventReview) -> Task<Void, Never> {
        let keys = selectedKeys(for: event)
        guard canApprove(event) else { return Task {} }
        return decide(event, .approve(keys: keys))
    }

    @discardableResult
    func dismiss(_ event: SubscriptionEventReview) -> Task<Void, Never> {
        guard busyEventId == nil else { return Task {} }
        return decide(event, .dismiss)
    }

    private func decide(_ event: SubscriptionEventReview, _ action: SubscriptionEventResolution.Action) -> Task<Void, Never> {
        busyEventId = event.eventId
        report = nil
        failedToDecide = false
        let resolution = SubscriptionEventResolution(
            eventId: event.eventId,
            incarnation: event.incarnation,
            configGeneration: event.configGeneration,
            candidateRevision: event.candidateRevision,
            action: action
        )
        return Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.service.resolve(resolution)
                let result = SubscriptionCommitReport(outcome)
                // A dismissal that went through has nothing to report; everything else says what happened.
                if case .dismiss = action, !result.isRefusal { self.report = nil } else { self.report = result }
            } catch {
                self.failedToDecide = true
            }
            self.busyEventId = nil
            // What the store holds decides what is shown, whatever the outcome was.
            await self.load().value
        }
    }
}

/// The sentence for why an event waits for a person. One per reason, never joined from parts.
nonisolated extension SubscriptionReviewReason {
    var localizedExplanation: String {
        switch self {
        case .noReliableOrder:
            String(localized: "The source does not give a reliable reading order, so Ito can't tell where this chapter belongs.", comment: "Automatic downloads review: why new chapters need a decision")
        case .noBaselineOrder:
            String(localized: "The chapter list Ito saved first had no reliable reading order, so Ito can't tell whether this chapter is new.", comment: "Automatic downloads review: why new chapters need a decision")
        case .highWaterMissing:
            String(localized: "Ito can't find the last chapter it saw in the source's list, so it can't tell whether this chapter is new.", comment: "Automatic downloads review: why new chapters need a decision")
        case .anchorsReordered:
            String(localized: "The source reordered chapters it listed before, so Ito can't tell whether this chapter is new.", comment: "Automatic downloads review: why new chapters need a decision")
        case .positionIdentityChanged:
            String(localized: "The source changed how it identifies this chapter, so Ito can't tell whether it is new.", comment: "Automatic downloads review: why new chapters need a decision")
        case .knownPositionAfterHighWater:
            String(localized: "The source listed a chapter after the newest one Ito saw that Ito already knew about.", comment: "Automatic downloads review: why new chapters need a decision")
        case .insertedBeforeHighWater:
            String(localized: "The source added a chapter in the middle of the list, among chapters Ito already saw.", comment: "Automatic downloads review: why new chapters need a decision")
        case .olderThanBaseline:
            String(localized: "The source added a chapter that looks older than the chapters Ito saw first.", comment: "Automatic downloads review: why new chapters need a decision")
        case .tooManyCandidates:
            String(localized: "Too many chapters showed up at once to decide automatically.", comment: "Automatic downloads review: why new chapters need a decision")
        case .bulkArrival:
            String(localized: "A large number of chapters showed up at once, which looks more like a reorganized list than new releases.", comment: "Automatic downloads review: why new chapters need a decision")
        case .bulkRevisionChange:
            String(localized: "A large number of saved chapters changed at once, which looks more like a source-wide update than new revisions.", comment: "Automatic downloads review: why changed chapters need a decision")
        case .emptyAfterNonempty:
            String(localized: "The source returned no chapters, though it listed some before. Nothing was changed.", comment: "Automatic downloads review: the chapter list became empty")
        case .selectionUnresolved:
            String(localized: "The groups this rule follows don't match the chapters the source lists now.", comment: "Automatic downloads review: the rule's group choice does not fit the list")
        case .numberOnlyReadState:
            String(localized: "Your read marks only record chapter numbers, so Ito can't tell which exact chapters you have read.", comment: "Automatic downloads review: why the next chapters cannot be chosen")
        case .windowOrderAmbiguous:
            String(localized: "The reading order of the chapter list is unclear, so Ito can't tell which chapters come next.", comment: "Automatic downloads review: why the next chapters cannot be chosen")
        }
    }
}

nonisolated extension SubscriptionEventKind {
    /// The sentence that says what an event is about when it has no review reason, such as a choice among uploads.
    var localizedSummary: String {
        switch self {
        case .newPosition:
            String(localized: "New chapter — choose which uploads to download.", comment: "Automatic downloads review: a new chapter has several uploads and the person chooses")
        case .newAlternate:
            String(localized: "Another upload of a chapter you already have.", comment: "Automatic downloads review: a new upload of an existing chapter")
        case .revisionChanged:
            String(localized: "A saved chapter changed at the source.", comment: "Automatic downloads review: the source changed a chapter that is saved")
        case .unplacedKey:
            String(localized: "A chapter Ito can't place in the reading order.", comment: "Automatic downloads review: a chapter whose position is unclear")
        case .catalogAnomaly:
            String(localized: "The chapter list looks different from before.", comment: "Automatic downloads review: the chapter list changed in an unusual way")
        case .backfill:
            String(localized: "Unread chapters to download.", comment: "Automatic downloads review: unread chapters offered for download")
        case .window:
            String(localized: "Next unread chapters.", comment: "Automatic downloads review: the next unread chapters to keep downloaded")
        }
    }
}
