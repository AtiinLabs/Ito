import Foundation
import ito_runner

/// The facts about one catalog row that ordering, selection and coverage need, copied out of a
/// `ChapterDisplayable` so the pure code runs off the main actor and holds no references.
nonisolated struct ChapterFacts: Sendable, Equatable {
    let key: String
    let number: Float?
    let volume: Float?
    let scanlator: String?
    /// The source's group identifier, when available in its chapter descriptor.
    let scanlatorID: String?
    /// A known paywall lock. A locked row is never queued.
    let isLocked: Bool
    /// Manga and novel rows only; anime episodes are never stored.
    let isStorable: Bool
    /// The source's identifier shared by every upload it declares to be one reading position.
    let logicalUnitID: String?
    /// The source-declared reading position (ABI 3), when it gives one. Meaningful only within the
    /// response it came from.
    let readingOrder: Int64?

    init(
        key: String,
        number: Float? = nil,
        volume: Float? = nil,
        scanlator: String? = nil,
        scanlatorID: String? = nil,
        isLocked: Bool = false,
        isStorable: Bool = true,
        logicalUnitID: String? = nil,
        readingOrder: Int64? = nil
    ) {
        self.key = key
        self.number = number
        self.volume = volume
        self.scanlator = scanlator
        self.scanlatorID = scanlatorID
        self.isLocked = isLocked
        self.isStorable = isStorable
        self.logicalUnitID = logicalUnitID
        self.readingOrder = readingOrder
    }

    /// The source-supplied logical unit ID when it is usable: an absent or empty value identifies nothing.
    var sourceLogicalUnitID: String? {
        logicalUnitID.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `ChapterDisplayable` is main-actor isolated by the module's default, so this is the one place a
    /// row is read; everything after it is pure.
    @MainActor
    init<C: ChapterDisplayable>(_ chapter: C, isStorable: Bool = true) {
        self.init(
            key: chapter.key,
            number: chapter.chapterNumber,
            volume: chapter.volumeNumber,
            scanlator: chapter.scanlator,
            scanlatorID: chapter.scanlatorID,
            isLocked: chapter.isPaywalled,
            isStorable: isStorable,
            logicalUnitID: chapter.logicalUnitID,
            readingOrder: chapter.readingOrder
        )
    }

    /// The same projection for a runner chapter, usable off the main actor.
    init(_ chapter: Chapter, isStorable: Bool = true) {
        self.init(
            key: chapter.key,
            number: chapter.chapterNumber,
            volume: chapter.volumeNumber,
            scanlator: chapter.scanlator,
            scanlatorID: chapter.scanlatorID,
            isLocked: chapter.paywalled ?? false,
            isStorable: isStorable,
            logicalUnitID: chapter.logicalUnitID,
            readingOrder: chapter.readingOrder
        )
    }
}

/// Reading order for downloads: a total order over a catalog, with an honest statement of how much to
/// trust it.
///
/// Catalogs arrive newest first. Order is derived from numbers and volumes only; a title, a scanlator
/// name or an upload date never places a row. Where the order cannot be derived, the result is the
/// newest-first convention marked `.ambiguous`, so a caller can ask the user instead of guessing.
nonisolated enum ChapterReadingOrder {
    enum Confidence: Sendable, Equatable {
        case confident
        case ambiguous
    }

    struct Result: Sendable, Equatable {
        /// Indices into the input, earliest reading position first.
        let order: [Int]
        let confidence: Confidence
    }

    /// The rows in reading order, earliest first.
    @MainActor
    static func order<C: ChapterDisplayable>(_ rows: [C]) -> (rows: [C], confidence: Confidence) {
        let result = order(rows.map { ChapterFacts($0) })
        return (result.order.map { rows[$0] }, result.confidence)
    }

    /// Rows in reading order. Rows that share a source logical unit ID declare one position, so they may
    /// share a source reading order; any other shared order is not evidence of an order.
    static func order(_ facts: [ChapterFacts]) -> Result {
        var rowsByUnit: [ScanlatorUTF8: [ChapterFacts]] = [:]
        for fact in facts {
            if let unit = fact.sourceLogicalUnitID { rowsByUnit[ScanlatorUTF8(value: unit), default: []].append(fact) }
        }
        return order(facts, memberOrdersConflict: rowsByUnit.values.contains { hasConflictingOrders($0) })
    }

    /// Reading positions in reading order, earliest first. Each element holds the rows of one position, the
    /// first of which stands for it. Rows of one position that declare different source orders make the order
    /// ambiguous and leave it in source order; an order shared by two positions does the same.
    static func order(positions: [[ChapterFacts]]) -> Result {
        order(
            positions.compactMap(\.first),
            memberOrdersConflict: positions.contains { hasConflictingOrders($0) }
        )
    }

    private static func hasConflictingOrders(_ members: [ChapterFacts]) -> Bool {
        Set(members.compactMap(\.readingOrder)).count > 1
    }

    /// Whether two rows that are not declared one position carry the same source order.
    private static func sharesOrderAcrossPositions(_ facts: [ChapterFacts]) -> Bool {
        var seen: [Int64: ScanlatorUTF8?] = [:]
        for fact in facts {
            guard let order = fact.readingOrder else { continue }
            let unit = fact.sourceLogicalUnitID.map { ScanlatorUTF8(value: $0) }
            if let previous = seen[order] {
                guard let previous, let unit, previous == unit else { return true }
            } else {
                seen[order] = .some(unit)
            }
        }
        return false
    }

    private static func order(_ facts: [ChapterFacts], memberOrdersConflict: Bool) -> Result {
        let count = facts.count
        // Nothing to order: no direction to doubt.
        if count <= 1 { return Result(order: Array(0..<count), confidence: .confident) }
        let numbers = facts.map { fact in fact.number.flatMap { $0.isFinite ? $0 : nil } }
        let numbered = facts.indices.filter { numbers[$0] != nil }

        // The volume is part of the key only when every numbered row has one; a partial set cannot place
        // rows across volumes.
        let volumes = facts.map { fact in fact.volume.flatMap { $0.isFinite ? $0 : nil } }
        let volumeCount = numbered.filter { volumes[$0] != nil }.count
        let allNumberedHaveVolumes = !numbered.isEmpty && volumeCount == numbered.count
        let mixedVolumes = volumeCount != 0 && volumeCount != numbered.count

        func key(_ index: Int, usingVolume: Bool) -> OrderKey? {
            guard let number = numbers[index] else { return nil }
            return OrderKey(volume: usingVolume ? (volumes[index] ?? 0) : 0, number: number)
        }

        // The direction the source lists rows in, from the numbered rows alone.
        let sourceKeys = numbered.compactMap { key($0, usingVolume: allNumberedHaveVolumes) }
        let direction = Direction(of: sourceKeys)
        // Rows from oldest to newest as the source lists them. Without a determinable direction, the
        // newest-first convention holds.
        let oldestFirst: [Int] = direction == .oldestFirst ? Array(0..<count) : Array((0..<count).reversed())

        // 1. A source-declared reading position on every row decides, for this response only. Conflicting
        //    or shared declarations keep the source's own sequence and say so.
        if count > 0, facts.allSatisfy({ $0.readingOrder != nil }) {
            if memberOrdersConflict || sharesOrderAcrossPositions(facts) {
                return Result(order: oldestFirst, confidence: .ambiguous)
            }
            return Result(order: stableSort(oldestFirst) { facts[$0].readingOrder ?? 0 }, confidence: .confident)
        }

        // 2. Every row numbered.
        if numbered.count == count {
            if mixedVolumes {
                // A volume reset with partial volume data can only be ordered by number when numbers are
                // unique across the catalog.
                guard Set(numbers.compactMap { $0 }).count == count else {
                    return Result(order: oldestFirst, confidence: .ambiguous)
                }
                return Result(
                    order: stableSort(oldestFirst) { key($0, usingVolume: false) ?? OrderKey(volume: 0, number: 0) },
                    confidence: .confident
                )
            }
            let order = stableSort(oldestFirst) {
                key($0, usingVolume: allNumberedHaveVolumes) ?? OrderKey(volume: 0, number: 0)
            }
            // When the source direction is undetermined, any repeated key may mean the numbering restarts
            // (a new season or arc without volume data), so the order cannot be trusted. Adjacent splits
            // keep a clear direction, and unique numbers need none.
            let hasRepeatedKeys = Set(sourceKeys).count < sourceKeys.count
            let confidence: Confidence = direction == .undetermined && hasRepeatedKeys ? .ambiguous : .confident
            return Result(order: order, confidence: confidence)
        }

        // 3. Some rows unnumbered: keep the source sequence, oriented by the numbered rows when they run
        //    one way, and otherwise assume newest first and say so.
        switch direction {
        case .oldestFirst:
            return Result(order: Array(0..<count), confidence: .confident)
        case .newestFirst:
            return Result(order: Array((0..<count).reversed()), confidence: .confident)
        case .undetermined:
            return Result(order: Array((0..<count).reversed()), confidence: .ambiguous)
        }
    }

    // MARK: - Internals

    /// Volume then number. Equal keys are Float collisions or same-number splits; they are never merged.
    private struct OrderKey: Comparable, Hashable {
        let volume: Float
        let number: Float

        static func < (lhs: OrderKey, rhs: OrderKey) -> Bool {
            lhs.volume != rhs.volume ? lhs.volume < rhs.volume : lhs.number < rhs.number
        }
    }

    private enum Direction: Equatable {
        case newestFirst
        case oldestFirst
        /// Fewer than two distinct keys, or keys that run both ways.
        case undetermined

        init(of keys: [OrderKey]) {
            var increases = false
            var decreases = false
            for (previous, next) in zip(keys, keys.dropFirst()) {
                if next > previous { increases = true }
                if next < previous { decreases = true }
            }
            switch (increases, decreases) {
            case (true, false): self = .oldestFirst
            case (false, true): self = .newestFirst
            default: self = .undetermined
            }
        }
    }

    /// An ascending sort in which equal keys keep their input order.
    private static func stableSort<K: Comparable>(_ indices: [Int], by key: (Int) -> K) -> [Int] {
        indices.enumerated()
            .map { (position: $0.offset, index: $0.element, key: key($0.element)) }
            .sorted { $0.key != $1.key ? $0.key < $1.key : $0.position < $1.position }
            .map(\.index)
    }
}
