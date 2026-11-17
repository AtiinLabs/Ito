import Foundation
import OSLog

/// Tells a person that automatic downloads need a decision, at most once per event and only when the person asked.
///
/// The cycle is claim, post, invalidate. Every event that waits for a person is claimed once in the store, whether or
/// not a notification can be posted: the claim records that the decision to notify was taken, so turning the setting
/// on later never announces what was already waiting. A notification is posted only while the app is not in the
/// foreground (the screens show the state there), only when the setting is on and the system allows it, and as one
/// notification per rule whose identifier is the rule's, so a newer one replaces the older. A notification names the
/// generations of the rule it was posted for; once the rule was edited, replaced or turned off, or nothing waits any
/// more, the sweep removes it. Nothing here builds UI, and nothing it logs names a series, a chapter or an identifier.
@MainActor
final class SubscriptionAttentionNotifier {
    static let identifierPrefix = "ito.subscription.attention."
    static let threadIdentifier = "AutomaticDownloads"

    private let system: any NotificationSystem
    private let claim: @Sendable (Date) async throws -> [SubscriptionAttentionClaim]
    private let readStates: @Sendable () async throws -> [SubscriptionAttentionState]
    private let isForeground: @MainActor () -> Bool
    private let isEnabled: @MainActor () -> Bool
    private let now: @Sendable () -> Date
    /// Claims and sweeps run one after another, so two never post or remove against each other.
    private var tail: Task<Void, Never>?

    init(
        system: any NotificationSystem,
        claim: @escaping @Sendable (Date) async throws -> [SubscriptionAttentionClaim],
        readStates: @escaping @Sendable () async throws -> [SubscriptionAttentionState],
        isForeground: @escaping @MainActor () -> Bool,
        isEnabled: @escaping @MainActor () -> Bool,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.system = system
        self.claim = claim
        self.readStates = readStates
        self.isForeground = isForeground
        self.isEnabled = isEnabled
        self.now = now
    }

    static func identifier(for subscriptionId: String) -> String { identifierPrefix + subscriptionId }

    /// Called after a commit, drain, resolution or approval. Does nothing unless the outcome has events that wait for a
    /// person. Returns when the claim and any post are done.
    func didCommit(_ outcome: SubscriptionCommitOutcome) async {
        guard !outcome.needsAttentionEventIds.isEmpty else { return }
        await serialized { [self] in await claimAndPost() }
    }

    /// Asks for a sweep and returns at once. Which notifications are stale is decided when the sweep runs, from the store,
    /// behind every claim and post queued before it.
    func requestSweep() {
        Task { await sweep() }
    }

    /// Removes the notifications that are no longer true and, in the foreground, claims silently what waits. The rules are
    /// read from the store inside the serialized queue, so a notification posted just before is judged by a picture that
    /// includes it, and a rule that cannot be read removes nothing.
    func sweep() async {
        await serialized { [self] in
            let states: [SubscriptionAttentionState]
            do {
                states = try await readStates()
            } catch {
                AppLogger.database.error("The automatic download rules could not be read for a notification sweep")
                return
            }
            let byId = Dictionary(states.map { ($0.subscriptionId, $0) }, uniquingKeysWith: { first, _ in first })
            let stale = await system.deliveredAttention().filter { delivered in
                guard let rule = byId[delivered.payload.subscriptionId] else { return true }
                return !rule.isEnabled
                    || rule.incarnation != delivered.payload.incarnation
                    || rule.configGeneration != delivered.payload.configGeneration
                    || rule.attentionCount == 0
            }
            if !stale.isEmpty {
                let identifiers = stale.map(\.identifier)
                await system.removeDelivered(identifiers: identifiers)
                await system.removePending(identifiers: identifiers)
            }
            if isForeground() {
                do {
                    _ = try await claim(now())
                } catch {
                    AppLogger.database.error("An automatic download attention claim failed")
                }
            }
        }
    }

    private func claimAndPost() async {
        let claims: [SubscriptionAttentionClaim]
        do {
            claims = try await claim(now())
        } catch {
            // Nothing was claimed, so nothing is posted; the next activation's sweep claims it silently.
            AppLogger.database.error("An automatic download attention claim failed")
            return
        }
        guard !claims.isEmpty, !isForeground(), isEnabled(), await system.isAuthorized() else { return }
        for claim in claims {
            do {
                try await system.add(
                    identifier: Self.identifier(for: claim.subscriptionId),
                    title: String(localized: "Automatic Downloads", comment: "Title of a notification saying that new chapters of a series wait for the person's decision"),
                    body: Self.body(title: claim.title, count: claim.openAttention),
                    threadIdentifier: Self.threadIdentifier,
                    payload: SubscriptionAttentionPayload(
                        subscriptionId: claim.subscriptionId,
                        incarnation: claim.incarnation,
                        configGeneration: claim.configGeneration
                    )
                )
            } catch {
                AppLogger.general.error("An automatic download notification could not be posted")
            }
        }
    }

    /// The body of a notification: the series' title (source content, shown as it is) and how many items wait. An item is
    /// a new chapter, a changed chapter or a list that looks different: anything that needs the person's decision.
    static func body(title: String?, count: Int) -> String {
        guard let title else {
            return String(localized: "\(count) items need your decision.", comment: "Notification body: how many items of automatic downloads wait for the person to decide, such as new chapters. The placeholder is a count.")
        }
        return String(localized: "\(title) has \(count) items that need your decision.", comment: "Notification body: the first placeholder is a series title, the second how many of its items (new chapters or changes) wait for the person to decide.")
    }

    private func serialized(_ body: @escaping @MainActor () async -> Void) async {
        let preceding = tail
        let task = Task { @MainActor in
            await preceding?.value
            await body()
        }
        tail = task
        await task.value
    }
}
