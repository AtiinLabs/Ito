import Combine
import SwiftUI

/// Settings › Storage › Download Presets: the custom presets a series' download menu offers.
///
/// Every write goes through `DownloadPresetStore`, and the list always comes from its observation, so a stale or
/// cancelled write never shows as success. When the store cannot read its rows, the list shows no presets and offers
/// only "Delete All Presets".
struct DownloadPresetsSettingsView: View {
    @StateObject private var model: DownloadPresetsSettingsModel
    @State private var draft: DownloadPresetDraft?
    @State private var isConfirmingDeleteAll = false

    init(store: DownloadPresetStore) {
        _model = StateObject(wrappedValue: DownloadPresetsSettingsModel(store: store))
    }

    var body: some View {
        List {
            switch model.state {
            case .loading:
                Section {
                    ProgressView()
                }
            case .unreadable:
                Section {
                    Text(
                        "Couldn't load download presets.",
                        comment: "Download presets settings: the stored presets cannot be read, so none are shown."
                    )
                    .foregroundStyle(.red)
                    Button(role: .destructive) { isConfirmingDeleteAll = true } label: {
                        Text(
                            "Delete All Presets",
                            comment: "Download presets settings: remove every stored custom preset after the presets cannot be read."
                        )
                    }
                } footer: {
                    Text(
                        "Deleting presets doesn't remove downloaded chapters.",
                        comment: "Download presets settings footer: deleting presets never removes downloaded chapters."
                    )
                }
            case .loaded(let presets):
                if presets.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No Custom Presets", comment: "Download presets settings empty state title.")
                                .font(.headline)
                            Text(
                                "Add a preset to download a set number of chapters from a series' download menu.",
                                comment: "Download presets settings empty state: what a preset is for."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        ForEach(presets) { preset in
                            Button { draft = DownloadPresetDraft(editing: preset) } label: {
                                DownloadPresetRow(preset: preset)
                            }
                            .buttonStyle(.plain)
                        }
                        .onMove { source, destination in model.move(from: source, to: destination) }
                        .onDelete { offsets in model.delete(at: offsets) }
                    }
                }
            }
            if let failure = model.failure {
                Section {
                    Text(failure).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(String(
            localized: "Download Presets",
            comment: "Navigation title of the custom download presets editor."
        ))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                EditButton()
                    .disabled(model.presets.count < 2)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    draft = DownloadPresetDraft(newPreset: ())
                } label: {
                    Text("Add Preset", comment: "Download presets settings: add a custom preset.")
                }
                .disabled(!model.isLoaded || model.presets.count >= DownloadPresetDefinitionRecord.maximumCount)
            }
        }
        .sheet(item: $draft) { draft in
            DownloadPresetEditorView(draft: draft, store: model.store)
        }
        .confirmationDialog(
            Text("Delete All Presets", comment: "Confirmation title: delete every custom download preset."),
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) { model.deleteAll() } label: {
                Text("Delete All Presets", comment: "Confirmation button: delete every custom download preset.")
            }
        } message: {
            Text(
                "Removes every custom download preset. Downloaded chapters are kept.",
                comment: "Confirmation message: deleting every custom download preset keeps downloaded chapters."
            )
        }
    }
}

