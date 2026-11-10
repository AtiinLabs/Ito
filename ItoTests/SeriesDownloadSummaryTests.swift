import Testing
@testable import Ito

/// The header summary counts exact editions by what the store says about each chapter key.
struct SeriesDownloadSummaryTests {
    @Test func eachStateCountsInItsOwnBucket() {
        let summary = SeriesDownloadSummary(states: [
            "a": .downloaded, "b": .downloaded,
            "c": .queued, "d": .downloading(completed: 1, total: 3), "e": .waiting(.meteredNetwork),
            "f": .failed(.network),
            "g": .damaged
        ])

        #expect(summary == SeriesDownloadSummary(saved: 2, queued: 3, failed: 1, damaged: 1))
        #expect(!summary.isEmpty)
    }

    @Test func noStatesIsEmpty() {
        #expect(SeriesDownloadSummary(states: [:]).isEmpty)
    }

    @Test func aSeriesWithOnlyAFailedChapterIsNotEmpty() {
        #expect(!SeriesDownloadSummary(states: ["a": .failed(.network)]).isEmpty)
    }
}
