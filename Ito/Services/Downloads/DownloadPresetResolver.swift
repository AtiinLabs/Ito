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
}

nonisolated enum DownloadPlanIssue: Hashable, Sendable {
    /// Reading order cannot be derived confidently.
    case orderingAmbiguous
    /// The recorded anchor key is absent from the selected rows.
    case anchorNotInSelection
    /// Two selected rows share a (volume, number) hint and have distinct source group identities.
    case alternativeUploads
    /// Unread or All over the source list spans multiple source group identities.
    case multipleScanlators
    /// A locked row was skipped inside the window.
    case lockedGap
    case damagedCopies
    /// Fewer positions than requested because the selection filtered rows out; they may fill the gap.
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
    /// Rows outside the selection inside the window, shown and never queued.
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

struct DownloadPresetInput<C: ChapterDisplayable> {
    let preset: DownloadPreset
    /// The chapter list as the source returned it.
    let catalog: [C]
    let selection: EditionSelection
    /// The exact key of the last-read chapter, if one was recorded.
    let anchorKey: String?
    /// The read markers the list shows: exact key or chapter number.
    let isRead: (C) -> Bool
    /// The stored state of one exact key.
    let stored: (String) -> StoredEditionState
    /// Manga and novel chapters; never anime.
    let isStorable: (C) -> Bool
    /// Concrete extraction seam for a source-provided group ID; absent IDs remain nil.
    let scanlatorID: (C) -> String?
    let largeBatchThreshold: Int

    init(
        preset: DownloadPreset,
        catalog: [C],
        selection: EditionSelection,
        anchorKey: String?,
        isRead: @escaping (C) -> Bool,
        stored: @escaping (String) -> StoredEditionState,
        isStorable: @escaping (C) -> Bool,
        scanlatorID: @escaping (C) -> String? = { _ in nil },
        largeBatchThreshold: Int = DownloadPresetResolver.largeBatchThreshold
    ) {
        self.preset = preset
        self.catalog = catalog
        self.selection = selection
        self.anchorKey = anchorKey
        self.isRead = isRead
        self.stored = stored
        self.isStorable = isStorable
        self.scanlatorID = scanlatorID
        self.largeBatchThreshold = largeBatchThreshold
    }
}

/// Resolves a preset over a catalog into exact rows to queue.
///
/// A preset selects reading positions, not transfers: a row already saved or queued satisfies its
/// position and counts toward N. Each exact catalog row is its own position. Number, title and scanlator
/// name are never used to merge rows, to identify a stored edition or to decide that a position is
/// satisfied; (volume, number) only orders rows and flags possible alternative uploads.
nonisolated enum DownloadPresetResolver {
    /// Unread and All preview above this many rows to queue.
    static let largeBatchThreshold = 10
    /// Any preset previews above this many rows to queue.
    static let previewCeiling = 50

    /// Reads each row once, then resolves purely.
    @MainActor
    static func plan<C: ChapterDisplayable & Sendable>(_ input: DownloadPresetInput<C>) -> DownloadPlan<C> {
        let rows = input.catalog.map { chapter -> DownloadPlanRow in
            let storable = input.isStorable(chapter)
            let facts = ChapterFacts(chapter, scanlatorID: input.scanlatorID(chapter), isStorable: storable)
            return DownloadPlanRow(
                facts: facts,
                isRead: storable && input.isRead(chapter),
                stored: storable ? input.stored(facts.key) : .none
            )
        }
        let indexPlan = plan(
            rows: rows,
            preset: input.preset,
            selection: input.selection,
            anchorKey: input.anchorKey,
            largeBatchThreshold: input.largeBatchThreshold
        )
        return indexPlan.map { input.catalog[$0] }
    }

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

        let selectionResolution: ResolvedEditionSelection?
        if let resolvedSelection {
            selectionResolution = resolvedSelection
        } else if case .scanlators = selection {
            selectionResolution = ScanlatorCatalogIndex(
                rows,
                id: { $0.facts.scanlatorID },
                name: { $0.facts.scanlator }
            ).resolve(selection)
        } else {
            selectionResolution = selection.resolve(in: [])
        }
        let selectedCatalog = catalog.filter {
            selectionResolution?.admits(
                scanlator: rows[$0].facts.scanlator,
                groupID: rows[$0].facts.scanlatorID
            ) ?? false
        }
        let ordering = ChapterReadingOrder.order(selectedCatalog.map { rows[$0].facts })
        let selectedOrder = ordering.order.map { selectedCatalog[$0] }

        var plan = DownloadPlan<Int>()
        var taken = 0
        var lastTaken: Int?
        var firstUnreadExamined: Int?

        /// 3. Eligibility, in precedence: locked, satisfied, damaged, candidate.
        func place(_ index: Int) {
            let row = rows[index]
            if row.facts.isLocked {
                plan.locked.append(index)
                return
            }
            switch row.stored {
            case .verified, .queued: plan.satisfied.append(index)
            case .damaged: plan.damaged.append(index)
            case .none: plan.toQueue.append(index)
            }
            taken += 1
            lastTaken = index
        }

        var anchorIndex: Int?
        if let limit = preset.positionLimit {
            // 4. The anchor decides where the window starts.
            var start = 0
            if let anchorKey {
                if let position = selectedOrder.firstIndex(where: { rows[$0].facts.key == anchorKey }) {
                    anchorIndex = selectedOrder[position]
                    start = rows[selectedOrder[position]].isRead ? position + 1 : position
                } else {
                    plan.issues.insert(.anchorNotInSelection)
                }
            }
            // 5. Walk forward, skipping read rows, until N positions are taken.
            for position in start..<selectedOrder.count {
                if taken >= limit { break }
                let index = selectedOrder[position]
                if rows[index].isRead {
                    plan.skippedReadCount += 1
                    continue
                }
                if firstUnreadExamined == nil { firstUnreadExamined = index }
                place(index)
            }
            // Running out at the natural end of the series is not an issue; running out because the
            // selection filtered rows away is, since those rows may fill the gap.
            if taken < limit, selectedCatalog.count < catalog.count { plan.issues.insert(.selectionExhausted) }
        } else {
            for index in selectedOrder {
                // 6. Unread skips read rows; 7. All keeps them.
                if preset == .unread, rows[index].isRead {
                    plan.skippedReadCount += 1
                    continue
                }
                place(index)
            }
            let selectedGroupCount = Set(selectedCatalog.map {
                ScanlatorGroupKey(id: rows[$0].facts.scanlatorID, name: rows[$0].facts.scanlator)
            }).count
            if selectedGroupCount >= 2, selection == .sourceList {
                plan.issues.insert(.multipleScanlators)
            }
        }

        if selectedCatalog.count < catalog.count {
            plan.alternatives = alternatives(
                rows: rows,
                catalog: catalog,
                selectedCatalog: selectedCatalog,
                preset: preset,
                placed: plan.toQueue + plan.satisfied + plan.damaged,
                taken: taken,
                lastTaken: lastTaken,
                anchorIndex: anchorIndex,
                firstUnreadExamined: firstUnreadExamined
            )
        }

        if ordering.confidence == .ambiguous { plan.issues.insert(.orderingAmbiguous) }
        if !plan.locked.isEmpty { plan.issues.insert(.lockedGap) }
        if !plan.damaged.isEmpty { plan.issues.insert(.damagedCopies) }
        if plan.toQueue.isEmpty { plan.issues.insert(.nothingToDo) }
        if hasAlternativeUploads(rows: rows, positions: plan.toQueue + plan.satisfied + plan.damaged) {
            plan.issues.insert(.alternativeUploads)
        }

        // The preview rules: any issue but nothingToDo, a large Unread or All, or a very large batch.
        let isBulk = preset == .unread || preset == .all
        plan.requiresPreview = !plan.issues.subtracting([.nothingToDo]).isEmpty
            || (isBulk && plan.toQueue.count > largeBatchThreshold)
            || plan.toQueue.count > previewCeiling
        return plan
    }

    // MARK: - Internals

    /// Two selected rows with one exact (volume, number) hint and distinct source group identities are
    /// possible alternative uploads. Cached labels never establish or erase group identity.
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

    /// Rows outside the selection that the user may tick in the preview. A candidate is unlocked, has
    /// no stored copy or job, and (except for All) is unread.
    private static func alternatives(
        rows: [DownloadPlanRow],
        catalog: [Int],
        selectedCatalog: [Int],
        preset: DownloadPreset,
        placed: [Int],
        taken: Int,
        lastTaken: Int?,
        anchorIndex: Int?,
        firstUnreadExamined: Int?
    ) -> [Int] {
        let fullOrder = ChapterReadingOrder.order(catalog.map { rows[$0].facts }).order.map { catalog[$0] }
        var position: [Int: Int] = [:]
        for (offset, index) in fullOrder.enumerated() { position[index] = offset }
        let selected = Set(selectedCatalog)

        let candidates = fullOrder.filter { index in
            let row = rows[index]
            return !selected.contains(index) && !row.facts.isLocked && row.stored == .none
                && (preset == .all || !row.isRead)
        }

        if let limit = preset.positionLimit {
            // From the anchor (or the first unread row examined) to the last position taken. When the
            // selection ran out, the rows after it fill the remaining positions.
            var lower = 0
            if let anchorIndex {
                lower = (position[anchorIndex] ?? 0) + (rows[anchorIndex].isRead ? 1 : 0)
            } else if let firstUnreadExamined {
                lower = position[firstUnreadExamined] ?? 0
            }
            let upper = lastTaken.flatMap { position[$0] }
            var inside: [Int] = []
            var tail: [Int] = []
            for index in candidates {
                guard let offset = position[index], offset >= lower else { continue }
                if let upper, offset < upper {
                    inside.append(index)
                } else {
                    tail.append(index)
                }
            }
            return inside + (taken < limit ? Array(tail.prefix(limit - taken)) : [])
        }

        // Unread and All: rows between the first and last selected position.
        let offsets = placed.compactMap { position[$0] }
        guard let lower = offsets.min(), let upper = offsets.max() else { return [] }
        return candidates.filter { index in
            guard let offset = position[index] else { return false }
            return offset > lower && offset < upper
        }
    }
}
