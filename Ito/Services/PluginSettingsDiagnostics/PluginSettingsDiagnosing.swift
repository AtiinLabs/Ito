import Foundation
import ito_runner

nonisolated struct PluginSettingsInspection: Sendable {
    let actions: [SettingsAction]
    let issues: [SettingIssue]? // nil unsupported, empty validated

    init(actions: [SettingsAction], issues: [SettingIssue]?) {
        self.actions = actions
        self.issues = issues
    }
}

@MainActor
protocol PluginSettingsDiagnosing: AnyObject {
    func inspect(pluginID: String, surface: SettingsSurface, secretDrafts: [String: String]) async throws -> PluginSettingsInspection
    func run(pluginID: String, surface: SettingsSurface, secretDrafts: [String: String], actionID: String) async throws -> String?
}
