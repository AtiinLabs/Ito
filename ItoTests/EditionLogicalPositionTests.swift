import Foundation
import ito_runner
import Testing
@testable import Ito

/// Reading positions: which uploads the source declares to be one position, and what every download preset
/// does with them.
struct EditionLogicalPositionTests {
    // MARK: Fixtures

    /// A catalog row. A group named "A" has the ID "id-A"; `unit` is the source's logical unit ID.
    private func row(
        _ key: String,
        _ number: Float? = nil,
        group: String? = nil,
        unit: String? = nil,
        volume: Float? = nil,
        locked: Bool = false,
        order: Int64? = nil,
        read: Bool = false,
        stored: StoredEditionState = .none
    ) -> DownloadPlanRow {
        DownloadPlanRow(
            facts: ChapterFacts(
                key: key,
                number: number,
                volume: volume,
                scanlator: group,
                scanlatorID: group.map { "id-\($0)" },
                isLocked: locked,
                logicalUnitID: unit,
                readingOrder: order
            ),
            isRead: read,
            stored: stored
        )
    }

    private func group(_ name: String) -> ScanlatorRef {
        ScanlatorRef(id: "id-\(name)", name: name)
    }

    private struct Outcome {
        let rows: [DownloadPlanRow]
        let plan: DownloadPlan<Int>

        private func keys(_ indices: [Int]) -> [String] { indices.map { rows[$0].facts.key } }
        var toQueue: [String] { keys(plan.toQueue) }
        var satisfied: [String] { keys(plan.satisfied) }
        var damaged: [String] { keys(plan.damaged) }
        var locked: [String] { keys(plan.locked) }
        var alternatives: [String] { keys(plan.alternatives) }
    }

    private func plan(
        _ preset: DownloadPreset,
        _ rows: [DownloadPlanRow],
        selection: EditionSelection = .sourceList,
        anchor: String? = nil
    ) -> Outcome {
        Outcome(
            rows: rows,
            plan: DownloadPresetResolver.plan(rows: rows, preset: preset, selection: selection, anchorKey: anchor)
        )
    }

    /// A1 and B1 are one position, as are A2 and B2, and so on, listed A before B.
    private func twoGroups(_ count: Int) -> [DownloadPlanRow] {
        (1...count).flatMap { number in
            [
                row("A\(number)", Float(number), group: "A", unit: "u\(number)"),
                row("B\(number)", Float(number), group: "B", unit: "u\(number)")
            ]
        }
    }

    // MARK: One edition per position

    @Test func twoGroupsOfferingOneLogicalUnitQueueExactlyOneSelectedKey() {
        let rows = twoGroups(2)

        let followingTheSource = plan(.all, rows)
        #expect(followingTheSource.toQueue == ["A1", "A2"])
        #expect(followingTheSource.alternatives == ["B1", "B2"], "The other uploads are offered, never queued")
        #expect(followingTheSource.plan.issues.isEmpty)

        #expect(plan(.all, rows, selection: .scanlators([group("B"), group("A")])).toQueue == ["B1", "B2"])
        #expect(plan(.all, rows, selection: .scanlators([group("A"), group("B")])).toQueue == ["A1", "A2"])
        #expect(plan(.all, rows, selection: .scanlators([group("B")])).toQueue == ["B1", "B2"])
    }

    @Test func allEditionsDeliberatelyTakesEveryUploadOfEveryPosition() {
        let result = plan(.all, twoGroups(2), selection: .allUploads)

        #expect(result.toQueue == ["A1", "B1", "A2", "B2"])
        #expect(result.alternatives.isEmpty)
    }

    @Test func allIncludesReadPositionsOnEditionPerPosition() {
        let rows = [
            row("A1", 1, group: "A", unit: "u1", read: true),
            row("B1", 1, group: "B", unit: "u1"),
            row("A2", 2, group: "A", unit: "u2")
        ]
        #expect(plan(.all, rows).toQueue == ["A1", "A2"])
    }

    // MARK: No false merges

    @Test func theSameNumberUnderDifferentLogicalIDsIsTwoPositionsWithOnlyAWarning() {
        let rows = [
            row("A16", 16, group: "A", unit: "u1"),
            row("B16", 16, group: "B", unit: "u2")
        ]
        let result = plan(.all, rows)

        #expect(Set(result.toQueue) == ["A16", "B16"])
        #expect(result.plan.issues.contains(.alternativeUploads))
        #expect(result.plan.requiresPreview)
    }

