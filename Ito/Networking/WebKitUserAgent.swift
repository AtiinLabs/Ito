import Foundation
import WebKit

/// The host could not read the WebKit user agent, which a site verification needs to bind its clearance to.
enum WebKitUserAgentError: LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(
                localized: "Ito couldn't read the browser identity that site verification needs. Try again in a moment.",
                comment: "Error: the app could not read WebKit's user agent, so a site's verification cannot finish. Shown where the source's screen reports a failed load."
            )
        }
    }
}

extension WKWebpagePreferences {
    /// The page settings of every web view the host shows or probes. They are pinned to the phone layout: left to
    /// the system, a full-size iPad page asks for the desktop layout and reports a different user agent.
    @MainActor
    static func hostWebView() -> WKWebpagePreferences {
        let preferences = WKWebpagePreferences()
        preferences.preferredContentMode = .mobile
        return preferences
    }
}

/// The WebKit user agent: the one a web view sends by default, and so the one a Cloudflare clearance is bound to.
/// Plugin HTTP, image and download transfers that carry a clearance send this same value.
///
/// The value is read from a web view's `navigator.userAgent` on the main actor and kept in memory. A caller waits
/// for it cancellably. A probe that fails, or runs past `probeDeadline`, is not repeated for `retryInterval`, so a
/// broken WebKit never creates a web view per request. The host has one instance, owned by `PluginManager`, and
/// every consumer is handed that instance.
actor WebKitUserAgent {
    static let probeDeadline: TimeInterval = 10
    static let retryInterval: TimeInterval = 30

    private let probe: @Sendable @MainActor () async -> String?
    private let now: @Sendable () -> Date
    private var known: String?
    /// The probe in flight. A generation tells a late answer apart from the probe that is current now.
    private var probing: Int?
    private var generation = 0
    private var deadline: Task<Void, Never>?
    private var retryAfter: Date?
    private var waiters: [UUID: CheckedContinuation<String?, Error>] = [:]

    init(
        probe: @escaping @Sendable @MainActor () async -> String? = WebKitUserAgent.probeWebKit,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.probe = probe
        self.now = now
    }

    /// The WebKit user agent, or nil when none can be read now. Waits for a probe in flight; throws
    /// `CancellationError` if the caller is cancelled while it waits.
    func value() async throws -> String? {
        if let known { return known }
        if probing == nil, isBackingOff { return nil }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = continuation
                if probing == nil { startProbe() }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Starts the probe without waiting for it, so the first request finds the value ready. A no-op once the value
    /// is known, while a probe is in flight, and during the retry interval after a failure.
    func warm() {
        guard known == nil, probing == nil, !isBackingOff else { return }
        startProbe()
    }

    /// `request` with the WebKit user agent, replacing any the plugin set (header names are case-insensitive here),
    /// as plugin HTTP does: a clearance only matches its own user agent. Without a value the request is unchanged,
    /// so a plugin's own header is kept.
    func withUserAgent(_ request: URLRequest) async throws -> URLRequest {
        guard let agent = try await value() else { return request }
        var sent = request
        sent.setValue(agent, forHTTPHeaderField: "User-Agent")
        return sent
    }

    private var isBackingOff: Bool {
        retryAfter.map { now() < $0 } ?? false
    }

    private func startProbe() {
        generation += 1
        let token = generation
        probing = token
        let probe = self.probe
        Task { @MainActor in
            let answer = await probe()
            await self.finishProbe(token, answer)
        }
        deadline = Task {
            guard (try? await Task.sleep(nanoseconds: UInt64(Self.probeDeadline * 1_000_000_000))) != nil else { return }
            self.finishProbe(token, nil)
        }
    }

    private func finishProbe(_ token: Int, _ answer: String?) {
        guard probing == token else { return }
        probing = nil
        deadline?.cancel()
        deadline = nil
        if let answer, !answer.isEmpty {
            known = answer
            retryAfter = nil
        } else {
            retryAfter = now().addingTimeInterval(Self.retryInterval)
        }
        let settled = Array(waiters.values)
        waiters.removeAll()
        for waiter in settled {
            waiter.resume(returning: known)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Reads `navigator.userAgent` from a web view configured as the host's web views are, so it reports the value
    /// they send.
    @MainActor
    static func probeWebKit() async -> String? {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences = .hostWebView()
        let page = WKWebView(frame: .zero, configuration: configuration)
        let result = try? await page.evaluateJavaScript("navigator.userAgent")
        withExtendedLifetime(page) {}
        return result as? String
    }
}
