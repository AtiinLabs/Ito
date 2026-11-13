import Foundation
import ito_runner

/// The attempt outcome a host policy outcome ends a download with. Total: every outcome maps to one.
nonisolated extension DownloadAttemptOutcome {
    init(policy: HostNetworkPolicyOutcome) {
        switch policy {
        case .deferred(.unknownPath):
            self = .waiting(.networkUnknown)
        case .deferred(.offline):
            self = .waiting(.noConnection)
        case .deferred(.expensivePath):
            self = .waiting(.meteredNetwork)
        case .deferred(.constrainedPath):
            self = .waiting(.lowDataMode)
        case .foregroundPermissionRequired:
            self = .failed(.requiresInteractiveSource)
        case .deferred(.policyChanged):
            self = .queued
        case .sourceAuthorizationFailure:
            self = .waiting(.sourceConfigurationChanged)
        case .hardUserBlocked:
            self = .failed(.sourceError)
        }
    }
}

/// Whether the policy admits this attempt's bulk transfers right now.
nonisolated protocol DownloadAdmissionGate: Sendable {
    func admission() -> NetworkDecision
    var authorityIsCurrent: Bool { get }
    /// Whether an expensive, unconstrained path would be admitted now. The attempt's transport allows the system to
    /// use such a path only then.
    var allowsExpensiveTransport: Bool { get }
    /// Whether `context` was stamped under the policy revision in force now.
    func isCurrent(_ context: NetworkOperationContext) -> Bool
}

/// Admission decided by `NetworkPolicy` from the live configuration, the observed path and, for an exact batch,
/// its scoped consent.
nonisolated struct NetworkPathAdmissionGate: DownloadAdmissionGate {
    let observer: any NetworkPathObserving
    var policy: NetworkPolicyCenter = NetworkPolicyCenter()
    var intent: NetworkIntent = .manualBulkDownload
    var consent: NetworkConsentBinding?
    var operation: PluginNetworkOperation?
    var authorizationScope: UUID?

    private var hasRequestConsent: Bool {
        guard let consent, let operation, let authorizationScope else { return false }
        guard operation.purpose == .manualBulkDownload || operation.purpose == .automaticBulkDownload else { return false }
        return policy.hasValidConsent(
            consent, reference: operation.scopedGrant, operationID: operation.operationID,
            authorizationScope: authorizationScope
        )
    }

    var authorityIsCurrent: Bool {
        guard let operation else { return true }
        guard operation.policyRevision == nil || operation.policyRevision == policy.revision else { return false }
        if let consent, authorizationScope != consent.liveAuthorizationScope() { return false }
        return operation.scopedGrant == nil || hasRequestConsent
    }

    func admission() -> NetworkDecision {
        NetworkPolicy.evaluate(intent, path: observer.current, configuration: policy.current, hasBatchConsent: hasRequestConsent)
    }

    var allowsExpensiveTransport: Bool {
        NetworkPolicy.evaluate(
            intent, path: NetworkPathSnapshot(status: .satisfied, isExpensive: true),
            configuration: policy.current, hasBatchConsent: hasRequestConsent
        ) == .allow
    }

    func isCurrent(_ context: NetworkOperationContext) -> Bool {
        guard context.policyRevision == policy.revision else { return false }
        if let authorizationScope, context.authorizationScope != authorizationScope { return false }
        if let consent {
            guard context.batchID == consent.batchID, context.sourceID == consent.sourceID,
                  context.authorizationScope == consent.liveAuthorizationScope() else { return false }
        }
        if let operation {
            guard context.operationID == operation.operationID, context.purpose == operation.purpose,
                  context.scopedGrant == operation.scopedGrant else { return false }
        }
        if context.scopedGrant != nil {
            guard context.purpose == .manualBulkDownload || context.purpose == .automaticBulkDownload else { return false }
            guard let consent, policy.hasValidConsent(
                consent, reference: context.scopedGrant, operationID: context.operationID,
                authorizationScope: context.authorizationScope
            ) else { return false }
        }
        return true
    }
}

/// Lock-protected, first-write-wins record of the host policy outcome that ended one attempt's transport.
/// A denial also runs its handler once, which cancels the attempt in flight.
nonisolated final class DownloadPolicyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var denial: HostNetworkPolicyOutcome?
    private var handler: (@Sendable () -> Void)?

    var firstDenial: HostNetworkPolicyOutcome? {
        lock.withLock { denial }
    }

    /// The one way a download module refuses a call: records `outcome`, then throws what the recorder holds.
    /// That is the first outcome recorded, so the runner never sees an outcome the recorder lacks.
    func deny(_ outcome: HostNetworkPolicyOutcome) throws -> Never {
        throw record(outcome)
    }

    /// Stores `newOutcome` when no outcome was recorded yet, then runs the handler once. Returns the recorded
    /// outcome. The store happens under the lock before the handler runs, so a handler always sees it.
    @discardableResult
    func record(_ newOutcome: HostNetworkPolicyOutcome) -> HostNetworkPolicyOutcome {
        let (recorded, handlerToRun): (HostNetworkPolicyOutcome, (@Sendable () -> Void)?) = lock.withLock {
            if let denial { return (denial, nil) }
            denial = newOutcome
            return (newOutcome, handler)
        }
        handlerToRun?()
        return recorded
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
        if let denial = recorder.firstDenial { throw denial }
        // A context stamped under an earlier policy revision never decides for the current one: the attempt
        // is queued again and rebuilds its contexts under the revision in force.
        if !gate.isCurrent(context) {
            try recorder.deny(.deferred(.policyChanged))
        }
        if case .wait(let wait) = gate.admission() {
            try recorder.deny(wait.policyOutcome)
        }
        do {
            return try await inner.fetch(request: request, context: context)
        } catch let error as URLError {
            guard let outcome = Self.denial(for: error) else { throw error }
            try recorder.deny(outcome)
        }
    }

    /// The outcome the system reports for a path that bulk downloads wait out. Other URL errors keep
    /// their own meaning.
    static func denial(for error: URLError) -> HostNetworkPolicyOutcome? {
        switch error.networkUnavailableReason {
        case .expensive?:
            return .deferred(.expensivePath)
        case .constrained?:
            return .deferred(.constrainedPath)
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
        try recorder.deny(.foregroundPermissionRequired)
    }
}

/// Refuses every web view request a plugin makes during a download. Downloads never load pages.
nonisolated struct DownloadWebviewModule: WebviewModule {
    let recorder: DownloadPolicyRecorder

    func loadUrl(request: WebviewRequest, context: NetworkOperationContext) async throws -> WebviewResponse {
        try recorder.deny(.foregroundPermissionRequired)
    }

    func executeJs(script: String, context: NetworkOperationContext) async throws -> String {
        try recorder.deny(.foregroundPermissionRequired)
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
            configuration: .bulkDownload(allowingExpensiveAccess: gate.allowsExpensiveTransport),
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
