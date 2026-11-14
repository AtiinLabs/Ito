import Foundation
import ito_runner

/// What a batch is planned from: the source's chapters and scanlators, and the policy it is reviewed under. These
/// read only the host's list and a remembered choice, so they live apart from the queueing state.
extension MediaDetailDownloadBatchModel {
    /// The catalog's source-provided scanlator identities, with exact-row counts.
    func scanlatorOptions() -> [ScanlatorOption] {
        var counts: [ScanlatorRef: Int] = [:]
        for chapter in host?.batchChapters ?? [] {
            let reference = ScanlatorRef(
                id: chapter.scanlatorID,
                name: chapter.scanlator,
                binding: chapter.scanlatorID == nil ? .exactIDless : nil
            )
            counts[reference, default: 0] += 1
        }
        return counts
            .map { ScanlatorOption(ref: $0.key, chapterCount: $0.value) }
            .sorted {
                if $0.chapterCount != $1.chapterCount { return $0.chapterCount > $1.chapterCount }
                switch ($0.ref.name, $1.ref.name) {
                case (nil, nil): break
                case (nil, _): return true
                case (_, nil): return false
                case (let left?, let right?):
                    if !left.utf8.elementsEqual(right.utf8) {
                        return left.utf8.lexicographicallyPrecedes(right.utf8)
                    }
                }
                switch ($0.ref.id, $1.ref.id) {
                case (nil, nil): return $0.ref.binding == .exactIDless && $1.ref.binding != .exactIDless
                case (nil, _): return true
                case (_, nil): return false
                case (let left?, let right?): return left.utf8.lexicographicallyPrecedes(right.utf8)
                }
            }
    }

    /// The exact source chapters for `keys`, in reading order. The list is the one a plan was just made from.
    func frozenChapters(keys: Set<String>) -> [Chapter] {
        var seen = Set<String>()
        let chosen = (host?.batchChapters ?? []).filter {
            keys.contains($0.key) && !$0.isPaywalled && seen.insert($0.key).inserted
        }
        let order = ChapterReadingOrder.order(chosen.map { ChapterFacts($0) }).order
        return order.map { chosen[$0] }
    }

    /// What a batch is checked against in the store: the remembered policy this screen planned under.
    /// An unknown policy (a read that failed) is not claimed.
    func reviewedPolicy(of choice: RememberedEditionChoice) -> ReviewedEditionPolicy? {
        switch choice {
        case .none: return ReviewedEditionPolicy.none
        case .unreadable: return ReviewedEditionPolicy.unreadable
        case .chosen(let selection): return ReviewedEditionPolicy.selection(selection)
        case .unknown: return nil
        }
    }
}
