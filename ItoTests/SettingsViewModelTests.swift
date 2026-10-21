import Combine
import XCTest
@testable import Ito

@MainActor
final class SettingsViewModelTests: XCTestCase {
    func testPreparedSettingsDependenciesPreserveInjectedIdentities() {
        let bundle = TestPreparedSettingsDependencyBundle()
        let dependencies = bundle.dependencies

        XCTAssertTrue(dependencies.settingsStore === bundle.settingsStore)
        XCTAssertTrue(dependencies.notificationAuthorization === bundle.notificationAuthorization)
        XCTAssertTrue(dependencies.applicationSettingsOpener === bundle.applicationSettingsOpener)
        XCTAssertTrue(dependencies.storageAccess === bundle.storageAccess)
        XCTAssertTrue(dependencies.discordRPCManager === bundle.discordRPCManager)
        XCTAssertTrue((dependencies.logReader as? TestDebugLogReader) === bundle.logReader)
        XCTAssertTrue(dependencies.clipboardWriter === bundle.clipboardWriter)
    }

    func testLiveSettingsModelsFollowAuthoritativeRestoreWithoutActionSideEffects() async throws {
        try await verifyLiveSettingsRestorePropagation { [self] settings, messageCenter in
            makeScope(settings: settings, messageCenter: messageCenter)
        }
    }

    func testScopeDebugLogPresenterReusesOwnedMessageCenter() throws {
        let center = AppMessageCenter()
        let scope = makeScope(messageCenter: center)

        scope.debugLogMessagePresenter.present(.copied)

        XCTAssertTrue(scope.messageCenter === center)
        let message = try XCTUnwrap(center.currentMessage)
        XCTAssertEqual(message.kind, .debugLogsCopied)
        XCTAssertEqual(
            message.kind.presentation,
            AppMessagePresentation(
                style: .success,
                title: "Copied to clipboard",
                detail: nil
            )
        )
    }