/// One preset as the list shows it: its name, or what it downloads when it has none.
private struct DownloadPresetRow: View {
    let preset: CustomDownloadPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name = preset.name {
                Text(verbatim: name.value)
                Text(preset.rule.summary).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(preset.rule.summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

@MainActor
final class DownloadPresetsSettingsModel: ObservableObject {
    @Published private(set) var state: DownloadPresetStore.State = .loading
    /// Shown when a reorder or delete was refused; cleared by the next one that succeeds.
    @Published private(set) var failure: String?

    /// The presets the store last published; empty while loading and when unreadable.
    var presets: [CustomDownloadPreset] {
        if case .loaded(let presets) = state { return presets }
        return []
    }

    var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    let store: DownloadPresetStore
    private var stateObservation: AnyCancellable?

    init(store: DownloadPresetStore) {
        self.store = store
        stateObservation = store.$state.sink { [weak self] state in self?.state = state }
    }

    func move(from source: IndexSet, to destination: Int) {
        guard case .loaded(var presets) = state else { return }
        presets.move(fromOffsets: source, toOffset: destination)
        let ids = presets.map(\.id)
        Task { [store] in
            do {
                try await store.reorder(ids)
                failure = nil
            } catch {
                failure = Self.saveFailure
            }
        }
    }

    func delete(at offsets: IndexSet) {
        guard case .loaded(let presets) = state else { return }
        let ids = offsets.map { presets[$0].id }
        Task { [store] in
            do {
                for id in ids {
                    try await store.delete(id: id)
                }
                failure = nil
            } catch DownloadPresetStoreError.notFound {
                // Already gone elsewhere; the observed list shows that without an error.
                failure = nil
            } catch {
                failure = Self.saveFailure
            }
        }
    }

    @discardableResult
    func deleteAll() -> Task<Void, Never> {
        Task { [store] in
            do {
                try await store.deleteAll()
                failure = nil
            } catch {
                failure = Self.saveFailure
            }
        }
    }

    static let saveFailure = String(
        localized: "Couldn't save the preset. Try again.",
        comment: "Download presets settings: a preset could not be saved, reordered or deleted. The draft is kept."
    )
}

/// The editor's state. It exists only while the sheet is open; a save reads it once.
struct DownloadPresetDraft: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case next
        case more

        var id: String { rawValue }
    }

    let id = UUID()
    /// The preset being edited, or nil for a new one.
    let existingID: UUID?
    var name: String
    var kind: Kind
    var countText: String

    init(newPreset: Void) {
        existingID = nil
        name = ""
        kind = .next
        countText = String(DownloadPositionCount.builtIn(5).value)
    }

    init(editing preset: CustomDownloadPreset) {
        existingID = preset.id
        name = preset.name?.value ?? ""
        switch preset.rule {
        case .next(let count):
            kind = .next
            countText = String(count.value)
        case .more(let count):
            kind = .more
            countText = String(count.value)
        }
    }

    var count: DownloadPositionCount? {
        DownloadPositionCount(Int(countText.trimmingCharacters(in: .whitespaces)) ?? 0)
    }

    var rule: CustomDownloadRule? {
        guard let count else { return nil }
        switch kind {
        case .next: return .next(count)
        case .more: return .more(count)
        }
    }

    /// Persists this exact draft only after validation. A failed transaction leaves both the draft and the
    /// observed list unchanged; the editor dismisses only after this returns successfully.
    @MainActor
    func persist(in store: DownloadPresetStore) async throws {
        let name = try validatedName.get()
        guard let rule else { throw PersistenceError.invalidCount }
        if let existingID {
            try await store.update(id: existingID, name: name, rule: rule)
        } else {
            _ = try await store.create(name: name, rule: rule)
        }
    }

    enum PersistenceError: Error { case invalidCount }

    /// The name as accepted, nil when left empty. Nil with a problem message when it is not accepted.
    var validatedName: Result<CustomPresetName?, NameProblem> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(nil) }
        if let accepted = CustomPresetName(validating: name) { return .success(accepted) }
        if trimmed.contains(where: \.isNewline) { return .failure(.lineBreak) }
        if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return .failure(.unsupportedCharacters)
        }
        return .failure(.tooLong)
    }

    /// The problem with the name, when it is not accepted. Nil when it is empty or valid.
    var nameProblem: NameProblem? {
        if case .failure(let problem) = validatedName { return problem }
        return nil
    }

    enum NameProblem: Error, Equatable {
        case lineBreak
        case unsupportedCharacters
        case tooLong

        var message: String {
            switch self {
            case .lineBreak:
                String(
                    localized: "Names can't contain line breaks.",
                    comment: "Download preset editor: the name contains a line break, which is not allowed."
                )
            case .unsupportedCharacters:
                String(
                    localized: "Names can't contain control characters.",
                    comment: "Download preset editor: the name contains an unsupported control character, such as a tab."
                )
            case .tooLong:
                String(
                    localized: "Name is too long.",
                    comment: "Download preset editor: the name is longer than 40 characters or 256 bytes."
                )
            }
        }
    }
}

