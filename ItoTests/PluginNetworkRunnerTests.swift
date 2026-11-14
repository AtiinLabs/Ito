import Foundation
import ito_runner
import Testing
@testable import Ito

/// Records the host context of every net fetch and web view load the guest makes, and answers each with a fixed success.
private final class HostCallRecorder: NetModule, WebviewModule, @unchecked Sendable {
    private let lock = NSLock()
    private var fetched: [NetworkOperationContext] = []
    private var loaded: [NetworkOperationContext] = []

    var fetchedContexts: [NetworkOperationContext] { lock.withLock { fetched } }
    var loadedContexts: [NetworkOperationContext] { lock.withLock { loaded } }

    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        lock.withLock { fetched.append(context) }
        return NetResponse(status: 200, headers: [:], body: [])
    }

    func loadUrl(request: WebviewRequest, context: NetworkOperationContext) async throws -> WebviewResponse {
        lock.withLock { loaded.append(context) }
        return WebviewResponse(url: request.url, html: "")
    }

    func executeJs(script: String, context: NetworkOperationContext) async throws -> String {
        ""
    }
}

/// Refuses every transfer with the same host policy outcome, and counts the calls that reach it.
private final class RefusingNet: NetModule, @unchecked Sendable {
    let calls = DownloadCallCounter()

    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        calls.increment()
        throw ItoError.networkPolicy(.deferred(.expensivePath))
    }
}

/// Parks each fetch until the test resolves it, so a test can act while the guest's export is in flight.
/// Cancelling the fetch's task resolves it with `CancellationError` and records that the cancel reached it.
private final class SuspendedFetchNet: NetModule, @unchecked Sendable {
    let calls = DownloadCallCounter()
    /// Yields once for each fetch that has started.
    let entries: AsyncStream<Void>
    private let entrySignal: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var parked: CheckedContinuation<NetResponse, any Error>?
    /// How the fetch ends. Set before or after the fetch parks, so a resolution is never lost.
    private var resolution: Result<NetResponse, any Error>?
    private var cancelReached = false

    init() {
        var signal: AsyncStream<Void>.Continuation?
        entries = AsyncStream { signal = $0 }
        entrySignal = signal!
    }

    var cancelHookRan: Bool { lock.withLock { cancelReached } }

    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        calls.increment()
        entrySignal.yield()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let resolution {
                    lock.unlock()
                    continuation.resume(with: resolution)
                    return
                }
                parked = continuation
                lock.unlock()
            }
        } onCancel: {
            self.resolve(with: .failure(CancellationError()), cancelled: true)
        }
    }

    /// Ends the parked fetch with a successful, empty response.
    func release() {
        resolve(with: .success(NetResponse(status: 200, headers: [:], body: [])), cancelled: false)
    }

    private func resolve(with outcome: Result<NetResponse, any Error>, cancelled: Bool) {
        lock.lock()
        if cancelled { cancelReached = true }
        resolution = outcome
        let continuation = parked
        parked = nil
        lock.unlock()
        continuation?.resume(with: outcome)
    }
}

/// Exports from a real runner with a real module at the host's ABI, so the host context crosses the guest boundary.
struct PluginNetworkRunnerTests {
    private static let request = NetRequest(url: "https://api.example/ack", method: "GET", headers: [:], body: nil)

