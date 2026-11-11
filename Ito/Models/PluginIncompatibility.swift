import Foundation
import ito_runner

/// Why a plugin can't run in this version of Ito, and which side has to change. A source built for an
/// older ABI needs its source updated; a source built for a newer Ito needs Ito updated.
nonisolated enum PluginIncompatibility: LocalizedError, Equatable {
    /// The source needs a newer Ito. `minimumAppVersion` is the version it names, or nil when it needs
    /// something this version lacks (its ABI or a host function).
    case requiresNewerApp(minimumAppVersion: String?)
    /// The source was built for an ABI older than this Ito reads, so the source must be updated.
    case requiresSourceUpdate
    /// The source's module is damaged, or is built in a form no host runs. Nothing about the direction is known, so
    /// the message names neither side.
    case unsupportedFile

    var errorDescription: String? {
        message
    }

    /// The user-facing explanation. Fixed text only.
    var message: String {
        switch self {
        case .requiresNewerApp(let minimumAppVersion):
            guard let minimumAppVersion else {
                return String(localized: "This source needs a newer version of Ito. Update Ito to use it.")
            }
            return String(localized: "This source needs Ito \(minimumAppVersion) or later. Update Ito to use it.")
        case .requiresSourceUpdate:
            return String(
                localized: "This source was built for an older version of Ito. Update the source to use it.",
                comment: "Error shown when a source was built for an older Ito plugin interface than this version of Ito reads. The source's publisher must release an update; the user cannot fix it in Ito."
            )
        case .unsupportedFile:
            return String(
                localized: "This source's file is damaged or can't be run by this version of Ito.",
                comment: "Error shown on a source's screen when its installed file is damaged, or is built in a form this version of Ito can't run. The user cannot pick another file here, and the message names neither Ito nor the source as the side to update."
            )
        }
    }

    /// Why a plugin needing `minimum` (its manifest's or index's `min_app_version`) can't run in
    /// `current`, or nil when it can.
    static func appVersion(required minimum: String?, current: String = AppVersion.marketing) -> PluginIncompatibility? {
        guard let minimum, !AppVersion.isAtLeast(minimum, current: current) else { return nil }
        return .requiresNewerApp(minimumAppVersion: minimum)
    }

    /// Why a plugin declaring `abi` and `imports` (in its manifest or index entry) can't run when `supported`
    /// is the ABI range this Ito reads, or nil when it can. Used when no module is available to read.
    static func declared(
        abi: Int?,
        imports: [String]?,
        supported: ClosedRange<Int> = ItoRunner.supportedABIVersions
    ) -> PluginIncompatibility? {
        if let abi, !supported.contains(abi) {
            return abi < supported.lowerBound ? .requiresSourceUpdate : .requiresNewerApp(minimumAppVersion: nil)
        }
        if let imports, !ItoRunner.unsupportedImports(imports).isEmpty {
            return .requiresNewerApp(minimumAppVersion: nil)
        }
        return nil
    }

    /// Why a module with this static interface can't run, or nil when it can.
    static func binary(_ compatibility: PluginBinaryCompatibility) -> PluginIncompatibility? {
        switch compatibility {
        case .compatible:
            return nil
        case .pluginTooOld:
            return .requiresSourceUpdate
        case .pluginTooNew, .missingImports:
            return .requiresNewerApp(minimumAppVersion: nil)
        case .invalid:
            return .unsupportedFile
        }
    }

    /// The refusal a runner's load error stands for, or nil for any other error. A module built for an ABI
    /// below the runner's range needs its source updated; one built for a newer ABI, or needing a host
    /// function this Ito lacks, needs Ito updated.
    static func loading(_ error: ItoError) -> PluginIncompatibility? {
        switch error {
        case .requiresNewerHost:
            return .requiresNewerApp(minimumAppVersion: nil)
        case .unsupportedABI(let version, let supported):
            return version < supported.lowerBound ? .requiresSourceUpdate : .requiresNewerApp(minimumAppVersion: nil)
        default:
            return nil
        }
    }
}
