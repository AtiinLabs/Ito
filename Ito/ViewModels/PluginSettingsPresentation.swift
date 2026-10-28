import Foundation
import ito_runner

struct PluginSettingsPresentation {
    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let summary: String?
        let isPage: Bool
        let controls: [Control]
    }

    let sections: [Section]
    let isLegacy: Bool
    let formFailure: ItoError?
    private let richForm: SettingsForm?

    init(surface: SettingsSurface) {
        switch surface {
        case .form(let form):
            richForm = form
            sections = form.sections.map {
                Section(id: $0.id, title: $0.title, summary: $0.summary, isPage: $0.flags.contains(.page), controls: $0.controls)
            }
            isLegacy = false
            formFailure = nil
        case .legacy(let schema, let formFailure):
            richForm = nil
            sections = [
                Section(id: "legacy", title: "", summary: nil, isPage: false,
                        controls: schema.settings.map(Self.control(for:)))
            ]
            isLegacy = true
            self.formFailure = formFailure
        }
    }

    var controls: [Control] { sections.flatMap(\.controls) }

    func effectiveValue(for control: Control, stored: String?) -> (value: ControlValue?, state: StoredValueState) {
        guard isLegacy else { return control.effectiveValue(stored: stored) }
        guard let stored else { return (control.kind.defaultValue, .unset) }
        // Legacy schemas store raw strings, not the rich form's validated value language.
        switch control.kind {
        case .toggle: return (.toggle(stored == "true"), .valid)
        case .text: return (.text(stored), .valid)
        case .select: return (.select(stored), .valid)
        default: return control.effectiveValue(stored: stored)
        }
    }

    func accepts(_ value: ControlValue, for control: Control) -> Bool {
        guard isLegacy else { return control.kind.accepts(value) }
        switch (control.kind, value) {
        case (.toggle, .toggle), (.text, .text), (.select, .select): return true
        default: return false
        }
    }

    func visibleControlIDs(value: (Control) -> ControlValue?) -> Set<String> {
        if let richForm {
            return richForm.visibleControlIDs(effectiveValue: value)
        }
        return Set(controls.map(\.id))
    }

    private static func control(for setting: Setting) -> Control {
        switch setting {
        case .toggle(let id, let title, let summary, let defaultValue):
            return Control(id: id, title: title, summary: summary, flags: 0, visibleWhen: [], kind: .toggle(ToggleControl(defaultValue: defaultValue)))
        case .text(let id, let title, let summary, let defaultValue):
            return Control(id: id, title: title, summary: summary, flags: 0, visibleWhen: [], kind: .text(TextControl(defaultValue: defaultValue, placeholder: nil, flags: [])))
        case .picker(let id, let title, let summary, let optionNames, let defaultValue):
            let options = optionNames.map { ChoiceOption(value: $0, label: $0, group: nil) }
            return Control(id: id, title: title, summary: summary, flags: 0, visibleWhen: [], kind: .select(SelectControl(options: .inline(options), defaultValue: defaultValue)))
        case .secret(let id, let title, let summary):
            return Control(id: id, title: title, summary: summary, flags: 0, visibleWhen: [], kind: .secret(SecretControl(placeholder: nil)))
        }
    }
}
