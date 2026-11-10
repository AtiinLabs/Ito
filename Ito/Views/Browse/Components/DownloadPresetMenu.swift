import SwiftUI

/// The chapter list's download menu: the presets, and the scanlator choice they follow.
struct DownloadPresetMenu: View {
    /// False while a batch is being queued: a second preset would wait behind it, so it is not offered.
    let isEnabled: Bool
    let onSelect: (DownloadPreset) -> Void
    let onChooseScanlators: () -> Void

    var body: some View {
        Menu {
            ForEach(DownloadPreset.allCases, id: \.self) { preset in
                Button {
                    onSelect(preset)
                } label: {
                    Label(preset.menuTitle, systemImage: preset.systemImage)
                }
                .disabled(!isEnabled)
            }
            Divider()
            Button(action: onChooseScanlators) {
                Label(
                    String(
                        localized: "Scanlators…",
                        comment: "Download menu item: choose which scanlators' chapters the download presets select."
                    ),
                    systemImage: "person.2"
                )
            }
        } label: {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 20))
                .foregroundStyle(Color.secondary)
        }
        .accessibilityLabel(Text(
            "Download chapters",
            comment: "Accessibility label of the menu that queues several chapters for offline reading."
        ))
    }
}

extension DownloadPreset {
    /// The preset's name in the download menu and in its preview.
    var menuTitle: String {
        switch self {
        case .next:
            String(localized: "Next Unread Chapter", comment: "Download menu item: download the next unread chapter.")
        case .next5:
            String(localized: "Next 5 Chapters", comment: "Download menu item: download the next five unread chapters.")
        case .next10:
            String(localized: "Next 10 Chapters", comment: "Download menu item: download the next ten unread chapters.")
        case .unread:
            String(localized: "All Unread Chapters", comment: "Download menu item: download every unread chapter.")
        case .all:
            String(localized: "All Chapters", comment: "Download menu item: download every chapter, including those already read.")
        }
    }

    var systemImage: String {
        switch self {
        case .next: "arrow.down.to.line"
        case .next5, .next10: "arrow.down.circle"
        case .unread: "circle.dashed"
        case .all: "square.stack.3d.down.right"
        }
    }
}
