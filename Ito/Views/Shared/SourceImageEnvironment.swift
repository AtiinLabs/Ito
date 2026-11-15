import SwiftUI

private nonisolated struct SourceCoverRequestsKey: EnvironmentKey {
    static let defaultValue = SourceCoverRequests(contexts: nil)
}

private nonisolated struct ImageSourceIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Prepared by composition so a screen cannot turn source cover URLs into app-owned traffic.
    var sourceCoverRequests: SourceCoverRequests {
        get { self[SourceCoverRequestsKey.self] }
        set { self[SourceCoverRequestsKey.self] = newValue }
    }

    /// The source that owns the images below this view, supplied by the screen that knows it.
    var imageSourceID: String? {
        get { self[ImageSourceIDKey.self] }
        set { self[ImageSourceIDKey.self] = newValue }
    }
}
