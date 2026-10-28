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
        return Page(options: try await context.loadOptionPage(request), context: context)
    }
}
