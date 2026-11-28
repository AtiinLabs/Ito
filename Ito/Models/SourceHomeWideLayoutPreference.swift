import SwiftUI

/// How a source's home is laid out when the window is wide enough for two columns (an unfolded iPhone Duo in
/// landscape, iPad, Mac): the featured carousel pinned beside the shelves, or stacked above them like on a phone.
nonisolated public enum SourceHomeWideLayoutPreference: String, Codable, CaseIterable, Sendable {
    case sideBySide = "SideBySide"
    case stacked = "Stacked"

    public var localizedTitle: String {
        switch self {
        case .sideBySide:
            return String(localized: "Side by Side", comment: "Source home layout on wide screens: the featured carousel beside the shelves. The picker is in Settings, under Appearance.")
        case .stacked:
            return String(localized: "Stacked", comment: "Source home layout on wide screens: the featured carousel above the shelves. The picker is in Settings, under Appearance.")
        }
    }
}

private struct SourceHomeWideLayoutKey: EnvironmentKey {
    static let defaultValue: SourceHomeWideLayoutPreference = .sideBySide
}

extension EnvironmentValues {
    /// The user's wide-screen layout for source homes. Injected at the app root from `AppSettingsStore`.
    var sourceHomeWideLayout: SourceHomeWideLayoutPreference {
        get { self[SourceHomeWideLayoutKey.self] }
        set { self[SourceHomeWideLayoutKey.self] = newValue }
    }
}
