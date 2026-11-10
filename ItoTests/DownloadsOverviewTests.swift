import Combine
import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

@MainActor
struct DownloadsOverviewTests {
    @Test func groupsQueueInQueueOrderAndInventoryBySeriesThenReadingOrder() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store, chapterKey: "a2", canonicalMediaId: "a")
        _ = try await fixture.publishedEdition(store, chapterKey: "b1", canonicalMediaId: "b")
        _ = try await fixture.publishedEdition(store, chapterKey: "a1", canonicalMediaId: "a")
        _ = try await fixture.enqueueBatch(store, chapterKeys: ["q2", "q1"], canonicalMediaId: "z")
        _ = try await fixture.enqueue(store, chapterKey: "q3", canonicalMediaId: "y")
        try await fixture.database.dbPool.write { db in
            for (key, number) in [("a1", Float(1)), ("a2", Float(2)), ("b1", Float(1))] {
                var chapter = OfflineStoreFixture.chapter(key)
                chapter.chapter = number
                let data = try JSONEncoder().encode(chapter)
                try db.execute(sql: "UPDATE downloadedChapter SET chapterSnapshot = ?, seriesTitle = canonicalMediaId WHERE chapterKey = ?",
                               arguments: [data, key])
            }
            try db.execute(sql: "UPDATE downloadedChapter SET state = 'damaged', damageReason = 'pageMismatch' WHERE chapterKey = 'a2'")
            try db.execute(sql: "UPDATE downloadJob SET createdAt = ? WHERE canonicalMediaId = 'y'",
                           arguments: [OfflineStoreFixture.fixedDate.addingTimeInterval(1)])
        }
        let snapshot = try await fixture.database.dbPool.read { db in try DownloadsSnapshot.read(db) }

        #expect(snapshot.downloaded.map(\.id.canonicalMediaId) == ["a", "b"])
        #expect(snapshot.downloaded[0].rows.map(\.edition.chapterKey) == ["a1", "a2"])
        #expect(snapshot.downloaded[0].damagedCount == 1)
        #expect(snapshot.inProgress.map(\.id.canonicalMediaId) == ["z", "y"])
        #expect(snapshot.inProgress[0].rows.map(\.edition.chapterKey) == ["q2", "q1"])
        #expect(snapshot.inProgress.flatMap(\.rows).allSatisfy { $0.byteCount == 0 && $0.state == .queued })
        let summaries = try await store.inventorySummary()
        #expect(summaries.reduce(0) { $0 + $1.count } == 3)
        #expect(summaries.reduce(0) { $0 + $1.byteCount } == snapshot.byteCount)
        #expect(summaries.first { $0.media.canonicalMediaId == "a" && $0.state == .damaged }?.count == 1)
    }

    @Test func volumeResetsSortAndSameNumberEditionsRemainDistinctAndStable() {
        let rows = [
            TestDownloadsOverview.row("v2-1", number: 1, volume: 2),
            TestDownloadsOverview.row("v1-2-split-b", number: 2, volume: 1),
            TestDownloadsOverview.row("v1-1", number: 1, volume: 1),
            TestDownloadsOverview.row("v1-2-split-a", number: 2, volume: 1)
        ]
        #expect(DownloadsSnapshot.readingOrder(rows).map(\.edition.chapterKey) == [
            "v1-1", "v1-2-split-b", "v1-2-split-a", "v2-1"
        ])
        var mixed = rows
        mixed[0].volume = nil
        #expect(DownloadsSnapshot.readingOrder(mixed).map(\.id) == mixed.map(\.id))
        mixed[0].number = nil
        #expect(DownloadsSnapshot.readingOrder(mixed).map(\.id) == mixed.map(\.id))
    }

    @Test func undecodableSnapshotStillShowsInventoryForDeletion() async throws {
        let fixture = try OfflineStoreFixture()
        let store = fixture.makeStore()
        _ = try await fixture.publishedEdition(store)
        try await fixture.database.dbPool.write { db in
            try db.execute(sql: "UPDATE downloadedChapter SET chapterSnapshot = ?", arguments: [Data("invalid".utf8)])
        }
        let snapshot = try await fixture.database.dbPool.read { db in try DownloadsSnapshot.read(db) }
        #expect(snapshot.downloaded.count == 1)
        #expect(snapshot.downloaded.first?.rows.first?.edition == OfflineStoreFixture.mangaEdition)
        #expect(snapshot.downloaded.first?.rows.first?.title == nil)
        #expect(snapshot.byteCount > 0)
    }

    @Test func productionAdapterUsesBulkCancelRetryAndSuppressedDeletion() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        let overview = LiveDownloadsOverview(center: fixture.center, store: fixture.store)
        let ids = try await fixture.offline.enqueueBatch(fixture.store, chapterKeys: ["one", "two"])
        try await fixture.store.setWaiting(jobID: ids[0], reason: .restoredPendingReview)
        try await overview.retry(jobIDs: [ids[0]])
        #expect(try await fixture.store.job(id: ids[0])?.state == .queued)
        try await overview.cancel(jobIDs: ids)
        #expect(try await fixture.store.jobs().isEmpty)
        _ = try await fixture.offline.publishedEdition(fixture.store)
        _ = try await overview.deleteMedia(OfflineStoreFixture.mangaEdition.mediaIdentityForTest, suppress: true)
        #expect(try await fixture.offline.rowCount("downloadedChapter") == 0)
        #expect(try await fixture.offline.rowCount("downloadSuppression") == 1)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func visibleManagerObservesQueueAndVolatilePageProgress() async throws {
        let fixture = try DownloadWorkerFixture()
        let id = try await fixture.offline.enqueue(fixture.store)
        _ = try await fixture.store.beginAttempt(jobID: id)
        fixture.center.startObserving(scheduling: ImmediateValueObservationScheduler())
        let overview = LiveDownloadsOverview(center: fixture.center, store: fixture.store)
        let (stream, continuation) = AsyncThrowingStream<DownloadsSnapshot, Error>.makeStream()
        let token = overview.observe { result in
            switch result {
            case .success(let value): continuation.yield(value)
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
        defer { token.cancel(); continuation.finish() }
        fixture.progress.update(DownloadProgress(jobID: id, completedPages: 1, totalPages: 3, bytes: 42))
        for try await snapshot in stream {
            if snapshot.inProgress.first?.rows.first?.state == .downloading(completed: 1, total: 3) {
                #expect(snapshot.downloaded.isEmpty)
                #expect(snapshot.byteCount == 0)
                return
            }
        }
        Issue.record("Manager observation ended without publishing live progress")
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func progressOfACancelledJobNeverShowsOnItsReplacementForTheSameEdition() async throws {
        let fixture = try DownloadWorkerFixture()
        let stale = try await fixture.offline.enqueue(fixture.store)
        _ = try await fixture.store.beginAttempt(jobID: stale)
        fixture.progress.update(DownloadProgress(jobID: stale, completedPages: 9, totalPages: 10, bytes: 90))
        try await fixture.store.cancel(jobID: stale)
        let replacement = try await fixture.offline.enqueue(fixture.store)
        #expect(replacement != stale)
        _ = try await fixture.store.beginAttempt(jobID: replacement)
        fixture.center.startObserving(scheduling: ImmediateValueObservationScheduler())
        let overview = LiveDownloadsOverview(center: fixture.center, store: fixture.store)
        let (stream, continuation) = AsyncThrowingStream<DownloadsSnapshot, Error>.makeStream()
        let token = overview.observe { result in
            switch result {
            case .success(let value): continuation.yield(value)
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
        defer { token.cancel(); continuation.finish() }
        var sawReplacementWithoutStaleProgress = false
        for try await snapshot in stream {
            guard let row = snapshot.inProgress.first?.rows.first, row.jobID == replacement else { continue }
            if !sawReplacementWithoutStaleProgress {
                #expect(row.state == .downloading(completed: 0, total: nil))
                sawReplacementWithoutStaleProgress = true
                fixture.progress.update(DownloadProgress(jobID: replacement, completedPages: 1, totalPages: 3, bytes: 10))
            } else if row.state == .downloading(completed: 1, total: 3) {
                return
            } else {
                #expect(row.state == .downloading(completed: 0, total: nil))
            }
        }
        Issue.record("Manager observation ended before the replacement job published its own progress")
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aDatabaseChangeDoesNotRepublishUnchangedLiveProgress() async throws {
        let fixture = try DownloadWorkerFixture()
        fixture.center.startObserving(scheduling: ImmediateValueObservationScheduler())
        let emissions = ProgressEmissionCount()
        let token = fixture.center.$jobProgress.sink { @MainActor _ in emissions.value += 1 }
        defer { token.cancel() }
        #expect(emissions.value == 1)
        _ = try await fixture.offline.enqueue(fixture.store)
        for await states in fixture.center.$states.values where !states.isEmpty { break }
        #expect(emissions.value == 1)
    }
}

private extension OfflineChapterEdition {
    var mediaIdentityForTest: MediaIdentity {
        MediaIdentity(pluginId: pluginId, canonicalMediaId: canonicalMediaId, mediaKind: mediaKind)
    }
}

@MainActor
private final class ProgressEmissionCount {
    var value = 0
}
