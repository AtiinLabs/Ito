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
        // The last write wins: a token stored earlier under the key would otherwise hide this value.
        try? store.tokens.removeValue(pluginID: pluginId, key: key)
        store.set(pluginId: pluginId, key: key, value: value)
    }

    /// Keeps a credential the plugin obtained in the Keychain, never in the settings database or
    /// backups. A secret the user entered for the key wins and is left alone. Once the token is
    /// stored, any plain copy under the key is dropped so it can't be backed up.
    public func setSecret(key: String, value: String) {
        guard store.secrets.value(pluginID: pluginId, key: key) == nil else { return }
        do {
            try store.tokens.setValue(value, pluginID: pluginId, key: key)
        } catch {
            return
        }
        store.remove(pluginId: pluginId, key: key)
    }

    public func get(key: String) -> String? {
        store.secrets.value(pluginID: pluginId, key: key)
            ?? store.tokens.value(pluginID: pluginId, key: key)
            ?? store.get(pluginId: pluginId, key: key)
            ?? lock.withLock { schemaDefaults[key] }
    }

    /// Removes what the plugin stored. Secrets the user entered change only in the settings screen.
    public func remove(key: String) {
        try? store.tokens.removeValue(pluginID: pluginId, key: key)
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
