import Foundation
import Testing
@testable import Ito

/// A probe the test answers: each run waits until `release` and is counted.
@MainActor
final class HeldUserAgentProbe {
    private var continuations: [CheckedContinuation<String?, Never>] = []
    private let started = AsyncStream<Void>.makeStream()
    private(set) var calls = 0

    func run() async -> String? {
        calls += 1
        started.continuation.yield()
        return await withCheckedContinuation { continuations.append($0) }
    }

    /// Returns once a probe has started (one call per started probe).
    func waitUntilStarted() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release(_ value: String?) {
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume(returning: value) }
    }
}

/// A clock the test moves.
private final class UserAgentTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

@MainActor
struct WebKitUserAgentTests {
    private let url = URL(string: "https://comix.to/title/1")!

    @Test func theProbeRunsOnceAndItsAnswerIsKept() async throws {
        let probe = HeldUserAgentProbe()
        let agent = WebKitUserAgent(probe: { await probe.run() })

        let first = Task { try await agent.value() }
        await probe.waitUntilStarted()
        probe.release("Agent/1")

        #expect(try await first.value == "Agent/1")
        #expect(try await agent.value() == "Agent/1")
        #expect(probe.calls == 1)
    }

    @Test func concurrentCallersShareOneProbe() async throws {
        let probe = HeldUserAgentProbe()
        let agent = WebKitUserAgent(probe: { await probe.run() })

        let first = Task { try await agent.value() }
        await probe.waitUntilStarted()
        let second = Task { try await agent.value() }
        let third = Task { try await agent.value() }
        // Callers that reach the actor before the answer wait on the same probe; later ones find its answer.
        await agent.warm()
        probe.release("Agent/1")

        #expect(try await first.value == "Agent/1")
        #expect(try await second.value == "Agent/1")
        #expect(try await third.value == "Agent/1")
        #expect(probe.calls == 1)
    }

    @Test func aFailedProbeBacksOffInsteadOfProbingPerRequest() async throws {
        let probe = HeldUserAgentProbe()
        let clock = UserAgentTestClock()
        let agent = WebKitUserAgent(probe: { await probe.run() }, now: { clock.now })

        let failed = Task { try await agent.value() }
        await probe.waitUntilStarted()
        probe.release(nil)
        #expect(try await failed.value == nil)

        // Within the retry interval no web view is made: callers get nil at once, and warming does nothing.
        #expect(try await agent.value() == nil)
        await agent.warm()
        #expect(try await agent.value() == nil)
        #expect(probe.calls == 1)

        clock.advance(WebKitUserAgent.retryInterval + 1)
        let retried = Task { try await agent.value() }
        await probe.waitUntilStarted()
        probe.release("Agent/2")
        #expect(try await retried.value == "Agent/2")
        #expect(probe.calls == 2)
    }

    @Test func aCancelledCallerStopsWaitingWithoutEndingTheProbe() async throws {
        let probe = HeldUserAgentProbe()
        let agent = WebKitUserAgent(probe: { await probe.run() })

        let cancelled = Task { try await agent.value() }
        await probe.waitUntilStarted()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        let later = Task { try await agent.value() }
        await agent.warm()
        probe.release("Agent/1")
        #expect(try await later.value == "Agent/1")
        #expect(probe.calls == 1)
    }

    @Test func warmingStartsTheProbeBeforeAnyRequest() async throws {
        let probe = HeldUserAgentProbe()
        let agent = WebKitUserAgent(probe: { await probe.run() })

        await agent.warm()
        await probe.waitUntilStarted()
        probe.release("Agent/1")

        #expect(try await agent.value() == "Agent/1")
        #expect(probe.calls == 1)
    }

    @Test func aRequestWithoutAUserAgentGetsTheWebKitOne() async throws {
        let sent = try await WebKitUserAgent.testing("Agent/1").withUserAgent(URLRequest(url: url))

        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "Agent/1")
    }

    @Test func theWebKitUserAgentReplacesThePluginsInAnyCase() async throws {
        var request = URLRequest(url: url)
        request.setValue("Plugin/9", forHTTPHeaderField: "user-agent")

        let sent = try await WebKitUserAgent.testing("Agent/1").withUserAgent(request)

        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "Agent/1")
        #expect(sent.allHTTPHeaderFields?.keys.filter { $0.lowercased() == "user-agent" }.count == 1)
    }

    @Test func thePluginsUserAgentIsKeptWhenWebKitReportsNone() async throws {
        var request = URLRequest(url: url)
        request.setValue("Plugin/9", forHTTPHeaderField: "User-Agent")

        let sent = try await WebKitUserAgent.testing(nil).withUserAgent(request)

        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "Plugin/9")
    }

    @Test func theUnavailableErrorHasReadableText() {
        let description = WebKitUserAgentError.unavailable.localizedDescription
        #expect(!description.isEmpty)
        #expect(!description.contains("WebKitUserAgentError"))
    }
}
