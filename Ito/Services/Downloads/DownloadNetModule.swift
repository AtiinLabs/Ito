import Foundation
import ito_runner

/// Why a download attempt's transport refused to continue. The first denial an attempt records is its
/// outcome, whatever the plugin reports afterwards.
nonisolated enum DownloadHostDenial: Equatable, Sendable {
    case waiting(DownloadWaitingReason)
    case requiresInteractiveSource

    var outcome: DownloadAttemptOutcome {
        switch self {
        case .waiting(let reason):
            return .waiting(reason)
        case .requiresInteractiveSource:
            return .failed(.requiresInteractiveSource)
        }
    }
}

/// Whether the network path admits bulk downloads right now.
nonisolated protocol DownloadAdmissionGate: Sendable {
    func admission() -> BulkDownloadAdmission
}

/// Admission read from the live network path through `BulkDownloadPolicy`.
nonisolated struct NetworkPathAdmissionGate: DownloadAdmissionGate {
    let observer: any NetworkPathObserving

    func admission() -> BulkDownloadAdmission {
        BulkDownloadPolicy.admit(observer.current)
    }
}

/// What a refused transport call throws. The plugin only sees a host error; the recorder holds the reason.
nonisolated struct DownloadTransportDenied: Error, Sendable {}

/// Lock-protected, first-write-wins record of the denial that ended one attempt's transport. A denial
/// also runs its handler once, which cancels the attempt in flight.
nonisolated final class DownloadPolicyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var denial: DownloadHostDenial?
    private var handler: (@Sendable () -> Void)?

    var firstDenial: DownloadHostDenial? {
        lock.withLock { denial }
    }

    /// Records the denial when none was recorded yet. Later denials are ignored.
    func record(_ newDenial: DownloadHostDenial) {
        let handlerToRun: (@Sendable () -> Void)? = lock.withLock {
            guard denial == nil else { return nil }
            denial = newDenial
            return handler
        }
        handlerToRun?()
    }

    /// Runs `action` once a denial is recorded, or now when one already was.
    func onFirstDenial(_ action: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if denial != nil { return true }
            handler = action
            return false
        }
        if runNow { action() }
    }
}

/// Transport for one download attempt. It refuses every request once the path stops admitting bulk
/// downloads, and it refuses every later request after the first denial, so a plugin that swallows the
/// error cannot keep fetching. The system's own refusal of a metered or Low Data Mode path is read from
/// the URL error and recorded the same way.
nonisolated final class DownloadNetModule: NetModule, Sendable {
    private let inner: any NetModule
    private let gate: any DownloadAdmissionGate
    private let recorder: DownloadPolicyRecorder

    init(inner: any NetModule, gate: any DownloadAdmissionGate, recorder: DownloadPolicyRecorder) {
        self.inner = inner
        self.gate = gate
        self.recorder = recorder
    }

    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        guard recorder.firstDenial == nil else { throw DownloadTransportDenied() }
        if case .wait(let reason) = gate.admission() {
            recorder.record(.waiting(reason))
            throw DownloadTransportDenied()
        }
        do {
            return try await inner.fetch(request: request, context: context)
        } catch let error as URLError {
            guard let denial = Self.denial(for: error) else { throw error }
            recorder.record(denial)
            throw DownloadTransportDenied()
        }
    }

    /// The denial the system reports for a path that bulk downloads wait out. Other URL errors keep
    /// their own meaning.
    static func denial(for error: URLError) -> DownloadHostDenial? {
        switch error.networkUnavailableReason {
        case .expensive?:
            return .waiting(.meteredNetwork)
        case .constrained?:
            return .waiting(.lowDataMode)
        default:
            return nil
        }
    }
}

/// Answers every Cloudflare challenge with a refusal. Downloads never solve challenges, so they can
/// never cancel or present one for the reader. A clearance the reader already earned stays usable: the
/// cached User-Agent for a host comes from `userAgent`, which only reads.
nonisolated struct RefusingCloudflareHandler: AppNetCloudflareHandling {
    let recorder: DownloadPolicyRecorder
    /// The cached User-Agent for a host. An empty string means none.
    let userAgent: @Sendable (String) async -> String

    nonisolated func cachedUserAgent(for host: String) async -> String {
        await userAgent(host)
    }

    nonisolated func resolveChallenge(for url: URL) async throws -> AppNetCloudflareResolution {
        recorder.record(.requiresInteractiveSource)
        throw DownloadTransportDenied()
    }
}

/// Refuses every web view request a plugin makes during a download. Downloads never load pages.
nonisolated struct DownloadWebviewModule: WebviewModule {
    let recorder: DownloadPolicyRecorder

    func loadUrl(request: WebviewRequest, context: NetworkOperationContext) async throws -> WebviewResponse {
        recorder.record(.requiresInteractiveSource)
        throw ItoError.hostModuleError(domain: "webview", message: "Downloads do not use a web view.")
    }

    func executeJs(script: String, context: NetworkOperationContext) async throws -> String {
        recorder.record(.requiresInteractiveSource)
        throw ItoError.hostModuleError(domain: "webview", message: "Downloads do not use a web view.")
    }
}

extension PluginRunnerHostModules {
    /// The modules of one download attempt: the bulk transport with Cloudflare refused, and a web view
    /// that refuses. Both report to the attempt's recorder.
    @MainActor
    static func download(
        pluginID: String,
        cookieJar: PluginCookieJar,
        trust: PluginTrustStore,
        gate: any DownloadAdmissionGate,
        recorder: DownloadPolicyRecorder,
        cloudflareUserAgent: @escaping @Sendable (String) async -> String
    ) -> PluginRunnerHostModules {
        let transport = AppNetModule(
            configuration: .bulkDownload,
            cloudflare: RefusingCloudflareHandler(recorder: recorder, userAgent: cloudflareUserAgent),
            retryLogger: OSLogAppNetRetryLogger(),
            pluginID: pluginID,
            cookieJar: cookieJar,
            trust: trust
        )
        return PluginRunnerHostModules(
            net: DownloadNetModule(inner: transport, gate: gate, recorder: recorder),
            webview: DownloadWebviewModule(recorder: recorder)
        )
    }
}
