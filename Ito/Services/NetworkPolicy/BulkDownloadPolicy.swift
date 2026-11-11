import ito_runner

/// Whether a bulk download attempt may start or continue on the current network path.
nonisolated enum BulkDownloadAdmission: Equatable, Sendable {
    case allow
    case wait(BulkDownloadWait)
}

/// Why the network path makes bulk downloads wait. Closed: the admission rule is the only producer. Each
/// reason maps to the job's waiting reason and to the host policy outcome a download module refuses with.
nonisolated enum BulkDownloadWait: Equatable, Sendable, CaseIterable {
    case networkUnknown
    case noConnection
    case meteredNetwork
    case lowDataMode

    var waitingReason: DownloadWaitingReason {
        switch self {
        case .networkUnknown:
            return .networkUnknown
        case .noConnection:
            return .noConnection
        case .meteredNetwork:
            return .meteredNetwork
        case .lowDataMode:
            return .lowDataMode
        }
    }

    var policyOutcome: HostNetworkPolicyOutcome {
        switch self {
        case .networkUnknown:
            return .deferred(.unknownPath)
        case .noConnection:
            return .deferred(.offline)
        case .meteredNetwork:
            return .deferred(.expensivePath)
        case .lowDataMode:
            return .deferred(.constrainedPath)
        }
    }
}

/// Pure admission rule for bulk downloads. M0 has no user setting: only an unmetered,
/// unconstrained satisfied path is admitted.
nonisolated enum BulkDownloadPolicy {
    /// The revision of the network policy a host context carries. Ito has no network-policy setting
    /// yet, so there is exactly one revision; a setting would bump it when its value changes.
    static let revision: UInt64 = 1

    static func admit(_ path: NetworkPathSnapshot) -> BulkDownloadAdmission {
        switch path.status {
        case .unknown:
            return .wait(.networkUnknown)
        case .unsatisfied, .requiresConnection:
            return .wait(.noConnection)
        case .satisfied:
            // Expensive is checked first so a path that is both expensive and constrained
            // reports the stricter, metered reason.
            if path.isExpensive { return .wait(.meteredNetwork) }
            if path.isConstrained { return .wait(.lowDataMode) }
            return .allow
        }
    }
}
