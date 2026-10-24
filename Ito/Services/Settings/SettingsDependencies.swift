import Foundation
import UIKit
import WebKit

@MainActor
protocol NotificationAuthorizationRequesting: AnyObject {
    func requestPermission() async -> Bool
}

extension NotificationManager: NotificationAuthorizationRequesting {}

@MainActor
protocol ApplicationSettingsOpening: AnyObject {
    func openApplicationSettings() async -> Bool
}

@MainActor
final class SystemApplicationSettingsOpener: ApplicationSettingsOpening {
    func openApplicationSettings() async -> Bool {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { opened in
                continuation.resume(returning: opened)
            }
        }
    }
}

@MainActor
protocol SettingsStorageAccessing: AnyObject {
    var currentCacheSizeBytes: Int? { get }

    func refreshCacheSize() async
    func clearCache() async
    func formatBytes(_ bytes: Int) -> String
}

extension StorageManager: SettingsStorageAccessing {}

@MainActor
protocol ClipboardWriting: AnyObject {
    func write(_ text: String) throws
}

@MainActor
final class SystemClipboardWriter: ClipboardWriting {
    func write(_ text: String) throws {
        UIPasteboard.general.string = text
    }
}

enum DebugLogMessage: Equatable {
    case copied
}

@MainActor
protocol DebugLogMessagePresenting: AnyObject {
    func present(_ message: DebugLogMessage)
}

@MainActor
final class AppMessageDebugLogMessagePresenter: DebugLogMessagePresenting {
    private let messageCenter: AppMessageCenter

    init(messageCenter: AppMessageCenter) {
        self.messageCenter = messageCenter
    }

    func present(_ message: DebugLogMessage) {
        switch message {
        case .copied:
            messageCenter.publish(.debugLogsCopied)
        }
    }
}

@MainActor
protocol SiteDataClearing: AnyObject {
    func clearSiteData() async throws
}

@MainActor
final class SystemSiteDataClearer: SiteDataClearing {
    private let pluginCookies: PluginCookieJar?

    /// `pluginCookies` holds the sources' sign-in cookies, cleared with the rest.
    init(pluginCookies: PluginCookieJar? = nil) {
        self.pluginCookies = pluginCookies
    }

    func clearSiteData() async throws {
        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        try pluginCookies?.removeEveryPlugin()
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
        CloudflareManager.shared.clearCachedUserAgents()
    }
}

@MainActor
struct PreparedSettingsDependencies {
    let settingsStore: AppSettingsStore
    let notificationAuthorization: any NotificationAuthorizationRequesting
    let applicationSettingsOpener: any ApplicationSettingsOpening
    let storageAccess: any SettingsStorageAccessing
    let discordRPCManager: DiscordRPCManager
    let logReader: any DebugLogReading
    let clipboardWriter: any ClipboardWriting
    let siteDataClearer: any SiteDataClearing

    init(
        settingsStore: AppSettingsStore,
        notificationAuthorization: any NotificationAuthorizationRequesting,
        applicationSettingsOpener: any ApplicationSettingsOpening,
        storageAccess: any SettingsStorageAccessing,
        discordRPCManager: DiscordRPCManager,
        logReader: any DebugLogReading,
        clipboardWriter: any ClipboardWriting,
        siteDataClearer: any SiteDataClearing = SystemSiteDataClearer()
    ) {
        self.settingsStore = settingsStore
        self.notificationAuthorization = notificationAuthorization
        self.applicationSettingsOpener = applicationSettingsOpener
        self.storageAccess = storageAccess
        self.discordRPCManager = discordRPCManager
        self.logReader = logReader
        self.clipboardWriter = clipboardWriter
        self.siteDataClearer = siteDataClearer
    }
}
