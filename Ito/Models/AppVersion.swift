import Foundation
import ito_runner

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

/// A plugin that needs a newer version of Ito than this one. `minimumAppVersion` is the version it
/// names, or nil when it needs something this version lacks (its ABI or a host function).
nonisolated struct PluginRequiresNewerAppError: LocalizedError, Equatable {
    let minimumAppVersion: String?

    static let unnamedVersionMessage = "This source needs a newer version of Ito. Update Ito to use it."

    var errorDescription: String? {
        guard let minimumAppVersion else { return Self.unnamedVersionMessage }
        return "This source needs Ito \(minimumAppVersion) or later. Update Ito to use it."
    }

    /// Why a plugin with these requirements can't run in this Ito, or nil when it can. `abi` and
    /// `imports` come from the plugin's manifest or repository entry; older ones don't have them.
    static func refusal(
        minAppVersion: String,
        abi: Int?,
        imports: [String]?,
        currentAppVersion: String = AppVersion.marketing
    ) -> PluginRequiresNewerAppError? {
        if !AppVersion.isAtLeast(minAppVersion, current: currentAppVersion) {
            return PluginRequiresNewerAppError(minimumAppVersion: minAppVersion)
        }
        if let abi, !ItoRunner.supportedABIVersions.contains(abi) {
            return PluginRequiresNewerAppError(minimumAppVersion: nil)
        }
        if let imports, !ItoRunner.unsupportedImports(imports).isEmpty {
            return PluginRequiresNewerAppError(minimumAppVersion: nil)
        }
        return nil
    }
}

extension PluginInfo {
    /// Why this installed or imported plugin can't run in this Ito, or nil when it can.
    nonisolated var compatibilityRefusal: PluginRequiresNewerAppError? {
        PluginRequiresNewerAppError.refusal(minAppVersion: minAppVersion, abi: abi, imports: imports)
    }
}
