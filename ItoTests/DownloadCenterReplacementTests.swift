import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

@MainActor
struct DownloadCenterReplacementTests {
    @Test func staleConfirmationNeverQueuesWhicheverCopyNowExists() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = try await fixture.offline.publishedEdition(fixture.store)
        let preview = try await fixture.confirmablePreview()
        try await fixture.store.delete(fixture.edition())
        let other = try await fixture.offline.publishedEdition(fixture.store)
        #expect(await fixture.center.replace(preview) == .refused(.unavailable))
        #expect(try await fixture.copy()?.versionId == other)
        #expect(try await fixture.job() == nil)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
    }

    @Test func confirmationQueuesOnceAndReportsDuplicateTruthfully() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = try await fixture.offline.publishedEdition(fixture.store)
        let preview = try await fixture.confirmablePreview()
        #expect(await fixture.center.replace(preview) == .queued)
        #expect(await fixture.center.replace(preview) == .alreadyQueued)
        #expect(try await fixture.offline.rowCount("downloadReplacementIntent") == 1)
        let job = try #require(try await fixture.job())
        let intent = try #require(try await fixture.store.replacementIntent(jobID: job.id))
        #expect(UUID(uuidString: intent.authorizationId) != nil)
        #expect(fixture.fetcher.requestedURLs.isEmpty)
    }

    @Test func replacementActivityShowsBesideTheSavedCopyAndNotInPlaceOfIt() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = try await fixture.offline.publishedEdition(fixture.store)
        let preview = try await fixture.confirmablePreview()
        #expect(await fixture.center.replace(preview) == .queued)
        let copies = [try #require(try await fixture.copy())]
        let jobs = try await fixture.store.jobs()

        let copyStates = DownloadCenter.states(copies: copies, jobs: jobs, progress: [:])
        let activity = DownloadCenter.replacementStates(copies: copies, jobs: jobs, progress: [:])
        #expect(copyStates[MediaDetailDownloadsFake.series]?["chapter-1"] == .downloaded)
        #expect(activity[MediaDetailDownloadsFake.series]?["chapter-1"] == .queued)
    }

    @Test func replaceIsRefusedAsACopyThatCannotBeReplacedForAnOlderSourceEpoch() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = try await fixture.offline.publishedEdition(fixture.store)
        let request = OfflineStoreFixture.request()
        try fixture.rotateEpoch()
        let access = try await fixture.center.replacementPreview(
            media: MediaDetailDownloadsFake.series, entry: request.entry,
            chapter: request.chapter, seriesTitle: request.seriesTitle
        )
        #expect(access.refusal == .copyCannotBeReplaced)
        #expect(try await fixture.job() == nil)
    }

    @Test func replaceIsRefusedAsUnavailableWhenNothingIsSaved() async throws {
        let fixture = try DownloadWorkerFixture()
        let request = OfflineStoreFixture.request()
        let access = try await fixture.center.replacementPreview(
            media: MediaDetailDownloadsFake.series, entry: request.entry,
            chapter: request.chapter, seriesTitle: request.seriesTitle
        )
        #expect(access.refusal == .unavailable)
    }

    @Test func knownChangedRevisionAndUnknownManualRefreshStayDistinct() {
        let download = OfflineStoreFixture.request()
        let unknown = DownloadReplacementPreview(
            download: download, installed: Chapter(key: "chapter-1"), expectedVersionId: "old"
        )
        #expect(!unknown.hasChangedRevision)
        let knownDownload = DownloadEnqueueRequest(
            pluginId: download.pluginId, mediaKind: download.mediaKind,
            canonicalMediaId: download.canonicalMediaId, entry: download.entry,
            chapter: Chapter(key: "chapter-1", revision: "r2"), seriesTitle: download.seriesTitle,
            sourceEpoch: download.sourceEpoch
        )
        let changed = DownloadReplacementPreview(
            download: knownDownload, installed: Chapter(key: "chapter-1", revision: "r1"), expectedVersionId: "old"
        )
        #expect(changed.hasChangedRevision)
    }

    @Test func confirmationNamesTheExactGroupAndTitleAndSaysNewerContent() {
        let download = OfflineStoreFixture.request()
        let target = DownloadEnqueueRequest(
            pluginId: download.pluginId, mediaKind: download.mediaKind,
            canonicalMediaId: download.canonicalMediaId, entry: download.entry,
            chapter: Chapter(key: "chapter-1", title: "Chapter 1: New", scanlator: "Group B", revision: "r2"),
            seriesTitle: download.seriesTitle, sourceEpoch: download.sourceEpoch
        )
        let preview = DownloadReplacementPreview(
            download: target,
            installed: Chapter(key: "chapter-1", title: "Chapter 1: Old", scanlator: "Group A", revision: "r1"),
            expectedVersionId: "old"
        )
        #expect(preview.message.contains("Chapter 1: Old"))
        #expect(preview.message.contains("Group A"))
        #expect(preview.message.contains("Chapter 1: New"))
        #expect(preview.message.contains("Group B"))
        #expect(preview.message.contains("newer content"))
        #expect(!preview.message.contains("newer edition"))
    }
}
