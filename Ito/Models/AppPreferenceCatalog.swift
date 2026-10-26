import CoreFoundation
import Foundation

nonisolated public struct AppPreferenceKey<Value: Codable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value
    private let validator: @Sendable (Value) -> Bool

    nonisolated public init(name: String, defaultValue: Value, validator: @escaping @Sendable (Value) -> Bool) {
        self.name = name
        self.defaultValue = defaultValue
        self.validator = validator
    }

    nonisolated public func isValid(_ value: Value) -> Bool {
        validator(value)
    }
}

nonisolated public enum AppThemePreference: String, Codable, CaseIterable, Sendable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

nonisolated public enum NovelFontPreference: String, Codable, CaseIterable, Sendable {
    case system = "System"
    case serif = "Serif"
    case monospaced = "Monospace"
    case rounded = "Rounded"
    case lora = "Lora"
    case karla = "Karla"
    case rubik = "Rubik"
    case cardo = "Cardo"
    case nunito = "Nunito"
    case merriweather = "Merriweather"
}

nonisolated public enum NovelThemePreference: String, Codable, CaseIterable, Sendable {
    case system = "System"
    case white = "White"
    case cream = "Cream"
    case mint = "Mint"
    case sepia = "Sepia"
    case dark = "Dark"
}

nonisolated public enum UpdateIntervalPreference: Int, Codable, CaseIterable, Sendable {
    case hourly = 1
    case twoHours = 2
    case fourHours = 4
    case sixHours = 6
    case twelveHours = 12
    case daily = 24
}

nonisolated public enum ImagePreloadCountPreference: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case three = 3
    case five = 5
    case ten = 10
    case fifteen = 15
    case twenty = 20
}

nonisolated public enum AppPreferenceKeys {
    public static let libraryLayoutStyle = "ito_library_layout_style"
    public static let alwaysShowCategoryPicker = "ito_always_show_category_picker"
    public static let backgroundUpdatesEnabled = "ito_bg_updates_enabled"
    public static let updateInterval = "ito_update_interval"
    public static let skipCompleted = "ito_skip_completed"
    public static let updateNotifications = "ito_update_notifications"
    public static let wifiOnlyUpdates = "ito_wifi_only_updates"
    public static let discordRPCEnabled = "ito_discord_rpc_enabled"
    public static let discordRPCURL = "ito_discord_rpc_url"
    public static let appTheme = "selectedTheme"
    public static let novelFontSize = "Ito.NovelFontSize"
    public static let novelLineSpacing = "Ito.NovelLineSpacing"
    public static let novelFontFamily = "Ito.NovelFontFamily"
    public static let novelTheme = "Ito.NovelTheme"
    public static let novelIsPaging = "Ito.NovelIsPaging"
    public static let novelPrefetchChapters = "Ito.NovelPrefetchChapters"
    public static let preloadImageCount = "Ito.PreloadImageCount"
    public static let incognitoMode = "Ito.IncognitoMode"
    public static let autoSyncTrackersToLocal = "Ito.AutoSyncTrackersToLocal"
    public static let diskCacheLimitGB = "Ito.DiskCacheLimitGB"
    public static let mangaWordLookup = "Ito.MangaWordLookup"
}

