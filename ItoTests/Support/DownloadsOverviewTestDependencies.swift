import Combine
import Foundation
import ito_runner
@testable import Ito

extension DownloadsViewModel {
    /// What a screen does when it appears: count itself visible, then read free space.
    func start() async {
        attach()
        await refreshAvailableSpace()
    }
}

/// Counts subscriptions still alive. A subscription is cancelled when its token is cancelled or released.
private nonisolated final class ActiveSubscriptions: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func adjust(_ delta: Int) {
        lock.lock()
        value += delta
        lock.unlock()
    }
}

@MainActor
class TestDownloadsOverview: DownloadsOverviewServing {
    enum Failure: Error { case requested }
    var snapshot = DownloadsSnapshot()
    var receive: ((Result<DownloadsSnapshot, Error>) -> Void)?
    var subscriptions = 0
    private let active = ActiveSubscriptions()
    var activeSubscriptions: Int { active.count }
    var cancelledIDs: [[String]] = []
    var retriedIDs: [[String]] = []
    var deletedSeries: [MediaIdentity] = []
    var deletedEditions: [[OfflineChapterEdition]] = []
    var suppressionFlags: [Bool] = []
    var failedSeries: Set<MediaIdentity> = []
    var failJobs = false
    var summaries: [OfflineInventorySummary] = []
    var queuedSeries: [MediaIdentity] = []

    func observe(_ receive: @escaping (Result<DownloadsSnapshot, Error>) -> Void) -> AnyCancellable {
        subscriptions += 1
        self.receive = receive
        receive(.success(snapshot))
        active.adjust(1)
        let active = active
        return AnyCancellable { active.adjust(-1) }
    }
    func inventorySummary() async throws -> [OfflineInventorySummary] { summaries }
    func queuedMedia() async throws -> [MediaIdentity] { queuedSeries }
    func availableCapacity() async throws -> Int64 { 1_024 }
    func cancel(jobIDs: [String]) async throws {
        cancelledIDs.append(jobIDs)
        if failJobs { throw Failure.requested }
    }
    func retry(jobIDs: [String]) async throws {
        retriedIDs.append(jobIDs)
        if failJobs { throw Failure.requested }
    }
    func delete(_ editions: [OfflineChapterEdition], suppress: Bool) async throws -> DownloadDeleteSummary {
        deletedEditions.append(editions)
        suppressionFlags.append(suppress)
        return DownloadDeleteSummary(removedCopies: editions.count)
    }
    func deleteMedia(_ media: MediaIdentity, suppress: Bool) async throws -> DownloadDeleteSummary {
        deletedSeries.append(media)
        suppressionFlags.append(suppress)
        if failedSeries.contains(media) { throw Failure.requested }
        summaries.removeAll { $0.media == media }
        queuedSeries.removeAll { $0 == media }
        return DownloadDeleteSummary(removedCopies: 1)
    }

    static func media(_ key: String) -> MediaIdentity {
        MediaIdentity(pluginId: "source", canonicalMediaId: key, mediaKind: .manga)
    }
    static func row(_ key: String, media: String = "a", number: Float? = nil,
                    volume: Float? = nil, state: ChapterDownloadState = .downloaded,
                    bytes: Int64 = 12, job: String? = nil) -> DownloadListRow {
        DownloadListRow(edition: OfflineChapterEdition(media: Self.media(media), chapterKey: key),
                        title: key, number: number, volume: volume, scanlator: nil,
                        state: state, byteCount: bytes, jobID: job)
    }
}
