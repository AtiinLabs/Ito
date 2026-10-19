import Foundation
import Testing
@testable import Ito

struct MALWritePolicyTests {
    private func snapshot(
        _ status: MALListSnapshot.ListStatus?,
        progress: Int = 0,
        total: Int = 12,
        repeating: Bool = false,
        unreleased: Bool = false,
        volumesOnly: Bool = false
    ) -> MALListSnapshot {
        MALListSnapshot(
            listStatus: status,
            isRepeating: repeating,
            progress: progress,
            total: total,
            isUnreleased: unreleased,
            tracksVolumesOnly: volumesOnly
        )
    }

    // MARK: Automatic sync (status nil)

    @Test func automaticSyncNeverCreatesOrTouchesFinishedPausedOrDroppedEntries() throws {
        let untouchable: [MALListSnapshot] = [
            snapshot(nil),
            snapshot(.completed, progress: 12),
            snapshot(.onHold, progress: 4),
            snapshot(.dropped, progress: 4),
            snapshot(.unknown("rewatching_later"), progress: 4),
            snapshot(.active, progress: 4, unreleased: true),
            snapshot(.active, progress: 0, total: 0, volumesOnly: true)
        ]
        for entry in untouchable {
            #expect(try MALWritePolicy.patch(for: entry, progress: 9, status: nil) == nil)
        }
    }

