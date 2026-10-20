import OSLog
import Foundation
import UserNotifications
import UIKit
import Combine

/// The parts of the system notification settings `NotificationManager` uses.
nonisolated protocol NotificationSystem: Sendable {
    /// Whether the app may post notifications (authorized or provisional).
    nonisolated func isAuthorized() async -> Bool
    /// Sets the number on the app icon.
    nonisolated func setIconBadgeCount(_ count: Int) async
}

nonisolated struct UserNotificationSystem: NotificationSystem {
    nonisolated func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    nonisolated func setIconBadgeCount(_ count: Int) async {
        if #available(iOS 16.0, *) {
            try? await UNUserNotificationCenter.current().setBadgeCount(count)
        } else {
            await MainActor.run { UIApplication.shared.applicationIconBadgeNumber = count }
        }
    }
}

@MainActor
public class NotificationManager: ObservableObject {
    @Published public private(set) var isAuthorized = false
    private var settingsStore: AppSettingsStore?
    private weak var updateManager: UpdateManager?
    private let system: any NotificationSystem
    private var iconBadgeSubscription: AnyCancellable?
    /// Icon badge writes run one after another, so an older count never lands last.
    private var iconBadgeWrite: Task<Void, Never>?

    init(system: any NotificationSystem = UserNotificationSystem()) {
        self.system = system
        Task {
            await checkStatus()
        }
    }

    func configure(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
    }

    /// Keeps the app icon badge equal to the library's unread new chapters.
    func configure(updateManager: UpdateManager) {
        self.updateManager = updateManager
        iconBadgeSubscription = $isAuthorized
            .combineLatest(updateManager.libraryBadgeCountsPublisher.map { $0.values.reduce(0, +) })
            .filter { isAuthorized, _ in isAuthorized }
            .map { _, unread in unread }
            .removeDuplicates()
            .sink { [weak self] unread in
                self?.setIconBadge(unread)
            }
    }

    private func setIconBadge(_ count: Int) {
        let previous = iconBadgeWrite
        let system = system
        iconBadgeWrite = Task {
            await previous?.value
            await system.setIconBadgeCount(count)
        }
    }

    public func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            self.isAuthorized = granted
            return granted
        } catch {
            AppLogger.general.error("Failed to request notification permission: \(error)")
            return false
        }
    }

    public func checkStatus() async {
        isAuthorized = await system.isAuthorized()
    }

    /// Dispatch a summary notification for updated library items
    /// Highlights standard HIG patterns for communication
    public func dispatchUpdateSummary(updatedItems: [(LibraryItem, Int)]) async {
        guard isAuthorized else { return }
        guard !updatedItems.isEmpty else { return }

        // Check user settings for notifications
        guard settingsStore?.updateNotifications == true else { return }

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()

        if updatedItems.count == 1 {
            let item = updatedItems[0].0
            let chapters = updatedItems[0].1
            let typeLabel = item.isAnime ? "episodes" : "chapters"
            content.title = "New Update"
            content.body = "\(item.title) has \(chapters) new \(typeLabel)."
        } else {
            content.title = "Library Updates"
            let itemsString = updatedItems.prefix(2).map { $0.0.title }.joined(separator: ", ")
            content.body = "\(updatedItems.count) titles have new updates, including \(itemsString)"
            content.threadIdentifier = "LibraryUpdates"
        }

        content.sound = .default

        // Use UIApplication to set badge if modifying outside of notifications too,
        // but here we just bundle it with the push notification response.
        let totalUnread = updateManager?.totalBadgeCount ?? 0
        content.badge = NSNumber(value: totalUnread)

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await center.add(request)
        } catch {
            AppLogger.general.error("Failed to schedule local notification: \(error)")
        }
    }
}
