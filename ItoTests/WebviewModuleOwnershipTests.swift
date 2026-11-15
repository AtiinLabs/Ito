import Foundation
import XCTest
import ito_runner
@testable import Ito

final class WebviewModuleOwnershipTests: XCTestCase {
    func testBackgroundCallerCanUseAndReleaseItsPageOwner() async throws {
        let context = NetworkOperationContext(
            purpose: .foregroundReading, sourceID: "fixture", authorizationScope: UUID(),
            operationID: UUID(), policyRevision: 0, generation: UUID()
        )
        let result = try await Task.detached {
            // The final module reference is released by a background executor, as on runner teardown.
            var module: AppWebviewModule? = await AppWebviewModule(websites: SourceWebsiteContexts())
            _ = try await module?.loadUrl(
                request: WebviewRequest(url: "data:text/html,<p id='value'>operation-owned</p>", script: nil),
                context: context
            )
            let value = try await module?.executeJs(script: "document.getElementById('value').textContent", context: context)
            module = nil
            return value
        }.value
        XCTAssertEqual(result, "operation-owned")
    }
}
