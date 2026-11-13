import Foundation
import ito_runner
import Testing
@testable import Ito

/// Answers every image export with a fixed resolution and records the host context each export received.
private actor RecordingImageRunner: PluginImageRunner {
    private(set) var contexts: [NetworkOperationContext] = []

    func getImageRequest(_ locator: String, context: NetworkOperationContext) async throws -> PluginImageRequest? {
        contexts.append(context)
        return PluginImageRequest(url: "https://images.example/cover")
    }

    func getImageOrigins(context: NetworkOperationContext) async throws -> [String]? {
        contexts.append(context)
        return ["https://images.example"]
    }

    func handleImage(_ locator: String, context: NetworkOperationContext) async throws -> Data? {
        contexts.append(context)
        return nil
    }
}

struct PluginImageNetworkContextTests {
    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func everyExportOfOneResolutionSharesItsOperationAndGetsItsOwnGeneration() async throws {
        let locator = PluginImageLocator(pluginID: "fixture.plugin", realURLString: "https://images.example/cover")
        let runner = RecordingImageRunner()
        let contexts = PluginNetworkContexts(policy: NetworkPolicyCenter())
        let operation = PluginNetworkOperation(purpose: .coverImage, operationID: UUID())

        let result = try await PluginImageResolution.resolve(locator, runner: runner, context: {
            contexts.context(pluginID: "fixture.plugin", operation)
        })

        guard case .fetch = result else {
            Issue.record("A resolved cover must be fetched, not returned as bytes")
            return
        }
        let seen = await runner.contexts
        #expect(seen.count == 2)
        #expect(Set(seen.map(\.operationID)) == [operation.operationID])
        #expect(Set(seen.map(\.generation)).count == 2)
        #expect(seen.allSatisfy { $0.purpose == .coverImage && $0.sourceID == "fixture.plugin" })
    }
}
