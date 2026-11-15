import Foundation
@testable import Ito

@MainActor
final class MediaDetailDownloadTestInventory {
    let rows: [DownloadedChapterRecord]
    private(set) var requested: [MediaIdentity] = []
    var readCount: Int { requested.count }
    var holdReads = false
    private var pendingReads: [CheckedContinuation<Void, Never>] = []
    private var readArrivalWaiters: [CheckedContinuation<Void, Never>] = []

    init(rows: [DownloadedChapterRecord]) { self.rows = rows }

    func read(_ media: MediaIdentity) async -> [DownloadedChapterRecord] {
        requested.append(media)
        if holdReads {
            await withCheckedContinuation { continuation in
                pendingReads.append(continuation)
                let waiters = readArrivalWaiters
                readArrivalWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return rows.filter { $0.canonicalMediaId == media.canonicalMediaId }
    }

    func waitForPendingRead() async {
        if !pendingReads.isEmpty { return }
        await withCheckedContinuation { readArrivalWaiters.append($0) }
    }

    func releaseReads() {
        let pending = pendingReads
        pendingReads.removeAll()
        pending.forEach { $0.resume() }
    }
}
