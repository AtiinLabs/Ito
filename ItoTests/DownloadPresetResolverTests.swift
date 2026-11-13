import Foundation
import Testing
@testable import Ito

/// A catalog row for resolver tests.
nonisolated struct DownloadTestChapter: ChapterDisplayable, Sendable {
    let key: String
    let chapterNumber: Float?
    let scanlator: String?
    let volumeNumber: Float?
    let isPaywalled: Bool

    var id: String { key }
    var title: String? { nil }
    var dateUpload: String? { nil }

    init(key: String, number: Float?, scanlator: String? = nil, volume: Float? = nil, locked: Bool = false) {
        self.key = key
        self.chapterNumber = number
        self.scanlator = scanlator
        self.volumeNumber = volume
        self.isPaywalled = locked
    }
}

@MainActor
struct DownloadPresetResolverTests {
    private typealias Chapter = DownloadTestChapter
    private typealias Plan = DownloadPlan<DownloadTestChapter>

    // MARK: Fixtures

    /// Rows numbered `numbers` from one scanlator, earliest first. Keys read "A16" or, without a
    /// scanlator, "c16".
    private func rows(_ scanlator: String?, _ numbers: ClosedRange<Int>) -> [Chapter] {
        numbers.map { Chapter(key: "\(scanlator ?? "c")\($0)", number: Float($0), scanlator: scanlator) }
    }

    /// A catalog as a source lists it: newest first.
    private func listed(_ earliestFirst: [Chapter]...) -> [Chapter] {
        Array(earliestFirst.flatMap { $0 }.reversed())
    }

    /// The read markers the list shows: an exact key or a chapter number.
    private func plan(
        _ preset: DownloadPreset,
        _ catalog: [Chapter],
        selection: EditionSelection = .sourceList,
        anchor: String? = nil,
        read: Set<String> = [],
        readNumbers: Set<Float> = [],
        stored: [String: StoredEditionState] = [:],
        storable: Bool = true,
        threshold: Int = DownloadPresetResolver.largeBatchThreshold
    ) -> Plan {
        let rows = catalog.map { chapter -> DownloadPlanRow in
            let isRead = read.contains(chapter.key) || (chapter.chapterNumber.map { readNumbers.contains($0) } ?? false)
            let state = stored[chapter.key] ?? StoredEditionState.none
            return DownloadPlanRow(
                facts: ChapterFacts(chapter, isStorable: storable),
                isRead: storable && isRead,
                stored: storable ? state : StoredEditionState.none
            )
        }
        return DownloadPresetResolver.plan(
            rows: rows,
            preset: preset,
            selection: selection,
            anchorKey: anchor,
            largeBatchThreshold: threshold
        ).map { catalog[$0] }
    }

    private func keys(_ rows: [Chapter]) -> [String] { rows.map(\.key) }

    private func keys(_ prefix: String, _ numbers: ClosedRange<Int>) -> [String] {
        numbers.map { "\(prefix)\($0)" }
    }

    // MARK: Contract examples

    @Test func nextFiveQueuesOnlyTheMissingPositionOfTwentyOneToTwentyFive() {
        let catalog = listed(rows(nil, 1...25))
        let read = Set(keys("c", 1...20))
        let stored = Dictionary(uniqueKeysWithValues: keys("c", 21...24).map { ($0, StoredEditionState.verified) })

        let result = plan(.next5, catalog, anchor: "c20", read: read, stored: stored)

        #expect(keys(result.toQueue) == ["c25"])
        #expect(keys(result.satisfied) == keys("c", 21...24))
        #expect(result.issues.isEmpty)
        #expect(!result.requiresPreview)
    }

    @Test func queuedRowsAlreadySatisfyTheirPositionAndAreNotQueuedAgain() {
        let catalog = listed(rows(nil, 21...25))
        let result = plan(.next5, catalog, stored: ["c21": .queued, "c22": .verified])

        #expect(keys(result.toQueue) == keys("c", 23...25))
        #expect(keys(result.satisfied) == ["c21", "c22"])
        #expect(!result.requiresPreview)
    }

    @Test func nextAtTheNaturalEndOfASeriesTakesWhatRemainsWithoutAPreview() {
        let catalog = listed(rows(nil, 1...10))
        let result = plan(.next5, catalog, anchor: "c7", read: Set(keys("c", 1...7)))

        #expect(keys(result.toQueue) == ["c8", "c9", "c10"])
        #expect(result.issues.isEmpty)
        #expect(!result.requiresPreview)
    }

