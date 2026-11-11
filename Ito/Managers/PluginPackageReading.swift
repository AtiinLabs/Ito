import Foundation
import ito_runner

/// Why a package can't be checked for installation, as the install paths report it.
nonisolated enum PluginPackageInspectionError: LocalizedError, Equatable, Sendable {
    /// The package's archive, manifest or module can't be read as an Ito plugin.
    case unreadablePackage
    /// A downloaded package couldn't be copied to scratch storage to be checked.
    case temporaryStorageFailed

    var errorDescription: String? {
        switch self {
        case .unreadablePackage:
            String(
                localized: "The plugin package could not be read, so it was not installed.",
                comment: "Error shown when a downloaded or imported plugin file is damaged or is not an Ito plugin."
            )
        case .temporaryStorageFailed:
            String(
                localized: "The plugin package could not be checked because temporary storage failed. Try again.",
                comment: "Error shown when Ito cannot copy a plugin file to temporary storage in order to check it."
            )
        }
    }
}

/// Why a package may not replace the installed file.
nonisolated enum PluginPackageRefusal: Equatable, Sendable {
    /// The manifest or module needs a newer Ito. A module built for an older ABI is reported here too, as it
    /// always has been, until the install states split the two directions.
    case requiresNewerApp(PluginRequiresNewerAppError)
    /// The module is damaged, missing, or not one Ito can run.
    case unreadable
}

/// What one packaged `.ito` file declares. Reading inflates the module, so callers reach this through
/// `readInBackground`, never on the main actor.
nonisolated struct PluginPackageReading: Sendable {
    let manifest: PluginManifest
    let icon: Data?
    /// The module's interface, or nil when the module is missing, too large, damaged or not inspectable.
    let binary: PluginBinaryInterface?
    /// Why this package may not replace the installed file; nil when it may. Computed here, so the main
    /// actor never runs the import checks either.
    let installRefusal: PluginPackageRefusal?

    /// Reads the file at `url` in place. The runner opens the archive by URL, so the manifest and the module are
    /// two opens of the same file. The plugin directory gate keeps app writers out while a scan runs, and a manual
    /// import reads its private staging copy, so both opens see one version. Writes nothing, so it doesn't depend on
    /// temporary storage. Throws when the file can't be read, which a caller that finds it gone treats as absent, or
    /// when its archive or manifest can't be read. A malformed module is not an error here.
    static func readInBackground(at url: URL) async throws -> PluginPackageReading {
        try await Task.detached(priority: .utility) {
            try PluginPackageReading.read(at: url)
        }.value
    }

    /// Reads a package already in memory, such as a download. The runner reads archives by URL, so the bytes are
    /// copied to `scratchDirectory` for the check and the copy is removed before this returns. A failure to write
    /// the copy throws `PluginPackageInspectionError.temporaryStorageFailed`.
    static func readInBackground(
        downloaded data: Data,
        scratchDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> PluginPackageReading {
        try await Task.detached(priority: .utility) {
            try PluginPackageReading.inspect(bytes: data, in: scratchDirectory)
        }.value
    }

    /// Copies `bytes` to a scratch file in `directory`, reads that copy, and removes it. Removal is registered before
    /// the write, so a partial write is removed too.
    private static func inspect(bytes: Data, in directory: URL) throws -> PluginPackageReading {
        let copyURL = directory.appendingPathComponent("ito-package-\(UUID().uuidString).ito", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: copyURL) }
        do {
            try bytes.write(to: copyURL, options: .withoutOverwriting)
        } catch {
            throw PluginPackageInspectionError.temporaryStorageFailed
        }
        return try read(at: copyURL)
    }

    private static func read(at url: URL) throws -> PluginPackageReading {
        let extracted = try ItoRunner.extractPluginInfo(from: url)
        let binary = (try? ItoRunner.inspectBundle(at: url))?.binary
        return PluginPackageReading(
            manifest: extracted.manifest,
            icon: extracted.icon,
            binary: binary,
            installRefusal: refusal(manifest: extracted.manifest, binary: binary)
        )
    }

    /// The manifest's own requirements come first, so a `min_app_version` names its version. Then the module: a
    /// module this Ito can't run is refused, and so is one that can't be read at all.
    private static func refusal(
        manifest: PluginManifest,
        binary: PluginBinaryInterface?
    ) -> PluginPackageRefusal? {
        if let refusal = manifest.info.compatibilityRefusal {
            return .requiresNewerApp(refusal)
        }
        guard let binary else { return .unreadable }
        switch ItoRunner.compatibility(of: binary) {
        case .compatible:
            return nil
        case .pluginTooOld, .pluginTooNew, .missingImports:
            return .requiresNewerApp(PluginRequiresNewerAppError(minimumAppVersion: nil))
        case .invalid:
            return .unreadable
        }
    }
}
