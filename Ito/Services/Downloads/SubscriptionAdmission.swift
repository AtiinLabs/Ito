import Foundation

/// What the store knows about the verified copy of a key, for the one rule that replaces it.
nonisolated struct InstalledCopyEvidence: Sendable, Equatable {
    let isVerified: Bool
    /// The revision of the copy's saved chapter, normalized as `DownloadReplacementIntent.revision(_:)` does.
    let revision: String?
    /// Whether the copy was saved under the source epoch in force now.
    let sourceEpochIsCurrent: Bool
}

/// Everything admission reads, gathered by the store inside its write transaction. Keys are exact UTF-8 bytes.
nonisolated struct AdmissionContext: Sendable {
    var subscription: SeriesSubscriptionRecord
    /// nil when the stored selection cannot be read: nothing is admitted, and the check reports it.
    var selection: EditionSelection?
    /// The present rows of the accepted baseline, in source order.
    let baselineRows: [CatalogRowEvidence]
    /// What each baseline key already has in the store.
    var stored: [ScanlatorUTF8: StoredEditionState]
    /// Keys the user deleted on purpose.
    var suppressed: Set<ScanlatorUTF8>
    var installed: [ScanlatorUTF8: InstalledCopyEvidence]
    /// Every job, of every owner.
    var jobCount: Int
    /// Jobs whose owners are all subscriptions.
    var autoOnlyOutstandingJobs: Int
    var storedBytes: Int64
    let limits: AutomaticDownloadLimits
    /// Positions this run may still enqueue; nil exempts approvals, backfill and drains.
    var runCapRemaining: Int?

    fileprivate let rowIndex: [ScanlatorUTF8: Int]
    fileprivate let catalogIndex: ScanlatorCatalogIndex

    init(
        subscription: SeriesSubscriptionRecord,
        selection: EditionSelection?,
        baselineRows: [CatalogRowEvidence],
        stored: [ScanlatorUTF8: StoredEditionState],
        suppressed: Set<ScanlatorUTF8>,
        installed: [ScanlatorUTF8: InstalledCopyEvidence] = [:],
        jobCount: Int,
        autoOnlyOutstandingJobs: Int,
        storedBytes: Int64,
        limits: AutomaticDownloadLimits,
        runCapRemaining: Int?
    ) {
        self.subscription = subscription
        self.selection = selection
        self.baselineRows = baselineRows
        self.stored = stored
        self.suppressed = suppressed
        self.installed = installed
        self.jobCount = jobCount
        self.autoOnlyOutstandingJobs = autoOnlyOutstandingJobs
        self.storedBytes = storedBytes
        self.limits = limits
        self.runCapRemaining = runCapRemaining
        var index: [ScanlatorUTF8: Int] = [:]
        for (offset, row) in baselineRows.enumerated() { index[ScanlatorUTF8(value: row.facts.key)] = offset }
        rowIndex = index
        catalogIndex = ScanlatorCatalogIndex(baselineRows, id: { $0.facts.scanlatorID }, name: { $0.facts.scanlator })
    }

    /// Records what an enqueue did, so the next event of the same pass is decided on the new counts: the keys now have
    /// a job, `created` of them are new jobs and only this subscription asked for them, and one position was used.
    mutating func apply(enqueued keys: [String], created: Int) {
        for key in keys { stored[ScanlatorUTF8(value: key)] = .queued }
        jobCount += created
        autoOnlyOutstandingJobs += created
        if let remaining = runCapRemaining { runCapRemaining = remaining - 1 }
    }
}

nonisolated enum AdmissionDecision: Sendable, Equatable {
    /// Exact keys in reading order. A key that already has a job gains the subscription as an owner.
    case enqueue(keys: [String])
    case satisfied(keys: [String])
    case pending(SubscriptionPendingReason)
    case awaitingEdition
    case needsChoice(candidates: [String])
    case needsReview(SubscriptionReviewReason)
    case locked
    case blockedDamaged
    case suppressed
    case superseded
    case recorded
}

