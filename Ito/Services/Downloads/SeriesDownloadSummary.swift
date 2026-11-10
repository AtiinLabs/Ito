import Foundation

/// What one series has in the store, counted by exact editions: each chapter key in the download states is one
/// edition, whatever its number or scanlator. Nothing here is a share of the series.
nonisolated struct SeriesDownloadSummary: Equatable, Sendable {
    /// Verified, readable copies.
    var saved = 0
    /// Chapters queued, downloading or waiting.
    var queued = 0
    /// Chapters whose download failed; Retry is in the chapter menu.
    var failed = 0
    /// Copies that failed verification and need deleting.
    var damaged = 0

    init(saved: Int = 0, queued: Int = 0, failed: Int = 0, damaged: Int = 0) {
        self.saved = saved
        self.queued = queued
        self.failed = failed
        self.damaged = damaged
    }

    init(states: [String: ChapterDownloadState]) {
        for state in states.values {
            switch state {
            case .downloaded: saved += 1
            case .queued, .downloading, .waiting: queued += 1
            case .failed: failed += 1
            case .damaged: damaged += 1
            }
        }
    }

    /// Whether the series has no state at all.
    var isEmpty: Bool { saved == 0 && queued == 0 && failed == 0 && damaged == 0 }
}
