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

    /// Whether `current` is at least `minimum`. Versions compare by their numeric components,
    /// missing ones counting as 0 ("1.2" is "1.2.0"); a pre-release or build suffix ("-beta.1",
    /// "+5") is ignored.
    static func isAtLeast(_ minimum: String, current: String = marketing) -> Bool {
        let have = numericComponents(current)
        let need = numericComponents(minimum)
        for index in 0..<max(have.count, need.count) {
            let lhs = index < have.count ? have[index] : 0
            let rhs = index < need.count ? need[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return true
    }

    private static func numericComponents(_ version: String) -> [Int] {
        version.prefix { $0 != "-" && $0 != "+" }
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}

/// A plugin that needs a newer version of Ito than this one.
nonisolated struct PluginRequiresNewerAppError: LocalizedError, Equatable {
    let minimumAppVersion: String

    var errorDescription: String? {
        "This source needs Ito \(minimumAppVersion) or later. Update Ito to use it."
    }
}
