import Foundation
import ito_runner

/// Rejects all network requests immediately during diagnostic inspection (schema discovery/validation).
nonisolated struct PluginDiagnosticDenyingNetModule: NetModule, Sendable {
    func fetch(request: NetRequest) async throws -> NetResponse {
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
        surface: SettingsSurface,
        secretDrafts: [String: String]
    ) async throws -> PluginSettingsInspection {
        try Task.checkCancellation()
        let pluginURL = try locatePlugin(pluginID)
        try Task.checkCancellation()

        let defaults = try await captureDefaults(pluginID: pluginID, surface: surface, secretDrafts: secretDrafts)
        try Task.checkCancellation()

        let runner = try await loadRunner(
            pluginURL: pluginURL, defaults: defaults, surface: surface, netModule: PluginDiagnosticDenyingNetModule()
        )
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
        surface: SettingsSurface,
        secretDrafts: [String: String],
        actionID: String
    ) async throws -> String? {
        try Task.checkCancellation()
        let pluginURL = try locatePlugin(pluginID)
        try Task.checkCancellation()

        let defaults = try await captureDefaults(pluginID: pluginID, surface: surface, secretDrafts: secretDrafts)
        try Task.checkCancellation()

        let cookies = settingsStore.cookies
        let netModule = PluginCompletionNetModule(
            cookies: { url in cookies.cookies(pluginID: pluginID, for: url) },
            trust: (pluginID, settingsStore.trust)
        )
        defer { netModule.invalidate() }

        let runner = try await loadRunner(pluginURL: pluginURL, defaults: defaults, surface: surface, netModule: netModule)
        try Task.checkCancellation()

        let result = try await pluginCall {
            try await runner.runSettingsAction(actionID)
        }
        try Task.checkCancellation()

        return result
    }

    func captureDefaults(
        pluginID: String,
        surface: SettingsSurface,
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

        // Only declared secret controls may overlay saved credentials with an unsaved draft.
        let schemaSecretKeys = surface.secretSettingIDs

        for (key, draft) in secretDrafts where schemaSecretKeys.contains(key) {
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                values[key] = trimmed
            }
        }

        let defaults = PluginCompletionDefaults(settings: values)
        defaults.useSchemaDefaults(surface.storedDefaults)
        return defaults
    }

    private func loadRunner(
        pluginURL: URL,
        defaults: PluginCompletionDefaults,
        surface: SettingsSurface,
        netModule: any NetModule
    ) async throws -> ItoRunner {
        let runner = ItoRunner()
        await runner.setNetModule(netModule)
        await runner.setStdModule(PluginCompletionStdModule())
        await runner.setDefaultsModule(defaults)
        await runner.setHtmlModule(DefaultHtmlModule())
        await runner.setWebviewModule(PluginDiagnosticWebviewModule())
        _ = try await runner.loadBundle(from: pluginURL)
        if case .form = surface {
            // The isolated instance must negotiate the same surface before interpreting saved values.
            _ = try await pluginCall { try await runner.getSettingsSurface() }
        }
        return runner
    }
}
