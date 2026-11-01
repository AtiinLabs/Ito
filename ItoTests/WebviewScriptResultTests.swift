import Testing
import UIKit
import WebKit
import ito_runner
@testable import Ito

private let asyncMarker = "//# ito-async\n"

@MainActor
private func dispose(_ manager: WebviewManager) {
    manager.webView?.stopLoading()
    manager.webView?.removeFromSuperview()
}

@MainActor
private func loadedPage(_ html: String = "<p>x</p>") async throws -> WebviewManager {
    let manager = WebviewManager(pageLoadDeadline: 20)
    do {
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,\(html)", script: nil))
        return manager
    } catch {
        dispose(manager)
        throw error
    }
}

@MainActor
struct WebviewScriptResultTests {
    @Test func aScriptThatEvaluatesToNothingGivesThePluginAnEmptyResult() async throws {
        let manager = try await loadedPage()
        defer { dispose(manager) }

        for script in ["undefined", "null", "''"] {
            #expect(try await manager.executeJs(script: script).isEmpty, "\(script)")
        }
        #expect(try await manager.executeJs(script: "6 * 7") == "42")
        #expect(try await manager.executeJs(script: "'abc'") == "abc")
    }

    @Test func aLegacyScriptStillCannotReturnAPromise() async throws {
        let manager = try await loadedPage()
        defer { dispose(manager) }

        await #expect(throws: (any Error).self) {
            try await manager.executeJs(script: "Promise.resolve(1)")
        }
        #expect(try await manager.executeJs(script: "6 * 7") == "42")
    }

    @Test func anAsyncScriptGivesThePluginItsResolvedValue() async throws {
        let manager = try await loadedPage()
        defer { dispose(manager) }

        #expect(try await manager.executeJs(script: asyncMarker + "return 'x'") == "x")
        #expect(try await manager.executeJs(script: asyncMarker + "return Promise.resolve('x')") == "x")
        #expect(try await manager.executeJs(script: asyncMarker + "return 42") == "42")
        #expect(try await manager.executeJs(script: asyncMarker + "return await Promise.resolve(7)") == "7")
    }

    @Test func anAsyncScriptThatReturnsNothingGivesAnEmptyResult() async throws {
        let manager = try await loadedPage()
        defer { dispose(manager) }

        for body in [
            "",
            "return",
            "return undefined",
            "return null",
            "return Promise.resolve(undefined)",
            "return Promise.resolve(null)"
        ] {
            #expect(try await manager.executeJs(script: asyncMarker + body).isEmpty, "\(body)")
        }
    }

    @Test func aRejectedAsyncScriptThrows() async throws {
        let manager = try await loadedPage()
        defer { dispose(manager) }

        await #expect(throws: (any Error).self) {
            try await manager.executeJs(script: asyncMarker + "return Promise.reject(new Error('nope'))")
        }
        #expect(try await manager.executeJs(script: "6 * 7") == "42")
    }

    @Test func onlyTheExactMarkerLineSelectsTheAsyncPath() async throws {
        let manager = try await loadedPage()
        defer { dispose(manager) }

        // Not at the start of the script: an ordinary script.
        #expect(try await manager.executeJs(script: " //# ito-async\n6 * 7") == "42")
        #expect(try await manager.executeJs(script: "//# ito-asynctest\n6 * 7") == "42")
        // Not exact (trailing space): evaluated as before, where a top-level `return` is a SyntaxError.
        await #expect(throws: (any Error).self) {
            try await manager.executeJs(script: "//# ito-async \nreturn 1")
        }
    }

    @Test func anAsyncScriptSeesThePageGlobals() async throws {
        let manager = try await loadedPage("<script>window.pageValue='seen'</script>")
        defer { dispose(manager) }

        #expect(try await manager.executeJs(script: asyncMarker + "return window.pageValue") == "seen")
    }
}