    func testNewSettingsCoreUsesConstructorInjectionWithoutMutableConfigure() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "Ito/AppScope.swift",
            "Ito/Services/Settings/SettingsDependencies.swift",
            "Ito/Services/Settings/DebugLogDependencies.swift"
        ]
        let source = try paths.map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")

        XCTAssertFalse(source.contains("func configure("))
    }

    func testAppearanceStartsFromCommittedThemeAndExposesEveryTheme() async throws {
        let (store, _) = try await makeSettingsStore(theme: .light)
        let viewModel = AppearanceSettingsViewModel(settingsStore: store)

        XCTAssertEqual(viewModel.currentTheme, .light)
        XCTAssertEqual(viewModel.availableThemes, AppThemePreference.allCases)
        XCTAssertNil(viewModel.alert)
    }

    func testAppearanceSavesOnceAndPublishesOnlyAfterCommit() async throws {
        let (store, persistence) = try await makeSettingsStore(theme: .light)
        let viewModel = AppearanceSettingsViewModel(settingsStore: store)
        await persistence.suspendNextWriteAttempt()

        let save = Task { await viewModel.selectTheme(.dark) }
        let writeStarted = await boundedTaskYieldWait {
            await persistence.writeStarted
        }
        XCTAssertTrue(writeStarted)
        guard writeStarted else {
            await persistence.resumeWrite()
            await save.value
            return
        }

        XCTAssertEqual(viewModel.currentTheme, .light)
        XCTAssertEqual(store.appTheme, .light)
        await persistence.resumeWrite()
        await save.value

        let writeCallCount = await persistence.writeCallCount
        XCTAssertEqual(writeCallCount, 1)
        XCTAssertEqual(store.appTheme, .dark)
        XCTAssertEqual(viewModel.currentTheme, .dark)
        XCTAssertNil(viewModel.alert)
    }

    func testAppearanceFailureKeepsCommittedThemeAndRetryClearsTypedAlert() async throws {
        let (store, persistence) = try await makeSettingsStore(theme: .light)
        let viewModel = AppearanceSettingsViewModel(settingsStore: store)
        await persistence.failNextWriteAttempt()

        await viewModel.selectTheme(.dark)

        var writeCallCount = await persistence.writeCallCount
        XCTAssertEqual(writeCallCount, 1)
        XCTAssertEqual(store.appTheme, .light)
        XCTAssertEqual(viewModel.currentTheme, .light)
        XCTAssertEqual(viewModel.alert, .saveFailed)

        await viewModel.selectTheme(.dark)

        writeCallCount = await persistence.writeCallCount
        XCTAssertEqual(writeCallCount, 2)
        XCTAssertEqual(store.appTheme, .dark)
        XCTAssertEqual(viewModel.currentTheme, .dark)
        XCTAssertNil(viewModel.alert)
    }

    func testAppearanceModelIdentityIsStableWithinScopeAndNewAcrossScopes() {
        let firstScope = makeScope()
        let secondScope = makeScope()

        XCTAssertFalse(firstScope.rootModels.hasLoadedAppearanceSettingsViewModel)
        _ = firstScope.viewFactory.makeAppearanceSettingsView()
        let first = firstScope.rootModels.appearanceSettingsViewModel
        let repeated = firstScope.rootModels.appearanceSettingsViewModel
        let second = secondScope.rootModels.appearanceSettingsViewModel

        XCTAssertTrue(firstScope.rootModels.hasLoadedAppearanceSettingsViewModel)
        XCTAssertTrue(first === repeated)
        XCTAssertFalse(first === second)
    }

    func testAppearanceViewAndModelHaveNoDirectGlobalsOrEnvironmentLookup() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try [
            "Ito/ViewModels/Settings/AppearanceSettingsViewModel.swift",
            "Ito/Views/Settings/AppearanceSettingsView.swift"
        ].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")

        for forbidden in [
            "UserDefaults.standard",
            "UIApplication.shared",
            "UNUserNotificationCenter.current()",
            "FileManager.default",
            "SnackBarManager.shared",
            "AppLogger",
            "URLSession.shared",
            "@EnvironmentObject",
            "func configure("
        ] {
            XCTAssertFalse(source.contains(forbidden), "Forbidden Appearance access: \(forbidden)")
        }
        XCTAssertTrue(source.contains("@StateObject private var viewModel"))
    }

    func testLibraryStartsFromCommittedPreferencesAndPreservesConditionalChoices() async throws {
        let (store, _, notification, opener) = try await makeLibrarySettingsStore()
        let viewModel = LibrarySettingsViewModel(
            settingsStore: store,
            notificationAuthorization: notification,
            applicationSettingsOpener: opener
        )

        XCTAssertFalse(viewModel.alwaysShowCategoryPicker)
        XCTAssertFalse(viewModel.backgroundUpdatesEnabled)
        XCTAssertTrue(viewModel.updateNotifications)
        XCTAssertEqual(viewModel.updateInterval, .fourHours)
        XCTAssertFalse(viewModel.skipCompleted)
        XCTAssertFalse(viewModel.showsUpdateOptions)
        XCTAssertEqual(
            viewModel.updateIntervals,
            [.hourly, .twoHours, .fourHours, .sixHours, .twelveHours, .daily]
        )

        await viewModel.setBackgroundUpdatesEnabled(true)
        XCTAssertTrue(viewModel.showsUpdateOptions)
    }

    func testLibraryWritesEachOfFivePreferenceKeysExactlyOnce() async throws {
        let (store, persistence, notification, opener) = try await makeLibrarySettingsStore()
        let viewModel = LibrarySettingsViewModel(
            settingsStore: store,
            notificationAuthorization: notification,
            applicationSettingsOpener: opener
        )

        await viewModel.setAlwaysShowCategoryPicker(true)
        await viewModel.setBackgroundUpdatesEnabled(true)
        await viewModel.setUpdateNotifications(false)
        await viewModel.setUpdateInterval(.daily)
        await viewModel.setSkipCompleted(true)

        let history = await persistence.writeHistory
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(
            history.compactMap(\.first).map(\.key),
            [
                AppPreferenceKeys.alwaysShowCategoryPicker,
                AppPreferenceKeys.backgroundUpdatesEnabled,
                AppPreferenceKeys.updateNotifications,
                AppPreferenceKeys.updateInterval,
                AppPreferenceKeys.skipCompleted
            ]
        )
        XCTAssertEqual(notification.requestCallCount, 1)
        XCTAssertTrue(viewModel.alwaysShowCategoryPicker)
        XCTAssertTrue(viewModel.backgroundUpdatesEnabled)
        XCTAssertFalse(viewModel.updateNotifications)
        XCTAssertEqual(viewModel.updateInterval, .daily)
        XCTAssertTrue(viewModel.skipCompleted)
    }

    func testLibraryWriteFailureKeepsCommittedValueAndRetryClearsAlert() async throws {
        let (store, persistence, notification, opener) = try await makeLibrarySettingsStore()
        let viewModel = LibrarySettingsViewModel(
            settingsStore: store,
            notificationAuthorization: notification,
            applicationSettingsOpener: opener
        )
        await persistence.failNextWriteAttempt()

        await viewModel.setAlwaysShowCategoryPicker(true)

        XCTAssertFalse(store.alwaysShowCategoryPicker)
        XCTAssertFalse(viewModel.alwaysShowCategoryPicker)
        XCTAssertEqual(viewModel.alert, .saveFailed)
        var history = await persistence.writeHistory
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.first?.key, AppPreferenceKeys.alwaysShowCategoryPicker)

        await viewModel.setAlwaysShowCategoryPicker(true)

        history = await persistence.writeHistory
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(store.alwaysShowCategoryPicker)
        XCTAssertTrue(viewModel.alwaysShowCategoryPicker)
        XCTAssertNil(viewModel.alert)
    }

    func testLibraryEveryOtherOrdinarySetterRetainsCommittedValueOnWriteFailure() async throws {
        let (store, persistence, notification, opener) = try await makeLibrarySettingsStore()
        let viewModel = LibrarySettingsViewModel(
            settingsStore: store,
            notificationAuthorization: notification,
            applicationSettingsOpener: opener
        )

        await persistence.failNextWriteAttempt()
        await viewModel.setBackgroundUpdatesEnabled(true)
        XCTAssertFalse(store.backgroundUpdatesEnabled)
        XCTAssertFalse(viewModel.backgroundUpdatesEnabled)
        XCTAssertEqual(viewModel.alert, .saveFailed)

        await persistence.failNextWriteAttempt()
        await viewModel.setUpdateInterval(.daily)
        XCTAssertEqual(store.updateInterval, .fourHours)
        XCTAssertEqual(viewModel.updateInterval, .fourHours)
        XCTAssertEqual(viewModel.alert, .saveFailed)

        await persistence.failNextWriteAttempt()
        await viewModel.setSkipCompleted(true)
        XCTAssertFalse(store.skipCompleted)
        XCTAssertFalse(viewModel.skipCompleted)
        XCTAssertEqual(viewModel.alert, .saveFailed)

        let history = await persistence.writeHistory
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(
            history.compactMap(\.first).map(\.key),
            [
                AppPreferenceKeys.backgroundUpdatesEnabled,
                AppPreferenceKeys.updateInterval,
                AppPreferenceKeys.skipCompleted
            ]
        )
    }

    func testLibraryNotificationGrantOccursAfterCommitAndKeepsEnabled() async throws {
        let (store, persistence, notification, opener) = try await makeLibrarySettingsStore(
            updateNotifications: false
        )
        let viewModel = LibrarySettingsViewModel(
            settingsStore: store,
            notificationAuthorization: notification,
            applicationSettingsOpener: opener
        )
        var committedValueObservedAtRequest: Bool?
        notification.onRequest = {
            committedValueObservedAtRequest = store.updateNotifications
        }

        await viewModel.setUpdateNotifications(true)

        let history = await persistence.writeHistory
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(notification.requestCallCount, 1)
        XCTAssertEqual(committedValueObservedAtRequest, true)
        XCTAssertTrue(store.updateNotifications)
        XCTAssertTrue(viewModel.updateNotifications)
        XCTAssertNil(viewModel.alert)
    }

    func testLibraryNotificationDenialRollsBackOnceAndPresentsExistingAlert() async throws {
        let (store, persistence, notification, opener) = try await makeLibrarySettingsStore(
            updateNotifications: false
        )
        notification.result = false
        let viewModel = LibrarySettingsViewModel(
            settingsStore: store,
            notificationAuthorization: notification,
            applicationSettingsOpener: opener
        )

        await viewModel.setUpdateNotifications(true)

        let history = await persistence.writeHistory
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(notification.requestCallCount, 1)
        XCTAssertEqual(
            try history.map { try XCTUnwrap($0.first).decodedValue(
                for: AppPreferenceCatalog.updateNotifications
            ) },
            [true, false]
        )
        XCTAssertFalse(store.updateNotifications)
        XCTAssertFalse(viewModel.updateNotifications)
        XCTAssertEqual(viewModel.alert, .notificationsDisabled)
    }

    func testLibraryNotificationRollbackFailureKeepsAccurateEnabledValue() async throws {
        let (store, persistence, notification, opener) = try await makeLibrarySettingsStore(
            updateNotifications: false
        )
        notification.result = false
        await persistence.failWriteAttempts([2])
        let viewModel = LibrarySettingsViewModel(
            settingsStore: store,
            notificationAuthorization: notification,
            applicationSettingsOpener: opener
        )

        await viewModel.setUpdateNotifications(true)

        let history = await persistence.writeHistory
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(notification.requestCallCount, 1)
        XCTAssertTrue(store.updateNotifications)
        XCTAssertTrue(viewModel.updateNotifications)
        XCTAssertEqual(viewModel.alert, .notificationRollbackFailed)
    }

    func testLibraryDisablingNotificationsDoesNotRequestPermission() async throws {
        let (store, persistence, notification, opener) = try await makeLibrarySettingsStore()
        let viewModel = LibrarySettingsViewModel(
            settingsStore: store,
            notificationAuthorization: notification,
            applicationSettingsOpener: opener
        )

        await viewModel.setUpdateNotifications(false)

        let writeCallCount = await persistence.writeCallCount
        XCTAssertEqual(writeCallCount, 1)
        XCTAssertEqual(notification.requestCallCount, 0)
        XCTAssertFalse(viewModel.updateNotifications)
    }

    func testLibraryNotificationEnablePersistenceFailureDoesNotRequestPermission() async throws {
        let (store, persistence, notification, opener) = try await makeLibrarySettingsStore(
            updateNotifications: false
        )
        let viewModel = LibrarySettingsViewModel(
            settingsStore: store,
            notificationAuthorization: notification,
            applicationSettingsOpener: opener
        )
        await persistence.failNextWriteAttempt()

        await viewModel.setUpdateNotifications(true)

        var history = await persistence.writeHistory
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(
            try history.first?.first?.decodedValue(for: AppPreferenceCatalog.updateNotifications),
            true
        )
        XCTAssertFalse(store.updateNotifications)
        XCTAssertFalse(viewModel.updateNotifications)
        XCTAssertEqual(notification.requestCallCount, 0)
        XCTAssertEqual(viewModel.alert, .saveFailed)

        await viewModel.setUpdateNotifications(true)

        history = await persistence.writeHistory
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(notification.requestCallCount, 1)
        XCTAssertTrue(store.updateNotifications)
        XCTAssertTrue(viewModel.updateNotifications)
        XCTAssertNil(viewModel.alert)
    }

    func testLibraryNotificationMutationsSerializeThroughSuspendedAuthorization() async throws {
        let (store, persistence, notification, opener) = try await makeLibrarySettingsStore(
            updateNotifications: false
        )
        notification.result = false
        notification.suspendNextPermissionRequest()
        let viewModel = LibrarySettingsViewModel(
            settingsStore: store,
            notificationAuthorization: notification,
            applicationSettingsOpener: opener
        )

        let enable = Task { await viewModel.setUpdateNotifications(true) }
        let requestStarted = await boundedTaskYieldWait {
            notification.requestCallCount == 1
        }
        XCTAssertTrue(requestStarted)
        guard requestStarted else {
            notification.resumePermissionRequest()
            await enable.value
            return
        }
        XCTAssertTrue(store.updateNotifications)
        XCTAssertTrue(viewModel.updateNotifications)

        let disable = Task { await viewModel.setUpdateNotifications(false) }
        let disableWroteEarly = await boundedTaskYieldWait {
            await persistence.writeHistory.count > 1
        }
        XCTAssertFalse(disableWroteEarly)
        var history = await persistence.writeHistory
        XCTAssertEqual(history.count, 1, "Queued disable must not write during authorization")

        notification.resumePermissionRequest()
        await enable.value
        await disable.value

        history = await persistence.writeHistory
        XCTAssertEqual(
            try history.map { try XCTUnwrap($0.first).decodedValue(
                for: AppPreferenceCatalog.updateNotifications
            ) },
            [true, false, false]
        )
        XCTAssertEqual(notification.requestCallCount, 1)
        XCTAssertFalse(store.updateNotifications)
        XCTAssertFalse(viewModel.updateNotifications)
        XCTAssertNil(viewModel.alert)
    }

    func testLibraryNotificationAlertCancelAndSettingsOpeningOutcomes() async throws {
        let (store, _, notification, opener) = try await makeLibrarySettingsStore(
            updateNotifications: false
        )
        notification.result = false
        let viewModel = LibrarySettingsViewModel(
            settingsStore: store,
            notificationAuthorization: notification,
            applicationSettingsOpener: opener
        )
        await viewModel.setUpdateNotifications(true)
        XCTAssertEqual(viewModel.alert, .notificationsDisabled)

        viewModel.dismissAlert()
        XCTAssertEqual(opener.openCallCount, 0)
        XCTAssertNil(viewModel.alert)

        opener.result = true
        await viewModel.openApplicationSettings()
        XCTAssertEqual(opener.openCallCount, 1)
        XCTAssertNil(viewModel.alert)

        opener.result = false
        await viewModel.openApplicationSettings()
        XCTAssertEqual(opener.openCallCount, 2)
        XCTAssertEqual(viewModel.alert, .applicationSettingsOpenFailed)
    }

    func testLibraryModelIdentityIsStableWithinScopeAndNewAcrossScopes() {
        let firstScope = makeScope()
        let secondScope = makeScope()

        XCTAssertFalse(firstScope.rootModels.hasLoadedLibrarySettingsViewModel)
        _ = firstScope.viewFactory.makeLibrarySettingsView()
        let first = firstScope.rootModels.librarySettingsViewModel
        let repeated = firstScope.rootModels.librarySettingsViewModel
        let second = secondScope.rootModels.librarySettingsViewModel

        XCTAssertTrue(firstScope.rootModels.hasLoadedLibrarySettingsViewModel)
        XCTAssertTrue(first === repeated)
        XCTAssertFalse(first === second)
    }

    func testLibraryViewAndModelStayWithinPreferencesOnlyBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try [
            "Ito/ViewModels/Settings/LibrarySettingsViewModel.swift",
            "Ito/Views/Settings/LibrarySettingsView.swift"
        ].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")

        for forbidden in [
            "UserDefaults.standard",
            "UIApplication.shared",
            "UNUserNotificationCenter.current()",
            "FileManager.default",
            "SnackBarManager.shared",
            "AppLogger",
            "URLSession.shared",
            "@Environment",
            "configure(",
            "LibraryManager",
            "HistoryManager",
            "RepoManager",
            "PluginManager",
            "UpdateManager"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Forbidden Library access: \(forbidden)")
        }
        XCTAssertTrue(source.contains("@StateObject private var viewModel"))
    }

    func testPrivacyStartsFromCommittedPreferencesAndDiscordManagerState() async throws {
        let (store, _, manager) = try await makePrivacySettingsStore(
            incognitoMode: true,
            discordRPCEnabled: true,
            discordRPCURL: "wss://example.com/socket"
        )
        manager.state = .connecting
        let viewModel = PrivacySettingsViewModel(
            settingsStore: store,
            discordRPCManager: manager
        )

        XCTAssertTrue(viewModel.incognitoMode)
        XCTAssertTrue(viewModel.discordRPCEnabled)
        XCTAssertEqual(viewModel.discordRPCURL, "wss://example.com/socket")
        XCTAssertTrue(viewModel.showsDiscordDetails)
        XCTAssertEqual(viewModel.discordState, .connecting)
        XCTAssertNil(viewModel.alert)
    }

    func testPrivacyWritesEachOfThreePreferenceKeysExactlyOnce() async throws {
        let (store, persistence, manager) = try await makePrivacySettingsStore()
        let viewModel = PrivacySettingsViewModel(
            settingsStore: store,
            discordRPCManager: manager
        )

        await viewModel.setIncognitoMode(true)
        await viewModel.setDiscordRPCEnabled(true)
        viewModel.discordRPCURLDraft = "wss://example.com/socket"
        await viewModel.commitDiscordRPCURLDraft()

        let history = await persistence.writeHistory
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(
            history.compactMap(\.first).map(\.key),
            [
                AppPreferenceKeys.incognitoMode,
                AppPreferenceKeys.discordRPCEnabled,
                AppPreferenceKeys.discordRPCURL
            ]
        )
        XCTAssertTrue(viewModel.incognitoMode)
        XCTAssertTrue(viewModel.discordRPCEnabled)
        XCTAssertEqual(viewModel.discordRPCURL, "wss://example.com/socket")
        XCTAssertNil(viewModel.alert)
    }

    func testPrivacyPublishesOnlyAfterStoreCommit() async throws {
        let (store, persistence, manager) = try await makePrivacySettingsStore()
        let viewModel = PrivacySettingsViewModel(
            settingsStore: store,
            discordRPCManager: manager
        )
        await persistence.suspendNextWriteAttempt()

        let save = Task { await viewModel.setIncognitoMode(true) }
        let writeStarted = await boundedTaskYieldWait {
            await persistence.writeStarted
        }
        XCTAssertTrue(writeStarted)
        guard writeStarted else {
            await persistence.resumeWrite()
            await save.value
            return
        }

        XCTAssertFalse(store.incognitoMode)
        XCTAssertFalse(viewModel.incognitoMode)
        await persistence.resumeWrite()
        await save.value

        let writeCallCount = await persistence.writeCallCount
        XCTAssertEqual(writeCallCount, 1)
        XCTAssertTrue(store.incognitoMode)
        XCTAssertTrue(viewModel.incognitoMode)
    }

    func testPrivacyWriteFailureKeepsCommittedValueAndRetryClearsAlert() async throws {
        let (store, persistence, manager) = try await makePrivacySettingsStore()
        let viewModel = PrivacySettingsViewModel(
            settingsStore: store,
            discordRPCManager: manager
        )
        await persistence.failNextWriteAttempt()

        await viewModel.setDiscordRPCEnabled(true)

        XCTAssertFalse(store.discordRPCEnabled)
        XCTAssertFalse(viewModel.discordRPCEnabled)
        XCTAssertEqual(viewModel.alert, .saveFailed)

        await viewModel.setDiscordRPCEnabled(true)

        let history = await persistence.writeHistory
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(store.discordRPCEnabled)
        XCTAssertTrue(viewModel.discordRPCEnabled)
        XCTAssertNil(viewModel.alert)
    }

    func testPrivacyEverySetterRetainsCommittedValueOnPersistenceFailure() async throws {
        let (store, persistence, manager) = try await makePrivacySettingsStore()
        let viewModel = PrivacySettingsViewModel(
            settingsStore: store,
            discordRPCManager: manager
        )

        await persistence.failNextWriteAttempt()
        await viewModel.setIncognitoMode(true)
        XCTAssertFalse(store.incognitoMode)
        XCTAssertFalse(viewModel.incognitoMode)
        XCTAssertEqual(viewModel.alert, .saveFailed)

        await persistence.failNextWriteAttempt()
        await viewModel.setDiscordRPCEnabled(true)
        XCTAssertFalse(store.discordRPCEnabled)
        XCTAssertFalse(viewModel.discordRPCEnabled)
        XCTAssertEqual(viewModel.alert, .saveFailed)

        await persistence.failNextWriteAttempt()
        viewModel.discordRPCURLDraft = "wss://example.com/socket"
        await viewModel.commitDiscordRPCURLDraft()
        XCTAssertEqual(store.discordRPCURL, "ws://127.0.0.1:3000")
        XCTAssertEqual(viewModel.discordRPCURL, "ws://127.0.0.1:3000")
        XCTAssertEqual(viewModel.discordRPCURLDraft, "wss://example.com/socket")
        XCTAssertEqual(viewModel.alert, .saveFailed)

        let history = await persistence.writeHistory
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(
            history.compactMap(\.first).map(\.key),
            [
                AppPreferenceKeys.incognitoMode,
                AppPreferenceKeys.discordRPCEnabled,
                AppPreferenceKeys.discordRPCURL
            ]
        )
    }

    func testPrivacyInvalidDiscordURLKeepsTypedTextWithoutWritingAndValidRetrySaves() async throws {
        let (store, persistence, manager) = try await makePrivacySettingsStore()
        let viewModel = PrivacySettingsViewModel(
            settingsStore: store,
            discordRPCManager: manager
        )

        viewModel.discordRPCURLDraft = "https://example.com/not-a-websocket"
        await viewModel.commitDiscordRPCURLDraft()

        var history = await persistence.writeHistory
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(store.discordRPCURL, "ws://127.0.0.1:3000")
        XCTAssertEqual(viewModel.discordRPCURL, "ws://127.0.0.1:3000")
        XCTAssertEqual(viewModel.discordRPCURLDraft, "https://example.com/not-a-websocket")
        XCTAssertEqual(viewModel.alert, .invalidDiscordURL)

        viewModel.discordRPCURLDraft = " wss://example.com/socket "
        await viewModel.commitDiscordRPCURLDraft()

        history = await persistence.writeHistory
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(store.discordRPCURL, "wss://example.com/socket")
        XCTAssertEqual(viewModel.discordRPCURL, "wss://example.com/socket")
        XCTAssertEqual(viewModel.discordRPCURLDraft, "wss://example.com/socket")
        XCTAssertNil(viewModel.alert)
    }

    func testPrivacyLeavingWithInvalidDiscordURLResetsFieldWithoutAlert() async throws {
        let (store, persistence, manager) = try await makePrivacySettingsStore()
        let viewModel = PrivacySettingsViewModel(
            settingsStore: store,
            discordRPCManager: manager
        )

        viewModel.discordRPCURLDraft = "ws://"
        await viewModel.commitDiscordRPCURLDraft(discardingInvalid: true)

        let history = await persistence.writeHistory
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(viewModel.discordRPCURLDraft, "ws://127.0.0.1:3000")
        XCTAssertNil(viewModel.alert)
    }

    func testPrivacyForwardsCommittedEnabledAndDiscordStateChanges() async throws {
        let (store, _, manager) = try await makePrivacySettingsStore()
        let viewModel = PrivacySettingsViewModel(
            settingsStore: store,
            discordRPCManager: manager
        )

        try await store.set(true, for: AppPreferenceCatalog.discordRPCEnabled)
        manager.state = .error("fixture")

        XCTAssertTrue(viewModel.discordRPCEnabled)
        XCTAssertTrue(viewModel.showsDiscordDetails)
        XCTAssertEqual(viewModel.discordState, .error("fixture"))
    }

    func testPrivacyModelIdentityIsStableWithinScopeAndNewAcrossScopes() {
        let firstScope = makeScope()
        let secondScope = makeScope()

        XCTAssertFalse(firstScope.rootModels.hasLoadedPrivacySettingsViewModel)
        _ = firstScope.viewFactory.makePrivacySettingsView()
        let first = firstScope.rootModels.privacySettingsViewModel
        let repeated = firstScope.rootModels.privacySettingsViewModel
        let second = secondScope.rootModels.privacySettingsViewModel

        XCTAssertTrue(firstScope.rootModels.hasLoadedPrivacySettingsViewModel)
        XCTAssertTrue(first === repeated)
        XCTAssertFalse(first === second)
    }

    func testPrivacyViewAndModelStayWithinExistingDiscordPresentationBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try [
            "Ito/ViewModels/Settings/PrivacySettingsViewModel.swift",
            "Ito/Views/Settings/PrivacySettingsView.swift"
        ].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")

        for forbidden in [
            "UserDefaults.standard",
            "UIApplication.shared",
            "UNUserNotificationCenter.current()",
            "FileManager.default",
            "SnackBarManager.shared",
            "AppLogger",
            "URLSession.shared",
            "@Environment",
            "configure(",
            "NotificationAuthorizationRequesting",
            "ApplicationSettingsOpening",
            "LibraryManager",
            "HistoryManager",
            "TrackerManager",
            "RepoManager",
            "PluginManager"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Forbidden Privacy access: \(forbidden)")
        }
        XCTAssertTrue(source.contains("@StateObject private var viewModel"))
        XCTAssertTrue(source.contains("DiscordRPCManager"))
        XCTAssertTrue(source.contains("Connecting..."))
        XCTAssertTrue(source.contains("Error: "))
    }

    func testStorageStartsFromCommittedLimitAndExposesExactChoices() async throws {
        let (store, _, storageAccess) = try await makeStorageSettingsStore(limit: 12)
        storageAccess.currentCacheSizeBytes = 512
        let viewModel = StorageSettingsViewModel(
            settingsStore: store,
            storageAccess: storageAccess
        )

        XCTAssertEqual(viewModel.diskCacheLimitGB, 12)
        XCTAssertEqual(viewModel.cacheLimitChoices, (1...50).map(Double.init))
        XCTAssertEqual(viewModel.formattedCurrentUsage, "bytes:512")
        XCTAssertEqual(storageAccess.formattedBytes, [512])
        XCTAssertNil(viewModel.alert)
    }

    func testStorageSavesOnceAndPublishesOnlyAfterCommit() async throws {
        let (store, persistence, storageAccess) = try await makeStorageSettingsStore()
        let viewModel = StorageSettingsViewModel(
            settingsStore: store,
            storageAccess: storageAccess
        )
        await persistence.suspendNextWriteAttempt()

        let save = Task { await viewModel.setDiskCacheLimitGB(25) }
        let writeStarted = await boundedTaskYieldWait {
            await persistence.writeStarted
        }
        XCTAssertTrue(writeStarted)
        guard writeStarted else {
            await persistence.resumeWrite()
            await save.value
            return
        }

        XCTAssertEqual(store.diskCacheLimitGB, 10)
        XCTAssertEqual(viewModel.diskCacheLimitGB, 10)
        await persistence.resumeWrite()
        await save.value

        let history = await persistence.writeHistory
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.compactMap(\.first).map(\.key), [AppPreferenceKeys.diskCacheLimitGB])
        XCTAssertEqual(store.diskCacheLimitGB, 25)
        XCTAssertEqual(viewModel.diskCacheLimitGB, 25)
        XCTAssertNil(viewModel.alert)
    }

    func testStorageFailuresKeepCommittedLimitAndRetryClearsAlert() async throws {
        let (store, persistence, storageAccess) = try await makeStorageSettingsStore()
        let viewModel = StorageSettingsViewModel(
            settingsStore: store,
            storageAccess: storageAccess
        )
        await persistence.failNextWriteAttempt()

        await viewModel.setDiskCacheLimitGB(25)

        XCTAssertEqual(store.diskCacheLimitGB, 10)
        XCTAssertEqual(viewModel.diskCacheLimitGB, 10)
        XCTAssertEqual(viewModel.alert, .saveFailed)

        await viewModel.setDiskCacheLimitGB(25)

        var history = await persistence.writeHistory
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(store.diskCacheLimitGB, 25)
        XCTAssertEqual(viewModel.diskCacheLimitGB, 25)
        XCTAssertNil(viewModel.alert)

        await viewModel.setDiskCacheLimitGB(2.5)

        history = await persistence.writeHistory
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(store.diskCacheLimitGB, 25)
        XCTAssertEqual(viewModel.diskCacheLimitGB, 25)
        XCTAssertEqual(viewModel.alert, .saveFailed)
    }

    func testStorageShowsCalculatingUntilFirstMeasurementThenFormattedUsage() async throws {
        let (store, _, storageAccess) = try await makeStorageSettingsStore()
        storageAccess.cacheSizeAfterRefresh = 2_048
        let viewModel = StorageSettingsViewModel(
            settingsStore: store,
            storageAccess: storageAccess
        )
        XCTAssertEqual(viewModel.formattedCurrentUsage, "Calculating…")

        await viewModel.refreshCacheUsage()

        XCTAssertEqual(storageAccess.refreshCallCount, 1)
        XCTAssertEqual(storageAccess.clearCallCount, 0)
        XCTAssertEqual(storageAccess.formattedBytes, [2_048])
        XCTAssertEqual(viewModel.formattedCurrentUsage, "bytes:2048")
    }

    func testStorageClearRunsOnceAndUsesUpdatedSizeWithoutExtraRefreshOrMessage() async throws {
        let (store, _, storageAccess) = try await makeStorageSettingsStore()
        storageAccess.currentCacheSizeBytes = 4_096
        storageAccess.cacheSizeAfterClear = 0
        let viewModel = StorageSettingsViewModel(
            settingsStore: store,
            storageAccess: storageAccess
        )

        await viewModel.clearCache()

        XCTAssertEqual(storageAccess.clearCallCount, 1)
        XCTAssertEqual(storageAccess.refreshCallCount, 0)
        XCTAssertEqual(storageAccess.formattedBytes, [4_096, 0])
        XCTAssertEqual(viewModel.formattedCurrentUsage, "bytes:0")
        XCTAssertNil(viewModel.alert)
    }

    func testStorageModelIdentityIsStableWithinScopeAndNewAcrossScopes() {
        let firstScope = makeScope()
        let secondScope = makeScope()

        XCTAssertFalse(firstScope.rootModels.hasLoadedStorageSettingsViewModel)
        _ = firstScope.viewFactory.makeStorageSettingsView()
        let first = firstScope.rootModels.storageSettingsViewModel
        let repeated = firstScope.rootModels.storageSettingsViewModel
        let second = secondScope.rootModels.storageSettingsViewModel

        XCTAssertTrue(firstScope.rootModels.hasLoadedStorageSettingsViewModel)
        XCTAssertTrue(first === repeated)
        XCTAssertFalse(first === second)
    }

    func testStorageViewAndModelStayWithinExistingCacheBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try [
            "Ito/ViewModels/Settings/StorageSettingsViewModel.swift",
            "Ito/Views/Settings/StorageSettingsView.swift"
        ].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")

        for forbidden in [
            "UserDefaults.standard",
            "UIApplication.shared",
            "UNUserNotificationCenter.current()",
            "FileManager.default",
            "SnackBarManager.shared",
            "AppLogger",
            "URLSession.shared",
            "@Environment",
            "configure(",
            "StorageManager",
            "Nuke",
            "URLCache",
            "AppMessageCenter",
            "DebugLogMessagePresenting"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Forbidden Storage access: \(forbidden)")
        }
        XCTAssertTrue(source.contains("@StateObject private var viewModel"))
    }

    private func makeSettingsStore(
        theme: AppThemePreference
    ) async throws -> (AppSettingsStore, TestAppSettingsPersistence) {
        let preference = try AppPreference(key: AppPreferenceCatalog.appTheme, value: theme)
        let persistence = TestAppSettingsPersistence(preferences: [preference])
        let store = AppSettingsStore(persistence: persistence)
        try await store.reload()
        await persistence.resetWriteTracking()
        return (store, persistence)
    }

    func makeLibrarySettingsStore(
        updateNotifications: Bool = true
    ) async throws -> (
        AppSettingsStore,
        TestAppSettingsPersistence,
        TestNotificationAuthorization,
        TestApplicationSettingsOpener
    ) {
        let preferences = [
            try AppPreference(
                key: AppPreferenceCatalog.alwaysShowCategoryPicker,
                value: false
            ),
            try AppPreference(
                key: AppPreferenceCatalog.backgroundUpdatesEnabled,
                value: false
            ),
            try AppPreference(
                key: AppPreferenceCatalog.updateNotifications,
                value: updateNotifications
            ),
            try AppPreference(
                key: AppPreferenceCatalog.updateInterval,
                value: UpdateIntervalPreference.fourHours
            ),
            try AppPreference(key: AppPreferenceCatalog.skipCompleted, value: false),
            try AppPreference(key: AppPreferenceCatalog.wifiOnlyUpdates, value: false)
        ]
        let persistence = TestAppSettingsPersistence(preferences: preferences)
        let store = AppSettingsStore(persistence: persistence)
        try await store.reload()
        await persistence.resetWriteTracking()
        return (
            store,
            persistence,
            TestNotificationAuthorization(),
            TestApplicationSettingsOpener()
        )
    }

    private func makePrivacySettingsStore(
        incognitoMode: Bool = false,
        discordRPCEnabled: Bool = false,
        discordRPCURL: String = "ws://127.0.0.1:3000"
    ) async throws -> (
        AppSettingsStore,
        TestAppSettingsPersistence,
        DiscordRPCManager
    ) {
        let preferences = [
            try AppPreference(
                key: AppPreferenceCatalog.incognitoMode,
                value: incognitoMode
            ),
            try AppPreference(
                key: AppPreferenceCatalog.discordRPCEnabled,
                value: discordRPCEnabled
            ),
            try AppPreference(
                key: AppPreferenceCatalog.discordRPCURL,
                value: discordRPCURL
            )
        ]
        let persistence = TestAppSettingsPersistence(preferences: preferences)
        let store = AppSettingsStore(persistence: persistence)
        try await store.reload()
        await persistence.resetWriteTracking()
        return (store, persistence, makeTestDiscordRPCManager())
    }

    private func makeStorageSettingsStore(
        limit: Double = 10
    ) async throws -> (
        AppSettingsStore,
        TestAppSettingsPersistence,
        TestSettingsStorageAccess
    ) {
        let preference = try AppPreference(
            key: AppPreferenceCatalog.diskCacheLimitGB,
            value: limit
        )
        let persistence = TestAppSettingsPersistence(preferences: [preference])
        let store = AppSettingsStore(persistence: persistence)
        try await store.reload()
        await persistence.resetWriteTracking()
        return (store, persistence, TestSettingsStorageAccess())
    }

    private func makeScope(
        settings: PreparedSettingsDependencies = makeTestPreparedSettingsDependencies(),
        messageCenter: AppMessageCenter = AppMessageCenter()
    ) -> AppScope {
        AppScope(
            preparedDependencies: PreparedApplicationDependencies(
                settings: settings,
                searchExecutor: SettingsTestSearchExecutor(),
                recentSearchStore: SettingsTestRecentStore(),
                searchDebounceMilliseconds: nil,
                presentationLogger: PresentationEventCaptureSpy(),
                browseRepositoryManager: SettingsTestRepositoryManager(),
                repositoryManagement: makeTestRepositoryManagementDependencies(),
                browsePluginManager: SettingsTestPluginManager(),
                browseFileOperations: SettingsTestFileOperations()
            ),
            messageCenter: messageCenter
        )
    }
}

