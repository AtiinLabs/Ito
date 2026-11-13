import SwiftUI

/// A small symbol for a chapter's download state. Its label names the state; the row it sits in carries
/// the progress value, because the row merges its children into one accessibility element.
struct ChapterDownloadIndicator: View {
    let state: ChapterDownloadState
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 15

    var body: some View {
        symbol
            .font(.subheadline)
            .foregroundStyle(tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.label)
    }

    @ViewBuilder
    private var symbol: some View {
        switch state {
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
        case .downloading(let completed, let total):
            DownloadProgressRing(fraction: ChapterDownloadState.fraction(completed: completed, total: total))
                .frame(width: ringSize, height: ringSize)
        case .queued:
            Image(systemName: "clock")
        case .waiting:
            Image(systemName: "pause.circle")
        case .failed:
            Image(systemName: "exclamationmark.circle")
        case .damaged:
            Image(systemName: "exclamationmark.triangle")
        }
    }

    private var tint: Color {
        switch state {
        case .downloaded, .downloading:
            return .accentColor
        case .failed, .damaged:
            return .orange
        case .queued, .waiting:
            return .secondary
        }
    }
}

extension ChapterDownloadState {
    /// How far a download in progress has got, for the row's accessibility value. Nil otherwise.
    var progressValue: Text? {
        guard case .downloading(let completed, let total) = self,
              let fraction = Self.fraction(completed: completed, total: total) else {
            return nil
        }
        return Text(fraction, format: .percent.precision(.fractionLength(0)))
    }

    fileprivate static func fraction(completed: Int, total: Int?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}

/// A determinate ring for a download in progress, or a plain ring before the page count is known.
private struct DownloadProgressRing: View {
    let fraction: Double?

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction ?? 0)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

extension ChapterDownloadState {
    /// What the state is called, for the row's accessibility label and the menu header.
    var label: Text {
        switch self {
        case .downloaded:
            return Text("Downloaded", comment: "Chapter download status")
        case .downloading:
            return Text("Downloading", comment: "Chapter download status")
        case .queued:
            return Text("Queued", comment: "Chapter download status: waiting for its turn")
        case .waiting(let reason):
            return reason.label
        case .failed(let reason):
            switch reason {
            case .replacementStale:
                return Text(
                    "Replacement no longer applies",
                    comment: "Chapter download status: the saved copy or its source changed after a replacement was confirmed. The saved copy is kept; replace it again to review the chapter."
                )
            case .replacementContentChanged:
                return Text(
                    "Source chapter changed",
                    comment: "Chapter download status: the source's chapter changed after a replacement was confirmed. The saved copy is kept; replace it again to review the chapter."
                )
            case .replacementInterrupted:
                return Text(
                    "Replacement interrupted",
                    comment: "Chapter download status: the app restarted before a replacement was verified. The saved copy is kept; replace it again to fetch the chapter."
                )
            default:
                return Text("Download failed", comment: "Chapter download status")
            }
        case .damaged:
            return Text(
                "Download damaged",
                comment: "Chapter download status: the saved copy no longer matches what was downloaded"
            )
        }
    }

    /// Whether the menu shows the state as a header: only where the state explains what to do next.
    var explainsMenu: Bool {
        switch self {
        case .waiting, .failed, .damaged:
            return true
        case .downloaded, .downloading, .queued:
            return false
        }
    }
}

extension ChapterDownloadState {
    /// The menu header while a replacement has activity over a saved copy. The saved copy stays available beside it,
    /// through the menu's own actions.
    var replacementLabel: Text {
        switch self {
        case .queued, .downloading:
            return Text(
                "Replacing download",
                comment: "Chapter download status: a replacement of a saved chapter is queued or running. The saved copy stays available."
            )
        case .waiting(let reason):
            return reason.label
        case .failed(let reason):
            guard reason.endsReplacement else {
                return Text(
                    "Replacement failed",
                    comment: "Chapter download status: a replacement of a saved chapter failed. The saved copy stays available."
                )
            }
            return label
        case .downloaded, .damaged:
            return label
        }
    }
}

extension DownloadWaitingReason {
    var label: Text {
        switch self {
        case .networkUnknown, .noConnection:
            return Text("Waiting for a connection", comment: "Chapter download status")
        case .meteredNetwork:
            return Text(
                "Waiting for Wi-Fi",
                comment: "Chapter download status: downloads do not use cellular or other metered networks"
            )
        case .lowDataMode:
            return Text("Waiting: Low Data Mode is on", comment: "Chapter download status")
        case .insufficientStorage:
            return Text("Waiting for free storage", comment: "Chapter download status")
        case .protectedDataUnavailable:
            return Text("Waiting for the device to unlock", comment: "Chapter download status")
        case .sourceUnavailable:
            return Text(
                "Source unavailable",
                comment: "Chapter download status: the source is not installed or could not load. Retry to download again."
            )
        case .sourceConfigurationChanged:
            return Text(
                "Source settings changed",
                comment: "Chapter download status: the source's settings or account changed after the chapter was queued. Retry to download again."
            )
        case .restoredPendingReview:
            return Text(
                "Paused after a restore",
                comment: "Chapter download status: the queue came from a restored backup. Retry to download again."
            )
        case .appInBackground:
            return Text(
                "Paused in the background",
                comment: "Chapter download status: downloads run only while the app is open"
            )
        }
    }
}

extension ChapterDownloadAction {
    var title: Text {
        switch self {
        case .download:
            return Text("Download", comment: "Chapter menu: save this chapter for offline reading")
        case .replace:
            return Text("Replace download", comment: "Chapter menu: manually replace the exact saved copy after confirmation")
        case .cancel:
            return Text("Cancel Download", comment: "Chapter menu: remove this chapter from the download queue")
        case .cancelReplacement:
            return Text(
                "Cancel Replacement",
                comment: "Chapter menu: stop a replacement of this saved chapter, or dismiss its ended record. The saved copy stays."
            )
        case .retry:
            return Text("Retry Download", comment: "Chapter menu")
        case .readOnlineThisTime:
            return Text("Read Online This Time", comment: "Chapter menu: open this downloaded chapter from its source once, without changing the saved copy")
        case .delete:
            return Text("Delete Download", comment: "Chapter menu: remove the saved copy of this chapter")
        }
    }

    var systemImage: String {
        switch self {
        case .download: return "arrow.down.circle"
        case .replace: return "arrow.triangle.2.circlepath"
        case .cancel: return "xmark.circle"
        case .cancelReplacement: return "xmark.circle"
        case .retry: return "arrow.clockwise"
        case .readOnlineThisTime: return "globe"
        case .delete: return "trash"
        }
    }
}
