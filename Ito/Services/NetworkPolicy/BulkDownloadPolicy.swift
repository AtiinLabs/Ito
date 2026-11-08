/// Whether a bulk download attempt may start or continue on the current network path.
nonisolated enum BulkDownloadAdmission: Equatable, Sendable {
    case allow
    case wait(DownloadWaitingReason)
}

/// Pure admission rule for bulk downloads. M0 has no user setting: only an unmetered,
/// unconstrained satisfied path is admitted.
nonisolated enum BulkDownloadPolicy {
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
