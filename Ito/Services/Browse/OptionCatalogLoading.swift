import Foundation
import ito_runner

@MainActor
final class OptionCatalogLoading {
    struct Page {
        let options: OptionPage?
        let context: any SourceRunnerContext
        var runnerIdentity: ObjectIdentifier { context.runnerIdentity }
    }

    private let pluginID: String
    private let runnerProvider: any SourceRunnerProviding

    init(pluginID: String, runnerProvider: any SourceRunnerProviding) {
        self.pluginID = pluginID
        self.runnerProvider = runnerProvider
    }
    func sourceContext() async throws -> any SourceRunnerContext {
        let context = try await runnerProvider.sourceRunnerContext(for: pluginID)
        return context
    }

    func load(_ request: OptionRequest) async throws -> Page {
        let context = try await runnerProvider.sourceRunnerContext(for: pluginID)
        // Each page request is its own interactive operation.
        let options = try await loadOptionPage(request, on: context)
        return Page(options: options, context: context)
    }

    /// Reads one option page from `context`. A crash retires the instance behind `context`, whether or not the
    /// caller still wants the answer, so the next request acquires a new runner instead of the crashed one.
    func loadOptionPage(_ request: OptionRequest, on context: any SourceRunnerContext) async throws -> OptionPage? {
        do {
            return try await context.loadOptionPage(request, operationID: UUID())
        } catch {
            if (error as? PluginCallError)?.kind == .crashed {
                runnerProvider.retireSourceRunner(for: pluginID, matching: context)
            }
            throw error
        }
    }
}
