import SwiftUI
import ito_runner

struct OptionSelectionView: View {
    let control: Control
    let value: ControlValue
    let currentValue: () -> ControlValue
    let onChange: (ControlValue) -> Void
    let catalog: OptionCatalogModel?

    @State private var query = ""
    @State private var resolution: OptionCatalogModel.LabelResolution?
    @State private var maximumSelectionError = false
    @State private var editRevision = 0
    @State private var labelRetry = 0
    @State private var labelConsumer = UUID()

    private var selectedValues: [String] { currentValue().selectedOptions }
    private var source: OptionSource {
        switch control.kind {
        case .select(let spec): return spec.options
        case .multiSelect(let spec): return spec.options
        default: return .inline([])
        }
    }
    private var searchable: Bool {
        if case .catalog(let spec) = source { return spec.flags.contains(.searchable) }
        return true
    }

    var body: some View {
        Group {
            if searchable { content.searchable(text: $query, prompt: "Search options") } else { content }
        }
        .navigationTitle(control.title)
        .onChange(of: query) { catalog?.textChanged($0) }
        .onAppear {
            query = catalog?.query ?? ""
            catalog?.appear()
        }
        .onDisappear { catalog?.disappear(); resolution = nil }
        .onChange(of: value) { _ in maximumSelectionError = false }
        .task(id: selectedValues.map { Data($0.utf8) }) { await resolveSelection() }
        .task(id: labelRetry) { if labelRetry > 0 { await resolveSelection() } }
    }

    private var content: some View {
        // Every tap invalidates the rendered checkmarks even when persistence failed.
        _ = editRevision
        return List {
            selectedRows
            if case let .select(spec) = control.kind, spec.defaultValue == nil {
                Button("None") { update([]) }
            }
            if case let .inline(options) = source {
                let filtered = options.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || ($0.group?.localizedCaseInsensitiveContains(query) == true) }
                GroupedOptionRows(options: filtered, selected: selectedValues, toggle: toggle)
                if filtered.isEmpty { Text("No options found.").foregroundColor(.secondary) }
            } else if let catalog {
                CatalogOptionRows(catalog: catalog, selected: selectedValues, toggle: toggle)
            } else {
                Text("Options unavailable.").foregroundColor(.secondary)
            }
            if maximumSelectionError {
                Text("Selection limit reached.").font(.caption).foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder private var selectedRows: some View {
        if !selectedValues.isEmpty {
            Section(header: Text("Selected")) {
                if let error = resolution?.error {
                    Text(error).foregroundColor(.secondary)
                    Button("Retry labels") { labelRetry += 1 }
                }
                ForEach(selectedValues.map { SelectedOption(value: $0) }) { row in
                    let selected = row.value
                    HStack {
                        Text(label(for: selected))
                        Spacer()
                        Button("Remove", role: .destructive) {
                            update(selectedValues.filter { !$0.utf8.elementsEqual(selected.utf8) })
                        }
                        .accessibilityLabel("Remove \(label(for: selected))")
                    }
                }
                if !unavailable.isEmpty {
                    Button("Remove unavailable", role: .destructive) {
                        update(selectedValues.filter { !unavailable.contains(Data($0.utf8)) })
                    }
                }
                if case .multiSelect = control.kind {
                    Button("Clear selection") { update([]) }
                }
            }
        }
    }

    private var inlineOptions: [ChoiceOption] { if case let .inline(options) = source { return options }; return [] }
    private var unavailable: Set<Data> {
        if case .inline = source {
            return Set(selectedValues.map { Data($0.utf8) }).subtracting(inlineOptions.map(\.identity))
        }
        return resolution?.unavailable ?? []
    }
    private func label(for value: String) -> String {
        let identity = Data(value.utf8)
        if let label = inlineOptions.first(where: { $0.identity == identity })?.label ?? resolution?.labels[identity] { return label }
        if unavailable.contains(identity) { return "Unavailable option" }
        return resolution?.error != nil || catalog == nil ? "Labels unavailable" : "Loading label…"
    }

    private func toggle(_ option: String) {
        maximumSelectionError = !ControlSelectionEditing.toggle(
            option, control: control, currentValue: currentValue, onChange: onChange
        )
        editRevision += 1
    }

    private func update(_ values: [String]) {
        maximumSelectionError = false
        if case .select = control.kind { onChange(.select(values.first)) } else { onChange(.multiSelect(values)) }
        editRevision += 1
    }

    private func resolveSelection() async {
        guard let catalog, !selectedValues.isEmpty else { resolution = nil; return }
        resolution = nil
        let result = await catalog.resolve(values: selectedValues, consumer: labelConsumer)
        guard !Task.isCancelled else { return }
        resolution = result
    }
}

/// Synchronous read/modify/write shared by persisted settings and search drafts.
@MainActor
enum ControlSelectionEditing {
    @discardableResult
    static func toggle(
        _ option: String,
        control: Control,
        currentValue: () -> ControlValue,
        onChange: (ControlValue) -> Void
    ) -> Bool {
        switch control.kind {
        case .select:
            onChange(.select(option))
        case .multiSelect(let spec):
            var next = currentValue().selectedOptions
            if let index = next.firstIndex(where: { $0.utf8.elementsEqual(option.utf8) }) { next.remove(at: index) } else {
                if let maximum = spec.maxSelected, next.count >= Int(maximum) { return false }
                next.append(option)
            }
            onChange(.multiSelect(next))
        default: return false
        }
        return true
    }
}

private struct SelectedOption: Identifiable {
    let value: String
    var id: Data { Data(value.utf8) }
}

private struct CatalogOptionRows: View {
    @ObservedObject var catalog: OptionCatalogModel
    let selected: [String]
    let toggle: (String) -> Void

    var body: some View {
        switch catalog.state {
        case .idle, .loading:
            ProgressView()
        case let .loaded(items, nextOffset, _, _, _, loadingMore, moreError):
            GroupedOptionRows(options: items, selected: selected, toggle: toggle)
            if items.count >= 10_000 { Text("Refine your search.").foregroundColor(.secondary) }
            if let moreError {
                Text(moreError).foregroundColor(.red)
                Button("Retry") { catalog.retry() }
            } else if nextOffset != nil {
                Button(loadingMore ? "Loading…" : "Load more") { catalog.loadMore() }.disabled(loadingMore)
            }
        case .empty:
            Text("No options found.").foregroundColor(.secondary)
        case .failed(let message):
            Text(message).foregroundColor(.secondary)
            Button("Retry") { catalog.retry() }
        }
    }
}

private struct GroupedOptionRows: View {
    let options: [ChoiceOption]
    let selected: [String]
    let toggle: (String) -> Void

    private var groups: [(title: String?, options: [ChoiceOption])] {
        var groups: [(title: String?, options: [ChoiceOption])] = []
        for option in options {
            if !groups.isEmpty && groups.last?.title == option.group { groups[groups.count - 1].options.append(option) } else { groups.append((option.group, [option])) }
        }
        return groups
    }

    var body: some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { entry in
            Section(header: entry.element.title.map { Text($0) }) {
                ForEach(entry.element.options, id: \.identity) { option in
                    Button { toggle(option.value) } label: {
                        HStack {
                            Text(option.label).foregroundColor(.primary)
                            Spacer()
                            if selected.contains(where: { $0.utf8.elementsEqual(option.value.utf8) }) { Image(systemName: "checkmark") }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(selected.contains(where: { $0.utf8.elementsEqual(option.value.utf8) }) ? "Selected" : "Not selected")
                }
            }
        }
    }
}
