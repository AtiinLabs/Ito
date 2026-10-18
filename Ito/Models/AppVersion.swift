import Foundation

/// The running app's version, read from Info.plist.
/// The values come from Configuration/Version.xcconfig; CI sets the build number.
nonisolated enum AppVersion {
    /// `CFBundleShortVersionString`, for example "1.1.0".
    static let marketing = string(for: "CFBundleShortVersionString") ?? "0.0.0"

    /// `CFBundleVersion`: the commit count of the built commit in CI builds, 1 locally.
    static let build = string(for: "CFBundleVersion") ?? "0"

    private static func string(for key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