nonisolated public enum AppPreferenceCatalog {
    public static let libraryLayoutStyle = AppPreferenceKey<Int>(name: AppPreferenceKeys.libraryLayoutStyle, defaultValue: 1) { [0, 1].contains($0) }
    public static let alwaysShowCategoryPicker = boolean(AppPreferenceKeys.alwaysShowCategoryPicker, defaultValue: false)
    public static let backgroundUpdatesEnabled = boolean(AppPreferenceKeys.backgroundUpdatesEnabled, defaultValue: false)
    public static let updateInterval = AppPreferenceKey<UpdateIntervalPreference>(name: AppPreferenceKeys.updateInterval, defaultValue: .fourHours) { _ in true }
    public static let skipCompleted = boolean(AppPreferenceKeys.skipCompleted, defaultValue: false)
    public static let updateNotifications = boolean(AppPreferenceKeys.updateNotifications, defaultValue: true)
    public static let wifiOnlyUpdates = boolean(AppPreferenceKeys.wifiOnlyUpdates, defaultValue: false)
    public static let discordRPCEnabled = boolean(AppPreferenceKeys.discordRPCEnabled, defaultValue: false)
    public static let discordRPCURL = AppPreferenceKey<String>(name: AppPreferenceKeys.discordRPCURL, defaultValue: "ws://127.0.0.1:3000") { value in
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return ["ws", "wss"].contains(scheme) && !(url.host ?? "").isEmpty
    }
    public static let appTheme = AppPreferenceKey<AppThemePreference>(name: AppPreferenceKeys.appTheme, defaultValue: .system) { _ in true }
    public static let novelFontSize = AppPreferenceKey<Double>(name: AppPreferenceKeys.novelFontSize, defaultValue: 18) { $0.isFinite && $0 > 0 }
    public static let novelLineSpacing = AppPreferenceKey<Double>(name: AppPreferenceKeys.novelLineSpacing, defaultValue: 8) { $0.isFinite && (0...40).contains($0) }
    public static let novelFontFamily = AppPreferenceKey<NovelFontPreference>(name: AppPreferenceKeys.novelFontFamily, defaultValue: .system) { _ in true }
    public static let novelTheme = AppPreferenceKey<NovelThemePreference>(name: AppPreferenceKeys.novelTheme, defaultValue: .system) { _ in true }
    public static let novelIsPaging = boolean(AppPreferenceKeys.novelIsPaging, defaultValue: false)
    public static let novelPrefetchChapters = boolean(AppPreferenceKeys.novelPrefetchChapters, defaultValue: true)
    public static let preloadImageCount = AppPreferenceKey<ImagePreloadCountPreference>(name: AppPreferenceKeys.preloadImageCount, defaultValue: .five) { _ in true }
    public static let incognitoMode = boolean(AppPreferenceKeys.incognitoMode, defaultValue: false)
    public static let autoSyncTrackersToLocal = boolean(AppPreferenceKeys.autoSyncTrackersToLocal, defaultValue: true)
    public static let diskCacheLimitGB = AppPreferenceKey<Double>(name: AppPreferenceKeys.diskCacheLimitGB, defaultValue: 10) {
        $0.isFinite && $0.rounded() == $0 && (1...50).contains($0)
    }
    public static let mangaWordLookup = boolean(AppPreferenceKeys.mangaWordLookup, defaultValue: true)

    private static func boolean(_ name: String, defaultValue: Bool) -> AppPreferenceKey<Bool> {
        AppPreferenceKey(name: name, defaultValue: defaultValue) { _ in true }
    }
}

nonisolated public enum LegacyPreferenceSourceType: String, Sendable {
    case booleanNSNumber
    case integerNSNumber
    case numericNSNumber
    case string
}

