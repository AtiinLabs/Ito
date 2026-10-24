import Foundation
import ito_runner

/// Settings a plugin sees while delivering one completion: the values captured with the attempt's
/// intent, held in memory. A plugin may `set`, `setSecret` or `remove` keys, but only inside this
/// sandbox and only for the attempt; nothing reaches the live settings store, the Keychain or
/// another attempt.
nonisolated final class PluginCompletionDefaults: DefaultsModule, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var schemaDefaults: [String: String] = [:]

    init(settings: [String: String]) {
        values = settings
    }

    /// The defaults the plugin's settings schema declares. A key the user never set reads as its
    /// default, exactly as it does in the reader, without anything being stored.
    func useSchemaDefaults(_ defaults: [String: String]) {
        lock.withLock { schemaDefaults = defaults }
    }

    func set(key: String, value: String) {
        lock.withLock { values[key] = value }
    }

    func setSecret(key: String, value: String) {
        set(key: key, value: value)
    }

    func get(key: String) -> String? {
        lock.withLock { values[key] ?? schemaDefaults[key] }
    }

    func remove(key: String) {
        lock.withLock { values[key] = nil }
    }
}

/// Plugin console output is discarded. A plugin's text can carry credentials or remote response
/// data, so no sink may keep it; the dispatcher keeps only the typed failure category the runner
/// reports.
nonisolated struct PluginCompletionStdModule: StdModule {
    func print(message: String) {}
}

/// A completion runs headless: it never loads a page, runs a page script, or shows login. A plugin
/// that needs a web view cannot deliver here, and says so with a typed error rather than a fake
/// page. The message is fixed text; nothing the plugin asked for is echoed.
nonisolated struct PluginCompletionWebviewModule: WebviewModule {
    static let unavailable = ItoError.hostModuleError(
        domain: "webview",
        message: "A web view is not available while syncing read progress."
    )

    func loadUrl(request: WebviewRequest) async throws -> WebviewResponse {
        throw Self.unavailable
    }

    func executeJs(script: String) async throws -> String {
        throw Self.unavailable
    }
}
