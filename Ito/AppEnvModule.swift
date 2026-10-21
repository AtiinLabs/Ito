import Foundation
import ito_runner

/// What plugins learn about the device's environment.
nonisolated struct AppEnvModule: EnvModule {
    private let preferredLanguages: @Sendable () -> [String]

    init(preferredLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages }) {
        self.preferredLanguages = preferredLanguages
    }

    /// The user's preferred languages as language codes ("en", "pt"), most preferred first.
    /// Plugins pass these to their sites, which name languages by code, not by device locale.
    func getLanguages() -> [String] {
        var codes: [String] = []
        for identifier in preferredLanguages() {
            guard let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased(),
                  !code.isEmpty, !codes.contains(code) else { continue }
            codes.append(code)
        }
        return codes.isEmpty ? ["en"] : codes
    }
}