    // MARK: Scanlators A 1-15 / B 16+

    @Test func sourceListFollowsTheAnchorFromOneScanlatorIntoTheNext() {
        let catalog = listed(rows("A", 1...15), rows("B", 16...30))
        let result = plan(.next5, catalog, anchor: "A15", read: Set(keys("A", 1...15)))

        #expect(keys(result.toQueue) == keys("B", 16...20))
        #expect(result.issues.isEmpty)
        #expect(!result.requiresPreview)
    }

    @Test func aStrictSelectionNeverBorrowsTheOtherScanlatorsRows() {
        let catalog = listed(rows("A", 1...15), rows("B", 16...30))
        let result = plan(
            .next5,
            catalog,
            selection: .scanlators([ScanlatorRef(name: "A")]),
            anchor: "A15",
            read: Set(keys("A", 1...15))
        )

        #expect(result.toQueue.isEmpty)
        #expect(result.issues.contains(.selectionExhausted))
        #expect(keys(result.alternatives) == keys("B", 16...20))
        #expect(result.requiresPreview)
    }

    @Test func unreadIncludesUnreadRowsBeforeTheAnchor() {
        let catalog = listed(rows("A", 1...15), rows("B", 16...30))
        let read = Set(keys("A", 1...15)).subtracting(["A3"])
        let result = plan(
            .unread,
            catalog,
            selection: .scanlators([ScanlatorRef(name: "A")]),
            anchor: "A15",
            read: read
        )

        #expect(keys(result.toQueue) == ["A3"])
        #expect(result.skippedReadCount == 14)
    }

    @Test func nameMatchingIsExactSoARenamedGroupSelectsNothing() {
        let catalog = listed(rows("Alpha", 1...3))
        for preset in [DownloadPreset.all, .unread] {
            let result = plan(preset, catalog, selection: .scanlators([ScanlatorRef(name: "alpha")]))
            #expect(result.toQueue.isEmpty)
            #expect(keys(result.alternatives).isEmpty)
            #expect(result.issues == [.nothingToDo])
        }
    }

    @Test func alternativesInsideTheWindowAreShownButNeverQueued() {
        // 16..18 listed by two scanlators, interleaved.
        let a = rows("A", 16...18)
        let b = rows("B", 16...18)
        let catalog = listed([a[0], b[0], a[1], b[1], a[2], b[2]])
        let onlyA = EditionSelection.scanlators([ScanlatorRef(name: "A")])

        // One position: B16 shares A16's number but is not inside that window.
        let next = plan(.next, catalog, selection: onlyA)
        #expect(keys(next.toQueue) == ["A16"])
        #expect(next.alternatives.isEmpty)
        #expect(!next.requiresPreview)

        // Five positions: A has only three, so B's rows inside the window are listed, and the rows after
        // it fill the positions A could not.
        let five = plan(.next5, catalog, selection: onlyA)
        #expect(keys(five.toQueue) == ["A16", "A17", "A18"])
        #expect(keys(five.alternatives) == ["B16", "B17", "B18"])
        #expect(five.issues.contains(.selectionExhausted))
    }

    // MARK: Exact versus number progress

    @Test func numberMarksSkipEveryEditionOfThatNumberOutsideAll() {
        let catalog = listed([
            Chapter(key: "A15", number: 15, scanlator: "A"),
            Chapter(key: "A16", number: 16, scanlator: "A"),
            Chapter(key: "B16", number: 16, scanlator: "B"),
            Chapter(key: "B17", number: 17, scanlator: "B")
        ])
        let read: Set<String> = ["A15", "B16"]
        let readNumbers: Set<Float> = [16]

        let unread = plan(.unread, catalog, read: read, readNumbers: readNumbers)
        #expect(keys(unread.toQueue) == ["B17"])

        let all = plan(.all, catalog, read: read, readNumbers: readNumbers)
        #expect(keys(all.toQueue) == ["A15", "A16", "B16", "B17"])
    }

    @Test func aNumberOnlyMarkMovesNextWithoutTouchingStoredIdentity() {
        let catalog = listed(rows(nil, 1...30))
        let readNumbers = Set((1...20).map(Float.init))

        let next = plan(.next, catalog, readNumbers: readNumbers)
        #expect(keys(next.toQueue) == ["c21"])

        let nextFive = plan(.next5, catalog, readNumbers: readNumbers, stored: ["c3": .verified])
        #expect(keys(nextFive.toQueue) == keys("c", 21...25))
        // Stored identity is by exact key: a copy of c3 is neither in the window nor re-keyed by number.
        #expect(nextFive.satisfied.isEmpty)
    }

