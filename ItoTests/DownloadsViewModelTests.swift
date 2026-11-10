import Combine
import Foundation
import Testing
@testable import Ito

@MainActor
struct DownloadsViewModelTests {
    private func model(_ service: TestDownloadsOverview) -> DownloadsViewModel {
        DownloadsViewModel(service: service, library: PreparedLibraryDependencies.unavailable().library)
    }

    @Test func multiSelectDeleteKeepsSuccessNamesFailureAndWritesSuppression() async {
        let service = TestDownloadsOverview()
        let first = DownloadsSeries(id: TestDownloadsOverview.media("a"), title: "Succeeded", rows: [TestDownloadsOverview.row("one")])
        let second = DownloadsSeries(id: TestDownloadsOverview.media("b"), title: "Failed series", rows: [TestDownloadsOverview.row("two", media: "b")])
        service.snapshot.downloaded = [first, second]
        service.failedSeries = [second.id]
        let model = model(service)
        await model.start()
        defer { model.stop() }
        model.selectedSeries = [first.id, second.id]

        await model.deleteSeries(model.selectedSeries)

        #expect(service.deletedSeries == [first.id, second.id])
        #expect(service.suppressionFlags == [true, true])
        #expect(model.selectedSeries == [second.id])
        #expect(model.message?.contains("1 series") == true)
        #expect(model.message?.contains("Failed series") == true)
        #expect(model.message?.contains("may already have been removed") == true)
        #expect(!model.isWorking)
    }

    @Test func chapterMultiSelectUsesOneBulkDeleteAndKeepsExactEditions() async {
        let service = TestDownloadsOverview()
        let rows = [TestDownloadsOverview.row("split-1", number: 16), TestDownloadsOverview.row("split-2", number: 16)]
        service.snapshot.downloaded = [DownloadsSeries(id: TestDownloadsOverview.media("a"), title: "Series", rows: rows)]
        let model = model(service)
        await model.start()
        defer { model.stop() }
        model.selectedChapters = Set(rows.map(\.id))

        await model.deleteChapters(model.selectedChapters)

        #expect(service.deletedEditions.count == 1)
        #expect(Set(service.deletedEditions[0]) == Set(rows.map(\.id)))
        #expect(service.suppressionFlags == [true])
        #expect(model.selectedChapters.isEmpty)
    }

    @Test func jobActionsDistinguishRetryAndRestoreApprovalAndUseBulkIDs() async {
        let service = TestDownloadsOverview()
        let rows = [
            TestDownloadsOverview.row("queued", state: .queued, bytes: 0, job: "q"),
            TestDownloadsOverview.row("failed", state: .failed(.sourceError), bytes: 0, job: "f"),
            TestDownloadsOverview.row("source", state: .waiting(.sourceUnavailable), bytes: 0, job: "s"),
            TestDownloadsOverview.row("settings", state: .waiting(.sourceConfigurationChanged), bytes: 0, job: "c"),
            TestDownloadsOverview.row("restored", state: .waiting(.restoredPendingReview), bytes: 0, job: "r"),
            TestDownloadsOverview.row("wifi", state: .waiting(.meteredNetwork), bytes: 0, job: "w")
        ]
        service.snapshot.inProgress = [DownloadsSeries(id: TestDownloadsOverview.media("a"), title: "Queue", rows: rows)]
        let model = model(service)
        await model.start()
        defer { model.stop() }

        await model.retry(model.retryableJobs)
        await model.resumePaused(model.pausedJobs)
        await model.cancel(model.allJobs)

        #expect(service.retriedIDs == [["f", "s", "c"], ["r"]])
        #expect(service.cancelledIDs == [["q", "f", "s", "c", "r", "w"]])
        #expect(model.snapshot.downloaded.isEmpty)
        #expect(model.snapshot.byteCount == 0)
    }

    @Test func failureDoesNotClaimSuccessAndStoppedScreenIgnoresLateObservation() async {
        let service = TestDownloadsOverview()
        service.failJobs = true
        let model = model(service)
        await model.start()
        await model.cancel([TestDownloadsOverview.row("queued", state: .queued, job: "q")])
        #expect(model.message?.contains("couldn't be cancelled") == true)
        #expect(!model.isWorking)
        model.stop()
        service.receive?(.success(DownloadsSnapshot(downloaded: [DownloadsSeries(
            id: TestDownloadsOverview.media("late"), title: "Late", rows: [TestDownloadsOverview.row("late")]
        )])))
        #expect(model.snapshot.downloaded.isEmpty)
        await model.start()
        #expect(service.subscriptions == 2)
        model.stop()
    }

    @Test func rootAndSeriesShareOneVisibleObservationAndStorageTotals() async {
        let service = TestDownloadsOverview()
        service.snapshot.downloaded = [DownloadsSeries(
            id: TestDownloadsOverview.media("a"), title: "Series",
            rows: [TestDownloadsOverview.row("one", bytes: 20), TestDownloadsOverview.row("damaged", state: .damaged, bytes: 8)]
        )]
        let model = model(service)
        await model.start()
        await model.start()
        #expect(service.subscriptions == 1)
        #expect(model.snapshot.byteCount == 28)
        #expect(model.series(TestDownloadsOverview.media("a"))?.damagedCount == 1)
        #expect(model.availableBytes == 1_024)
        #expect(model.libraryItems.isEmpty)
        model.stop()
        model.stop()
    }

    @Test func startingANewSessionChangesTheThumbnailRevisionSoVisibleRowsAskAgain() {
        let model = model(TestDownloadsOverview())
        let initial = model.thumbnailRevision
        model.attach()
        let first = model.thumbnailRevision
        #expect(first != initial)
        model.attach()
        #expect(model.thumbnailRevision == first)
        model.stop()
        model.stop()
        model.attach()
        #expect(model.thumbnailRevision != first)
        model.stop()
    }
}
