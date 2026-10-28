import Foundation
import ito_runner

/// A failed plugin call, described for people. Runner errors become this where the app calls a
/// plugin (see `pluginCall`), so every screen that shows an error shows the same wording.
struct PluginCallError: LocalizedError, Equatable {
    enum Kind: Equatable {
        /// The plugin reported the failure; `message` is its own text.
        case reported
        /// The plugin needs settings it doesn't have, or its credentials were rejected: the way
        /// out is the plugin's settings. `message` is its own text.
        case needsSettings
        /// The source needs the user to sign in on its website. `message` is its own text.
        case needsLogin
        /// The plugin stopped part-way (a trap or a bad memory access). Reload it before calling
        /// it again: its state may be inconsistent.
        case crashed
        /// The plugin sent data this version of Ito can't read.
        case incompatible
        /// Something Ito provides to the plugin failed, such as the network or the web view.
        case host
    }

    let kind: Kind
    let message: String

    var errorDescription: String? { message }

    init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    init(_ error: ItoError) {
        switch error {
        case .pluginFailed(_, let reason, _) where reason.map(Self.isSDKDecodingFailure) == true:
            self.init(kind: .incompatible, message: Self.incompatibleMessage)
        case .pluginFailed(_, let reason, .needsLogin):
            let message = reason?.isEmpty == false ? Self.pluginMessage(reason) : "Sign in to this source to continue."
            self.init(kind: .needsLogin, message: message)
        case .pluginFailed(_, let reason, let category):
            let kind: Kind = category == .needsSetup || category == .unauthorized ? .needsSettings : .reported
            self.init(kind: kind, message: Self.pluginMessage(reason))
        case .wasmTrap, .memoryOutOfBounds:
            self.init(kind: .crashed, message: "The source stopped unexpectedly. Try again.")
        case .postcardDecodingError, .postcardEncodingError, .controlContractViolation:
            self.init(kind: .incompatible, message: Self.incompatibleMessage)
        case .requiresNewerHost, .unsupportedABI:
            // Only raised while loading, where PluginManager turns them into
            // PluginRequiresNewerAppError; mapped here for completeness.
            self.init(kind: .incompatible, message: PluginRequiresNewerAppError.unnamedVersionMessage)
        case .hostModuleError(let domain, let message):
            self.init(kind: .host, message: domain == "webview" ? "The source's web page failed: \(message)" : message)
        }
    }

    /// `error` as a `PluginCallError` when it came from the runner; other errors (cancellation,
    /// URL errors) are returned unchanged.
    static func wrapping(_ error: any Error) -> any Error {
        guard let error = error as? ItoError else { return error }
        return PluginCallError(error)
    }

    private static let incompatibleMessage =
        "The source sent something this version of Ito can't read. Update the source or Ito."

    /// The plugin couldn't read what Ito sent or encode its answer: the plugin and Ito disagree on
    /// the data format, so it's a version mismatch rather than something the plugin said.
    private static func isSDKDecodingFailure(_ reason: String) -> Bool {
        reason.hasPrefix("Deserialization error: ")
            || reason.hasPrefix("Serialization error: ")
            || reason.hasPrefix("Postcard decoding error in ")
    }

    /// The SDK formats a plugin's own message as "Host error: <message>"; other reasons
    /// ("Network error: …") are shown as the plugin gave them.
    private static func pluginMessage(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else {
            return "The source couldn't complete this request."
        }
        let hostPrefix = "Host error: "
        return reason.hasPrefix(hostPrefix) ? String(reason.dropFirst(hostPrefix.count)) : reason
    }
}

/// Runs a plugin call so that runner failures come out as `PluginCallError`.
func pluginCall<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ operation: () async throws -> T
) async throws -> T {
    do {
        return try await operation()
    } catch {
        throw PluginCallError.wrapping(error)
    }
}
