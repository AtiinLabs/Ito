import SwiftUI
import ito_runner

// Shared by settings and search: draft text is never itself a persisted value.
struct IntegerControlDraft {
    var lower: String
    var upper: String
    private(set) var isDirty = false
    private(set) var error: String?

    init(value: ControlValue) {
        switch value {
        case .integer(let number): lower = number.map(String.init) ?? ""; upper = ""
        case .integerRange(let low, let high): lower = low.map(String.init) ?? ""; upper = high.map(String.init) ?? ""
        default: lower = ""; upper = ""
        }
    }

    mutating func edit(lower: String? = nil, upper: String? = nil, kind: ControlKind) {
        if let lower { self.lower = lower }
        if let upper { self.upper = upper }
        isDirty = true
        validate(kind: kind)
    }

    mutating func committedValue(kind: ControlKind) -> ControlValue? {
        validate(kind: kind)
        return parsedValue(kind: kind)
    }

    private mutating func validate(kind: ControlKind) {
        if parsedValue(kind: kind) != nil { error = nil; return }
        switch kind {
        case .integer(let spec): error = "Enter a whole number between \(spec.min) and \(spec.max)."
        case .integerRange(let spec): error = "Enter values between \(spec.min) and \(spec.max), with minimum no greater than maximum."
        default: error = nil
        }
    }

    private func parsedValue(kind: ControlKind) -> ControlValue? {
        switch kind {
        case .integer(let spec):
            guard let number = Self.bound(lower, min: spec.min, max: spec.max) else { return nil }
            return .integer(number)
        case .integerRange(let spec):
            guard let low = Self.bound(lower, min: spec.min, max: spec.max),
                  let high = Self.bound(upper, min: spec.min, max: spec.max) else { return nil }
            if let low, let high, low > high { return nil }
            return .integerRange(lower: low, upper: high)
        default: return nil
        }
    }

    private static func bound(_ text: String, min: Int64, max: Int64) -> Int64?? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .some(nil) }
        guard let number = Int64(text), number >= min, number <= max else { return nil }
        return .some(number)
    }
}

struct IntegerControlRow: View {
    let control: Control
    let spec: IntegerControl
    let value: ControlValue
    let currentValue: () -> ControlValue
    let onChange: (ControlValue) -> Void
    @State private var draft = IntegerControlDraft(value: .integer(nil))
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(control.title)
            HStack {
                TextField("Optional", text: Binding(
                    get: { draft.lower },
                    set: { draft.edit(lower: $0, kind: control.kind) }
                ))
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .focused($focused)
                .onSubmit(commit)
                .accessibilityLabel(control.title)
                if let unit = spec.unit { Text(unit).foregroundColor(.secondary) }
                Button("Done") { commit(); focused = false }
            }
            if let error = draft.error { Text(error).font(.caption).foregroundColor(.red) }
        }
        .onAppear { draft = IntegerControlDraft(value: currentValue()) }
        .onChange(of: value) { updated in if !draft.isDirty { draft = IntegerControlDraft(value: updated) } }
        .onChange(of: focused) { if !$0 && draft.isDirty { commit() } }
    }

    private func commit() {
        guard draft.isDirty else { return }
        guard let parsed = draft.committedValue(kind: control.kind) else { return }
        onChange(parsed)
        draft = IntegerControlDraft(value: currentValue())
    }
}

struct IntegerRangeControlRow: View {
    let control: Control
    let spec: IntegerRangeControl
    let value: ControlValue
    let currentValue: () -> ControlValue
    let onChange: (ControlValue) -> Void
    @State private var draft = IntegerControlDraft(value: .integerRange(lower: nil, upper: nil))
    @FocusState private var focused: Bound?
    private enum Bound: Hashable { case lower, upper }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(control.title)
            HStack {
                TextField("Minimum", text: Binding(
                    get: { draft.lower },
                    set: { draft.edit(lower: $0, kind: control.kind) }
                ))
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .focused($focused, equals: .lower)
                .onSubmit(commit)
                .accessibilityLabel("\(control.title), minimum")
                Text("to").foregroundColor(.secondary)
                TextField("Maximum", text: Binding(
                    get: { draft.upper },
                    set: { draft.edit(upper: $0, kind: control.kind) }
                ))
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .focused($focused, equals: .upper)
                .onSubmit(commit)
                .accessibilityLabel("\(control.title), maximum")
                if let unit = spec.unit { Text(unit).foregroundColor(.secondary) }
                Button("Done") { commit(); focused = nil }
            }
            if let error = draft.error { Text(error).font(.caption).foregroundColor(.red) }
        }
        .onAppear { draft = IntegerControlDraft(value: currentValue()) }
        .onChange(of: value) { updated in if !draft.isDirty { draft = IntegerControlDraft(value: updated) } }
        .onChange(of: focused) { if $0 == nil && draft.isDirty { commit() } }
    }

    private func commit() {
        guard draft.isDirty else { return }
        guard let parsed = draft.committedValue(kind: control.kind) else { return }
        onChange(parsed)
        draft = IntegerControlDraft(value: currentValue())
    }
}
