import Foundation

/// Where a catalog the update check already fetched goes for the subscription ledger. The check asks for a ticket before
/// it fetches, so the one request is made under the source epoch the ledger will verify, then hands over what it read
/// or why it could not. Nothing here fetches, and nothing infers an event from a chapter count.
@MainActor
protocol SubscriptionCatalogSink: AnyObject {
    /// The ticket of a check of this series, or nil when it has no enabled rule (or its source scope cannot be read).
    func begin(media: MediaIdentity) async -> SubscriptionCheckTicket?
    /// Judges and records the observation. It may queue downloads; the sink wakes the worker when it did.
    func commit(_ ticket: SubscriptionCheckTicket, _ observation: CatalogObservation) async
    /// Records that the check produced no observation.
    func fail(_ ticket: SubscriptionCheckTicket, _ outcome: SubscriptionCheckOutcome) async
}
