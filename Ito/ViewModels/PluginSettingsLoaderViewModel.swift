import Combine
import Foundation

/// Loads a source's settings independently of its home or search, so a source that cannot run
/// until its credentials are fixed can still be configured.
@MainActor
final class PluginSettingsLoaderViewModel: ObservableObject {
    @Published private(set) var destination: SourceSettingsDestination?
    @Published private(set) var failure: String?
    @Published private(set) var isLoading = false

    private let plugin: InstalledPlugin?
    private let runnerProvider: any SourceRunnerProviding
    private var generation = UUID()

    init(plugin: InstalledPlugin?, runnerProvider: any SourceRunnerProviding) {
        self.plugin = plugin
        self.runnerProvider = runnerProvider
    }

    func load() async {
        let operation = UUID()
        generation = operation
        destination = nil
        failure = nil
        isLoading = true
        defer { if generation == operation { isLoading = false } }
        guard let plugin else {
            failure = String(localized: "This source is no longer installed.")
            return
        }
        var failedContext: (any SourceRunnerContext)?
        do {
            let context = try await runnerProvider.sourceRunnerContext(for: plugin.id)
            failedContext = context
            try Task.checkCancellation()
            let surface = try await context.loadSettingsSurface(operationID: operation)
            try Task.checkCancellation()
            guard generation == operation else { return }
            if let surface {
                destination = SourceSettingsDestination(plugin: plugin, surface: surface)
            } else {
                failure = String(localized: "This source does not offer settings.")
            }
        } catch is CancellationError {
            return
        } catch {
            // A crashed runner is retired even when its load was cancelled or superseded; only a current load shows
            // the failure.
            if (error as? PluginCallError)?.kind == .crashed, let failedContext {
                runnerProvider.retireSourceRunner(for: plugin.id, matching: failedContext)
            }
            guard generation == operation, !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }

    func settingsClosed() {
        generation = UUID()
        if let plugin { runnerProvider.evictSourceRunner(for: plugin.id) }
    }
}