@MainActor
private final class SettingsTestSearchExecutor: SearchPluginExecuting {
    let plugins: [SearchPluginDescriptor] = []

    func search(
        plugin: SearchPluginDescriptor,
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult] {
        _ = plugin
        _ = query
        _ = limit
        return []
    }

    func evictRunner(for pluginID: String) {
        _ = pluginID
    }
}

@MainActor
private final class SettingsTestRecentStore: RecentSearchPersisting {
    func load() -> [String] { [] }
    func save(_ searches: [String]) { _ = searches }
    func clear() {}
}

@MainActor
private final class SettingsTestRepositoryManager: BrowseRepositoryManaging {
    let repositories: [Repository] = []
    var repositoriesPublisher: AnyPublisher<[Repository], Never> {
        Just(repositories).eraseToAnyPublisher()
    }

    func addRepository(url: String) async throws -> RepositoryAdditionResult {
        _ = url
        return .added
    }

    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws {
        _ = package
        _ = repositoryURL
    }

    func refreshAll() async {}
}

@MainActor
private final class SettingsTestPluginManager: BrowsePluginManaging {
    let installedPlugins: [String: InstalledPlugin] = [:]
    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        Just(installedPlugins).eraseToAnyPublisher()
    }

    func reloadInstalledPlugins() async {}
    func removeSecrets(for pluginID: String) {}
}

@MainActor
private final class SettingsTestFileOperations: BrowsePluginFileOperating {
    func supportsPluginFile(at url: URL) -> Bool { _ = url; return false }
    func installPluginFile(from url: URL) throws { _ = url }
    func deletePluginFile(at url: URL) throws { _ = url }
}
