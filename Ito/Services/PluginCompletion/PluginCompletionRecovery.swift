import Combine
import Foundation

/// The explicit-recovery surface of the completion dispatcher that source settings depend on.
///
/// `reauthorize` is the user's confirmation to send paused read progress to the server and account
/// that are configured now; `discard` deletes paused rows only. Neither may touch pending rows.
@MainActor
protocol PluginCompletionRecovering: AnyObject {
    var completionSummariesPublisher: AnyPublisher<[PluginCompletionSummary], Never> { get }
    func reauthorize(pluginID: String) async throws
    func discard(pluginID: String) async throws
}

extension PluginCompletionPauseReason {
    /// User-facing explanation. Fixed text only: remote URLs, credentials, response bodies and raw
    /// error descriptions never reach recovery presentation.
    nonisolated var recoveryDescription: String {
        switch self {
        case .configurationChanged:
            return "The server or account settings changed, or are incomplete."
        case .unknownOrigin:
            return "The account this progress was recorded under could not be verified."
        case .credentials:
            return "The source rejected the saved credentials."
        case .missingRemote:
            return "The title could not be found on the server."
        case .sourceUnavailable:
            return "The source is not installed or is unavailable."
        case .incompatible:
            return "The source must be updated before it can sync progress."
        case .sourceError:
            return "The source reported an error."
        case .retryLimit:
            return "Too many attempts failed."
        }
    }
}
