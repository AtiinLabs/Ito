import XCTest
@testable import Ito

@MainActor
extension SettingsViewModelTests {
    func testLibraryEnablingBackgroundUpdatesRequestsPermissionForEnabledNotifications() async throws {
        let (store, persistence, notification, opener) = try await makeLibrarySettingsStore()
        notification.result = false
        let viewModel = LibrarySettingsViewModel(
            settingsStore: store,
            notificationAuthorization: notification,
            applicationSettingsOpener: opener
        )

        await viewModel.setBackgroundUpdatesEnabled(true)

        let history = await persistence.writeHistory
        XCTAssertEqual(
            history.compactMap(\.first).map(\.key),
            [AppPreferenceKeys.backgroundUpdatesEnabled, AppPreferenceKeys.updateNotifications]
        )
        XCTAssertEqual(notification.requestCallCount, 1)
        XCTAssertTrue(store.backgroundUpdatesEnabled)
        XCTAssertFalse(store.updateNotifications)
        XCTAssertFalse(viewModel.updateNotifications)
        XCTAssertEqual(viewModel.alert, .notificationsDisabled)
    }

    func testLibraryEnablingBackgroundUpdatesSkipsPermissionWhenNotificationsAreOff() async throws {
        let (store, persistence, notification, opener) = try await makeLibrarySettingsStore(
            updateNotifications: false
        )
        let viewModel = LibrarySettingsViewModel(
            settingsStore: store,
            notificationAuthorization: notification,
            applicationSettingsOpener: opener
        )

        await viewModel.setBackgroundUpdatesEnabled(true)

        let history = await persistence.writeHistory
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(notification.requestCallCount, 0)
        XCTAssertNil(viewModel.alert)
    }
}
