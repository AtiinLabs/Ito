import SwiftUI

/// The reader's top-left title chip. When the series has chapters to list, the chip opens the chapter list: as a
/// popover on regular width, where the chip is the anchor; on other widths the reader presents the list itself.
struct ReaderTitleChip<ListContent: View>: View {
    let title: String
    let chapterTitle: String
    let canShowChapters: Bool
    @Binding var isShowingChapters: Bool
    let presentsAsPopover: Bool
    @ViewBuilder let listContent: () -> ListContent

    var body: some View {
        Group {
            if canShowChapters {
                Button {
                    isShowingChapters.toggle()
                } label: {
                    label
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens or closes the chapter list.", comment: "Reader title chip: hint for the button that opens the chapter list"))
            } else {
                label
                    .accessibilityElement(children: .combine)
            }
        }
        .popover(isPresented: presentsAsPopover ? $isShowingChapters : .constant(false)) {
            listContent()
                .frame(idealWidth: 380, idealHeight: 560)
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(chapterTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }

            if canShowChapters {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white.opacity(0.8))
                    .rotationEffect(.degrees(isShowingChapters ? 180 : 0))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}
