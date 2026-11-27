import SwiftUI
import ito_runner

/// The chapter list a reader shows over its content: a sheet on compact width, a popover from the title chip on
/// regular width, and a panel beside the content on wide screens. A pick the reader takes closes the list, except
/// in the panel, where a pick that stays in this reader leaves the list open for further browsing.
struct ReaderChapterListView: View {
    enum Style {
        case sheet
        case popover
        case panel
    }

    let rows: [ReaderChapterListRow]
    /// The format of the reader showing the list. A row that opens in the other format is marked with its glyph.
    let readerFormat: HistoryReaderFormat
    let style: Style
    /// Takes the pick and returns whether it was taken.
    let onSelect: (Chapter) -> Bool
    let onClose: () -> Void

    @AccessibilityFocusState private var headingFocused: Bool

    /// The panel's width: 40% of the reader's width, capped at 360 points.
    static func panelWidth(for size: CGSize) -> CGFloat {
        min(360, (size.width * 0.4).rounded(.down))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chapters", comment: "Reader chapter list: heading above the list of chapters")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
                Spacer()
                Button("Done", action: onClose)
            }
            .padding()

            Divider()

            ScrollViewReader { proxy in
                List {
                    ForEach(rows) { row in
                        rowButton(row)
                            .id(row.id)
                    }
                }
                .listStyle(.plain)
                .modifier(PanelListBackground(isPanel: style == .panel))
                .onAppear {
                    guard let current = rows.first(where: { $0.availability == .current }) else { return }
                    proxy.scrollTo(current.id, anchor: .center)
                }
            }
        }
        .background {
            if style == .panel {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            }
        }
        .onAppear {
            if style == .panel { headingFocused = true }
        }
    }

    private func rowButton(_ row: ReaderChapterListRow) -> some View {
        Button {
            if onSelect(row.chapter), style != .panel || row.availability == .opensInOtherReader {
                onClose()
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ReaderChapterTitle.heading(title: row.chapter.title, number: row.chapter.chapterNumber))
                        .font(.body.weight(row.availability == .current ? .bold : .regular))
                        .lineLimit(1)
                    uploadCaption(for: row.chapter)
                }

                Spacer()

                if let symbol = statusSymbol(for: row) {
                    Image(systemName: symbol)
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.isSelectable)
        .listRowBackground(row.availability == .current ? Color.accentColor.opacity(0.15) : nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.availability == .current ? .isSelected : [])
        .accessibilityValue(row.isRead ? String(localized: "Read", comment: "Reader chapter list: accessibility value for a chapter already read") : "")
        .accessibilityHint(hint(for: row))
    }

    /// The upload's date and group, in the series page row's order and separator, so the two uploads of one
    /// number read the same way in both lists.
    @ViewBuilder
    private func uploadCaption(for chapter: Chapter) -> some View {
        let date = chapter.dateUpload
        let scanlator = chapter.scanlator.flatMap { $0.isEmpty ? nil : $0 }
        if date != nil || scanlator != nil {
            HStack(spacing: 4) {
                if let date {
                    Text(date).font(.caption).foregroundColor(.secondary)
                }
                if let scanlator {
                    if date != nil {
                        Text("·").font(.caption).foregroundColor(.secondary)
                    }
                    Text(scanlator).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            .lineLimit(1)
        }
    }

    private func statusSymbol(for row: ReaderChapterListRow) -> String? {
        switch row.availability {
        case .opensInOtherReader:
            readerFormat == .pages ? "text.alignleft" : "photo.on.rectangle"
        case .locked:
            "lock.fill"
        case .notDownloaded:
            "arrow.down.circle"
        case .current, .opensHere:
            row.isRead ? "checkmark" : nil
        }
    }

    private func hint(for row: ReaderChapterListRow) -> String {
        switch row.availability {
        case .current, .opensHere:
            ""
        case .opensInOtherReader:
            readerFormat == .pages
                ? String(localized: "Opens in the text reader.", comment: "Reader chapter list: hint for a chapter that opens in the text reader")
                : String(localized: "Opens in the page reader.", comment: "Reader chapter list: hint for a chapter that opens in the page reader")
        case .locked:
            String(localized: "This chapter is locked.", comment: "Reader chapter list: hint for a chapter the account cannot open")
        case .notDownloaded:
            String(localized: "This chapter isn't downloaded.", comment: "Reader chapter list: hint for a chapter that is not stored for offline reading")
        }
    }
}

/// The panel sits over the reader's content, so the list's own opaque background must give way to its material.
private struct PanelListBackground: ViewModifier {
    let isPanel: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPanel, #available(iOS 16, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}