    @Test func automaticSyncOnlyMovesActiveProgressForwardAndCapsAtTheTotal() throws {
        let watching = snapshot(.active, progress: 5)

        #expect(try MALWritePolicy.patch(for: watching, progress: 6, status: nil) == MALListPatch(progress: 6))
        #expect(try MALWritePolicy.patch(for: watching, progress: 5, status: nil) == nil)
        #expect(try MALWritePolicy.patch(for: watching, progress: 2, status: nil) == nil)
        #expect(try MALWritePolicy.patch(for: watching, progress: 0, status: nil) == nil)
        #expect(try MALWritePolicy.patch(for: watching, progress: nil, status: nil) == nil)
        #expect(try MALWritePolicy.patch(for: watching, progress: 40, status: nil) == MALListPatch(progress: 12))
        #expect(try MALWritePolicy.patch(for: snapshot(.active, progress: 12), progress: 40, status: nil) == nil)
        #expect(
            try MALWritePolicy.patch(for: snapshot(.active, progress: 90, total: 0), progress: 140, status: nil)
                == MALListPatch(progress: 140)
        )
    }

    @Test func automaticSyncContinuesARewatchKeptAsCompleted() throws {
        let rewatch = snapshot(.completed, progress: 3, repeating: true)

        #expect(try MALWritePolicy.patch(for: rewatch, progress: 4, status: nil) == MALListPatch(progress: 4))
    }

    @Test func automaticSyncStartsAPlannedWorkOnlyAtTheFirstEpisode() throws {
        let planned = snapshot(.planned)

        #expect(try MALWritePolicy.patch(for: planned, progress: 1, status: nil) == MALListPatch(status: .active, progress: 1))
        #expect(try MALWritePolicy.patch(for: planned, progress: 7, status: nil) == nil)
        #expect(try MALWritePolicy.patch(for: snapshot(.planned, progress: 2), progress: 3, status: nil) == nil)
    }

    // MARK: Explicit saves from the tracker sheet

    @Test func explicitSaveSendsOnlyFieldsThatChange() throws {
        let watching = snapshot(.active, progress: 5)

        #expect(try MALWritePolicy.patch(for: watching, progress: 5, status: "CURRENT") == nil)
        #expect(try MALWritePolicy.patch(for: watching, progress: 3, status: "CURRENT") == nil)
        #expect(try MALWritePolicy.patch(for: watching, progress: 8, status: "CURRENT") == MALListPatch(progress: 8))
        #expect(try MALWritePolicy.patch(for: watching, progress: 5, status: "PAUSED") == MALListPatch(status: .onHold))
        #expect(
            try MALWritePolicy.patch(for: watching, progress: 12, status: "COMPLETED")
                == MALListPatch(status: .completed, progress: 12)
        )
    }

    @Test func explicitSaveMapsEveryTrackerStatusAndRejectsOthers() throws {
        let absent = snapshot(nil)
        let expected: [String: MALListSnapshot.ListStatus] = [
            "CURRENT": .active, "PLANNING": .planned, "COMPLETED": .completed, "PAUSED": .onHold, "DROPPED": .dropped
        ]
        for (status, listStatus) in expected {
            #expect(try MALWritePolicy.patch(for: absent, progress: 0, status: status) == MALListPatch(status: listStatus))
        }
        #expect(
            try MALWritePolicy.patch(for: absent, progress: 3, status: "REPEATING")
                == MALListPatch(status: .active, isRepeating: true, progress: 3)
        )
        #expect(throws: MALTrackerError.invalidStatus("WATCHING")) {
            try MALWritePolicy.patch(for: absent, progress: 1, status: "WATCHING")
        }
    }

    @Test func explicitSaveRefusesToOverwriteAStatusItDoesNotKnow() {
        #expect(throws: MALTrackerError.unsupportedRemoteStatus("rewatching_later")) {
            try MALWritePolicy.patch(for: snapshot(.unknown("rewatching_later")), progress: 1, status: "CURRENT")
        }
    }

    @Test func rewatchStatusRoundTripsAndOnlyARewatchMayLowerProgress() throws {
        let rewatch = snapshot(.completed, progress: 12, repeating: true)

        #expect(try MALWritePolicy.trackerStatus(for: rewatch) == "REPEATING")
        // Saving the sheet unchanged keeps the rewatch flag and the completed status.
        #expect(try MALWritePolicy.patch(for: rewatch, progress: 12, status: "REPEATING") == nil)
        #expect(try MALWritePolicy.patch(for: rewatch, progress: 1, status: "REPEATING") == MALListPatch(progress: 1))
        #expect(
            try MALWritePolicy.patch(for: snapshot(.completed, progress: 12), progress: 0, status: "REPEATING")
                == MALListPatch(isRepeating: true, progress: 0)
        )
        #expect(try MALWritePolicy.patch(for: rewatch, progress: 12, status: "COMPLETED") == MALListPatch(isRepeating: false))
    }

    @Test func trackerStatusMapsListStatuses() throws {
        #expect(try MALWritePolicy.trackerStatus(for: snapshot(nil)) == nil)
        #expect(try MALWritePolicy.trackerStatus(for: snapshot(.active)) == "CURRENT")
        #expect(try MALWritePolicy.trackerStatus(for: snapshot(.planned)) == "PLANNING")
        #expect(try MALWritePolicy.trackerStatus(for: snapshot(.completed)) == "COMPLETED")
        #expect(try MALWritePolicy.trackerStatus(for: snapshot(.onHold)) == "PAUSED")
        #expect(try MALWritePolicy.trackerStatus(for: snapshot(.dropped)) == "DROPPED")
        #expect(throws: MALTrackerError.unsupportedRemoteStatus("x")) {
            try MALWritePolicy.trackerStatus(for: snapshot(.unknown("x")))
        }
    }

    @Test func mediaIDParsingIsStrict() {
        #expect(MALMediaID(rawValue: "anime:52991") == MALMediaID(kind: .anime, id: 52991))
        #expect(MALMediaID(rawValue: "manga:2") == MALMediaID(kind: .manga, id: 2))
        for invalid in ["52991", "anime:", "anime:0", "anime:-3", "anime:007", "novel:2", "anime:1:2", "Anime:1", ""] {
            #expect(MALMediaID(rawValue: invalid) == nil)
        }
    }

    @Test func titleNumbersNeverJoinDigitsAcrossSeparators() {
        #expect(TrackerProgressParser.number(inTitle: "Chapter 10.5") == 10)
        #expect(TrackerProgressParser.number(inTitle: "Ch.12v2 Extra") == 12)
        #expect(TrackerProgressParser.number(inTitle: "episode-42") == 42)
        #expect(TrackerProgressParser.number(inTitle: "Epilogue") == nil)
    }
}
