import Foundation

/// The download presets: how many reading positions a menu action selects.
nonisolated enum DownloadPreset: String, Codable, CaseIterable, Sendable {
    case next, next5, next10, unread, all

    /// How many positions the preset asks for, or nil when it takes everything it selects.
    var positionLimit: Int? {
        switch self {
        case .next: 1
        case .next5: 5
        case .next10: 10
        case .unread, .all: nil
        }
    }
}

/// What one exact row already has in the store, looked up by exact chapter key only.
nonisolated enum StoredEditionState: Equatable, Sendable {
    case none
    /// A verified copy, ready to read offline.
    case verified
    /// A copy that failed verification; it must be deleted before it can be downloaded again.
    case damaged
    /// A job is already queued, running or waiting for this exact edition.
    case queued

    /// What the store knows of one exact key. A failed job still occupies its key, so it holds its position
    /// and is not queued again: Retry is the way back.
    init(_ state: ChapterDownloadState?) {
        switch state {
        case nil: self = .none
        case .downloaded?: self = .verified
        case .damaged?: self = .damaged
        case .queued?, .downloading?, .waiting?, .failed?: self = .queued
        }
    }
}

nonisolated enum DownloadPlanIssue: Hashable, Sendable {
    /// Reading order cannot be derived confidently.
    case orderingAmbiguous
    /// The recorded anchor key is not in a position the selection can supply.
    case anchorNotInSelection
    /// Two chosen rows from different source groups share a (volume, number) hint, so they may be
    /// uploads of one chapter. A warning only: nothing treats them as one position.
    case alternativeUploads
    /// Unread or All over the source list spans multiple source group identities.
    case multipleScanlators
    /// A locked row was skipped inside the window.
    case lockedGap
    case damagedCopies
    /// Fewer positions than requested because the selection cannot supply some positions; other rows
    /// may fill the gap.
    case selectionExhausted
    case nothingToDo
}

/// The outcome of one preset over one catalog. `Element` is an exact catalog row.
nonisolated struct DownloadPlan<Element: Sendable>: Sendable {
    /// Exact rows to enqueue, in reading order.
    var toQueue: [Element] = []
    /// Selected positions already verified or queued. They count toward the preset's N.
    var satisfied: [Element] = []
    /// Selected positions with a damaged copy: blocked until that copy is deleted. They count toward N.
    var damaged: [Element] = []
    /// Locked rows, skipped. A gap is noted rather than closed.
    var locked: [Element] = []
    /// Other uploads inside the window, from any group: the extra uploads of positions the plan took and the
    /// rows of positions the selection cannot supply. Shown, never queued unless the user ticks them.
    var alternatives: [Element] = []
    /// Rows the read markers skipped inside the window (Next presets and Unread).
    var skippedReadCount = 0
    var issues: Set<DownloadPlanIssue> = []
    /// Whether the action must show a preview and wait for the user instead of queueing at once.
    var requiresPreview = false

    func map<T: Sendable>(_ transform: (Element) -> T) -> DownloadPlan<T> {
        DownloadPlan<T>(
            toQueue: toQueue.map(transform),
            satisfied: satisfied.map(transform),
            damaged: damaged.map(transform),
            locked: locked.map(transform),
            alternatives: alternatives.map(transform),
            skippedReadCount: skippedReadCount,
            issues: issues,
            requiresPreview: requiresPreview
        )
    }
}

/// One catalog row with the per-row answers the resolver needs.
nonisolated struct DownloadPlanRow: Sendable, Equatable {
    var facts: ChapterFacts
    /// The read marker the user sees: exact key or chapter number.
    var isRead: Bool
    /// The stored state of this exact key. Progress never feeds it.
    var stored: StoredEditionState

    init(facts: ChapterFacts, isRead: Bool = false, stored: StoredEditionState = .none) {
        self.facts = facts
        self.isRead = isRead
        self.stored = stored
    }
}