    @Test func nextStartsAtAnUnfinishedAnchorAndAfterAFinishedOne() {
        let catalog = listed(rows(nil, 1...10))
        let read = Set(keys("c", 1...3))

        let unfinished = plan(.next5, catalog, anchor: "c5", read: read)
        #expect(keys(unfinished.toQueue) == keys("c", 5...9))

        let finished = plan(.next5, catalog, anchor: "c5", read: read.union(["c5"]))
        #expect(keys(finished.toQueue) == keys("c", 6...10))
    }

    @Test func noAnchorStartsAtTheEarliestUnreadRowWithoutAnIssue() {
        let catalog = listed(rows(nil, 1...10))
        let result = plan(.next5, catalog, read: Set(keys("c", 1...2)))

        #expect(keys(result.toQueue) == keys("c", 3...7))
        #expect(result.issues.isEmpty)
        #expect(!result.requiresPreview)
    }

    @Test func anAnchorOutsideTheSelectionIsNeverMappedAcrossScanlatorsByNumber() {
        let catalog = listed(rows("A", 1...5), rows("B", 6...10))
        let result = plan(
            .next5,
            catalog,
            selection: .scanlators([ScanlatorRef(name: "A")]),
            anchor: "B7",
            read: ["A1", "A2"]
        )

        #expect(keys(result.toQueue) == ["A3", "A4", "A5"])
        #expect(result.issues.contains(.anchorNotInSelection))
        #expect(result.requiresPreview)
    }

    @Test func anAnchorTheSourceDroppedIsHandledLikeOneOutsideTheSelection() {
        let catalog = listed(rows(nil, 1...10))
        let result = plan(.next5, catalog, anchor: "gone", read: Set(keys("c", 1...4)))

        #expect(keys(result.toQueue) == keys("c", 5...9))
        #expect(result.issues == [.anchorNotInSelection])
        #expect(result.requiresPreview)
    }

    // MARK: Same-number rows

    @Test func sameNumberSplitsFromOneScanlatorAreSeparatePositionsWithoutAPrompt() {
        let catalog = listed(
            [Chapter(key: "c15", number: 15, scanlator: "G")],
            [Chapter(key: "p1", number: 16, scanlator: "G")],
            [Chapter(key: "p2", number: 16, scanlator: "G")]
        )
        let result = plan(.next10, catalog)

        #expect(keys(result.toQueue) == ["c15", "p1", "p2"])
        #expect(!result.issues.contains(.alternativeUploads))
    }

    @Test func sameNumberFromDifferentScanlatorsInsideTheWindowIsFlagged() {
        let catalog = listed(
            [Chapter(key: "A16", number: 16, scanlator: "A")],
            [Chapter(key: "B16", number: 16, scanlator: "B")]
        )
        let result = plan(.next5, catalog)

        #expect(Set(keys(result.toQueue)) == ["A16", "B16"])
        #expect(result.issues.contains(.alternativeUploads))
        #expect(result.requiresPreview)
    }

    @Test func sameNumberInDifferentVolumesIsNotAnAlternativeUpload() {
        let catalog = listed(
            [Chapter(key: "v1", number: 1, scanlator: "A", volume: 1)],
            [Chapter(key: "v2", number: 1, scanlator: "B", volume: 2)]
        )
        let result = plan(.next5, catalog)

        #expect(!result.issues.contains(.alternativeUploads))
    }

    @Test func rowsWhoseNumbersRoundToOneFloatAreNeverMerged() {
        // Two distinct source numbers that round to the same Float.
        let rounded = Float(16.000000001)
        #expect(rounded == 16.0)
        let sameGroup = listed(
            [Chapter(key: "first", number: 16.0, scanlator: "G")],
            [Chapter(key: "second", number: rounded, scanlator: "G")]
        )
        let merged = plan(.next5, sameGroup)
        #expect(keys(merged.toQueue) == ["first", "second"])
        #expect(!merged.issues.contains(.alternativeUploads))

        let differentGroups = listed(
            [Chapter(key: "first", number: 16.0, scanlator: "G")],
            [Chapter(key: "second", number: rounded, scanlator: "H")]
        )
        let flagged = plan(.next5, differentGroups)
        #expect(Set(keys(flagged.toQueue)) == ["first", "second"])
        #expect(flagged.issues.contains(.alternativeUploads))
    }

