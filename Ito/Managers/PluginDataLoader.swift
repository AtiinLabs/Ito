import Foundation
import Nuke
import ito_runner

/// The optional image exports needed by the loader. The actor keeps WASM resolution serialized;
/// native HTTP work starts only after these calls return.
protocol PluginImageRunner: Sendable {
    func getImageRequest(_ locator: String, context: NetworkOperationContext) async throws -> PluginImageRequest?
    func getImageOrigins(context: NetworkOperationContext) async throws -> [String]?
    func handleImage(_ locator: String, context: NetworkOperationContext) async throws -> Data?
}

extension ItoRunner: PluginImageRunner {}

/// Intercepts requests that have custom schemes or special paths
/// and routes them through the PluginManager to the appropriate Wasm module.
public final class PluginDataLoader: DataLoading, @unchecked Sendable {
    private let defaultLoader: any DataLoading
    private let runnerProvider: @Sendable (String) async throws -> any PluginImageRunner
    private let networkContexts: PluginNetworkContexts
    private let runnerEvictor: (@Sendable (String, any PluginImageRunner) async -> Void)?
    private let imageTransport: PluginImageTransport

    /// Whether `url` is a remote HTTP(S) destination the network policy governs. A local or app scheme is not.
    private static func isRemote(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public convenience init(
        configuration: URLSessionConfiguration = .default,
        pluginManager: PluginManager
    ) {
        self.init(
            configuration: configuration,
            trust: pluginManager.pluginSettingsStore.trust,
            contexts: pluginManager.pluginSettingsStore.networkContexts,
            runnerProvider: { try await pluginManager.getImageRunner(for: $0) },
            runnerEvictor: { pluginId, runner in
                if let itoRunner = runner as? ItoRunner {
                    await pluginManager.evictImageRunner(for: pluginId, matching: itoRunner)
                }
            },
            userAgent: pluginManager.webKitUserAgent
        )
    }

    /// - Parameter defaultLoader: loads every request that is not `ito://`, and the direct requests a plugin
    ///   resolves to. Nil uses the policy-aware loader over `configuration`.
    init(
        configuration: URLSessionConfiguration,
        trust: PluginTrustStore? = nil,
        contexts: PluginNetworkContexts,
        defaultLoader: (any DataLoading)? = nil,
        runnerProvider: @escaping @Sendable (String) async throws -> any PluginImageRunner,
        runnerEvictor: (@Sendable (String, any PluginImageRunner) async -> Void)? = nil,
        userAgent: WebKitUserAgent
    ) {
        self.defaultLoader = defaultLoader ?? PolicyDataLoader(configuration: configuration, userAgent: userAgent)
        self.runnerProvider = runnerProvider
        self.runnerEvictor = runnerEvictor
        self.networkContexts = contexts
        self.imageTransport = PluginImageTransport(configuration: configuration, trust: trust, userAgent: userAgent)
    }

    public func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void, completion: @escaping @Sendable (Error?) -> Void) -> Cancellable {
        let mark = ImageRequestPurpose.marked(on: request)
        guard let url = request.url, url.scheme == "ito" else {
            // The reader's purpose mark stays on this side. A remote request is admitted under the purpose it was
            // marked with (an unmarked one is a cover image) before any byte is requested.
            let forwarded = ImageRequestSourceAuthority.unmarked(ImageRequestPurpose.unmarked(request))
            guard Self.isRemote(request.url) else {
                return defaultLoader.loadData(with: forwarded, didReceiveData: didReceiveData, completion: completion)
            }
            let authority = ImageRequestSourceAuthority.marked(on: request) ?? NetworkRequestAuthority.appOwned(
                contexts: networkContexts,
                purpose: mark?.networkPurpose ?? .coverImage
            )
            return admittedTransfer(forwarded, authority: authority, didReceiveData: didReceiveData, completion: completion)
        }

        let admission = ImageRequestSourceAuthority.marked(on: request) ?? startAuthority(for: url, mark: mark)
        let load = AdmittedImageLoad(authority: admission, completion: completion)
        let task = Task {
            var usedRunner: (any PluginImageRunner)?
            var targetPluginId: String?
            do {
                let locator = try PluginImageLocator.parse(url)
                let pluginId = locator.pluginID
                targetPluginId = pluginId
                guard admission.context.sourceID == pluginId else {
                    throw HostNetworkPolicyOutcome.sourceAuthorizationFailure
                }

                // Refused before the runner starts; the resolution and wire transfer keep the original scope.
                try admission.checkImageAdmission()

                let runner = try await runnerProvider(pluginId)
                usedRunner = runner
                try Task.checkCancellation()

                switch try await PluginImageResolution.resolve(locator, runner: runner, context: {
                    admission.context
                }) {
                case .fetch(let target, let headers, let allowedOrigins):
                    // Resolution and native transfer retain the same frozen authority.
                    let (data, response) = try await imageTransport.fetch(
                        url: target,
                        headers: headers,
                        allowedOrigins: allowedOrigins,
                        pluginID: pluginId,
                        authority: admission
                    )
                    try Task.checkCancellation()
                    load.deliver(data, response, to: didReceiveData)
                    load.complete(nil)
                case .bytes(let data):
                    let response = URLResponse(
                        url: url,
                        mimeType: ImageSignature.detect(data)?.mediaType,
                        expectedContentLength: data.count,
                        textEncodingName: nil
                    )
                    load.deliver(data, response, to: didReceiveData)
                    load.complete(nil)
                case .direct(let realUrl):
                    var realRequest = ImageRequestSourceAuthority.unmarked(ImageRequestPurpose.unmarked(request))
                    realRequest.url = realUrl
                    guard !Task.isCancelled else { throw CancellationError() }
                    guard Self.isRemote(realUrl) else { throw URLError(.unsupportedURL) }
                    // The direct transfer is its own admitted load; the outer load cancels it.
                    let sub = admittedTransfer(
                        realRequest,
                        authority: admission,
                        didReceiveData: { load.deliver($0, $1, to: didReceiveData) },
                        completion: { load.complete($0) }
                    )
                    load.attach(sub)
                }
            } catch is CancellationError {
                load.complete(URLError(.cancelled))
            } catch {
                if let runner = usedRunner,
                   let pluginId = targetPluginId,
                   let callError = error as? PluginCallError,
                   callError.kind == .crashed {
                    await runnerEvictor?(pluginId, runner)
                }
                load.complete(error)
            }
        }
        load.attach(task: task)

        return load
    }