/// Decides what one open event does, from the event, the accepted baseline and the state of the store. Pure: the same
/// inputs always give the same decision, and nothing here reads a database, a clock or the network. It owns no
/// resolver of its own: groups are resolved by `ScanlatorCatalogIndex` and positions by `EditionPositionResolver`,
/// the same code the manual presets use. A decision never adopts a key that is not in the event's candidate list.
nonisolated enum SubscriptionAdmission {
    static func decide(_ event: SubscriptionEventRecord, _ ctx: AdmissionContext) -> AdmissionDecision {
        // Events that only ask a person to look: a catalog anomaly and an unreadable read state or window order.
        if event.kind == .catalogAnomaly || event.identityKind == .catalog {
            return .needsReview(event.reviewReason ?? .noReliableOrder)
        }
        if event.kind == .newAlternate { return .recorded }
        if event.kind == .unplacedKey, event.approved == nil {
            return .needsReview(event.reviewReason ?? .noReliableOrder)
        }
        // 1. Mode gate.
        let subscription = ctx.subscription
        switch event.kind {
        case .newPosition:
            if subscription.mode == .maintainNextUnread { return .recorded }
        case .window:
            if subscription.mode != .maintainNextUnread { return .superseded }
        case .backfill:
            if subscription.mode != .newAndFillUnread { return .superseded }
        case .revisionChanged:
            if subscription.replacementRule != .sameKeyReliableRevision { return .recorded }
        case .unplacedKey, .newAlternate, .catalogAnomaly:
            break
        }
        // 2. Liveness: only keys of the frozen candidate list that the accepted catalog still lists.
        let keys = event.approved ?? event.candidates
        guard !keys.isEmpty, keys.allSatisfy({ ctx.rowIndex[ScanlatorUTF8(value: $0)] != nil }) else {
            return .superseded
        }
        guard let selection = ctx.selection else { return .needsReview(.selectionUnresolved) }

        if event.kind == .revisionChanged { return decideReplacement(event, key: keys[0], selection: selection, ctx) }

        // 3. The edition: an approval is used as it is, anything else is resolved by the selection.
        let chosen: Chosen
        if event.approved != nil {
            chosen = approved(keys, ctx)
        } else {
            switch resolved(keys, selection: selection, ctx) {
            case .chosen(let value): chosen = value
            case .decision(let decision): return decision
            }
        }
        if !chosen.toQueue.isEmpty || !chosen.attach.isEmpty {
            // 4. Suppression: never fall through to another group's row, never clear a record.
            if chosen.toQueue.contains(where: { ctx.suppressed.contains(ScanlatorUTF8(value: $0)) }) {
                return .suppressed
            }
            // 5. Caps.
            if let blocked = capBlock(newJobs: chosen.toQueue.count, ctx) { return .pending(blocked) }
            return .enqueue(keys: chosen.toQueue + chosen.attach)
        }
        if !chosen.satisfied.isEmpty { return .satisfied(keys: chosen.satisfied) }
        if !chosen.damaged.isEmpty { return .blockedDamaged }
        if !chosen.locked.isEmpty { return .locked }
        return .superseded
    }

    // MARK: - Edition

    /// The rows of one event that the store would act on, by exact key.
    private struct Chosen {
        var toQueue: [String] = []
        /// Rows that already have a job; the subscription becomes one more owner of it.
        var attach: [String] = []
        var satisfied: [String] = []
        var damaged: [String] = []
        var locked: [String] = []
    }

    private enum Resolution {
        case chosen(Chosen)
        case decision(AdmissionDecision)
    }

    /// An approved key is taken verbatim: stored state and the source's lock decide, no selection does.
    private static func approved(_ keys: [String], _ ctx: AdmissionContext) -> Chosen {
        var chosen = Chosen()
        for key in keys {
            let exact = ScanlatorUTF8(value: key)
            guard let index = ctx.rowIndex[exact] else { continue }
            switch ctx.stored[exact] ?? StoredEditionState.none {
            case .verified: chosen.satisfied.append(key)
            case .damaged: chosen.damaged.append(key)
            case .queued: chosen.attach.append(key)
            case .none:
                if ctx.baselineRows[index].facts.isLocked { chosen.locked.append(key) } else { chosen.toQueue.append(key) }
            }
        }
        return chosen
    }

    private static func resolved(_ keys: [String], selection: EditionSelection, _ ctx: AdmissionContext) -> Resolution {
        guard let resolvedSelection = ctx.catalogIndex.resolve(selection) else {
            return .decision(.needsReview(.selectionUnresolved))
        }
        let facts = keys.compactMap { key in ctx.rowIndex[ScanlatorUTF8(value: key)].map { ctx.baselineRows[$0].facts } }
        let stored = keys.map { ctx.stored[ScanlatorUTF8(value: $0)] ?? StoredEditionState.none }
        var chosen = Chosen()
        for position in EditionPositionResolver.resolve(facts: facts, stored: stored, selection: resolvedSelection) {
            chosen.toQueue += position.toQueue.map { keys[$0] }
            chosen.satisfied += position.satisfied.map { keys[$0] }
            chosen.damaged += position.damaged.map { keys[$0] }
            chosen.locked += position.locked.map { keys[$0] }
        }
        let hasChosen = !chosen.toQueue.isEmpty || !chosen.satisfied.isEmpty || !chosen.damaged.isEmpty
        if hasChosen || !chosen.locked.isEmpty { return .chosen(chosen) }
        // No row of the position is permitted. Ask only when the person said to; otherwise wait for the group.
        if selection.asksBeforeSwitching {
            let unlocked = zip(keys, facts).filter { !$0.1.isLocked }.map(\.0)
            if !unlocked.isEmpty { return .decision(.needsChoice(candidates: unlocked)) }
        }
        return .decision(.awaitingEdition)
    }

    // MARK: - Caps

    /// The cap that holds new work back, in the order the contract lists them. Attaching to existing jobs adds no
    /// jobs, so it passes the queue and quota caps; the run cap counts positions, the queue cap counts jobs.
    private static func capBlock(newJobs: Int, _ ctx: AdmissionContext) -> SubscriptionPendingReason? {
        if let remaining = ctx.runCapRemaining, remaining <= 0 { return .runCap }
        guard newJobs > 0 else { return nil }
        if ctx.jobCount + newJobs > ctx.limits.queueLimit { return .queueCap }
        let estimated = Int64(ctx.autoOnlyOutstandingJobs + newJobs) * ctx.limits.estimatedJobBytes
        if ctx.storedBytes + estimated > ctx.limits.quotaBytes { return .quota }
        return nil
    }

    // MARK: - Replacement

    /// A revision change under the rule: only a verified copy of the same exact key that carries the revision the
    /// event saw, saved under the current source epoch. Anything else is superseded; a key the selection does not
    /// admit is only recorded.
    private static func decideReplacement(
        _ event: SubscriptionEventRecord,
        key: String,
        selection: EditionSelection,
        _ ctx: AdmissionContext
    ) -> AdmissionDecision {
        let exact = ScanlatorUTF8(value: key)
        guard let index = ctx.rowIndex[exact] else { return .superseded }
        let facts = ctx.baselineRows[index].facts
        guard let resolvedSelection = ctx.catalogIndex.resolve(selection) else {
            return .needsReview(.selectionUnresolved)
        }
        guard resolvedSelection.admits(scanlator: facts.scanlator, groupID: facts.scanlatorID) else { return .recorded }
        switch ctx.stored[exact] ?? StoredEditionState.none {
        case .damaged: return .blockedDamaged
        case .none, .queued: return .superseded
        case .verified: break
        }
        guard let copy = ctx.installed[exact], copy.isVerified, copy.sourceEpochIsCurrent,
              let previous = event.previousRevision, let installedRevision = copy.revision,
              ScanlatorUTF8.bytesEqual(previous, installedRevision) else { return .superseded }
        if ctx.suppressed.contains(exact) { return .suppressed }
        if facts.isLocked { return .locked }
        if let blocked = capBlock(newJobs: 1, ctx) { return .pending(blocked) }
        return .enqueue(keys: [key])
    }
}
