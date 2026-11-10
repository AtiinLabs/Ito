import Foundation
import Testing
@testable import Ito

struct ChapterReadingOrderTests {
    private func row(_ key: String, _ number: Float?, volume: Float? = nil, order: Int? = nil) -> ChapterFacts {
        ChapterFacts(key: key, number: number, volume: volume, readingOrder: order)
    }

    private func keys(_ rows: [ChapterFacts]) -> (order: [String], confidence: ChapterReadingOrder.Confidence) {
        let result = ChapterReadingOrder.order(rows)
        return (result.order.map { rows[$0].key }, result.confidence)
    }

    @Test func newestFirstCatalogReadsOldestFirst() {
        let result = keys([row("5", 5), row("4", 4), row("3", 3), row("2", 2), row("1", 1)])
        #expect(result.order == ["1", "2", "3", "4", "5"])
        #expect(result.confidence == .confident)
    }

    @Test func oldestFirstCatalogKeepsItsOrder() {
        let result = keys([row("1", 1), row("2", 2), row("3", 3)])
        #expect(result.order == ["1", "2", "3"])
        #expect(result.confidence == .confident)
    }

    @Test func numberedRowsSortEvenWhenTheSourceListIsShuffled() {
        let result = keys([row("3", 3), row("1", 1), row("5", 5), row("2", 2), row("4", 4)])
        #expect(result.order == ["1", "2", "3", "4", "5"])
        #expect(result.confidence == .confident)
    }

    @Test func equalNumbersKeepTheSourceDirectionNewestFirst() {
        let result = keys([row("17", 17), row("part2", 16), row("part1", 16), row("15", 15)])
        #expect(result.order == ["15", "part1", "part2", "17"])
        #expect(result.confidence == .confident)
    }

    @Test func equalNumbersKeepTheSourceDirectionOldestFirst() {
        let result = keys([row("15", 15), row("part1", 16), row("part2", 16), row("17", 17)])
        #expect(result.order == ["15", "part1", "part2", "17"])
        #expect(result.confidence == .confident)
    }

    @Test func floatCollisionsAreOrderedBySourceDirectionAndNeverMerged() {
        // Two distinct source numbers that round to one Float.
        let near = Float(16.000000001)
        let result = keys([row("b", near), row("a", 16.0), row("15", 15)])
        #expect(near == 16.0)
        #expect(result.order == ["15", "a", "b"])
        #expect(result.confidence == .confident)
    }

    @Test func fullVolumeResetOrdersByVolumeThenNumber() {
        var rows: [ChapterFacts] = []
        for volume in [Float(2), 1] {
            for number in (1...10).reversed() {
                rows.append(row("v\(Int(volume))c\(number)", Float(number), volume: volume))
            }
        }
        let result = keys(rows)
        let expected = [1, 2].flatMap { volume in (1...10).map { "v\(volume)c\($0)" } }
        #expect(result.order == expected)
        #expect(result.confidence == .confident)
    }

    @Test func aNumberingResetWithoutVolumesIsAmbiguous() {
        let season2 = (1...10).reversed().map { row("s2c\($0)", Float($0)) }
        let season1 = (1...10).reversed().map { row("s1c\($0)", Float($0)) }
        let result = keys(season2 + season1)

        #expect(result.confidence == .ambiguous)
        #expect(Set(result.order).count == 20)
    }

    @Test func adjacentSplitsAndUniqueShuffledNumbersStayConfident() {
        let splits = keys([row("c3", 3), row("p2", 2), row("p1", 2), row("c1", 1)])
        #expect(splits.confidence == .confident)

        let shuffled = keys([row("c2", 2), row("c4", 4), row("c1", 1), row("c3", 3)])
        #expect(shuffled.confidence == .confident)
        #expect(shuffled.order == ["c1", "c2", "c3", "c4"])
    }

