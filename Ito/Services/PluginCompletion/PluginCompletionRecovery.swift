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
            return String(localized: "The server or account settings changed, or are incomplete.")
        case .unknownOrigin:
            return String(localized: "The account this progress was recorded under could not be verified.")
        case .credentials:
            return String(localized: "The source rejected the saved credentials.")
        case .missingRemote:
            return String(localized: "The title could not be found on the server.")
        case .sourceUnavailable:
            return String(localized: "The source is not installed or is unavailable.")
        case .incompatible:
            // The stored pause keeps no direction: the source may need an update, or Ito may. The text names neither.
            return String(
                localized: "This source can't sync progress with this version of Ito.",
                comment: "Shown in source settings when read progress is paused because the source and this version of Ito don't match. The stored reason has no direction, so the text must not say which side to update."
            )
        case .sourceError:
            return String(localized: "The source reported an error.")
        case .retryLimit:
            return String(localized: "Too many attempts failed.")
        }
    }
}