/// Add or edit one preset. Save stays disabled until the store acknowledges the write; a failure keeps the draft.
struct DownloadPresetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DownloadPresetDraft
    @State private var isSaving = false
    @State private var failure: String?
    let store: DownloadPresetStore

    init(draft: DownloadPresetDraft, store: DownloadPresetStore) {
        _draft = State(initialValue: draft)
        self.store = store
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(
                        "Optional",
                        text: $draft.name,
                        prompt: Text("Optional", comment: "Download preset editor: the name field is optional.")
                    )
                } header: {
                    Text("Name", comment: "Download preset editor: section header for the optional name.")
                } footer: {
                    if let problem = draft.nameProblem {
                        Text(problem.message).foregroundStyle(.red)
                    }
                }

                Section {
                    Picker(
                        selection: $draft.kind,
                        content: {
                            Text("Next Chapters", comment: "Download preset editor: the Next type.")
                                .tag(DownloadPresetDraft.Kind.next)
                            Text("More Chapters", comment: "Download preset editor: the More type.")
                                .tag(DownloadPresetDraft.Kind.more)
                        },
                        label: { Text("Type", comment: "Download preset editor: the type of preset.") }
                    )
                } footer: {
                    if draft.kind == .next {
                        Text(
                            "Saved and queued chapters count toward the number, like Next 5 Chapters.",
                            comment: "Download preset editor footer: a Next preset counts chapters already saved or queued."
                        )
                    } else {
                        Text(
                            "Skips saved and queued chapters and downloads this many missing ones.",
                            comment: "Download preset editor footer: a More preset counts only chapters not yet saved or queued."
                        )
                    }
                }

                Section {
                    TextField(
                        "Chapters",
                        text: $draft.countText,
                        prompt: Text("Chapters", comment: "Download preset editor: the count field.")
                    )
                    .keyboardType(.numberPad)
                } footer: {
                    if draft.count == nil {
                        Text(
                            "Enter a number from \(DownloadPositionCount.range.lowerBound) to \(DownloadPositionCount.range.upperBound).",
                            comment: "Download preset editor: the count must be a whole number in the range. The placeholders are the bounds."
                        )
                        .foregroundStyle(.red)
                    }
                }

                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(draft.existingID == nil
                ? String(localized: "New Preset", comment: "Download preset editor title when adding a preset.")
                : String(localized: "Edit Preset", comment: "Download preset editor title when editing a preset."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Text("Cancel") }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { Text("Save", comment: "Download preset editor: save the preset.") }
                        .disabled(!canSave || isSaving)
                }
            }
        }
    }

    private var canSave: Bool {
        if case .failure = draft.validatedName { return false }
        return draft.rule != nil
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        failure = nil
        let submitted = draft
        Task {
            do {
                try await submitted.persist(in: store)
                dismiss()
            } catch {
                isSaving = false
                failure = Self.message(for: error)
            }
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? DownloadPresetStoreError {
        case .limitReached?:
            String(
                localized: "You can have up to \(DownloadPresetDefinitionRecord.maximumCount) presets.",
                comment: "Download preset editor: the maximum number of presets has been reached. The placeholder is that maximum."
            )
        case .notFound?:
            String(
                localized: "This preset no longer exists.",
                comment: "Download preset editor: the preset was deleted while it was being edited."
            )
        case .stale?, nil:
            DownloadPresetsSettingsModel.saveFailure
        }
    }
}
