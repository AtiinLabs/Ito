import XCTest
import ito_runner
@testable import Ito

@MainActor
final class PluginSettingsLoaderViewModelTests: XCTestCase {
    func testSettingsLoadWithoutCallingTheBrokenHome() async throws {
        let context = PR7BSourceRunnerContextSpy()
        context.settingsResult = .success(try pr7bSettingsSchema(settings: [
            .secret(id: "key", name: "API key", summary: nil)
        ]))
        context.homeResult = .failure(PluginCallError(kind: .needsSettings, message: "Rejected"))
        let provider = PR7BSourceRunnerProviderSpy(contexts: [context])
        let model = PluginSettingsLoaderViewModel(plugin: pr7bPlugin(), runnerProvider: provider)

        await model.load()

        XCTAssertNotNil(model.destination)
        XCTAssertNil(model.failure)
        XCTAssertEqual(context.homeLoadCount, 0)
    }

    func testMissingPluginDoesNotAcquireARunner() async {
        let provider = PR7BSourceRunnerProviderSpy()
        let model = PluginSettingsLoaderViewModel(plugin: nil, runnerProvider: provider)

        await model.load()

        XCTAssertNil(model.destination)
        XCTAssertEqual(model.failure, "This source is no longer installed.")
        XCTAssertTrue(provider.requestedPluginIDs.isEmpty)
    }

    func testCrashedSchemaEvictsAndRetryUsesFreshRunner() async throws {
        let crashed = PR7BSourceRunnerContextSpy()
        crashed.settingsResult = .failure(PluginCallError(kind: .crashed, message: "Stopped"))
        let fresh = PR7BSourceRunnerContextSpy()
        fresh.settingsResult = .success(try pr7bSettingsSchema())
        let provider = PR7BSourceRunnerProviderSpy(contexts: [crashed, fresh])
        let model = PluginSettingsLoaderViewModel(plugin: pr7bPlugin(), runnerProvider: provider)

        await model.load()
        XCTAssertEqual(model.failure, "Stopped")
        XCTAssertEqual(provider.evictedPluginIDs, ["plugin.manga"])
        await model.load()
        XCTAssertNotNil(model.destination)
        XCTAssertNil(model.failure)
    }
}
