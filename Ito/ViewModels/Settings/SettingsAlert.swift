import Foundation

enum SettingsAlert: Identifiable, Equatable {
    case saveFailed
    case invalidDiscordURL
    case notificationsDisabled
    case notificationRollbackFailed
    case applicationSettingsOpenFailed
    case siteDataCleared
    case siteDataClearFailed

    var id: Self { self }

    var title: String {
        switch self {
        case .saveFailed:
            return String(localized: "Unable to Save Settings")
        case .invalidDiscordURL:
            return String(localized: "Invalid Server Address")
        case .notificationsDisabled:
            return String(localized: "Notifications Disabled")
        case .notificationRollbackFailed:
            return String(localized: "Unable to Disable Notifications")
        case .applicationSettingsOpenFailed:
            return String(localized: "Unable to Open Settings")
        case .siteDataCleared:
            return String(localized: "Site Data Cleared")
        case .siteDataClearFailed:
            return String(localized: "Unable to Clear Site Data")
        }
    }

    var message: String {
        switch self {
        case .saveFailed:
            return String(localized: "Your changes could not be saved. Please try again.")
        case .invalidDiscordURL:
            return String(localized: "Enter a ws:// or wss:// address, such as ws://127.0.0.1:3000.")
        case .notificationsDisabled:
            return String(localized: "Please enable notifications for Ito in your device Settings to receive update alerts.")
        case .notificationRollbackFailed:
            return String(localized: "Notification permission was denied, but the preference could not be disabled. Please try again.")
        case .applicationSettingsOpenFailed:
            return String(localized: "Ito could not open the device Settings app. Please try again.")
        case .siteDataCleared:
            return String(localized: "Cookies, website data and Cloudflare clearance were removed.")
        case .siteDataClearFailed:
            return String(localized: "Some website data could not be removed. Try again.")
        }
    }
}