    @Test func splitsOfOneGroupStayDistinctWithOrWithoutLogicalIDs() {
        let withoutIDs = plan(.all, [
            row("p1", 16, group: "G"), row("p2", 16, group: "G")
        ])
        #expect(Set(withoutIDs.toQueue) == ["p1", "p2"])

        let withIDs = plan(.all, [
            row("p1", 16, group: "G", unit: "u1"), row("p2", 16, group: "G", unit: "u2")
        ])
        #expect(Set(withIDs.toQueue) == ["p1", "p2"])
    }

    @Test func rowsWithoutAUsableLogicalIDAreEachTheirOwnPosition() {
        let rows = [
            row("none", 5), row("empty", 5, unit: ""), row("empty-too", 5, unit: ""),
            row("note", nil), row("other-note", nil)
        ]
        let positions = EditionPositionResolver.positions(of: rows.map(\.facts))

        #expect(positions.map(\.members) == [[0], [1], [2], [3], [4]])
        #expect(Set(plan(.all, rows).toQueue) == Set(rows.map(\.facts.key)))
    }

    @Test func aLogicalIDAndAChapterKeyNeverCollide() {
        // A row keyed "u1" without a unit ID is not the logical unit "u1".
        let rows = [row("u1", 1, group: "A"), row("x", 1, group: "B", unit: "u1")]
        let positions = EditionPositionResolver.positions(of: rows.map(\.facts))

        #expect(positions.map(\.members) == [[0], [1]])
        #expect(positions.map(\.key) == [.exact(ScanlatorUTF8(value: "u1")), .logical(ScanlatorUTF8(value: "u1"))])
    }

    @Test func mixedMetadataMergesOnlyEqualNonNilIDs() {
        let rows = [
            row("A1", 1, group: "A", unit: "u1"),
            row("B1", 1, group: "B", unit: "u1"),
            row("C1", 1, group: "C"),
            row("D1", 1, group: "D", unit: "u2")
        ]
        let positions = EditionPositionResolver.positions(of: rows.map(\.facts))

        #expect(positions.map(\.members) == [[0, 1], [2], [3]])
        #expect(Set(plan(.all, rows).toQueue) == ["A1", "C1", "D1"])
    }

    @Test func volumeResetsNeverMergeAndStayOrdered() {
        let rows = [
            row("v2c1", 1, group: "A", volume: 2),
            row("v1c1", 1, group: "A", volume: 1)
        ]
        let result = plan(.all, rows)

        #expect(result.toQueue == ["v1c1", "v2c1"])
        #expect(result.plan.issues.isEmpty)
    }

    @Test func numbersThatRoundToOneFloatStayDistinctPositions() {
        let first = ChapterFacts(Chapter(key: "first", chapter: 16.0, scanlator: "G", logicalUnitID: "u1"))
        let second = ChapterFacts(Chapter(key: "second", chapter: 16.000000001, scanlator: "G", logicalUnitID: "u2"))
        #expect(first.number == second.number, "The legacy Float view cannot tell them apart")

        #expect(EditionPositionResolver.positions(of: [first, second]).map(\.members) == [[0], [1]])
        let result = plan(.all, [DownloadPlanRow(facts: first), DownloadPlanRow(facts: second)])
        #expect(Set(result.toQueue) == ["first", "second"])
    }

    @Test func aSharedLogicalIDMergesWhateverTheNumbersAre() {
        let rows = [row("a", 16, group: "A", unit: "u"), row("b", 16.5, group: "B", unit: "u")]
        #expect(EditionPositionResolver.positions(of: rows.map(\.facts)).map(\.members) == [[0, 1]])
    }

    @Test func aSourceReadingOrderNeverMergesRowsOrActsAsIdentity() {
        let rows = [
            row("A16", 16, group: "A", order: 7),
            row("B16", 16, group: "B", order: 7)
        ]
        let result = plan(.all, rows)

        #expect(Set(result.toQueue) == ["A16", "B16"])
        #expect(result.plan.issues.contains(.orderingAmbiguous), "A shared order is not evidence of an order")
    }

    @Test func conflictingSourceOrdersInOneUnitNeitherMergeNorFailThePlan() {
        let rows = [
            row("A1", 1, group: "A", unit: "u1", order: 5),
            row("B1", 1, group: "B", unit: "u1", order: 9),
            row("A2", 2, group: "A", unit: "u2", order: 6)
        ]
        let result = plan(.all, rows)

        #expect(Set(result.toQueue) == ["A1", "A2"])
        #expect(result.plan.issues.contains(.orderingAmbiguous))
    }

    // MARK: Unread

