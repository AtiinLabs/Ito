import Testing
import ito_runner
@testable import Ito

private let asyncMarker = "//# ito-async\n"

@MainActor
private func loadedPage(_ html: String = "<p>x</p>") async throws -> WebviewManager {
    let manager = WebviewManager(pageLoadDeadline: 20)
    _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,\(html)", script: nil))
    return manager
}

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

    @Test func aLegacyScriptStillCannotReturnAPromise() async throws {
        let manager = try await loadedPage()

        await #expect(throws: (any Error).self) {
            try await manager.executeJs(script: "Promise.resolve(1)")
        }
        #expect(try await manager.executeJs(script: "6 * 7") == "42")
    }

    @Test func anAsyncScriptGivesThePluginItsResolvedValue() async throws {
        let manager = try await loadedPage()

        #expect(try await manager.executeJs(script: asyncMarker + "return 'x'") == "x")
        #expect(try await manager.executeJs(script: asyncMarker + "return Promise.resolve('x')") == "x")
        #expect(try await manager.executeJs(script: asyncMarker + "return 42") == "42")
        #expect(try await manager.executeJs(script: asyncMarker + "return await Promise.resolve(7)") == "7")
    }

    @Test func anAsyncScriptThatReturnsNothingGivesAnEmptyResult() async throws {
        let manager = try await loadedPage()

        for body in [
            "",
            "return",
            "return undefined",
            "return null",
            "return Promise.resolve(undefined)",
            "return Promise.resolve(null)",
        ] {
            #expect(try await manager.executeJs(script: asyncMarker + body).isEmpty, "\(body)")
        }
    }

    @Test func aRejectedAsyncScriptThrows() async throws {
        let manager = try await loadedPage()

        await #expect(throws: (any Error).self) {
            try await manager.executeJs(script: asyncMarker + "return Promise.reject(new Error('nope'))")
        }
        #expect(try await manager.executeJs(script: "6 * 7") == "42")
    }

    @Test func onlyTheExactMarkerLineSelectsTheAsyncPath() async throws {
        let manager = try await loadedPage()

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

        #expect(try await manager.executeJs(script: asyncMarker + "return window.pageValue") == "seen")
    }
}
