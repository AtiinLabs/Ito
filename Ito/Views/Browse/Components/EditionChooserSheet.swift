import SwiftUI

/// Which scanlators' chapters downloads follow: the source's list, a chosen few, or every upload. The choice
/// is a filter by the names the source shows; it never says that two uploads are the same chapter.
struct EditionChooserSheet: View {
    private enum Mode: Hashable {
        case sourceList, scanlators, allUploads
    }

    let presentation: EditionChooserPresentation
    /// A choice is being applied; the button waits for it.
    let isApplying: Bool
    let onConfirm: (EditionSelection, Bool) -> Void
    let onCancel: () -> Void

    @State private var mode: Mode
    /// The ticked scanlators, in the order the user ticked them.
    @State private var chosen: [ScanlatorRef]
    @State private var remember: Bool

    init(
        presentation: EditionChooserPresentation,
        isApplying: Bool,
        onConfirm: @escaping (EditionSelection, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.isApplying = isApplying
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        switch presentation.initialSelection {
        case .sourceList:
            _mode = State(initialValue: .sourceList)
            _chosen = State(initialValue: [])
        case .allUploads:
            _mode = State(initialValue: .allUploads)
            _chosen = State(initialValue: [])
        case .scanlators(let references):
            _mode = State(initialValue: .scanlators)
            _chosen = State(initialValue: references)
        }
        _remember = State(initialValue: presentation.remember)
    }

    /// Current catalog groups plus remembered references that still need explicit review.
    private var options: [ScanlatorOption] {
        var result = presentation.options
        if case .scanlators(let references) = presentation.initialSelection {
            for reference in references where !result.contains(where: { $0.ref == reference }) {
                result.append(ScanlatorOption(ref: reference, chapterCount: 0))
            }
        }
        return result
    }

    private var canConfirm: Bool {
        guard mode == .scanlators else { return true }
        return !chosen.isEmpty && chosen.allSatisfy { reference in
            options.contains { $0.ref == reference && $0.chapterCount > 0 }
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    modeRow(
                        .sourceList,
                        title: String(
                            localized: "Follow the source's list",
                            comment: "Scanlator choice: download whatever the source lists, from every scanlator it shows."
                        )
                    )
                    modeRow(
                        .scanlators,
                        title: String(
                            localized: "Choose scanlators",
                            comment: "Scanlator choice: download only chapters from the scanlators the user ticks."
                        )
                    )
                    modeRow(
                        .allUploads,
                        title: String(
                            localized: "All uploads",
                            comment: "Scanlator choice: download every upload of every chapter. An advanced choice."
                        )
                    )
                } footer: {
                    if mode == .allUploads {
                        Text(
                            "Downloads every upload, including several translations of the same chapter.",
                            comment: "Footer under the All uploads scanlator choice."
                        )
                    }
                }

                if mode == .scanlators {
                    Section {
                        ForEach(options) { option in
                            scanlatorRow(option)
                        }
                    }
                }

                if let problem = presentation.storedChoiceProblem {
                    Section {
                        switch problem {
                        case .unreadable:
                            Text(
                                "The choice saved for this series couldn't be read. Saving a new one replaces it.",
                                comment: "Scanlator sheet warning: the scanlators remembered for this series cannot be read, and a new choice replaces them."
                            )
                        case .readFailed:
                            Text(
                                "The choice saved for this series couldn't be loaded. It isn't replaced unless you turn on Remember.",
                                comment: "Scanlator sheet warning: reading the scanlators remembered for this series failed this time, so the stored choice is kept unless the user turns Remember on."
                            )
                        case .needsReview:
                            Text(
                                "The remembered scanlator identity is missing or ambiguous. Remove it and choose the current group to continue.",
                                comment: "Scanlator sheet warning: a remembered group identifier cannot be matched safely to the current source catalog."
                            )
                        }
                    }
                    .foregroundStyle(.orange)
                }

                if presentation.offersRemember {
                    Section {
                        Toggle(isOn: $remember) {
                            Text(
                                "Remember for this series",
                                comment: "Toggle: keep this scanlator choice for the series, so downloads follow it next time."
                            )
                        }
                    }
                }
            }
            .navigationTitle(Text("Scanlators", comment: "Title of the sheet where the user chooses which scanlators to download."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel, action: onCancel) { Text("Cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: confirm) {
                        if presentation.preset == nil {
                            Text("Done")
                        } else {
                            Text("Use Selection", comment: "Button on the scanlator sheet: apply the choice and continue with the download.")
                        }
                    }
                    .disabled(!canConfirm || isApplying)
                }
            }
        }
    }

    private func modeRow(_ value: Mode, title: String) -> some View {
        Button {
            mode = value
        } label: {
            HStack {
                Text(title).foregroundColor(.primary)
                Spacer()
                if mode == value {
                    Image(systemName: "checkmark").foregroundColor(.accentColor).accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }

    private func renderedLabel(for option: ScanlatorOption) -> String {
        option.displayName ?? String(localized: "No group listed", comment: "Scanlator choice: the chapters whose source names no scanlator.")
    }

    private func hasRenderedLabelCollision(_ option: ScanlatorOption) -> Bool {
        let label = renderedLabel(for: option)
        return options.contains { other in
            other.ref != option.ref && renderedLabel(for: other) == label
        }
    }
    private func scanlatorRow(_ option: ScanlatorOption) -> some View {
        Button {
            if let index = chosen.firstIndex(of: option.ref) {
                chosen.remove(at: index)
            } else {
                chosen.append(option.ref)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(renderedLabel(for: option))
                        .foregroundColor(.primary)
                    if hasRenderedLabelCollision(option) {
                        if let groupID = option.ref.id {
                            Text(
                                String(
                                    localized: "ID: \(groupID)",
                                    comment: "Raw source-provided group ID shown when chooser labels collide."
                                )
                            )
                            .accessibilityLabel(
                                String(
                                    localized: "Group ID \(groupID)",
                                    comment: "Accessibility label for the untranslated source-provided group ID."
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else if option.ref.binding == .exactIDless {
                            Text("No source ID", comment: "Distinguishes an ID-less source group from a same-label group with an ID.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(
                                "Remembered name needs review",
                                comment: "Chooser row for a legacy name-only preference that cannot be matched unambiguously."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if option.ref.name?.isEmpty == true {
                        Text(
                            "Empty source label",
                            comment: "Distinguishes an explicitly empty source-provided group name from no group name."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Text(
                        option.chapterCount > 0
                            ? String(
                                localized: "\(option.chapterCount) chapters",
                                comment: "Scanlator choice: how many chapters of the series this scanlator has. The placeholder is a number, which needs plural forms."
                            )
                            : String(
                                localized: "No chapters in the current list",
                                comment: "Scanlator choice: a remembered scanlator that the source's current list has no chapters from."
                            )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if chosen.contains(option.ref) {
                    Image(systemName: "checkmark").foregroundColor(.accentColor).accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(chosen.contains(option.ref) ? .isSelected : [])
    }

    private func confirm() {
        let selection: EditionSelection
        switch mode {
        case .sourceList: selection = .sourceList
        case .allUploads: selection = .allUploads
        case .scanlators:
            selection = .scanlators(chosen.map { reference in
                options.first(where: { $0.ref == reference && $0.chapterCount > 0 })?.ref ?? reference
            })
        }
        // Without a download behind it the choice has nothing else to apply to, so it is always remembered.
        onConfirm(selection, presentation.offersRemember ? remember : true)
    }
}