    @Test func unreadExcludesAPositionReadThroughAnyMember() {
        let rows = [
            row("A1", 1, group: "A", unit: "u1"),
            row("B1", 1, group: "B", unit: "u1", read: true),
            row("A2", 2, group: "A", unit: "u2"),
            row("B2", 2, group: "B", unit: "u2")
        ]
        let result = plan(.unread, rows)

        #expect(result.toQueue == ["A2"])
        #expect(result.plan.skippedReadCount == 1)
    }

    @Test func unreadIncludesUnreadPositionsBeforeTheAnchor() {
        let rows = (1...5).map { row("A\($0)", Float($0), group: "A", unit: "u\($0)", read: $0 >= 4) }
        let result = plan(.unread, rows, anchor: "A4")

        #expect(result.toQueue == ["A1", "A2", "A3"])
    }

    // MARK: Next, Next 5, Next 10

    @Test func savedAndQueuedPositionsCountTowardNAndOnlyTheMissingOneTransfers() {
        let states: [Int: StoredEditionState] = [21: .verified, 22: .queued, 23: .verified, 24: .queued]
        let rows = (21...25).map { number in
            row("A\(number)", Float(number), group: "A", unit: "u\(number)", stored: states[number] ?? StoredEditionState.none)
        }
        let result = plan(.next5, rows)

        #expect(result.toQueue == ["A25"])
        #expect(result.satisfied == ["A21", "A22", "A23", "A24"])
        #expect(!result.plan.requiresPreview)
    }

    @Test func aPositionSavedUnderAPermittedGroupIsNotTransferredAgainWhenAnotherGroupAppears() {
        let rows = [
            row("A21", 21, group: "A", unit: "u21"),
            row("B21", 21, group: "B", unit: "u21", stored: .verified),
            row("A22", 22, group: "A", unit: "u22"),
            row("B22", 22, group: "B", unit: "u22", stored: .queued)
        ]
        let result = plan(.next5, rows, selection: .scanlators([group("A"), group("B")]))

        #expect(result.toQueue.isEmpty)
        #expect(result.satisfied == ["B21", "B22"])
    }

    @Test func aStrictSelectionIsNotSatisfiedByASavedCopyFromAnotherGroup() {
        let rows = [
            row("A21", 21, group: "A", unit: "u21"),
            row("B21", 21, group: "B", unit: "u21", stored: .verified),
            row("A22", 22, group: "A", unit: "u22"),
            row("B22", 22, group: "B", unit: "u22", stored: .damaged)
        ]
        let result = plan(.next5, rows, selection: .scanlators([group("A")]))

        #expect(result.toQueue == ["A21", "A22"])
        #expect(result.satisfied.isEmpty)
        #expect(result.damaged.isEmpty)
    }

    @Test func aPositionOnlyAnotherGroupOffersIsUnresolvedNotCountedAndNeverQueued() {
        let rows = [
            row("A21", 21, group: "A", unit: "u21"),
            row("B21", 21, group: "B", unit: "u21"),
            row("A22", 22, group: "A", unit: "u22"),
            row("B23", 23, group: "B", unit: "u23")
        ]
        let result = plan(.next5, rows, selection: .scanlators([group("A")]))

        #expect(result.toQueue == ["A21", "A22"])
        #expect(result.plan.issues.contains(.selectionExhausted))
        #expect(result.alternatives == ["B21", "B23"], "Shown in the preview, never queued unticked")
    }

    @Test func damagedAndFailedPositionsHoldTheirPlaceInTheCount() {
        let states: [Int: StoredEditionState] = [1: .verified, 2: .queued, 3: .damaged]
        let rows = (1...8).map { number in
            row("c\(number)", Float(number), unit: "u\(number)", stored: states[number] ?? StoredEditionState.none)
        }
        let result = plan(.next5, rows)

        #expect(result.toQueue == ["c4", "c5"])
        #expect(result.satisfied == ["c1", "c2"])
        #expect(result.damaged == ["c3"])
        #expect(result.plan.issues.contains(.damagedCopies))
    }

    @Test func aSavedCopyOfAnotherMemberOccupiesThePositionUnderTheSourceList() {
        let rows = [
            row("A1", 1, group: "A", unit: "u1"),
            row("B1", 1, group: "B", unit: "u1", stored: .queued),
            row("A2", 2, group: "A", unit: "u2")
        ]
        let result = plan(.next, rows)

        #expect(result.toQueue.isEmpty)
        #expect(result.satisfied == ["B1"])
    }

