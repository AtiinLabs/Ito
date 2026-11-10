import SwiftUI

/// What a series has stored, above its chapters: "Entire series offline" when the saved catalog says so, then
/// "12 saved · 3 queued · 1 failed · 340 MB". Each part is a phrase of its own and the separators come from
/// the layout, so a translation never has to rebuild the line. Counts are exact stored editions.
struct SeriesDownloadSummaryView: View {
    let summary: SeriesDownloadSummary
    /// What the stored copies occupy; nil when it is not known.
    let byteCount: Int64?
    let coversEntireSeries: Bool

    private enum Part: Hashable {
        case saved(Int), queued(Int), failed(Int), damaged(Int), size(String)
    }

    private var parts: [Part] {
        var result: [Part] = []
        if summary.saved > 0 { result.append(.saved(summary.saved)) }
        if summary.queued > 0 { result.append(.queued(summary.queued)) }
        if summary.failed > 0 { result.append(.failed(summary.failed)) }
        if summary.damaged > 0 { result.append(.damaged(summary.damaged)) }
        if let byteCount, byteCount > 0 {
            result.append(.size(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if coversEntireSeries {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                    Text(
                        "Entire series offline",
                        comment: "Series details: every chapter of the series is saved on this device, and the source confirmed its chapter list is complete."
                    )
                }
                .font(.footnote.weight(.semibold))
            }
            if !parts.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill").accessibilityHidden(true)
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        if index > 0 { Text(verbatim: "·").accessibilityHidden(true) }
                        text(for: part)
                    }
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func text(for part: Part) -> some View {
        switch part {
        case .saved(let count):
            Text(
                "\(count) saved",
                comment: "Series details: how many chapters of the series are saved on this device. The placeholder is a number, which needs plural forms."
            )
            .accessibilityLabel(Text(
                "\(count) chapters saved",
                comment: "Accessibility label for a count of chapters saved on this device, on a Library card and in a series' details header. The placeholder is the number of saved chapters."
            ))
        case .queued(let count):
            Text(
                "\(count) queued",
                comment: "Series details: how many chapters of the series are queued or downloading. The placeholder is a number, which needs plural forms."
            )
        case .failed(let count):
            Text(
                "\(count) failed",
                comment: "Series details: how many chapters of the series failed to download. The placeholder is a number, which needs plural forms."
            )
        case .damaged(let count):
            Text(
                "\(count) damaged",
                comment: "Series details: how many saved chapters of the series failed verification and need deleting. The placeholder is a number, which needs plural forms."
            )
        case .size(let size):
            Text(verbatim: size)
        }
    }
}