    @Test func rowsWithTheSameKeyAreOneEdition() {
        let catalog = [
            Chapter(key: "c2", number: 2),
            Chapter(key: "c1", number: 1),
            Chapter(key: "c1", number: 1)
        ]
        let result = plan(.all, catalog)

        #expect(keys(result.toQueue) == ["c1", "c2"])
    }

    // MARK: Locks, damage, filters

    @Test func aLockedRowIsSkippedAndTheWindowContinuesPastIt() {
        let numbers = (21...26).map { number in
            Chapter(key: "c\(number)", number: Float(number), locked: number == 22)
        }
        let result = plan(.next5, listed(numbers))

        #expect(keys(result.toQueue) == ["c21", "c23", "c24", "c25", "c26"])
        #expect(keys(result.locked) == ["c22"])
        #expect(result.issues.contains(.lockedGap))
        #expect(result.requiresPreview)
    }

    @Test func lockedRowsAreNeverQueuedByAnyPreset() {
        let catalog = listed((1...3).map { Chapter(key: "c\($0)", number: Float($0), locked: $0 == 1) })

        for preset in DownloadPreset.allCases {
            let result = plan(preset, catalog)
            #expect(!keys(result.toQueue).contains("c1"))
            #expect(keys(result.locked) == ["c1"])
            #expect(result.issues.contains(.lockedGap))
        }
    }

    @Test func aDamagedCopyCountsTowardNAndIsNotQueued() {
        let catalog = listed(rows(nil, 1...6))
        let result = plan(.next5, catalog, stored: ["c2": .damaged])

        #expect(keys(result.toQueue) == ["c1", "c3", "c4", "c5"])
        #expect(keys(result.damaged) == ["c2"])
        #expect(result.issues == [.damagedCopies])
        #expect(result.requiresPreview)

        let two = plan(.next, catalog, stored: ["c1": .damaged])
        #expect(two.toQueue.isEmpty)
        #expect(keys(two.damaged) == ["c1"])
    }

    @Test func storedRowsAbsentFromTheCatalogAreNotInThePlan() {
        let catalog = listed(rows("A", 1...3))
        let result = plan(
            .all,
            catalog,
            stored: ["B9": .verified, "B10": .damaged, "B11": .queued]
        )

        let planned = keys(result.toQueue + result.satisfied + result.damaged + result.locked + result.alternatives)
        #expect(Set(planned) == ["A1", "A2", "A3"])
        #expect(!result.issues.contains(.damagedCopies))
    }

    @Test func animeRowsAreNeverPlanned() {
        let catalog = listed(rows(nil, 1...12))

        for preset in DownloadPreset.allCases {
            let result = plan(preset, catalog, storable: false)
            #expect(result.toQueue.isEmpty)
            #expect(result.satisfied.isEmpty)
            #expect(result.alternatives.isEmpty)
            #expect(!result.requiresPreview)
        }
    }

    // MARK: Ordering

    @Test func unknownOrderingPreselectsButRequiresAPreview() {
        let catalog = [
            Chapter(key: "c3", number: 3),
            Chapter(key: "note", number: nil),
            Chapter(key: "c5", number: 5),
            Chapter(key: "c4", number: 4)
        ]
        let result = plan(.next5, catalog)

        #expect(result.issues.contains(.orderingAmbiguous))
        #expect(keys(result.toQueue) == ["c4", "c5", "note", "c3"])
        #expect(result.requiresPreview)
    }

    @Test func aNumberingResetWithoutVolumeDataIsAmbiguousAndPreviews() {
        // Season 2 listed first (10...1), then season 1 (10...1), no volumes.
        let season2 = (1...10).reversed().map { Chapter(key: "s2c\($0)", number: Float($0)) }
        let season1 = (1...10).reversed().map { Chapter(key: "s1c\($0)", number: Float($0)) }
        let result = plan(.next5, season2 + season1)

        #expect(result.issues.contains(.orderingAmbiguous))
        #expect(result.requiresPreview)
    }

