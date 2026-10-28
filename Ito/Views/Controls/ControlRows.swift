import SwiftUI
import ito_runner

struct ControlValueRow: View {
    let control: Control
    let value: ControlValue
    let currentValue: () -> ControlValue
    let onChange: (ControlValue) -> Void
    let optionCatalog: OptionCatalogModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch control.kind {
            case .toggle:
                Toggle(control.title, isOn: Binding(
                    get: { if case let .toggle(value) = currentValue() { return value }; return false },
                    set: { onChange(.toggle($0)) }
                ))
            case .text(let spec):
                Text(control.title)
                let textBinding = Binding(
                    get: { if case let .text(value) = currentValue() { return value }; return spec.defaultValue },
                    set: { onChange(.text($0)) }
                )
                if spec.flags.contains(.multiline) {
                    TextEditor(text: textBinding)
                        .frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                } else {
                    TextField(spec.placeholder ?? control.title, text: textBinding)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .textInputAutocapitalization(spec.flags.contains(.url) ? .never : .sentences)
                        .disableAutocorrection(spec.flags.contains(.url))
                }
            case .select, .multiSelect:
                NavigationLink {
                    OptionSelectionView(control: control, value: value, currentValue: currentValue, onChange: onChange, catalog: optionCatalog)
                } label: {
                    HStack {
                        Text(control.title)
                        Spacer()
                        SelectionSummary(control: control, value: value, catalog: optionCatalog)
                            .foregroundColor(.secondary)
                    }
                }
            case .integer(let spec):
                IntegerControlRow(control: control, spec: spec, value: value, currentValue: currentValue, onChange: onChange)
            case .integerRange(let spec):
                IntegerRangeControlRow(control: control, spec: spec, value: value, currentValue: currentValue, onChange: onChange)
            case .secret:
                // Settings renders its credential-backed editor before reaching this row.
                EmptyView()
            case .unsupported(let tag):
                Label("This control type (\(tag)) is not supported.", systemImage: "questionmark.circle")
                    .foregroundColor(.secondary)
            }
            if let summary = control.summary, !summary.isEmpty {
                Text(summary).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SelectionSummary: View {
    let control: Control
    let value: ControlValue
    let catalog: OptionCatalogModel?
    @State private var resolution: OptionCatalogModel.LabelResolution?
    @State private var retry = 0
    @State private var labelConsumer = UUID()

    private var selected: [String] { value.selectedOptions }

    var body: some View {
        VStack(alignment: .trailing) {
            Text(summary)
            if resolution?.error != nil {
                Button("Retry labels") { retry += 1 }.font(.caption)
            }
        }
        .task(id: selected.map { Data($0.utf8) }) { await resolve() }
        .task(id: retry) { if retry > 0 { await resolve() } }
    }

    private var summary: String {
        guard !selected.isEmpty else { return "None selected" }
        if let error = resolution?.error { return error }
        let options: OptionSource
        switch control.kind {
        case .select(let spec): options = spec.options
        case .multiSelect(let spec): options = spec.options
        default: return "None selected"
        }
        return selected.map { value in
            if case .inline(let inline) = options {
                return inline.first(where: { $0.value.utf8.elementsEqual(value.utf8) })?.label ?? "Unavailable option"
            }
            let identity = Data(value.utf8)
            if let label = resolution?.labels[identity] { return label }
            if resolution?.unavailable.contains(identity) == true { return "Unavailable option" }
            return catalog == nil ? "Labels unavailable." : "Loading label…"
        }.joined(separator: ", ")
    }

    private func resolve() async {
        guard let catalog, !selected.isEmpty else { resolution = nil; return }
        let result = await catalog.resolve(values: selected, consumer: labelConsumer)
        guard !Task.isCancelled else { return }
        resolution = result
    }
}

extension ControlValue {
    var selectedOptions: [String] {
        switch self {
        case .select(let value): return value.map { [$0] } ?? []
        case .multiSelect(let values): return values
        default: return []
        }
    }
}
