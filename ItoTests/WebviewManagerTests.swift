import Foundation
import Network
import Testing
import ito_runner
@testable import Ito

/// A local HTTP server that accepts connections and never answers, reporting each connection.
private final class SilentServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "WebviewManagerTests.SilentServer")
    private var connections: [NWConnection] = []
    private let connected = AsyncStream<Void>.makeStream()
    private let ready = AsyncStream<UInt16>.makeStream()

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connections.append(connection)
            connection.start(queue: queue)
            connected.continuation.yield()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state, let port = listener.port?.rawValue else { return }
            ready.continuation.yield(port)
        }
        listener.start(queue: queue)
    }

    func url() async -> String {
        var iterator = ready.stream.makeAsyncIterator()
        let port = await iterator.next() ?? 0
        return "http://localhost:\(port)/"
    }

    func connectionArrived() async {
        var iterator = connected.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    deinit {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }
}

@MainActor
@Suite("Web view page loads")
struct WebviewManagerTests {
    @Test func aPageThatNeverAnswersTimesOut() async throws {
        let server = try SilentServer()
        let manager = WebviewManager(pageLoadDeadline: 0.3)

        await #expect(throws: URLError(.timedOut)) {
            try await manager.loadUrl(request: WebviewRequest(url: await server.url(), script: nil))
        }
    }

    @Test func cancellingTheCallerEndsTheLoad() async throws {
        let server = try SilentServer()
        let manager = WebviewManager()
        let url = await server.url()

        let load = Task { try await manager.loadUrl(request: WebviewRequest(url: url, script: nil)) }
        await server.connectionArrived()
        load.cancel()

        await #expect(throws: CancellationError.self) { try await load.value }
    }

    @Test func aNewerLoadReplacesThePendingOne() async throws {
        let server = try SilentServer()
        let replacementServer = try SilentServer()
        let manager = WebviewManager()
        let url = await server.url()
        let replacementURL = await replacementServer.url()

        let first = Task { try await manager.loadUrl(request: WebviewRequest(url: url, script: nil)) }
        await server.connectionArrived()
        let second = Task { try await manager.loadUrl(request: WebviewRequest(url: replacementURL, script: nil)) }
        await #expect(throws: URLError(.cancelled)) { try await first.value }

        // Distinct endpoints require a new navigation request, not a second connection for
        // the same URL (which WebKit may reuse). Late old-navigation callbacks must not end it.
        let cancellation = Task {
            await replacementServer.connectionArrived()
            second.cancel()
        }
        await #expect(throws: CancellationError.self) { try await second.value }
        cancellation.cancel()
        await cancellation.value
    }
}
