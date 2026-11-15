import SwiftUI
import ito_runner

/// One saved copy as the chooser lists it. Everything a plugin supplied (group, group ID, upload key, title) is
/// kept exactly as saved and never translated; only the labels around it are the host's.
struct DownloadedAlternativeRowModel: Identifiable, Equatable {
    /// How the copy's translation group reads, without inventing an identity for a group the source left out.
    enum Group: Equatable {
        /// A named group, with the source's ID for it when it has one.
        case named(String, id: String?)
        /// A group with an ID but no name.
        case unnamed(id: String)
        case none
    }

    let id: String
    let group: Group
    let form: OfflineContentKind
    /// The upload's exact key, which tells apart two copies with the same group and form.
    let key: String
    let title: String?

    init(_ candidate: DownloadedChapterAlternative) {
        id = candidate.id
        let chapter = candidate.chapter
        let name = chapter.scanlator.flatMap { $0.isEmpty ? nil : $0 }
        let groupID = chapter.scanlatorID.flatMap { $0.isEmpty ? nil : $0 }
        switch (name, groupID) {
        case let (name?, groupID): group = .named(name, id: groupID)
        case let (nil, groupID?): group = .unnamed(id: groupID)
        case (nil, nil): group = .none
        }
        form = candidate.contentKind
        key = chapter.key
        title = chapter.title.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The chooser for saved copies of one reading position. It owns nothing: the series screen holds the state,
/// the task and the lease, and this reports the user's taps.
struct DownloadedAlternativeSheet: View {
    let state: DownloadedAlternativeSelectorState
    let onSelect: (String, UUID) -> Void
    let onConfirm: (UUID) -> Void
    let onCancel: () -> Void

    init(
        state: DownloadedAlternativeSelectorState,
        onSelect: @escaping (String, UUID) -> Void,
        onConfirm: @escaping (UUID) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.state = state
        self.onSelect = onSelect
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    /// Whether the confirmation can be pressed: one listed copy is selected and none is being opened.
    static func canConfirm(_ state: DownloadedAlternativeSelectorState) -> Bool {
        if case .choosing(_, let candidates, let selected?, _) = state {
            return candidates.contains { $0.id == selected }
        }
        return false
    }

    /// Whether a copy is being opened, so the rows and the confirmation wait.
    static func isAcquiring(_ state: DownloadedAlternativeSelectorState) -> Bool {
        if case .acquiring = state { return true }
        return false
    }

    var body: some View {
        NavigationView {
            List { content }
                .navigationTitle(Text("Downloaded Versions", comment: "Title of the sheet that lists the saved copies of a chapter's reading position"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel, action: onCancel) { Text("Cancel") }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            if let id = state.context?.id { onConfirm(id) }
                        } label: {
                            Text("Open This Saved Copy", comment: "Button in the downloaded versions sheet: reads the selected saved copy, for this reading only")
                        }
                        .disabled(!Self.canConfirm(state))
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading:
            progress(Text("Looking for saved copies…", comment: "Downloaded versions sheet: reading the list of saved copies"))
        case .handingOff:
            progress(Text("Opening the saved copy…", comment: "Downloaded versions sheet: the chosen saved copy is being opened"))
        case .choosing(let context, let candidates, let selected, let failure):
            if let failure { failureRow(failure) }
            candidateRows(candidates, selected: selected, context: context, isEnabled: true)
        case .acquiring(let context, let candidates, let selected):
            candidateRows(candidates, selected: selected, context: context, isEnabled: false)
            progress(Text("Opening the saved copy…", comment: "Downloaded versions sheet: the chosen saved copy is being opened"))
        case .failed(_, let failure):
            failureRow(failure)
        }
    }

    @ViewBuilder
    private func candidateRows(
        _ candidates: [DownloadedChapterAlternative],
        selected: String?,
        context: DownloadedAlternativeContext,
        isEnabled: Bool
    ) -> some View {
        if candidates.isEmpty {
            Text(
                "No other saved copy of this chapter is on this device.",
                comment: "Downloaded versions sheet: no saved upload shares this chapter's reading position"
            )
            .foregroundStyle(.secondary)
        }
        ForEach(candidates) { candidate in
            Button {
                onSelect(candidate.id, context.id)
            } label: {
                row(DownloadedAlternativeRowModel(candidate), isSelected: candidate.id == selected)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityAddTraits(candidate.id == selected ? .isSelected : [])
        }
    }

    private func row(_ model: DownloadedAlternativeRowModel, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                groupText(model.group).font(.body)
                if let title = model.title { Text(verbatim: title).font(.subheadline) }
                Text("Upload \(model.key)", comment: "Downloaded versions sheet: the source's exact key for one upload. The placeholder is that key, shown as the source wrote it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                formText(model.form).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func groupText(_ group: DownloadedAlternativeRowModel.Group) -> some View {
        switch group {
        case .named(let name, let id?):
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                Text("Group ID \(id)", comment: "Downloaded versions sheet: the source's identifier of a translation group. The placeholder is that identifier, shown as the source wrote it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .named(let name, nil):
            Text(verbatim: name)
        case .unnamed(let id):
            VStack(alignment: .leading, spacing: 1) {
                Text("Unnamed group", comment: "Downloaded versions sheet: the source gave this upload a group identifier but no name")
                Text("Group ID \(id)", comment: "Downloaded versions sheet: the source's identifier of a translation group. The placeholder is that identifier, shown as the source wrote it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .none:
            Text("No group listed", comment: "Downloaded versions sheet: the source named no translation group for this upload")
        }
    }

    private func formText(_ form: OfflineContentKind) -> Text {
        switch form {
        case .images:
            Text("Saved as images", comment: "Downloaded versions sheet: this copy is saved as page images")
        case .text:
            Text("Saved as text", comment: "Downloaded versions sheet: this copy is saved as text")
        case .mixed:
            Text("Saved as images and text", comment: "Downloaded versions sheet: this copy is saved with both page images and text")
        }
    }

    private func progress(_ label: Text) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            label.foregroundStyle(.secondary)
        }
    }

    private func failureRow(_ failure: DownloadedAlternativeFailure) -> some View {
        Text(Self.message(for: failure)).foregroundStyle(.orange)
    }

    /// What the host says about a failed lookup or a failed opening.
    static func message(for failure: DownloadedAlternativeFailure) -> String {
        switch failure {
        case .read(let error):
            return error.errorDescription ?? ""
        case .selection(.unavailable):
            return String(
                localized: "Saved copies aren't available on this device.",
                comment: "Downloaded versions sheet: offline storage is not available"
            )
        case .selection(.inventoryUnavailable):
            return String(
                localized: "The saved copies couldn't be read. Close this and try again.",
                comment: "Downloaded versions sheet: reading the list of saved copies failed"
            )
        case .selection(.selectionChanged):
            return String(
                localized: "The saved copies of this chapter changed. Close this and choose again.",
                comment: "Downloaded versions sheet: the listed copy is no longer the one that is stored"
            )
        case .selection(.sourceChanged):
            return String(
                localized: "This source's settings changed. Close this and choose again.",
                comment: "Downloaded versions sheet: the source's configuration changed after the list was read"
            )
        case .selection(.unsupportedMediaKind):
            return String(
                localized: "This kind of series has no saved chapters to choose from.",
                comment: "Downloaded versions sheet: the series cannot have saved chapter copies"
            )
        }
    }
}
