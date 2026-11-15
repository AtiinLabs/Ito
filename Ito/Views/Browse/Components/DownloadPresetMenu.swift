import SwiftUI

/// The chapter list's download menu: the built-in presets, "Download More…", the saved custom presets, and the
/// scanlator choice they follow.
struct DownloadPresetMenu: View {
    /// False while a batch is being queued: a second download would wait behind it, so none is offered.
    let isEnabled: Bool
    /// The saved custom presets in their order. Empty when there are none or the store is unreadable.
    let customPresets: [CustomDownloadPreset]
    let onSelect: (DownloadAction) -> Void
    let onDownloadMore: () -> Void
    let onChooseScanlators: () -> Void

    var body: some View {
        Menu {
            ForEach(DownloadPreset.allCases, id: \.self) { preset in
                Button {
                    onSelect(.builtIn(preset))
                } label: {
                    Label(preset.menuTitle, systemImage: preset.systemImage)
                }
                .disabled(!isEnabled)
            }
            Button(action: onDownloadMore) {
                Label(
                    String(
                        localized: "Download More…",
                        comment: "Download menu item: ask for a count and download that many missing chapters after the last read one."
                    ),
                    systemImage: "plus.circle"
                )
            }
            .disabled(!isEnabled)
            if !customPresets.isEmpty {
                Divider()
                ForEach(customPresets) { preset in
                    Button {
                        onSelect(.custom(preset))
                    } label: {
                        CustomPresetLabel(preset: preset)
                    }
                    .disabled(!isEnabled)
                }
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

/// A custom preset as a menu item: its name, with what it downloads underneath.
private struct CustomPresetLabel: View {
    let preset: CustomDownloadPreset

    var body: some View {
        if let name = preset.name {
            VStack(alignment: .leading) {
                Text(verbatim: name.value)
                Text(preset.rule.summary)
            }
            .accessibilityLabel(Text(
                "\(name.value), \(preset.rule.summary)",
                comment: "Accessibility label of a custom download preset: the user's name for it, then what it downloads."
            ))
        } else {
            Text(preset.rule.summary)
        }
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

extension CustomDownloadRule {
    /// What the rule downloads, in the menu and under a preset's name.
    var summary: String {
        switch self {
        case .next(let count):
            String(
                localized: "Next \(count.value) Chapters",
                comment: "Custom download preset summary: download the next N chapters from the last read one. The placeholder is the number of chapters, which needs plural forms."
            )
        case .more(let count):
            String(
                localized: "\(count.value) More Chapters",
                comment: "Custom download preset summary: download N more chapters that are not saved or queued yet. The placeholder is the number of chapters, which needs plural forms."
            )
        }
    }
}

extension DownloadAction {
    /// The title of the preview. A custom preset shows its name verbatim, or its summary when it has none.
    var title: String {
        switch self {
        case .builtIn(let preset):
            preset.menuTitle
        case .more(let count):
            CustomDownloadRule.more(count).summary
        case .custom(let preset):
            preset.name?.value ?? preset.rule.summary
        }
    }
}
