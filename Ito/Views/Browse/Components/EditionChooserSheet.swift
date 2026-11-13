import SwiftUI

/// Explicit series download policy. Group labels are source content, never group identity.
struct EditionChooserSheet: View {
    private enum Mode: Hashable {
        case sourceList, preferred, scanlators, allUploads
    }
    private enum FallbackMode: Hashable { case strict, ask, approved, anyAvailable }

    let presentation: EditionChooserPresentation
    /// A choice is being applied; the button waits for it.
    let isApplying: Bool
    let onConfirm: (EditionSelection, Bool) -> Void
    let onCancel: () -> Void

    @State private var mode: Mode
    /// The ticked scanlators, in the order the user ticked them.
    @State private var chosen: [ScanlatorRef]
    @State private var remember: Bool
    @State private var fallbackMode: FallbackMode = .ask

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
        case .preferred(let primary, let fallback):
            _mode = State(initialValue: .preferred)
            if case .approved(let refs) = fallback {
                _chosen = State(initialValue: [primary] + refs)
            } else {
                _chosen = State(initialValue: [primary])
            }
            switch fallback {
            case .strict: _fallbackMode = State(initialValue: .strict)
            case .ask: _fallbackMode = State(initialValue: .ask)
            case .approved: _fallbackMode = State(initialValue: .approved)
            case .anyAvailable: _fallbackMode = State(initialValue: .anyAvailable)
            }
        }
        _remember = State(initialValue: presentation.remember)
    }

    /// Current catalog groups plus remembered references that still need explicit review.
    private var options: [ScanlatorOption] {
        var result = presentation.options
        for reference in presentation.initialSelection.references where !result.contains(where: { $0.ref == reference }) {
            result.append(ScanlatorOption(ref: reference, chapterCount: 0))
        }
        return result
    }

    private var canConfirm: Bool {
        guard mode == .scanlators || mode == .preferred else { return true }
        let selected = choosesSinglePrimary ? Array(chosen.prefix(1)) : chosen
        return !selected.isEmpty && selected.allSatisfy { reference in
            options.contains {
                $0.ref == reference && ($0.chapterCount > 0
                    || (mode == .preferred && presentation.storedChoiceProblem != .needsReview))
            }
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    modeRow(
                        .sourceList,
                        title: String(
                            localized: "Follow the source's preferred edition",
                            comment: "Let the source choose which visible upload to download. Uploads form one reading position only when the source supplies a shared logical-unit ID; otherwise each listed upload is separate."
                        )
                    )
                    modeRow(.preferred, title: String(
                        localized: "Choose a preferred group",
                        comment: "Choose the translation group normally used for this series."
                    ))
                    modeRow(.scanlators, title: String(
                        localized: "Selected groups only",
                        comment: "Strict allowed set: only the ticked groups are used. Their order is not a fallback order and never authorizes another group."
                    ))
                    modeRow(
                        .allUploads,
                        title: String(
                            localized: "Download all editions",
                            comment: "Advanced action: download every exact upload, including multiple translations of one chapter."
                        )
                    )
                } footer: {
                    if mode == .allUploads {
                        Text(
                            "Downloads every upload, including several translations of the same chapter.",
                            comment: "Footer under the Download all editions choice."
                        )
                    }
                }

                if mode == .preferred {
                    Section {
                        Picker(selection: $fallbackMode) {
                            Text("Strict selection", comment: "Leave positions unavailable when the preferred group is missing.").tag(FallbackMode.strict)
                            Text("Ask before switching", comment: "Require batch consent before using another group.").tag(FallbackMode.ask)
                            Text("Use approved groups in order", comment: "Use only the explicitly ordered fallback groups.").tag(FallbackMode.approved)
                            Text("Any available group", comment: "Advanced explicit permission to use any eligible visible group.").tag(FallbackMode.anyAvailable)
                        } label: {
                            Text("When unavailable", comment: "Fallback policy for a missing preferred edition.")
                        }
                        if let primary = chosen.first {
                            Text(renderedLabel(for: ScanlatorOption(ref: primary, chapterCount: 0)))
                        }
                    } header: {
                        Text("Preferred group", comment: "The first selected group is the primary edition choice.")
                    }
                    if fallbackMode == .approved {
                        Section {
                            ForEach(Array(chosen.dropFirst()), id: \.self) { reference in
                                HStack {
                                    Text(renderedLabel(for: ScanlatorOption(ref: reference, chapterCount: 0)))
                                    Spacer()
                                    if chosen.firstIndex(of: reference).map({ $0 > 1 }) == true {
                                        Button {
                                            guard let index = chosen.firstIndex(of: reference), index > 1 else { return }
                                            chosen.swapAt(index, index - 1)
                                        } label: {
                                            Image(systemName: "arrow.up")
                                        }
                                        .accessibilityLabel(Text("Move earlier", comment: "Move an approved fallback group earlier in priority order."))
                                    }
                                }
                            }
                        } footer: {
                            Text("Only these groups are offered as fallbacks, in the order shown. You review them before anything is queued.", comment: "Approved fallback has no unlisted final fallback, and a fallback is always shown in a preview before it is queued.")
                        }
                    }
                }

                if mode == .scanlators || mode == .preferred {
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

    /// Outside an ordered approved list only the first group is the preferred one.
    private var choosesSinglePrimary: Bool { mode == .preferred && fallbackMode != .approved }

    private func isChosen(_ reference: ScanlatorRef) -> Bool {
        choosesSinglePrimary ? chosen.first == reference : chosen.contains(reference)
    }

    private func scanlatorRow(_ option: ScanlatorOption) -> some View {
        Button {
            if choosesSinglePrimary {
                chosen = [option.ref]
            } else if let index = chosen.firstIndex(of: option.ref) {
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
                if isChosen(option.ref) {
                    Image(systemName: "checkmark").foregroundColor(.accentColor).accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(isChosen(option.ref) ? .isSelected : [])
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
        case .preferred:
            guard let primary = chosen.first else { return }
            let fallback: EditionFallback
            switch fallbackMode {
            case .strict: fallback = .strict
            case .ask: fallback = .ask
            case .anyAvailable: fallback = .anyAvailable
            case .approved: fallback = .approved(Array(chosen.dropFirst()))
            }
            selection = .preferred(primary: primary, fallback: fallback)
        }
        // Without a download behind it the choice has nothing else to apply to, so it is always remembered.
        onConfirm(selection, presentation.offersRemember ? remember : true)
    }
}