    @Test func anExactAnchorFindsItsPositionEvenWhenAnotherMemberIsTheSelectedEdition() {
        let rows = [
            row("A1", 1, group: "A", unit: "u1"),
            row("B1", 1, group: "B", unit: "u1", read: true),
            row("A2", 2, group: "A", unit: "u2"),
            row("B2", 2, group: "B", unit: "u2")
        ]
        let result = plan(.next, rows, selection: .scanlators([group("A")]), anchor: "B1")

        #expect(result.toQueue == ["A2"])
        #expect(!result.plan.issues.contains(.anchorNotInSelection))
    }

    @Test func anAnchorIsNeverMappedToAnotherGroupsRowByNumber() {
        let rows = [
            row("A7", 7, group: "A", unit: "u7"),
            row("B7", 7, group: "B")
        ]
        let result = plan(.next, rows, selection: .scanlators([group("A")]), anchor: "B7")

        #expect(result.plan.issues.contains(.anchorNotInSelection))
        #expect(result.plan.requiresPreview)
    }

    // MARK: Locks

    @Test func aLockedMemberIsSkippedForAnUnlockedOneAndAFullyLockedPositionIsAGap() {
        let partly = plan(.all, [
            row("A1", 1, group: "A", unit: "u1", locked: true),
            row("B1", 1, group: "B", unit: "u1")
        ])
        #expect(partly.toQueue == ["B1"])
        #expect(partly.locked.isEmpty)

        let fully = plan(.next, [
            row("A1", 1, group: "A", unit: "u1", locked: true),
            row("B1", 1, group: "B", unit: "u1", locked: true),
            row("A2", 2, group: "A", unit: "u2")
        ])
        #expect(fully.toQueue == ["A2"], "A locked position does not count toward N")
        #expect(fully.locked == ["A1"])
        #expect(fully.plan.issues.contains(.lockedGap))
    }

    // MARK: One definition for every preset

    @Test func everyPresetResolvesTheSamePositionsOfOneCatalog() {
        let rows = twoGroups(12)
        let all = plan(.all, rows)
        #expect(all.toQueue.count == 12)

        for (preset, count) in [(DownloadPreset.next, 1), (.next5, 5), (.next10, 10)] {
            #expect(plan(preset, rows).toQueue == Array(all.toQueue.prefix(count)))
        }
        #expect(plan(.unread, rows).toQueue == all.toQueue)

        let positions = EditionPositionResolver.positions(of: rows.map(\.facts))
        #expect(positions.count == 12)
        #expect(positions.allSatisfy { $0.members.count == 2 })
    }

    // MARK: Locked rows that already have a copy

    @Test func aLockedUploadWithASavedCopySatisfiesItsPositionInsteadOfQueueingAnotherMember() {
        let rows = [
            row("A1", 1, group: "A", unit: "u1", locked: true, stored: .verified),
            row("B1", 1, group: "B", unit: "u1"),
            row("A2", 2, group: "A", unit: "u2")
        ]
        let result = plan(.next, rows)

        #expect(result.toQueue.isEmpty)
        #expect(result.satisfied == ["A1"], "It counts toward N")
        #expect(result.locked.isEmpty)
    }

    @Test func aStrictGroupIsSatisfiedByItsOwnLockedButSavedUpload() {
        let rows = [
            row("A1", 1, group: "A", unit: "u1", locked: true, stored: .verified),
            row("B1", 1, group: "B", unit: "u1")
        ]
        let result = plan(.all, rows, selection: .scanlators([group("A")]))

        #expect(result.toQueue.isEmpty)
        #expect(result.satisfied == ["A1"])
        #expect(result.locked.isEmpty)
    }

    @Test func allEditionsCountsLockedUploadsWithACopyAsSavedAndOnlyTheOthersAsGaps() {
        let rows = [
            row("A1", 1, group: "A", unit: "u1", locked: true, stored: .verified),
            row("B1", 1, group: "B", unit: "u1"),
            row("A2", 2, group: "A", unit: "u2", locked: true),
            row("B2", 2, group: "B", unit: "u2")
        ]
        let result = plan(.all, rows, selection: .allUploads)

        #expect(result.toQueue == ["B1", "B2"])
        #expect(result.satisfied == ["A1"])
        #expect(result.locked == ["A2"])
        #expect(result.plan.issues.contains(.lockedGap))
    }

    // MARK: All Editions with Unread, source list groups and the alternatives list

