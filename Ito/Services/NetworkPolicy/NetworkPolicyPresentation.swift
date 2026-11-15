import Foundation

extension NetworkDownloadMode {
    var localizedTitle: String {
        switch self {
        case .unmeteredOnly: String(localized: "Unmetered Only", comment: "Download mode that avoids cellular and hotspots")
        case .askMetered: String(localized: "Ask on Metered Networks", comment: "Download mode requiring batch confirmation on cellular")
        case .allowMetered: String(localized: "Allow Metered Networks", comment: "Download mode permitting cellular and hotspots")
        }
    }
}

extension NetworkDecision {
    var localizedReason: String {
        switch self {
        case .allow: String(localized: "Available on this network", comment: "Effective network policy status")
        case .wait(.networkUnknown): String(localized: "Waiting for a network reading", comment: "No path observation yet")
        case .wait(.noConnection): String(localized: "Waiting for a connection", comment: "Effective network policy refusal")
        case .wait(.lowDataMode): String(localized: "Paused by Low Data Mode", comment: "Effective network policy refusal")
        case .wait(.meteredConsentRequired): String(localized: "Requires confirmation for each batch", comment: "Metered download consent is batch-scoped")
        case .wait(.meteredNetwork), .wait(.wifiOnlyUpdates): String(localized: "Waiting for an unmetered network", comment: "Effective network policy refusal")
        }
    }
}