nonisolated public enum AppPreferenceCatalogEntry: String, CaseIterable, Sendable {
    case libraryLayoutStyle = "ito_library_layout_style"
    case alwaysShowCategoryPicker = "ito_always_show_category_picker"
    case backgroundUpdatesEnabled = "ito_bg_updates_enabled"
    case updateInterval = "ito_update_interval"
    case skipCompleted = "ito_skip_completed"
    case updateNotifications = "ito_update_notifications"
    case wifiOnlyUpdates = "ito_wifi_only_updates"
    case discordRPCEnabled = "ito_discord_rpc_enabled"
    case discordRPCURL = "ito_discord_rpc_url"
    case appTheme = "selectedTheme"
    case novelFontSize = "Ito.NovelFontSize"
    case novelLineSpacing = "Ito.NovelLineSpacing"
    case novelFontFamily = "Ito.NovelFontFamily"
    case novelTheme = "Ito.NovelTheme"
    case novelIsPaging = "Ito.NovelIsPaging"
    case novelPrefetchChapters = "Ito.NovelPrefetchChapters"
    case preloadImageCount = "Ito.PreloadImageCount"
    case incognitoMode = "Ito.IncognitoMode"
    case autoSyncTrackersToLocal = "Ito.AutoSyncTrackersToLocal"
    case diskCacheLimitGB = "Ito.DiskCacheLimitGB"
    case mangaWordLookup = "Ito.MangaWordLookup"

    /// The backup format that first carried this key. Backups list exactly the keys of their
    /// format, so a key added later must raise `BackupExportOperation.currentFormatVersion`.
    public var introducedFormatVersion: Int {
        switch self {
        case .libraryLayoutStyle, .alwaysShowCategoryPicker, .backgroundUpdatesEnabled,
             .updateInterval, .skipCompleted, .updateNotifications, .wifiOnlyUpdates,
             .discordRPCEnabled, .discordRPCURL, .appTheme, .novelFontSize,
             .novelLineSpacing, .novelFontFamily, .novelTheme, .novelIsPaging,
             .novelPrefetchChapters, .preloadImageCount, .incognitoMode,
             .autoSyncTrackersToLocal, .diskCacheLimitGB:
            return 1
        case .mangaWordLookup:
            return 2
        }
    }

    /// The keys a backup of `version` carries.
    public static func catalog(forFormatVersion version: Int) -> Set<String> {
        Set(allCases.filter { $0.introducedFormatVersion <= version }.map(\.rawValue))
    }

    public var acceptedSource: LegacyPreferenceSourceType {
        switch self {
        case .alwaysShowCategoryPicker, .backgroundUpdatesEnabled, .skipCompleted,
             .updateNotifications, .wifiOnlyUpdates, .discordRPCEnabled,
             .novelIsPaging, .novelPrefetchChapters, .incognitoMode,
             .autoSyncTrackersToLocal, .mangaWordLookup:
            return .booleanNSNumber
        case .libraryLayoutStyle, .updateInterval, .preloadImageCount:
            return .integerNSNumber
        case .novelFontSize, .novelLineSpacing, .diskCacheLimitGB:
            return .numericNSNumber
        case .discordRPCURL, .appTheme, .novelFontFamily, .novelTheme:
            return .string
        }
    }

    public var canonicalDefaultJSON: Data {
        switch self {
        case .libraryLayoutStyle: encode(1)
        case .alwaysShowCategoryPicker, .backgroundUpdatesEnabled, .skipCompleted,
             .wifiOnlyUpdates, .discordRPCEnabled, .novelIsPaging, .incognitoMode:
            encode(false)
        case .updateInterval: encode(4)
        case .updateNotifications, .novelPrefetchChapters, .autoSyncTrackersToLocal,
             .mangaWordLookup:
            encode(true)
        case .discordRPCURL: encode("ws://127.0.0.1:3000")
        case .appTheme, .novelFontFamily, .novelTheme: encode("System")
        case .novelFontSize: encode(18.0)
        case .novelLineSpacing: encode(8.0)
        case .preloadImageCount: encode(5)
        case .diskCacheLimitGB: encode(10.0)
        }
    }

    public var materializesDefaultWhenAbsent: Bool { true }

    public func canonicalJSON(forLegacyValue value: Any) -> Data? {
        guard acceptsLegacyValue(value) else { return nil }

        switch acceptedSource {
        case .booleanNSNumber:
            guard let number = value as? NSNumber else { return nil }
            return encode(number.boolValue)
        case .integerNSNumber:
            guard let number = value as? NSNumber else { return nil }
            return encode(number.intValue)
        case .numericNSNumber:
            guard let number = value as? NSNumber else { return nil }
            return encode(number.doubleValue)
        case .string:
            guard let string = value as? String else { return nil }
            return encode(string)
        }
    }

    public func acceptsLegacyValue(_ value: Any) -> Bool {
        switch acceptedSource {
        case .booleanNSNumber:
            guard let number = value as? NSNumber, isBoolean(number) else { return false }
            return validates(number.boolValue)
        case .integerNSNumber:
            guard let number = value as? NSNumber, !isBoolean(number) else { return false }
            let double = number.doubleValue
            guard double.isFinite, double.rounded() == double, let integer = Int(exactly: double) else { return false }
            return validates(integer)
        case .numericNSNumber:
            guard let number = value as? NSNumber, !isBoolean(number) else { return false }
            return validates(number.doubleValue)
        case .string:
            guard let string = value as? String else { return false }
            return validates(string)
        }
    }

    private func validates(_ value: Any) -> Bool {
        switch self {
        case .libraryLayoutStyle:
            return (value as? Int).map { [0, 1].contains($0) } ?? false
        case .updateInterval:
            return (value as? Int).map { [1, 2, 4, 6, 12, 24].contains($0) } ?? false
        case .preloadImageCount:
            return (value as? Int).map { [0, 3, 5, 10, 15, 20].contains($0) } ?? false
        case .discordRPCURL:
            guard let string = value as? String, let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return false }
            return ["ws", "wss"].contains(scheme) && !(url.host ?? "").isEmpty
        case .appTheme:
            return (value as? String).map { ["System", "Light", "Dark"].contains($0) } ?? false
        case .novelFontSize:
            return (value as? Double).map { $0.isFinite && $0 > 0 } ?? false
        case .novelLineSpacing:
            return (value as? Double).map { $0.isFinite && (0...40).contains($0) } ?? false
        case .novelFontFamily:
            return (value as? String).map { Set(NovelFontPreference.allCases.map(\.rawValue)).contains($0) } ?? false
        case .novelTheme:
            return (value as? String).map { Set(NovelThemePreference.allCases.map(\.rawValue)).contains($0) } ?? false
        case .diskCacheLimitGB:
            return (value as? Double).map { $0.isFinite && $0.rounded() == $0 && (1...50).contains($0) } ?? false
        case .alwaysShowCategoryPicker, .backgroundUpdatesEnabled, .skipCompleted,
             .updateNotifications, .wifiOnlyUpdates, .discordRPCEnabled,
             .novelIsPaging, .novelPrefetchChapters, .incognitoMode,
             .autoSyncTrackersToLocal, .mangaWordLookup:
            return value is Bool
        }
    }

    private func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value) else {
            preconditionFailure("Catalog defaults must be JSON-encodable")
        }
        return data
    }
}
