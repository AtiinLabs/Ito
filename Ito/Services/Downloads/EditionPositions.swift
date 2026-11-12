import Foundation

/// The identity of one reading position inside a single plugin, media kind and canonical series catalog.
///
/// Only the source can say that uploads are one position: a number, title, volume, group name or
/// reading order never merges rows. The tags keep a logical unit ID from colliding with a chapter key.
nonisolated enum EditionPositionKey: Hashable, Sendable {
    /// Every row carrying this source logical unit ID, whatever its group.
    case logical(ScanlatorUTF8)
    /// A row without a usable logical unit ID, identified by its exact chapter key.
    case exact(ScanlatorUTF8)

    init(_ facts: ChapterFacts) {
        if let unit = facts.sourceLogicalUnitID {
            self = .logical(ScanlatorUTF8(value: unit))
        } else {
            self = .exact(ScanlatorUTF8(value: facts.key))
        }
    }
}

/// The rows of one catalog that share a position, before any group policy is applied.
nonisolated struct EditionPosition: Sendable {
    let key: EditionPositionKey
    /// Indices into the facts the positions were built from, in source order.
    let members: [Int]
}

/// One position with the rows its group selection permits and what to do with them.
nonisolated struct ResolvedEditionPosition: Sendable {
    let key: EditionPositionKey
    /// Every row of the position, in source order. Read markers and ordering look at all of them.
    let members: [Int]
    /// The rows the selection admits, in the selected groups' order and then source order.
    let permitted: [Int]
    /// Chosen rows with no copy or job yet.
    var toQueue: [Int] = []
    /// Chosen rows already verified or queued: they satisfy the position.
    var satisfied: [Int] = []
    /// Chosen rows whose copy failed verification: they hold the position.
    var damaged: [Int] = []
    /// Permitted rows skipped because the source marks them locked.
    var locked: [Int] = []

    /// The selection admits at least one row of this position.
    var hasPermitted: Bool { !permitted.isEmpty }
    /// A row was chosen, so the position is one the selection can supply.
    var isOccupied: Bool { !toQueue.isEmpty || !satisfied.isEmpty || !damaged.isEmpty }
    /// The chosen rows.
    var chosen: [Int] { toQueue + satisfied + damaged }
    /// The rows in the order the position is represented by: permitted first, then the rest.
    var rankedMembers: [Int] {
        let permittedSet = Set(permitted)
        return permitted + members.filter { !permittedSet.contains($0) }
    }
}

/// Builds reading positions from a catalog and resolves each to exact rows. One definition serves every
/// download preset and saved-copy coverage, so they cannot disagree about what a position is.
nonisolated enum EditionPositionResolver {
    /// The positions of `facts`, in order of their first row. The rows are the full eligible catalog:
    /// group policy is applied afterwards, so a position missing from one group still exists.
    static func positions(of facts: [ChapterFacts]) -> [EditionPosition] {
        var order: [EditionPositionKey] = []
        var members: [EditionPositionKey: [Int]] = [:]
        for index in facts.indices {
            let key = EditionPositionKey(facts[index])
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(index)
        }
        return order.map { EditionPosition(key: $0, members: members[$0] ?? []) }
    }

    /// Resolves every position of `facts`.
    ///
    /// Per position, one permitted row is chosen. An existing copy wins, even when the source now marks the
    /// row locked: a verified copy, else a queued or failed job, else a damaged copy (which blocks the
    /// position). Otherwise the first unlocked row in the selected groups' order and then source order is
    /// queued. A locked row is never queued; a position whose permitted rows are all locked and unsaved is a
    /// gap. A copy outside the permitted groups never satisfies the position. `.allUploads` takes every
    /// permitted row of the position.
    ///
    /// - Parameters:
    ///   - facts: Eligible catalog rows with distinct exact keys.
    ///   - stored: The stored state of each row, by the same indices.
    ///   - selection: The resolved group selection; nil admits nothing.
    static func resolve(
        facts: [ChapterFacts],
        stored: [StoredEditionState],
        selection: ResolvedEditionSelection?
    ) -> [ResolvedEditionPosition] {
        let takesEveryEdition = selection?.selection == .allUploads
        return positions(of: facts).map { position in
            let ranked: [(index: Int, rank: Int, offset: Int)] = position.members.enumerated().compactMap { offset, index in
                guard let rank = selection?.rank(
                    scanlator: facts[index].scanlator,
                    groupID: facts[index].scanlatorID
                ) else { return nil }
                // A fallback group substitutes only inside a position the source proved with a logical unit ID.
                if case .preferred? = selection?.selection, case .exact = position.key, rank > 0 { return nil }
                return (index, rank, offset)
            }
            let permitted = ranked
                .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.offset < $1.offset }
                .map(\.index)
            var resolved = ResolvedEditionPosition(key: position.key, members: position.members, permitted: permitted)

            func choose(_ index: Int) {
                switch stored[index] {
                case .verified, .queued: resolved.satisfied.append(index)
                case .damaged: resolved.damaged.append(index)
                case .none: resolved.toQueue.append(index)
                }
            }

            if takesEveryEdition {
                for index in permitted {
                    if facts[index].isLocked, stored[index] == .none {
                        resolved.locked.append(index)
                    } else {
                        choose(index)
                    }
                }
            } else if let index = permitted.first(where: { stored[$0] == .verified })
                ?? permitted.first(where: { stored[$0] == .queued })
                ?? permitted.first(where: { stored[$0] == .damaged })
                ?? permitted.first(where: { !facts[$0].isLocked }) {
                choose(index)
            } else if let first = permitted.first {
                resolved.locked = [first]
            }
            return resolved
        }
    }
}
