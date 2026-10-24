import Testing
import ito_runner
@testable import Ito

@MainActor
struct WebviewScriptResultTests {
    @Test func aScriptThatEvaluatesToNothingGivesThePluginAnEmptyResult() async throws {
        let manager = WebviewManager(pageLoadDeadline: 20)
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))

        for script in ["undefined", "null", "''"] {
            #expect(try await manager.executeJs(script: script).isEmpty, "\(script)")
        }
        #expect(try await manager.executeJs(script: "6 * 7") == "42")
        #expect(try await manager.executeJs(script: "'abc'") == "abc")
    }
}
