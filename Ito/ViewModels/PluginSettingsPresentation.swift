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

    init(surface: SettingsSurface) {
        switch surface {
        case .form(let form):
            sections = form.sections.map {
                Section(id: $0.id, title: $0.title, summary: $0.summary, isPage: $0.flags.contains(.page), controls: $0.controls)
            }
            isLegacy = false
            formFailure = nil
        case .legacy(let schema, let formFailure):
            sections = [
                Section(id: "legacy", title: "", summary: nil, isPage: false,
                        controls: schema.settings.map(Self.control(for:)))
            ]
            isLegacy = true
            self.formFailure = formFailure
        }
    }

    var controls: [Control] { sections.flatMap(\.controls) }

    func visibleControlIDs(value: (Control) -> ControlValue?) -> Set<String> {
        let values = Dictionary(uniqueKeysWithValues: controls.map { ($0.id, value($0)) })
        return Set(controls.filter { control in
            control.visibleWhen.allSatisfy { condition in
                guard let target = controls.first(where: { $0.id == condition.control }) else { return false }
                guard let targetValue = values[target.id] else { return false }
                switch targetValue {
                case .toggle(let bool): return condition.anyOf.contains(bool ? "true" : "false")
                case .select(let selected): return selected.map(condition.anyOf.contains) ?? false
                case .multiSelect(let selected): return selected.contains(where: condition.anyOf.contains)
                default: return false
                }
            }
        }.map(\.id))
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
