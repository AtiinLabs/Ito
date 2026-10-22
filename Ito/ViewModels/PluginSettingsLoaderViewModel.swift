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
            failure = "This source is no longer installed."
            return
        }
        do {
            let context = try await runnerProvider.sourceRunnerContext(for: plugin.id)
            try Task.checkCancellation()
            let schema = try await context.loadSettingsSchema()
            try Task.checkCancellation()
            guard generation == operation else { return }
            if let schema {
                destination = SourceSettingsDestination(plugin: plugin, schema: schema)
            } else {
                failure = "This source does not offer settings."
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == operation, !Task.isCancelled else { return }
            if (error as? PluginCallError)?.kind == .crashed {
                runnerProvider.evictSourceRunner(for: plugin.id)
            }
            failure = error.localizedDescription
        }
    }
}
