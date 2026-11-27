import SwiftUI

/// The top bar shared by the manga and novel readers: the title chip, which opens the chapter list when the
/// series has more than one chapter, and the close button.
struct ReaderHeaderView: View {
    let title: String
    let chapterTitle: String
    let canShowChapters: Bool
    @Binding var isShowingChapters: Bool
    let presentsAsPopover: Bool
    let chapterList: ReaderChapterListView
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            ReaderTitleChip(
                title: title,
                chapterTitle: chapterTitle,
                canShowChapters: canShowChapters,
                isShowingChapters: $isShowingChapters,
                presentsAsPopover: presentsAsPopover,
                listContent: { chapterList }
            )

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
            }
            .accessibilityLabel("Close Reader")
        }
        .padding(.horizontal)
        // The header's container already keeps clear of the top safe area.
        .padding(.top, 8)
    }
}
