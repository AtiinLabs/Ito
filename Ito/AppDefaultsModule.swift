import ito_runner

public final class AppDefaultsModule: DefaultsModule, @unchecked Sendable {
    private let pluginId: String
    private let store: PluginSettingsStore

    public init(pluginId: String, store: PluginSettingsStore) {
        self.pluginId = pluginId
        self.store = store
    }

    public func set(key: String, value: String) {
        // Secrets come from the user. A plugin can't overwrite one or shadow it with a plain value.
        guard store.secrets.value(pluginID: pluginId, key: key) == nil else { return }
        store.set(pluginId: pluginId, key: key, value: value)
    }

    public func get(key: String) -> String? {
        store.secrets.value(pluginID: pluginId, key: key) ?? store.get(pluginId: pluginId, key: key)
    }

    public func remove(key: String) {
        try? store.secrets.removeValue(pluginID: pluginId, key: key)
        store.remove(pluginId: pluginId, key: key)
    }
}
