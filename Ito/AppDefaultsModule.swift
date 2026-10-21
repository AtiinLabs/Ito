import Foundation
import ito_runner

public final class AppDefaultsModule: DefaultsModule, @unchecked Sendable {
    private let pluginId: String
    private let store: PluginSettingsStore
    private let lock = NSLock()
    private var schemaDefaults: [String: String] = [:]

    public init(pluginId: String, store: PluginSettingsStore) {
        self.pluginId = pluginId
        self.store = store
    }

    /// The defaults the plugin's settings schema declares. A key the user never set reads as its
    /// default, as the settings screen shows it, without anything being stored.
    func useSchemaDefaults(_ defaults: [String: String]) {
        lock.withLock { schemaDefaults = defaults }
    }

    public func set(key: String, value: String) {
        // Secrets come from the user. A plugin can't overwrite one or shadow it with a plain value.
        guard store.secrets.value(pluginID: pluginId, key: key) == nil else { return }
        store.set(pluginId: pluginId, key: key, value: value)
    }

    public func get(key: String) -> String? {
        store.secrets.value(pluginID: pluginId, key: key)
            ?? store.get(pluginId: pluginId, key: key)
            ?? lock.withLock { schemaDefaults[key] }
    }

    public func remove(key: String) {
        try? store.secrets.removeValue(pluginID: pluginId, key: key)
        store.remove(pluginId: pluginId, key: key)
    }
}

extension SettingsSchema {
    /// Each setting's default, as the settings screen stores it. Secrets have none.
    var storedDefaults: [String: String] {
        settings.reduce(into: [:]) { defaults, setting in
            switch setting {
            case .toggle(let id, _, _, let defaultValue):
                defaults[id] = Setting.storedToggle(defaultValue)
            case .text(let id, _, _, let defaultValue), .picker(let id, _, _, _, let defaultValue):
                defaults[id] = defaultValue
            case .secret:
                break
            }
        }
    }
}

extension Setting {
    /// How a toggle's value is stored.
    static func storedToggle(_ isOn: Bool) -> String {
        isOn ? "true" : "false"
    }
}