    /// A runner that loads a module built from `fixture` at the host's ABI, with `net` and `webview` as its host modules.
    private static func runner(
        _ fixture: TestWasm.Fixture,
        net: any NetModule,
        webview: any WebviewModule
    ) async throws -> ItoRunner {
        let runner = ItoRunner()
        await runner.setNetModule(net)
        await runner.setWebviewModule(webview)
        try await runner.loadPlugin(fromBytes: TestWasm.build(fixture))
        return runner
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aCompletionsFetchReceivesTheExactContextTheHostBuiltForIt() async throws {
        let recorder = HostCallRecorder()
        let runner = try await Self.runner(try TestWasm.sending(Self.request), net: recorder, webview: recorder)
        let context = makeTestNetworkContext(purpose: .trackerWrite, pluginID: "plugin.tracker")

        let delivered = try await runner.markCompleted(kind: .manga, mediaKey: "media", unitKey: "unit", context: context)

        #expect(delivered)
        #expect(recorder.fetchedContexts == [context])
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aWebViewLoadReceivesTheExactContextTheHostBuiltForIt() async throws {
        let recorder = HostCallRecorder()
        let page = WebviewRequest(url: "https://source.example/login", script: nil)
        let runner = try await Self.runner(try TestWasm.openingWebView(page), net: recorder, webview: recorder)
        let context = makeTestNetworkContext(purpose: .trackerWrite, pluginID: "plugin.tracker")

        let delivered = try await runner.markCompleted(kind: .manga, mediaKey: "media", unitKey: "unit", context: context)

        #expect(delivered)
        #expect(recorder.loadedContexts == [context])
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func twoExportsOfOneOperationShareItsIDAndTheirOwnGenerations() async throws {
        let recorder = HostCallRecorder()
        let runner = try await Self.runner(try TestWasm.sending(Self.request), net: recorder, webview: recorder)
        let contexts = PluginNetworkContexts(policy: NetworkPolicyCenter())
        let operation = PluginNetworkOperation(purpose: .trackerWrite, operationID: UUID())

        _ = try await runner.markCompleted(
            kind: .manga, mediaKey: "media", unitKey: "one",
            context: contexts.context(pluginID: "plugin.tracker", operation)
        )
        _ = try await runner.markCompleted(
            kind: .manga, mediaKey: "media", unitKey: "two",
            context: contexts.context(pluginID: "plugin.tracker", operation)
        )

        let fetched = recorder.fetchedContexts
        #expect(fetched.count == 2)
        #expect(fetched.allSatisfy { $0.operationID == operation.operationID })
        #expect(fetched[0].generation != fetched[1].generation)
    }

    /// A refused transfer decides the export even though the guest acknowledges, so a delivery is retried, not acknowledged.
    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aRefusedTransferEndsTheExportWithThePolicyOutcomeAndCompletionRetriesIt() async throws {
        let net = RefusingNet()
        let runner = try await Self.runner(try TestWasm.sending(Self.request), net: net, webview: HostCallRecorder())
        let context = makeTestNetworkContext(purpose: .trackerWrite, pluginID: "plugin.tracker")
        let refusal = ItoError.networkPolicy(.deferred(.expensivePath))

        await #expect(throws: refusal) {
            try await runner.markCompleted(kind: .manga, mediaKey: "media", unitKey: "unit", context: context)
        }
        #expect(net.calls.count == 1)

        guard case .retryable(let category) = PluginCompletionExecutor.outcome(forFailure: refusal) else {
            Issue.record("A path deferral must retry the delivery")
            return
        }
        #expect(category.rawValue == "network")
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func cancellingAnExportStopsItsParkedFetchAndALaterExportNeverReachesTheModule() async throws {
        let net = SuspendedFetchNet()
        let runner = try await Self.runner(try TestWasm.sending(Self.request), net: net, webview: HostCallRecorder())
        let context = makeTestNetworkContext(purpose: .trackerWrite, pluginID: "plugin.tracker")

        let first = Task {
            try await runner.markCompleted(kind: .manga, mediaKey: "media", unitKey: "one", context: context)
        }
        var entries = net.entries.makeAsyncIterator()
        _ = await entries.next()
        let second = Task {
            try await runner.markCompleted(kind: .manga, mediaKey: "media", unitKey: "two", context: context)
        }
        second.cancel()
        first.cancel()

        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(net.cancelHookRan)
        #expect(net.calls.count == 1)
    }

    @MainActor
    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aPublicationDuringAnExportEvictsTheRunnerButTheExportFinishesOnItsOwn() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let suspended = SuspendedFetchNet()
        let plugin = try Self.installedPlugin()
        let loads = DownloadCallCounter()
        let manager = PluginManager(
            pluginSettingsStore: PluginSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter()),
            pluginsDirectory: database.databaseURL.deletingLastPathComponent(),
            runnerLoader: { _, _, _ in
                loads.increment()
                let net: any NetModule = loads.count == 1 ? suspended : HostCallRecorder()
                return try await Self.runner(try TestWasm.sending(Self.request), net: net, webview: HostCallRecorder())
            },
            downloadRunnerLoader: { _, _, _, _, _, _ in ItoRunner() }
        )
        manager.publishPreparedInstalledPlugins([plugin.id: plugin])

        let first = try await manager.getRunner(for: plugin.id)
        let export = Task {
            try await first.markCompleted(
                kind: .manga, mediaKey: "media", unitKey: "unit",
                context: makeTestNetworkContext(purpose: .trackerWrite, pluginID: plugin.id)
            )
        }
        var entries = suspended.entries.makeAsyncIterator()
        _ = await entries.next()
        // Releasing is idempotent; this keeps a failing expectation below from leaving the export parked.
        defer { suspended.release() }

        manager.publishPreparedInstalledPlugins([plugin.id: plugin])
        let replacement = try await manager.getRunner(for: plugin.id)
        #expect(replacement !== first)

        suspended.release()
        #expect(try await export.value)
        #expect(loads.count == 2)
    }

    private static func installedPlugin() throws -> InstalledPlugin {
        let fixture = try TestWasm.sending(request)
        return InstalledPlugin(
            url: URL(fileURLWithPath: "/test/publication-during-export.ito"),
            info: PluginInfo(
                id: "plugin.publication",
                name: "Publication",
                version: "1.0",
                minAppVersion: "1.0",
                type: .manga,
                abi: ItoRunner.supportedABIVersions.upperBound
            ),
            iconData: nil,
            binary: try ItoRunner.inspectBinary(TestWasm.build(fixture))
        )
    }
}