    /// The authority a `ito://` load is first admitted under: its source, scope and purpose, under the live policy.
    private func startAuthority(for url: URL, mark: ImageRequestPurpose?) -> NetworkRequestAuthority {
        let pluginID = (try? PluginImageLocator.parse(url).pluginID) ?? NetworkRequestAuthority.appSourceID
        let operation = PluginNetworkOperation(purpose: mark?.networkPurpose ?? .coverImage, operationID: UUID())
        return NetworkRequestAuthority(contexts: networkContexts, context: networkContexts.context(pluginID: pluginID, operation))
    }

    /// One remote transfer through the default loader, owned by its own authority. A live policy change that
    /// stops admitting it cancels this transfer only; a redirect is re-checked when the loader supports it.
    private func admittedTransfer(
        _ request: URLRequest,
        authority: NetworkRequestAuthority,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> Cancellable {
        let load = AdmittedImageLoad(authority: authority, completion: completion)
        let refreshed = authority
        do {
            try refreshed.checkImageAdmission()
        } catch {
            Task { load.complete(error) }
            return load
        }
        let received: @Sendable (Data, URLResponse) -> Void = { data, response in
            load.deliver(data, response, to: didReceiveData)
        }
        let finished: @Sendable (Error?) -> Void = { load.complete($0) }
        let transfer: any Cancellable
        if let loader = defaultLoader as? any AuthorizedDataLoading {
            transfer = loader.loadData(with: request, authority: refreshed, didReceiveData: received, completion: finished)
        } else {
            transfer = defaultLoader.loadData(with: request, didReceiveData: received, completion: finished)
        }
        load.attach(transfer)
        return load
    }
}
