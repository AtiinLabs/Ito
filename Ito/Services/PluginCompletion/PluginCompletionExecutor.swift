import Foundation
import ito_runner

/// Delivers one completion intent to its source and reports how it ended. The dispatcher calls
/// `beginAttempt` before this and `finish` after it; an executor never touches the queue itself.
///
/// An executor returns `.cancelled` only when its own task was cancelled. Anything else that
/// stops delivery is a real outcome, so a stuck attempt cannot loop without backoff.
nonisolated protocol PluginCompletionExecuting: Sendable {
    func execute(intent: PluginCompletionIntent) async -> PluginCompletionOutcome
}

/// Why an attempt could not reach the plugin at all. Fixed cases only: no remote text, URL or
/// credential is ever carried.
nonisolated enum PluginCompletionExecutionFailure: Error, Equatable, Sendable {
    /// The source is not installed, or its file cannot be located.
    case sourceUnavailable
    /// The server or account the intent was recorded under no longer matches current settings.
    case configurationChanged
    /// The attempt's settings or credentials could not be captured, so the account is unverified.
    case unverifiableConfiguration
}

/// The production executor. Every attempt gets its own runner: a fresh WASM instance with an
/// ephemeral network session, the settings captured with the intent as in-memory defaults, and
/// host modules that cannot touch live settings, cookies, logs or UI. Nothing is cached, and
/// nothing of a runner or its session outlives the attempt.
nonisolated final class PluginCompletionExecutor: PluginCompletionExecuting, Sendable {
    private let store: PluginCompletionStore
    private let locatePlugin: @MainActor @Sendable (String) throws -> URL
    private let makeNetModule: @Sendable (_ pluginID: String) -> PluginCompletionNetModule

    /// `locatePlugin` returns the installed file of a source that can run in this app, and throws
    /// when it is not installed or needs a newer app. `cookies` holds the sources' website
    /// cookies, sent read-only.
    convenience init(
        store: PluginCompletionStore,
        cookies: PluginCookieJar,
        trust: PluginTrustStore,
        locatePlugin: @escaping @MainActor @Sendable (String) throws -> URL
    ) {
        self.init(store: store, locatePlugin: locatePlugin, makeNetModule: { pluginID in
            PluginCompletionNetModule(
                cookies: { url in cookies.cookies(pluginID: pluginID, for: url) },
                trust: (pluginID, trust)
            )
        })
    }

    init(
        store: PluginCompletionStore,
        locatePlugin: @escaping @MainActor @Sendable (String) throws -> URL,
        makeNetModule: @escaping @Sendable (_ pluginID: String) -> PluginCompletionNetModule
    ) {
        self.store = store
        self.locatePlugin = locatePlugin
        self.makeNetModule = makeNetModule
    }

    func execute(intent: PluginCompletionIntent) async -> PluginCompletionOutcome {
        do {
            let delivered = try await deliver(intent)
            return delivered ? .acknowledged : .unsupported
        } catch {
            return Self.outcome(forFailure: error)
        }
    }

    private func deliver(_ intent: PluginCompletionIntent) async throws -> Bool {
        try Task.checkCancellation()
        let pluginURL = try await locate(intent.pluginId)
        try Task.checkCancellation()
        let snapshot = try await captureSnapshot(for: intent)
        try Task.checkCancellation()
        return try await run(snapshot, from: pluginURL)
    }

    private func locate(_ pluginID: String) async throws -> URL {
        do {
            return try await locatePlugin(pluginID)
        } catch let refusal as PluginRequiresNewerAppError {
            throw refusal
        } catch {
            throw PluginCompletionExecutionFailure.sourceUnavailable
        }
    }

    /// Captures the attempt's settings and secrets under the secret lock, off the main actor. The
    /// capture is finite and blocking, so cancellation is observed again once it returns.
    private func captureSnapshot(for intent: PluginCompletionIntent) async throws -> PluginCompletionSnapshot {
        let store = store
        let capture = Task.detached(priority: .utility) { try store.snapshot(for: intent) }
        do {
            return try await withTaskCancellationHandler {
                try await capture.value
            } onCancel: {
                capture.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch PluginCompletionScopeError.configurationChanged {
            throw PluginCompletionExecutionFailure.configurationChanged
        } catch {
            throw PluginCompletionExecutionFailure.unverifiableConfiguration
        }
    }

    private func run(_ snapshot: PluginCompletionSnapshot, from pluginURL: URL) async throws -> Bool {
        let intent = snapshot.intent
        let defaults = PluginCompletionDefaults(settings: snapshot.settings)
        let network = makeNetModule(intent.pluginId)
        defer { network.invalidate() }

        var runner = try await load(pluginURL, defaults: defaults, network: network)
        let schemaRead = try await readSchemaDefaults(from: runner, into: defaults)
        if !schemaRead {
            // The plugin crashed describing its settings, so that instance may be broken. Deliver
            // with a fresh one, as the app's own runner does, without the schema defaults.
            runner = try await load(pluginURL, defaults: defaults, network: network)
        }
        try Task.checkCancellation()

        switch intent.kind {
        case .manga, .novel:
            return try await runner.markChapterRead(mediaKey: intent.mediaKey, chapterKey: intent.unitKey)
        case .anime:
            return try await runner.markEpisodeWatched(mediaKey: intent.mediaKey, episodeKey: intent.unitKey)
        }
    }

    private func load(
        _ pluginURL: URL,
        defaults: PluginCompletionDefaults,
        network: PluginCompletionNetModule
    ) async throws -> ItoRunner {
        let runner = ItoRunner()
        await runner.setNetModule(network)
        await runner.setStdModule(PluginCompletionStdModule())
        await runner.setDefaultsModule(defaults)
        await runner.setHtmlModule(DefaultHtmlModule())
        await runner.setWebviewModule(PluginCompletionWebviewModule())
        _ = try await runner.loadBundle(from: pluginURL)
        return runner
    }

    /// Adds the schema's defaults to the sandbox so an unset key reads as the reader shows it.
    /// False when the plugin crashed describing its settings. Any other failure only leaves the
    /// plugin without defaults.
    private func readSchemaDefaults(from runner: ItoRunner, into defaults: PluginCompletionDefaults) async throws -> Bool {
        do {
            if let schema = try await runner.getSettings() {
                let stored = await MainActor.run { schema.storedDefaults }
                defaults.useSchemaDefaults(stored)
            }
            return true
        } catch let error as ItoError {
            return !Self.isCrash(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return true
        }
    }

    private static func isCrash(_ error: ItoError) -> Bool {
        switch error {
        case .wasmTrap, .memoryOutOfBounds:
            return true
        default:
            return false
        }
    }

    /// How a failed attempt is recorded. Only network and server failures retry on their own;
    /// everything the user or the source must fix pauses, and cancellation leaves the intent as
    /// it was.
    static func outcome(forFailure error: any Error) -> PluginCompletionOutcome {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        switch error {
        case let error as ItoError:
            return outcome(for: error)
        case let failure as PluginCompletionExecutionFailure:
            switch failure {
            case .sourceUnavailable: return .paused(.sourceUnavailable, .sourceUnavailable)
            case .configurationChanged: return .paused(.configurationChanged, .configurationChanged)
            case .unverifiableConfiguration: return .paused(.unknownOrigin, .unknownOrigin)
            }
        case is PluginRequiresNewerAppError:
            return .paused(.incompatible, .incompatible)
        default:
            return .paused(.sourceError, .sourceError)
        }
    }

    private static func outcome(for error: ItoError) -> PluginCompletionOutcome {
        switch error {
        case .pluginFailed(_, _, let category):
            switch category {
            case .unsupported: return .unsupported
            case .needsSetup: return .paused(.configurationChanged, .configurationChanged)
            case .unauthorized, .needsLogin: return .paused(.credentials, .credentials)
            case .notFound: return .paused(.missingRemote, .missingRemote)
            case .network: return .retryable(.network)
            case .server: return .retryable(.server)
            case .other: return .paused(.sourceError, .sourceError)
            }
        case .requiresNewerHost, .unsupportedABI, .postcardDecodingError, .postcardEncodingError:
            return .paused(.incompatible, .incompatible)
        case .hostModuleError(let domain, _):
            // The plugin needs a capability a headless completion deliberately lacks.
            return domain == "webview" || domain == "js"
                ? .paused(.incompatible, .incompatible)
                : .paused(.sourceError, .sourceError)
        case .wasmTrap, .memoryOutOfBounds:
            return .paused(.sourceError, .sourceError)
        }
    }
}
