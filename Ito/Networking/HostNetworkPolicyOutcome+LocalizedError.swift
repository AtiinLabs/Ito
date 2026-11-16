import Foundation
import ito_runner

/// The runner carries fixed typed outcomes; the host owns the text displayed by repository and tracker screens.
extension HostNetworkPolicyOutcome: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .deferred(.offline):
            String(localized: "No internet connection. Try again when connected.", comment: "A request was not sent because the device is offline.")
        case .deferred(.unknownPath):
            String(localized: "Waiting for a network connection.", comment: "A request is waiting until the network path is known.")
        case .deferred(.expensivePath):
            String(localized: "This request is waiting for an unmetered network.", comment: "Network policy refuses a request on a metered connection.")
        case .deferred(.constrainedPath):
            String(localized: "This request is paused while Low Data Mode is enabled.", comment: "Network policy refuses a request on a constrained connection.")
        case .deferred(.policyChanged):
            String(localized: "Network settings changed. Try again.", comment: "A request was stopped because its captured network policy is no longer current.")
        case .foregroundPermissionRequired:
            String(localized: "Open this source to continue in the foreground.", comment: "A source needs user interaction that background work cannot perform.")
        case .hardUserBlocked:
            String(localized: "This request is blocked by your network settings.", comment: "An explicit user network restriction blocks the request.")
        case .sourceAuthorizationFailure:
            String(localized: "The source's sign-in or settings changed. Review them and try again.", comment: "The request belongs to a source authorization scope that is no longer current.")
        }
    }
}