    @Test func aVolumeResetWithPartialVolumesIsAmbiguous() {
        let catalog = [
            Chapter(key: "v2c2", number: 2, volume: 2),
            Chapter(key: "v2c1", number: 1, volume: 2),
            Chapter(key: "c2", number: 2),
            Chapter(key: "c1", number: 1)
        ]
        let result = plan(.next5, catalog)

        #expect(result.issues.contains(.orderingAmbiguous))
        #expect(result.requiresPreview)
    }

    @Test func aVolumeResetWithFullVolumesIsOrderedByVolume() {
        var earliestFirst: [Chapter] = []
        for volume in 1...2 {
            for number in 1...10 {
                earliestFirst.append(Chapter(key: "v\(volume)c\(number)", number: Float(number), volume: Float(volume)))
            }
        }
        let result = plan(.next10, listed(earliestFirst), anchor: "v1c5", read: Set(earliestFirst.prefix(4).map(\.key)))

        #expect(keys(result.toQueue) == ["v1c5", "v1c6", "v1c7", "v1c8", "v1c9", "v1c10", "v2c1", "v2c2", "v2c3", "v2c4"])
        #expect(result.issues.isEmpty)
    }

    // MARK: Unread, All and previews

    @Test func nextCountsOnlyUnreadPositionsAndReportsWhatItSkipped() {
        let catalog = listed(rows(nil, 1...10))
        let result = plan(.next5, catalog, read: ["c2", "c4"])

        #expect(keys(result.toQueue) == ["c1", "c3", "c5", "c6", "c7"])
        #expect(result.skippedReadCount == 2)
    }

    @Test func allOverTheSourceListWithTwoScanlatorsRequiresAPreview() {
        let catalog = listed(rows("A", 1...3), rows("B", 4...6))
        let result = plan(.all, catalog)

        #expect(result.toQueue.count == 6)
        #expect(result.issues == [.multipleScanlators])
        #expect(result.requiresPreview)
    }

    @Test func aMissingScanlatorNameCountsAsAName() {
        let catalog = listed(rows(nil, 1...3), rows("B", 4...6))
        #expect(plan(.unread, catalog).issues.contains(.multipleScanlators))
    }

    @Test func allUploadsTakesEveryEligibleRowAndPreviewsBecauseItIsLarge() {
        let catalog = listed(rows("A", 1...6), rows("B", 1...6))
        let result = plan(.all, catalog, selection: .allUploads)

        #expect(result.toQueue.count == 12)
        #expect(!result.issues.contains(.multipleScanlators))
        #expect(result.requiresPreview)
    }

    @Test func allIncludesReadRows() {
        let catalog = listed(rows(nil, 1...4))
        let result = plan(.all, catalog, read: ["c1", "c2"])

        #expect(keys(result.toQueue) == ["c1", "c2", "c3", "c4"])
        #expect(result.skippedReadCount == 0)
    }

    @Test func bulkPresetsPreviewOnlyAboveTheLargeBatchThreshold() {
        let ten = plan(.unread, listed(rows(nil, 1...10)))
        #expect(ten.toQueue.count == 10)
        #expect(!ten.requiresPreview)

        let eleven = plan(.unread, listed(rows(nil, 1...11)))
        #expect(eleven.requiresPreview)

        let allEleven = plan(.all, listed(rows(nil, 1...11)))
        #expect(allEleven.requiresPreview)
    }

    @Test func anyPresetPreviewsAboveFiftyRows() {
        let fifty = plan(.unread, listed(rows(nil, 1...50)), threshold: 100)
        #expect(!fifty.requiresPreview)

        let fiftyOne = plan(.unread, listed(rows(nil, 1...51)), threshold: 100)
        #expect(fiftyOne.requiresPreview)
    }

    @Test func nothingToDoAloneDoesNotRequireAPreview() {
        let catalog = listed(rows(nil, 1...3))
        let result = plan(.next, catalog, stored: ["c1": .verified])

        #expect(result.toQueue.isEmpty)
        #expect(keys(result.satisfied) == ["c1"])
        #expect(result.issues == [.nothingToDo])
        #expect(!result.requiresPreview)
    }

    @Test func anEmptyCatalogHasNothingToDo() {
        let result = plan(.next5, [])

        #expect(result.toQueue.isEmpty)
        #expect(result.issues.contains(.nothingToDo))
    }
}

struct EditionSelectionTests {
    private func decode(_ json: String) throws -> EditionSelection {
        try JSONDecoder().decode(EditionSelection.self, from: Data(json.utf8))
    }

