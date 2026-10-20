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
            return "Unable to Save Settings"
        case .invalidDiscordURL:
            return "Invalid Server Address"
        case .notificationsDisabled:
            return "Notifications Disabled"
        case .notificationRollbackFailed:
            return "Unable to Disable Notifications"
        case .applicationSettingsOpenFailed:
            return "Unable to Open Settings"
        case .siteDataCleared:
            return "Site Data Cleared"
        case .siteDataClearFailed:
            return "Unable to Clear Site Data"
        }
    }

    var message: String {
        switch self {
        case .saveFailed:
            return "Your changes could not be saved. Please try again."
        case .invalidDiscordURL:
            return "Enter a ws:// or wss:// address, such as ws://127.0.0.1:3000."
        case .notificationsDisabled:
            return "Please enable notifications for Ito in your device Settings to receive update alerts."
        case .notificationRollbackFailed:
            return "Notification permission was denied, but the preference could not be disabled. Please try again."
        case .applicationSettingsOpenFailed:
            return "Ito could not open the device Settings app. Please try again."
        case .siteDataCleared:
            return "Cookies, website data and Cloudflare clearance were removed."
        case .siteDataClearFailed:
            return "Some website data could not be removed. Try again."
        }
    }
}