    @Test func partialVolumesWithRepeatedNumbersAreAmbiguous() {
        // Volume 2 restarts at 1 but the oldest rows carry no volume.
        let rows = [row("v2c2", 2, volume: 2), row("v2c1", 1, volume: 2), row("c2", 2), row("c1", 1)]
        let result = keys(rows)
        #expect(result.confidence == .ambiguous)
        // The newest-first convention stands in.
        #expect(result.order == ["c1", "c2", "v2c1", "v2c2"])
    }

    @Test func partialVolumesWithUniqueNumbersSortByNumber() {
        let rows = [row("3", 3, volume: 2), row("2", 2), row("1", 1)]
        let result = keys(rows)
        #expect(result.order == ["1", "2", "3"])
        #expect(result.confidence == .confident)
    }

    @Test func unnumberedRowsFollowTheSourceWhenNumberedRowsRunOneWay() {
        let newestFirst = keys([row("extra", nil), row("5", 5), row("4", 4), row("note", nil), row("3", 3)])
        #expect(newestFirst.order == ["3", "note", "4", "5", "extra"])
        #expect(newestFirst.confidence == .confident)

        let oldestFirst = keys([row("1", 1), row("note", nil), row("2", 2), row("3", 3)])
        #expect(oldestFirst.order == ["1", "note", "2", "3"])
        #expect(oldestFirst.confidence == .confident)
    }

    @Test func nonMonotoneNumberedRowsWithUnnumberedAreAmbiguous() {
        let result = keys([row("3", 3), row("x", nil), row("5", 5), row("4", 4)])
        #expect(result.confidence == .ambiguous)
        #expect(result.order == ["4", "5", "x", "3"])
    }

    @Test func aSingleNumberedRowCannotGiveADirection() {
        let result = keys([row("a", nil), row("1", 1), row("b", nil)])
        #expect(result.confidence == .ambiguous)
        #expect(result.order == ["b", "1", "a"])
    }

    @Test func allUnnumberedRowsAreAmbiguous() {
        let result = keys([row("c", nil), row("b", nil), row("a", nil)])
        #expect(result.confidence == .ambiguous)
        #expect(result.order == ["a", "b", "c"])
    }

    @Test func nonFiniteNumbersCountAsUnnumbered() {
        let result = keys([row("nan", .nan), row("2", 2), row("inf", .infinity), row("1", 1)])
        #expect(result.order == ["1", "inf", "2", "nan"])
        #expect(result.confidence == .confident)
    }

    @Test func sourceDeclaredPositionOverridesNumbers() {
        let result = keys([row("a", 1, order: 3), row("b", 2, order: 1), row("c", 3, order: 2)])
        #expect(result.order == ["b", "c", "a"])
        #expect(result.confidence == .confident)
    }

    @Test func sourceDeclaredPositionOnlyCountsWhenEveryRowHasOne() {
        let result = keys([row("a", 3, order: 1), row("b", 2), row("c", 1)])
        #expect(result.order == ["c", "b", "a"])
    }

    @Test func emptyAndSingleCatalogsAreConfident() {
        #expect(ChapterReadingOrder.order([]).order.isEmpty)
        #expect(ChapterReadingOrder.order([]).confidence == .confident)
        let single = ChapterReadingOrder.order([row("only", nil)])
        #expect(single.order == [0])
        #expect(single.confidence == .confident)
    }

    @Test func orderingNeverDropsOrRepeatsARow() {
        let rows = [row("a", 3), row("b", nil), row("c", 3), row("d", 1, volume: 2), row("e", 1)]
        let result = ChapterReadingOrder.order(rows)
        #expect(result.order.sorted() == Array(rows.indices))
    }

    @MainActor
    @Test func genericOrderReturnsTheRowsThemselves() {
        let rows = [
            DownloadTestChapter(key: "c3", number: 3),
            DownloadTestChapter(key: "c2", number: 2),
            DownloadTestChapter(key: "c1", number: 1)
        ]
        let result = ChapterReadingOrder.order(rows)
        #expect(result.rows.map(\.key) == ["c1", "c2", "c3"])
        #expect(result.confidence == .confident)
    }
}