    @Test func allEditionsUnreadJudgesEveryUploadByItsOwnReadMarker() {
        let rows = [
            row("A1", 1, group: "A", unit: "u1"),
            row("B1", 1, group: "B", unit: "u1", read: true),
            row("A2", 2, group: "A", unit: "u2"),
            row("B2", 2, group: "B", unit: "u2"),
            row("A3", 3, group: "A", unit: "u3", read: true),
            row("B3", 3, group: "B", unit: "u3", read: true)
        ]
        let result = plan(.unread, rows, selection: .allUploads)

        #expect(result.toQueue == ["A1", "A2", "B2"])
        #expect(result.plan.skippedReadCount == 1, "Only the position with nothing unread is skipped")
    }

    @Test func unreadStillFlagsMultipleGroupsWhenOneGroupIsEntirelyRead() {
        let read = (1...5).map { row("A\($0)", Float($0), group: "A", read: true) }
        let unread = (6...10).map { row("B\($0)", Float($0), group: "B") }
        let result = plan(.unread, read + unread)

        #expect(result.toQueue == (6...10).map { "B\($0)" })
        #expect(result.plan.issues.contains(.multipleScanlators))
        #expect(result.plan.requiresPreview)
    }

    @Test func aSelectedGroupsOwnExtraUploadsAreListedAsAlternativesNeverQueued() {
        let result = plan(.all, twoGroups(2), selection: .scanlators([group("A"), group("B")]))

        #expect(result.toQueue == ["A1", "A2"])
        #expect(result.alternatives == ["B1", "B2"])
    }

    // MARK: Source order

    @Test func aUnitWithOnlySomeUploadsOrderedIsOrderedByItsRepresentativeUpload() {
        let rows = [
            row("A1", 1, group: "A", unit: "u1", order: 5),
            row("B1", 1, group: "B", unit: "u1"),
            row("A2", 2, group: "A", unit: "u2", order: 6)
        ]
        let followingA = plan(.all, rows)
        #expect(followingA.toQueue == ["A1", "A2"])
        #expect(!followingA.plan.issues.contains(.orderingAmbiguous))

        // B1 carries no order, so this selection falls back to the numbers.
        let followingB = plan(.all, rows, selection: .scanlators([group("B"), group("A")]))
        #expect(followingB.toQueue == ["B1", "A2"])
        #expect(!followingB.plan.issues.contains(.orderingAmbiguous))
    }

    @Test func aSourceOrderOnlyOrdersWithinTheResponseItCameWith() {
        let first = [
            row("A1", 1, group: "A", unit: "u1", order: 10),
            row("A2", 2, group: "A", unit: "u2", order: 20)
        ]
        let refreshed = [
            row("A1", 1, group: "A", unit: "u1", order: 2),
            row("A2", 2, group: "A", unit: "u2", order: 1)
        ]

        #expect(plan(.all, first).toQueue == ["A1", "A2"])
        #expect(plan(.all, refreshed).toQueue == ["A2", "A1"])
    }

    // MARK: Projection

    @MainActor
    @Test func theRunnerChapterProjectionMatchesTheGenericOneOnAFullyPopulatedChapter() {
        let chapter = Chapter(
            key: "k", title: "Title", volume: 2, chapter: 16.5, dateUpdated: 1,
            scanlator: "Group", scanlatorID: "gid", url: "https://example.invalid", lang: "en", paywalled: true,
            logicalUnitID: "u1", readingOrder: 9, revision: "r"
        )
        let direct = ChapterFacts(chapter)
        let displayable: any ChapterDisplayable = chapter
        let generic = ChapterFacts(displayable)

        #expect(direct == generic)
        #expect(direct.scanlatorID == "gid")
        #expect(direct.logicalUnitID == "u1")
        #expect(direct.readingOrder == 9)
        #expect(direct.isLocked)
        #expect(direct.number == 16.5)
        #expect(direct.volume == 2)
    }

    @Test func allEditionsUnreadSkipsAReadLockedUploadAsReadNotAsAGap() {
        let rows = [
            row("c1", 1, locked: true, read: true),
            row("c2", 2)
        ]
        let result = plan(.unread, rows, selection: .allUploads)

        #expect(result.toQueue == ["c2"])
        #expect(result.plan.skippedReadCount == 1)
        #expect(result.locked.isEmpty)
        #expect(!result.plan.issues.contains(.lockedGap))
    }

    @Test func allEditionsUnreadDoesNotReportAReadLockedMemberOfAPositionWithAnOpenUpload() {
        let rows = [
            row("A1", 1, group: "A", unit: "u1", locked: true, read: true),
            row("B1", 1, group: "B", unit: "u1")
        ]
        let result = plan(.unread, rows, selection: .allUploads)

        #expect(result.toQueue == ["B1"])
        #expect(result.locked.isEmpty)
        #expect(!result.plan.issues.contains(.lockedGap))
    }
}
