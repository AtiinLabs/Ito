import Foundation
import Testing
@testable import Ito

/// Answers each probe with the next scripted value and counts the probes.
@MainActor
private final class ScriptedProbe {
    private var answers: [String?]
    private(set) var calls = 0

    init(answers: [String?]) {
        self.answers = answers
    }

    func next() -> String? {
        calls += 1
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

@MainActor
struct WebKitUserAgentTests {
    private let url = URL(string: "https://comix.to/title/1")!

    @Test func theProbeRunsOnceAndItsAnswerIsKept() async {
        let probe = ScriptedProbe(answers: ["Agent/1"])
        let agent = WebKitUserAgent(probe: { probe.next() })

        #expect(await agent.value() == "Agent/1")
        #expect(await agent.value() == "Agent/1")
        #expect(probe.calls == 1)
    }

    @Test func aFailedProbeIsNotKeptSoTheNextCallProbesAgain() async {
        let probe = ScriptedProbe(answers: [nil, "Agent/2"])
        let agent = WebKitUserAgent(probe: { probe.next() })

        #expect(await agent.value() == nil)
        #expect(await agent.value() == "Agent/2")
        #expect(probe.calls == 2)
    }

    @Test func aRequestWithoutAUserAgentGetsTheWebKitOne() async {
        let agent = WebKitUserAgent(probe: { "Agent/1" })

        let sent = await agent.withUserAgent(URLRequest(url: url))

        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "Agent/1")
    }

    @Test func aPluginsOwnUserAgentIsKept() async {
        let agent = WebKitUserAgent(probe: { "Agent/1" })
        var request = URLRequest(url: url)
        request.setValue("Plugin/9", forHTTPHeaderField: "User-Agent")

        let sent = await agent.withUserAgent(request)

        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "Plugin/9")
    }

    @Test func aRequestIsUnchangedWhenWebKitReportsNoUserAgent() async {
        let agent = WebKitUserAgent(probe: { nil })

        let sent = await agent.withUserAgent(URLRequest(url: url))

        #expect(sent.value(forHTTPHeaderField: "User-Agent") == nil)
    }
}
