import SwiftUI
import ito_runner

struct SearchFilterSheet: View {
    let capabilities: SearchCapabilities
    let onApply: ([String: ControlValue]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [String: ControlValue]
    @State private var optionCatalogs: [String: OptionCatalogModel]

    init(
        capabilities: SearchCapabilities,
        values: [String: ControlValue],
        optionCatalog: (OptionCatalog) -> OptionCatalogModel,
        onApply: @escaping ([String: ControlValue]) -> Void
    ) {
        self.capabilities = capabilities
        self.onApply = onApply
        _draft = State(initialValue: values)
        var catalogs: [String: OptionCatalogModel] = [:]
        for control in capabilities.controls {
            let source: OptionSource?
            switch control.kind {
            case .select(let body): source = body.options
            case .multiSelect(let body): source = body.options
            default: source = nil
            }
            if case .catalog(let catalog) = source {
                catalogs[control.id] = optionCatalog(catalog)
            }
        }
        _optionCatalogs = State(initialValue: catalogs)
    }

    var body: some View {
        NavigationView {
            Form {
                ForEach(capabilities.sections, id: \.id) { section in
                    if section.flags.contains(.page) {
                        NavigationLink {
                            Form { sectionRows(section) }
                                .navigationTitle(section.title)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(section.title)
                                if let summary = section.summary {
                                    Text(summary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Section {
                            sectionRows(section)
                        } header: {
                            Text(section.title)
                        } footer: {
                            if let summary = section.summary { Text(summary) }
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(draft)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset", role: .destructive) { draft = [:] }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onDisappear { optionCatalogs.values.forEach { $0.disappear() } }
    }

    @ViewBuilder
    private func sectionRows(_ section: ControlSection) -> some View {
        let visible = capabilities.visibleControlIDs(values: draft)
        ForEach(section.controls.filter { visible.contains($0.id) }, id: \.id) { control in
            if let value = draft[control.id] ?? control.kind.defaultValue {
                ControlValueRow(
                    control: control,
                    value: value,
                    currentValue: { draft[control.id] ?? control.kind.defaultValue ?? value },
                    onChange: { value in
                        guard control.kind.accepts(value) else { return }
                        draft[control.id] = value
                    },
                    optionCatalog: optionCatalogs[control.id]
                )
            } else {
                Label("This filter requires a newer version of Ito.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