    private func encode(_ selection: EditionSelection) throws -> String {
        try #require(String(bytes: try selection.storageData(), encoding: .utf8))
    }

    @Test func legacySourceListDecodesAndNewWritesUseVersionTwo() throws {
        let legacy = #"{"formatVersion":1,"kind":"sourceList"}"#
        let encoded = #"{"formatVersion":2,"kind":"sourceList"}"#
        #expect(try decode(legacy) == .sourceList)
        #expect(try EditionSelection.sourceList.storageData() == Data(encoded.utf8))
        #expect(try decode(encoded) == .sourceList)
    }

    @Test func everySelectionRoundTrips() throws {
        let selections: [EditionSelection] = [
            .sourceList,
            .allUploads,
            .scanlators([]),
            .scanlators([ScanlatorRef(id: "g1", name: "Group One"), ScanlatorRef(id: nil, name: nil)])
        ]
        for selection in selections {
            #expect(try decode(try encode(selection)) == selection)
        }
    }

    @Test func aScanlatorSelectionKeepsTheUsersOrder() throws {
        let first = ScanlatorRef(name: "A")
        let second = ScanlatorRef(name: "B")
        #expect(EditionSelection.scanlators([first, second]) != .scanlators([second, first]))
        #expect(try decode(try encode(.scanlators([second, first]))) == .scanlators([second, first]))
    }

    @Test func anUnknownVersionOrKindDoesNotDecode() {
        #expect(throws: DecodingError.self) { try decode(#"{"formatVersion":4,"kind":"sourceList"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"formatVersion":1,"kind":"newest"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"kind":"sourceList"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"formatVersion":1,"kind":"scanlators"}"#) }
    }

    @Test func namesMatchExactlyThroughCatalogResolution() {
        let selection = EditionSelection.scanlators([ScanlatorRef(name: "Group", binding: .exactIDless)])
        let catalog = [
            ScanlatorRef(name: "Group", binding: .exactIDless),
            ScanlatorRef(name: "group", binding: .exactIDless),
            ScanlatorRef(name: "Group ", binding: .exactIDless),
            ScanlatorRef(name: nil, binding: .exactIDless)
        ]
        let resolved = ScanlatorCatalogIndex(catalog).resolve(selection)
        #expect(resolved?.admits(scanlator: "Group", groupID: nil) == true)
        #expect(resolved?.admits(scanlator: "group", groupID: nil) == false)
        #expect(resolved?.admits(scanlator: "Group ", groupID: nil) == false)
        #expect(resolved?.admits(scanlator: nil, groupID: nil) == false)
    }

    @Test func noGroupListedIsAnExactIDlessGroup() {
        let selection = EditionSelection.scanlators([ScanlatorRef(name: nil, binding: .exactIDless)])
        let resolved = ScanlatorCatalogIndex([ScanlatorRef(name: nil)]).resolve(selection)
        #expect(resolved?.admits(scanlator: nil, groupID: nil) == true)
        #expect(resolved?.admits(scanlator: "Group", groupID: nil) == false)
        #expect(resolved?.admits(scanlator: nil, groupID: "id") == false)
    }

    @Test func boundIDsDecideMembershipWithoutNameFallback() {
        let selection = EditionSelection.scanlators([ScanlatorRef(id: "g1", name: "Old Name")])
        let resolved = ScanlatorCatalogIndex([
            ScanlatorRef(id: "g1", name: "New Name"),
            ScanlatorRef(id: "g2", name: "Old Name"),
            ScanlatorRef(name: "Old Name")
        ]).resolve(selection)

        #expect(resolved?.admits(scanlator: "New Name", groupID: "g1") == true)
        #expect(resolved?.admits(scanlator: "Old Name", groupID: "g2") == false)
        #expect(resolved?.admits(scanlator: "Old Name", groupID: nil) == false)
    }

    @Test func unrestrictedSelectionsAndEmptyStrictSetsResolveWithoutFallback() {
        for selection in [EditionSelection.sourceList, .allUploads] {
            #expect(selection.resolve(in: [])?.admits(scanlator: nil, groupID: nil) == true)
            #expect(selection.resolve(in: [])?.admits(scanlator: "Anyone", groupID: "g") == true)
        }
        let empty = EditionSelection.scanlators([])
        #expect(ScanlatorCatalogIndex([]).resolve(empty)?.admits(scanlator: "A", groupID: nil) == false)
    }
}
