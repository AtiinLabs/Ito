import Foundation
import Testing
@testable import Ito

struct MangaBakaWritePolicyTests {
    private func snapshot(
        _ state: MangaBakaEntrySnapshot.State?,
        progress: Double = 0,
        total: Int = 0,
        unreleased: Bool = false,
        volumesOnly: Bool = false
    ) -> MangaBakaEntrySnapshot {
        MangaBakaEntrySnapshot(
            state: state,
            progress: progress,
            total: total,
            isUnreleased: unreleased,
            tracksVolumesOnly: volumesOnly
        )
    }

    // MARK: Automatic sync (status nil)

    @Test func automaticSyncLeavesEntriesTheUserIsNotReadingAlone() throws {
        let untouchable: [MangaBakaEntrySnapshot] = [
            snapshot(nil),
            snapshot(.considering),
            snapshot(.completed, progress: 40),
            snapshot(.paused, progress: 4),
            snapshot(.dropped, progress: 4),
            snapshot(.unknown("abandoned"), progress: 4),
            snapshot(.reading, progress: 4, unreleased: true),
            snapshot(.reading, progress: 0, volumesOnly: true)
        ]
        for entry in untouchable {
            #expect(try MangaBakaWritePolicy.patch(for: entry, progress: 9, status: nil) == nil)
        }
    }

    @Test func automaticSyncOnlyMovesProgressForward() throws {
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.reading, progress: 4), progress: 5, status: nil) == MangaBakaEntryPatch(progress: 5))
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.rereading, progress: 4), progress: 5, status: nil) == MangaBakaEntryPatch(progress: 5))
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.reading, progress: 4), progress: 4, status: nil) == nil)
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.reading, progress: 4), progress: 2, status: nil) == nil)
        // A fractional chapter recorded on MangaBaka is never rounded down.
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.reading, progress: 12.5), progress: 12, status: nil) == nil)
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.reading, progress: 4), progress: 0, status: nil) == nil)
    }

    @Test func automaticSyncCapsAtTheChapterCountOfAFinishedSeries() throws {
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.reading, progress: 30, total: 40), progress: 45, status: nil) == MangaBakaEntryPatch(progress: 40))
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.reading, progress: 40, total: 40), progress: 45, status: nil) == nil)
    }

    @Test func startingChapterOneOfAPlannedSeriesMarksItReading() throws {
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.planToRead), progress: 1, status: nil) == MangaBakaEntryPatch(state: .reading, progress: 1))
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.planToRead), progress: 7, status: nil) == nil)
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.planToRead, progress: 2), progress: 1, status: nil) == nil)
        // Considering is shown as Planning, so it follows the same rule.
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.considering), progress: 1, status: nil) == MangaBakaEntryPatch(state: .reading, progress: 1))
    }

    // MARK: Explicit saves from the tracker sheet

    @Test func explicitSaveCreatesAnEntryWithStateAndProgress() throws {
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(nil), progress: 3, status: "CURRENT") == MangaBakaEntryPatch(state: .reading, progress: 3))
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(nil), progress: 0, status: "PLANNING") == MangaBakaEntryPatch(state: .planToRead))
    }

    @Test func explicitSaveNeverLowersProgressUnlessRereading() throws {
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.reading, progress: 10), progress: 4, status: "CURRENT") == nil)
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.reading, progress: 10), progress: 4, status: "PAUSED") == MangaBakaEntryPatch(state: .paused))
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.completed, progress: 10), progress: 0, status: "REPEATING") == MangaBakaEntryPatch(state: .rereading, progress: 0))
    }

    @Test func savingARereadUnchangedLeavesFractionalOrCappedProgressAlone() throws {
        // The sheet shows 12.5 as 12; saving it unchanged must not write 12.
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.rereading, progress: 12.5), progress: 12, status: "REPEATING") == nil)
        // Progress above a finished series' chapter count is not capped down when unchanged.
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.rereading, progress: 130, total: 120), progress: 130, status: "REPEATING") == nil)
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.rereading, progress: 12.5), progress: 3, status: "REPEATING") == MangaBakaEntryPatch(progress: 3))
    }

    @Test func keepingPlanningLeavesConsideringAsItIs() throws {
        #expect(try MangaBakaWritePolicy.patch(for: snapshot(.considering), progress: 0, status: "PLANNING") == nil)
        #expect(try MangaBakaWritePolicy.trackerStatus(for: snapshot(.considering)) == "PLANNING")
    }

    @Test func unknownStatesAreRefusedRatherThanOverwritten() {
        #expect(throws: MangaBakaTrackerError.unsupportedRemoteStatus("abandoned")) {
            try MangaBakaWritePolicy.patch(for: snapshot(.unknown("abandoned")), progress: 3, status: "CURRENT")
        }
        #expect(throws: MangaBakaTrackerError.invalidStatus("WATCHING")) {
            try MangaBakaWritePolicy.patch(for: snapshot(.reading), progress: 3, status: "WATCHING")
        }
    }

    @Test func trackerStatusesMapEveryMangaBakaState() throws {
        let expected: [(MangaBakaEntrySnapshot.State, String)] = [
            (.reading, "CURRENT"), (.rereading, "REPEATING"), (.planToRead, "PLANNING"),
            (.completed, "COMPLETED"), (.paused, "PAUSED"), (.dropped, "DROPPED")
        ]
        for (state, status) in expected {
            #expect(try MangaBakaWritePolicy.trackerStatus(for: snapshot(state)) == status)
        }
        #expect(try MangaBakaWritePolicy.trackerStatus(for: snapshot(nil)) == nil)
    }
}
