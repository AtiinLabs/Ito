import SwiftUI
import ito_runner

public struct ChapterRowView<C: ChapterDisplayable>: View {
    let chapter: C
    let isRead: Bool
    let onTap: () -> Void
    /// Marks a text chapter in a series that also has page chapters: it opens in the text reader.
    let marksText: Bool

    @State private var isPressed = false

    public init(chapter: C, isRead: Bool, marksText: Bool = false, onTap: @escaping () -> Void) {
        self.chapter = chapter
        self.isRead = isRead
        self.marksText = marksText
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    chapterTitle
                    chapterSubtitle
                }
                Spacer()
                trailingIcon
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(isPressed ? Color(.systemFill) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressRecordingButtonStyle(isPressed: $isPressed))
        .disabled(chapter.isPaywalled)
    }

    /// The foreground color for the chapter title, respecting paywalled, read, and default states.
    private var titleColor: Color {
        if chapter.isPaywalled { return .secondary }
        return isRead ? .secondary : .primary
    }

    /// The foreground color for subtitle elements like date and scanlator.
    private var subtitleColor: Color {
        if chapter.isPaywalled { return Color(.tertiaryLabel) }
        return .secondary
    }

    @ViewBuilder
    private var chapterTitle: some View {
        if let title = chapter.title, !title.isEmpty {
            Text(title).font(.subheadline)
                .fontWeight(chapter.isPaywalled ? .regular : (isRead ? .regular : .semibold))
                .foregroundStyle(titleColor)
                .lineLimit(2)
        } else if let num = chapter.chapterNumber {
            let isWhole = num.truncatingRemainder(dividingBy: 1) == 0
            Text("\(chapter is Anime.Episode ? "Episode" : "Chapter") \(isWhole ? String(Int(num)) : String(num))")
                .font(.subheadline)
                .fontWeight(chapter.isPaywalled ? .regular : (isRead ? .regular : .semibold))
                .foregroundStyle(titleColor)
                .lineLimit(1)
        } else {
            Text("\(chapter is Anime.Episode ? "Episode" : "Chapter") —").font(.subheadline).fontWeight(.regular).foregroundStyle(titleColor)
        }
    }

    @ViewBuilder
    private var chapterSubtitle: some View {
        HStack(spacing: 4) {
            if marksText {
                Text("Text")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(subtitleColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(subtitleColor, lineWidth: 0.5))
            }
            if let dateUpload = chapter.dateUpload {
                Text(dateUpload)
                    .font(.caption).foregroundStyle(subtitleColor)
            }
            if let scanlator = chapter.scanlator, !scanlator.isEmpty {
                if chapter.dateUpload != nil {
                    Text("·").font(.caption).foregroundStyle(subtitleColor)
                }
                Text(scanlator)
                    .font(chapter is Anime.Episode ? .caption2.weight(.semibold) : .caption)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var trailingIcon: some View {
        if chapter.isPaywalled {
            Image(systemName: "lock.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if isRead {
            Image(systemName: "checkmark.circle.fill").font(chapter is Anime.Episode ? .title3 : .subheadline).foregroundStyle(Color.secondary)
        } else if chapter is Anime.Episode {
             Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
        }
    }
}