/// Resolves a preset over a catalog into exact rows to queue.
///
/// A preset selects reading positions, not transfers. Positions come from `EditionPositionResolver`, built
/// over the whole eligible catalog before any group selection is applied: only rows the source gave one
/// logical unit ID share a position, and every other row is its own. Each position takes one permitted
/// exact row (every permitted row for All Editions); a row already saved or queued satisfies its position
/// and counts toward N. Number, title, volume and group name never merge rows or decide that a position is
/// satisfied; (volume, number) only orders rows and flags possible alternative uploads.
nonisolated enum DownloadPresetResolver {
    /// Unread and All preview above this many rows to queue.
    static let largeBatchThreshold = 10
    /// Any preset previews above this many rows to queue.
    static let previewCeiling = 50

    /// The pure resolver. The plan holds indices into `rows`.
    static func plan(
        rows: [DownloadPlanRow],
        preset: DownloadPreset,
        selection: EditionSelection,
        anchorKey: String?,
        largeBatchThreshold: Int = DownloadPresetResolver.largeBatchThreshold,
        resolvedSelection: ResolvedEditionSelection? = nil
    ) -> DownloadPlan<Int> {
        // The catalog the preset sees: storable rows, one per exact key.
        var catalog: [Int] = []
        var seenKeys = Set<String>()
        for index in rows.indices where rows[index].facts.isStorable {
            if seenKeys.insert(rows[index].facts.key).inserted { catalog.append(index) }
        }
        let catalogRows = catalog.map { rows[$0] }

        let selectionResolution: ResolvedEditionSelection?
        if let resolvedSelection {
            selectionResolution = resolvedSelection
        } else if case .scanlators = selection {
            selectionResolution = ScanlatorCatalogIndex(
                catalogRows,
                id: { $0.facts.scanlatorID },
                name: { $0.facts.scanlator }
            ).resolve(selection)
        } else {
            selectionResolution = selection.resolve(in: [])
        }

        // 1. Positions over the whole catalog, then the permitted rows of each. From here on, indices are
        //    offsets into `catalogRows`.
        let positions = EditionPositionResolver.resolve(
            facts: catalogRows.map(\.facts),
            stored: catalogRows.map(\.stored),
            selection: selectionResolution
        )
        var positionOfRow = [Int](repeating: 0, count: catalogRows.count)
        for (position, resolved) in positions.enumerated() {
            for row in resolved.members { positionOfRow[row] = position }
        }
        // A position is read when any of its rows carries the read marker the list shows.
        let isRead = positions.map { position in position.members.contains { catalogRows[$0].isRead } }

        // 2. The positions this selection can supply, in reading order.
        let permittedPositions = positions.indices.filter { positions[$0].hasPermitted }
        let ordering = ChapterReadingOrder.order(
            positions: permittedPositions.map { position in
                positions[position].rankedMembers.map { catalogRows[$0].facts }
            }
        )
        let selectedOrder = ordering.order.map { permittedPositions[$0] }

        var plan = DownloadPlan<Int>()
        var taken = 0
        var lastTaken: Int?
        var firstUnreadExamined: Int?
        var placed: [Int] = []

        /// 3. Eligibility: a locked position is skipped; any other takes its chosen rows. All Editions can
        ///    leave out the uploads that are read, locked ones included.
        func place(_ position: Int, skippingReadRows: Bool = false) {
            let resolved = positions[position]
            func unread(_ rows: [Int]) -> [Int] {
                skippingReadRows ? rows.filter { !catalogRows[$0].isRead } : rows
            }
            plan.locked += unread(resolved.locked)
            guard resolved.isOccupied else { return }
            plan.toQueue += unread(resolved.toQueue)
            plan.satisfied += unread(resolved.satisfied)
            plan.damaged += unread(resolved.damaged)
            placed.append(position)
            taken += 1
            lastTaken = position
        }

        var anchorPosition: Int?
        if let limit = preset.positionLimit {
            // 4. The anchor decides where the window starts. Its exact key finds its position; no number or
            //    group name maps an anchor into another group's rows.
            var start = 0
            if let anchorKey {
                if let anchorRow = catalogRows.firstIndex(where: { $0.facts.key == anchorKey }),
                   let offset = selectedOrder.firstIndex(of: positionOfRow[anchorRow]) {
                    anchorPosition = selectedOrder[offset]
                    start = isRead[selectedOrder[offset]] ? offset + 1 : offset
                } else {
                    plan.issues.insert(.anchorNotInSelection)
                }
            }
            // 5. Walk forward, skipping read positions, until N positions are taken.
            for offset in start..<selectedOrder.count {
                if taken >= limit { break }
                let position = selectedOrder[offset]
                if isRead[position] {
                    plan.skippedReadCount += 1
                    continue
                }
                if firstUnreadExamined == nil { firstUnreadExamined = position }
                place(position)
            }
            // Running out at the natural end of the series is not an issue; running out because the
            // selection cannot supply some positions is, since other groups' rows may fill the gap.
            if taken < limit, positions.contains(where: { !$0.hasPermitted }) { plan.issues.insert(.selectionExhausted) }
        } else {
            // 6. Unread skips read positions, or under All Editions the uploads that are read themselves;
            //    7. All keeps everything.
            let readsPerUpload = preset == .unread && selectionResolution?.selection == .allUploads
            for position in selectedOrder {
                if preset == .unread {
                    let resolved = positions[position]
                    // Under All Editions every upload, locked ones too, is judged by its own marker.
                    let uploads = resolved.chosen + resolved.locked
                    let skipped = readsPerUpload
                        ? !uploads.isEmpty && uploads.allSatisfy { catalogRows[$0].isRead }
                        : isRead[position]
                    if skipped {
                        plan.skippedReadCount += 1
                        continue
                    }
                }
                place(position, skippingReadRows: readsPerUpload)
            }
            // The groups the source list spans: the representative upload of every position the selection
            // can supply, read or locked or not.
            let representedGroups = Set(selectedOrder.compactMap { positions[$0].rankedMembers.first }.map {
                ScanlatorGroupKey(id: catalogRows[$0].facts.scanlatorID, name: catalogRows[$0].facts.scanlator)
            })
            if representedGroups.count >= 2, selection == .sourceList {
                plan.issues.insert(.multipleScanlators)
            }
        }

        plan.alternatives = alternatives(
            rows: catalogRows,
            positions: positions,
            isRead: isRead,
            preset: preset,
            placed: placed,
            taken: taken,
            lastTaken: lastTaken,
            anchorPosition: anchorPosition,
            firstUnreadExamined: firstUnreadExamined
        )

        if ordering.confidence == .ambiguous { plan.issues.insert(.orderingAmbiguous) }
        if !plan.locked.isEmpty { plan.issues.insert(.lockedGap) }
        if !plan.damaged.isEmpty { plan.issues.insert(.damagedCopies) }
        if plan.toQueue.isEmpty { plan.issues.insert(.nothingToDo) }
        if hasAlternativeUploads(rows: catalogRows, positions: plan.toQueue + plan.satisfied + plan.damaged) {
            plan.issues.insert(.alternativeUploads)
        }

        // The preview rules: any issue but nothingToDo, a large Unread or All, or a very large batch.
        let isBulk = preset == .unread || preset == .all
        plan.requiresPreview = !plan.issues.subtracting([.nothingToDo]).isEmpty
            || (isBulk && plan.toQueue.count > largeBatchThreshold)
            || plan.toQueue.count > previewCeiling
        return plan.map { catalog[$0] }
    }

    // MARK: - Internals

    /// Two chosen rows with one exact (volume, number) hint and distinct source group identities may be
    /// alternative uploads of one chapter. Only a warning: the source gave them no shared logical unit ID, so
    /// nothing treats them as one position. Cached labels never establish or erase group identity.
    private static func hasAlternativeUploads(rows: [DownloadPlanRow], positions: [Int]) -> Bool {
        struct Hint: Hashable {
            let volume: Float?
            let number: Float
        }
        var groupKeys: [Hint: Set<ScanlatorGroupKey>] = [:]
        for index in positions {
            let facts = rows[index].facts
            guard let number = facts.number, number.isFinite else { continue }
            let volume = facts.volume.flatMap { $0.isFinite ? $0 : nil }
            groupKeys[Hint(volume: volume, number: number), default: []]
                .insert(ScanlatorGroupKey(id: facts.scanlatorID, name: facts.scanlator))
        }
        return groupKeys.values.contains { $0.count >= 2 }
    }

    /// Rows the user may tick in the preview: other rows of the positions the plan took, and the rows of
    /// positions the selection cannot supply that sit inside the preset's range. A candidate is unlocked, has
    /// no stored copy or job, and (except for All) is unread. Never queued unless ticked.
    private static func alternatives(
        rows: [DownloadPlanRow],
        positions: [ResolvedEditionPosition],
        isRead: [Bool],
        preset: DownloadPreset,
        placed: [Int],
        taken: Int,
        lastTaken: Int?,
        anchorPosition: Int?,
        firstUnreadExamined: Int?
    ) -> [Int] {
        // Order over every position, permitted or not: a range needs both kinds.
        let fullOrder = ChapterReadingOrder.order(
            positions: positions.map { position in position.rankedMembers.map { rows[$0].facts } }
        ).order
        var offsets = [Int](repeating: 0, count: positions.count)
        for (offset, position) in fullOrder.enumerated() { offsets[position] = offset }
        let placedSet = Set(placed)

        func candidates(_ position: Int) -> [Int] {
            guard preset == .all || !isRead[position] else { return [] }
            let chosen = Set(positions[position].chosen)
            return positions[position].members.filter { index in
                !chosen.contains(index) && !rows[index].facts.isLocked && rows[index].stored == .none
                    && (preset == .all || !rows[index].isRead)
            }
        }

        var result: [Int] = []
        if let limit = preset.positionLimit {
            // From the anchor (or the first unread position examined) to the last position taken. When the
            // selection ran out, the positions after it fill the remaining ones.
            var lower = 0
            if let anchorPosition {
                lower = offsets[anchorPosition] + (isRead[anchorPosition] ? 1 : 0)
            } else if let firstUnreadExamined {
                lower = offsets[firstUnreadExamined]
            }
            let upper = lastTaken.map { offsets[$0] }
            var tailBudget = taken < limit ? limit - taken : 0
            for position in fullOrder {
                let candidateRows = candidates(position)
                guard !candidateRows.isEmpty else { continue }
                if placedSet.contains(position) {
                    result += candidateRows
                } else if offsets[position] >= lower {
                    if let upper, offsets[position] < upper {
                        result += candidateRows
                    } else if tailBudget > 0 {
                        tailBudget -= 1
                        result += candidateRows
                    }
                }
            }
            return result
        }

        // Unread and All: positions between the first and last one taken.
        let placedOffsets = placed.map { offsets[$0] }
        guard let lower = placedOffsets.min(), let upper = placedOffsets.max() else { return [] }
        for position in fullOrder {
            let candidateRows = candidates(position)
            guard !candidateRows.isEmpty else { continue }
            if placedSet.contains(position) || (offsets[position] > lower && offsets[position] < upper) {
                result += candidateRows
            }
        }
        return result
    }
}
