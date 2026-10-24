import Foundation
import ito_runner

/// Rejects all network requests immediately during diagnostic inspection (schema discovery/validation).
nonisolated struct PluginDiagnosticDenyingNetModule: NetModule, Sendable {
    func fetch(request: NetRequest) async throws -> NetResponse {
        throw URLError(.notConnectedToInternet)
    }

    func fetch(request: NetRequest, options: NetOptions) async throws -> NetResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// A diagnostic runs headless: it never loads a page, runs a page script, or shows login.
nonisolated struct PluginDiagnosticWebviewModule: WebviewModule {
    static let unavailable = ItoError.hostModuleError(
        domain: "webview",
        message: "A web view is not available during settings diagnostics."
    )

    func loadUrl(request: WebviewRequest) async throws -> WebviewResponse {
        throw Self.unavailable
    }

    func executeJs(script: String) async throws -> String {
        throw Self.unavailable
    }
}

@MainActor
final class PluginSettingsDiagnosticService: PluginSettingsDiagnosing {
    private let settingsStore: PluginSettingsStore
    private let locatePlugin: @MainActor @Sendable (String) throws -> URL

    init(
        settingsStore: PluginSettingsStore,
        locatePlugin: @escaping @MainActor @Sendable (String) throws -> URL
    ) {
        self.settingsStore = settingsStore
        self.locatePlugin = locatePlugin
    }

    func inspect(
        pluginID: String,
        schema: SettingsSchema,
        secretDrafts: [String: String]
    ) async throws -> PluginSettingsInspection {
        try Task.checkCancellation()
        let pluginURL = try locatePlugin(pluginID)
        try Task.checkCancellation()

        let defaults = try await captureDefaults(pluginID: pluginID, schema: schema, secretDrafts: secretDrafts)
        try Task.checkCancellation()

        let runner = try await loadRunner(pluginURL: pluginURL, defaults: defaults, netModule: PluginDiagnosticDenyingNetModule())
        try Task.checkCancellation()

        let actions = try await pluginCall {
            try await runner.getSettingsActions()
        } ?? []
        try Task.checkCancellation()

        let issues = try await pluginCall {
            try await runner.validateSettings()
        }
        try Task.checkCancellation()

        return PluginSettingsInspection(actions: actions, issues: issues)
    }

    func run(
        pluginID: String,
        schema: SettingsSchema,
        secretDrafts: [String: String],
        actionID: String
    ) async throws -> String? {
        try Task.checkCancellation()
        let pluginURL = try locatePlugin(pluginID)
        try Task.checkCancellation()

        let defaults = try await captureDefaults(pluginID: pluginID, schema: schema, secretDrafts: secretDrafts)
        try Task.checkCancellation()

        let netModule = PluginCompletionNetModule()
        defer { netModule.invalidate() }

        let runner = try await loadRunner(pluginURL: pluginURL, defaults: defaults, netModule: netModule)
        try Task.checkCancellation()

        let result = try await pluginCall {
            try await runner.runSettingsAction(actionID)
        }
        try Task.checkCancellation()

        return result
    }

    func captureDefaults(
        pluginID: String,
        schema: SettingsSchema,
        secretDrafts: [String: String]
    ) async throws -> PluginCompletionDefaults {
        let store = settingsStore
        let capture = Task.detached(priority: .utility) {
            try store.snapshot(pluginId: pluginID)
        }

        var values = try await withTaskCancellationHandler {
            try await capture.value
        } onCancel: {
            capture.cancel()
        }

        // Overlay ONLY schema-declared secret keys with nonblank (trimmed) draft; empty/blank means use saved
        let schemaSecretKeys: Set<String> = Set(schema.settings.compactMap { setting in
            switch setting {
            case .secret(let id, _, _): return id
            default: return nil
            }
        })

        for (key, draft) in secretDrafts where schemaSecretKeys.contains(key) {
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                values[key] = trimmed
            }
        }

        let defaults = PluginCompletionDefaults(settings: values)
        defaults.useSchemaDefaults(schema.storedDefaults)
        return defaults
    }

    private func loadRunner(
        pluginURL: URL,
        defaults: PluginCompletionDefaults,
        netModule: any NetModule
    ) async throws -> ItoRunner {
        let runner = ItoRunner()
        await runner.setNetModule(netModule)
        await runner.setStdModule(PluginCompletionStdModule())
        await runner.setDefaultsModule(defaults)
        await runner.setHtmlModule(DefaultHtmlModule())
        await runner.setJsModule(PluginCompletionJsModule())
        await runner.setWebviewModule(PluginDiagnosticWebviewModule())
        _ = try await runner.loadBundle(from: pluginURL)
        return runner
    }
}
