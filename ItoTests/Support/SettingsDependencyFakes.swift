import Foundation
import XCTest
@testable import Ito

func boundedTaskYieldWait(
    maximumAttempts: Int = 1_000,
    condition: () async -> Bool
) async -> Bool {
    for _ in 0..<maximumAttempts {
        if await condition() {
            return true
        }
        await Task.yield()
    }
    return false
}

actor TestAppSettingsPersistence: AppSettingsPersistence {
    private var preferences: [AppPreference]
    private var failNextWrite = false
    private var failingWriteCallNumbers: Set<Int> = []
    private var suspendNextWrite = false
    private var writeContinuation: CheckedContinuation<Void, Never>?
    private(set) var writeCallCount = 0
    private(set) var writeStarted = false
    private(set) var writeHistory: [[AppPreference]] = []

    init(preferences: [AppPreference] = []) {
        self.preferences = preferences
    }

    func readPreferences() async throws -> [AppPreference] {
        preferences
    }

    func writePreferences(_ preferences: [AppPreference]) async throws -> [AppPreference] {
        writeCallCount += 1
        writeStarted = true
        writeHistory.append(preferences)
        if failNextWrite || failingWriteCallNumbers.remove(writeCallCount) != nil {
            failNextWrite = false
            throw TestSettingsPersistenceError.writeFailed
        }
        if suspendNextWrite {
            suspendNextWrite = false
            await withCheckedContinuation { continuation in
                writeContinuation = continuation
            }
        }
        let replacements = Dictionary(
            preferences.map { ($0.key, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        self.preferences.removeAll { replacements[$0.key] != nil }
        self.preferences.append(contentsOf: preferences)
        return self.preferences
    }

    func failNextWriteAttempt() {
        failNextWrite = true
    }

    func suspendNextWriteAttempt() {
        suspendNextWrite = true
    }

    func failWriteAttempts(_ callNumbers: Set<Int>) {
        failingWriteCallNumbers = callNumbers
    }

    func resumeWrite() {
        writeContinuation?.resume()
        writeContinuation = nil
    }

    func resetWriteTracking() {
        writeCallCount = 0
        writeStarted = false
        writeHistory = []
        failingWriteCallNumbers = []
    }

    func replacePreferencesForRestore(_ preferences: [AppPreference]) {
        self.preferences = preferences
    }
}

enum TestSettingsPersistenceError: Error {
    case writeFailed
}

@MainActor
final class TestNotificationAuthorization: NotificationAuthorizationRequesting {
    var result = true
    var onRequest: (() -> Void)?
    private(set) var requestCallCount = 0
    private var suspendNextRequest = false
    private var requestContinuation: CheckedContinuation<Void, Never>?

    func requestPermission() async -> Bool {
        requestCallCount += 1
        onRequest?()
        if suspendNextRequest {
            suspendNextRequest = false
            await withCheckedContinuation { continuation in
                requestContinuation = continuation
            }
        }
        return result
    }

    func suspendNextPermissionRequest() {
        suspendNextRequest = true
    }

    func resumePermissionRequest() {
        requestContinuation?.resume()
        requestContinuation = nil
    }
}

@MainActor
final class TestApplicationSettingsOpener: ApplicationSettingsOpening {
    var result = true
    private(set) var openCallCount = 0

    func openApplicationSettings() async -> Bool {
        openCallCount += 1
        return result
    }
}

@MainActor
final class TestSettingsStorageAccess: SettingsStorageAccessing {
    var currentCacheSizeBytes = 0
    var cacheSizeAfterRefresh: Int?
    var cacheSizeAfterClear: Int?
    private(set) var refreshCallCount = 0
    private(set) var clearCallCount = 0
    private(set) var formattedBytes: [Int] = []

    func refreshCacheSize() {
        refreshCallCount += 1
        if let cacheSizeAfterRefresh {
            currentCacheSizeBytes = cacheSizeAfterRefresh
        }
    }

    func clearCache() {
        clearCallCount += 1
        if let cacheSizeAfterClear {
            currentCacheSizeBytes = cacheSizeAfterClear
        }
    }

    func formatBytes(_ bytes: Int) -> String {
        formattedBytes.append(bytes)
        return "bytes:\(bytes)"
    }
}

actor TestDebugLogReader: DebugLogReading {
    var entries: [DebugLogEntry]
    private(set) var requests: [(lookback: TimeInterval, allowedSubsystems: Set<String>)] = []

    init(entries: [DebugLogEntry] = []) {
        self.entries = entries
    }

    func readEntries(
        lookback: TimeInterval,
        allowedSubsystems: Set<String>
    ) async throws -> [DebugLogEntry] {
        requests.append((lookback, allowedSubsystems))
        return entries
    }
}

@MainActor
final class TestClipboardWriter: ClipboardWriting {
    private(set) var writtenTexts: [String] = []

    func write(_ text: String) throws {
        writtenTexts.append(text)
    }
}

@MainActor
final class TestSiteDataClearer: SiteDataClearing {
    private(set) var clearCallCount = 0
    var shouldThrow = false

    func clearSiteData() async throws {
        clearCallCount += 1
        if shouldThrow {
            throw URLError(.cannotRemoveFile)
        }
    }
}

@MainActor
struct TestPreparedSettingsDependencyBundle {
    let settingsStore: AppSettingsStore
    let notificationAuthorization: TestNotificationAuthorization
    let applicationSettingsOpener: TestApplicationSettingsOpener
    let storageAccess: TestSettingsStorageAccess
    let discordRPCManager: DiscordRPCManager
    let logReader: TestDebugLogReader
    let clipboardWriter: TestClipboardWriter
    let siteDataClearer: TestSiteDataClearer

    init(
        settingsStore: AppSettingsStore = AppSettingsStore(
            persistence: TestAppSettingsPersistence()
        ),
        notificationAuthorization: TestNotificationAuthorization = TestNotificationAuthorization(),
        applicationSettingsOpener: TestApplicationSettingsOpener = TestApplicationSettingsOpener(),
        storageAccess: TestSettingsStorageAccess = TestSettingsStorageAccess(),
        discordRPCManager: DiscordRPCManager = SharedSettingsTestRuntime.discordRPCManager,
        logReader: TestDebugLogReader = TestDebugLogReader(),
        clipboardWriter: TestClipboardWriter = TestClipboardWriter(),
        siteDataClearer: TestSiteDataClearer = TestSiteDataClearer()
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

    var dependencies: PreparedSettingsDependencies {
        PreparedSettingsDependencies(
            settingsStore: settingsStore,
            notificationAuthorization: notificationAuthorization,
            applicationSettingsOpener: applicationSettingsOpener,
            storageAccess: storageAccess,
            discordRPCManager: discordRPCManager,
            logReader: logReader,
            clipboardWriter: clipboardWriter,
            siteDataClearer: siteDataClearer
        )
    }
}

@MainActor
func makeTestPreparedSettingsDependencies() -> PreparedSettingsDependencies {
    TestPreparedSettingsDependencyBundle().dependencies
}

@MainActor
func makeTestDiscordRPCManager() -> DiscordRPCManager {
    DiscordRPCManager(libraryManager: SharedSettingsTestRuntime.libraryManager)
}

@MainActor
func verifyLiveSettingsRestorePropagation(
    makeScope: (PreparedSettingsDependencies, AppMessageCenter) -> AppScope
) async throws {
    let persistence = TestAppSettingsPersistence(preferences: [
        try AppPreference(key: AppPreferenceCatalog.updateNotifications, value: false)
    ])
    let store = AppSettingsStore(persistence: persistence)
    try await store.reloadAfterRestore()
    XCTAssertFalse(store.updateNotifications)
    await persistence.resetWriteTracking()

    let notification = TestNotificationAuthorization()
    let opener = TestApplicationSettingsOpener()
    let storage = TestSettingsStorageAccess()
    let discord = makeTestDiscordRPCManager()
    discord.state = .error("restore-sentinel")
    let logReader = TestDebugLogReader()
    let clipboard = TestClipboardWriter()
    let messageCenter = AppMessageCenter()
    let bundle = TestPreparedSettingsDependencyBundle(
        settingsStore: store,
        notificationAuthorization: notification,
        applicationSettingsOpener: opener,
        storageAccess: storage,
        discordRPCManager: discord,
        logReader: logReader,
        clipboardWriter: clipboard
    )
    let scope = makeScope(bundle.dependencies, messageCenter)
    XCTAssertTrue(bundle.settingsStore === store)
    XCTAssertTrue(scope.messageCenter === messageCenter)
    let appearance = scope.rootModels.appearanceSettingsViewModel
    let library = scope.rootModels.librarySettingsViewModel
    let privacy = scope.rootModels.privacySettingsViewModel
    let storageViewModel = scope.rootModels.storageSettingsViewModel
    let network = scope.rootModels.networkSettingsViewModel

    XCTAssertTrue(scope.rootModels.appearanceSettingsViewModel === appearance)
    XCTAssertTrue(scope.rootModels.librarySettingsViewModel === library)
    XCTAssertTrue(scope.rootModels.privacySettingsViewModel === privacy)
    XCTAssertTrue(scope.rootModels.storageSettingsViewModel === storageViewModel)
    XCTAssertTrue(scope.rootModels.networkSettingsViewModel === network)
    XCTAssertEqual(appearance.currentTheme, .system)
    XCTAssertFalse(library.alwaysShowCategoryPicker)
    XCTAssertFalse(library.backgroundUpdatesEnabled)
    XCTAssertFalse(library.updateNotifications)
    XCTAssertEqual(library.updateInterval, .fourHours)
    XCTAssertFalse(library.skipCompleted)
    XCTAssertFalse(privacy.incognitoMode)
    XCTAssertFalse(privacy.discordRPCEnabled)
    XCTAssertEqual(privacy.discordRPCURL, "ws://127.0.0.1:3000")
    XCTAssertFalse(network.wifiOnlyUpdates)
    XCTAssertEqual(storageViewModel.diskCacheLimitGB, 10)

    await persistence.replacePreferencesForRestore([
        try AppPreference(key: AppPreferenceCatalog.appTheme, value: AppThemePreference.dark),
        try AppPreference(key: AppPreferenceCatalog.alwaysShowCategoryPicker, value: true),
        try AppPreference(key: AppPreferenceCatalog.backgroundUpdatesEnabled, value: true),
        try AppPreference(key: AppPreferenceCatalog.updateNotifications, value: true),
        try AppPreference(key: AppPreferenceCatalog.updateInterval, value: UpdateIntervalPreference.daily),
        try AppPreference(key: AppPreferenceCatalog.skipCompleted, value: true),
        try AppPreference(key: AppPreferenceCatalog.wifiOnlyUpdates, value: true),
        try AppPreference(key: AppPreferenceCatalog.incognitoMode, value: true),
        try AppPreference(key: AppPreferenceCatalog.discordRPCEnabled, value: true),
        try AppPreference(key: AppPreferenceCatalog.discordRPCURL, value: "wss://restore.example/socket"),
        try AppPreference(key: AppPreferenceCatalog.diskCacheLimitGB, value: 25.0)
    ])

    try await store.reloadAfterRestore()

    XCTAssertEqual(appearance.currentTheme, .dark)
    XCTAssertTrue(library.alwaysShowCategoryPicker)
    XCTAssertTrue(library.backgroundUpdatesEnabled)
    XCTAssertTrue(library.updateNotifications)
    XCTAssertEqual(library.updateInterval, .daily)
    XCTAssertTrue(privacy.incognitoMode)
    XCTAssertTrue(privacy.discordRPCEnabled)
    XCTAssertTrue(network.wifiOnlyUpdates)
    XCTAssertEqual(privacy.discordRPCURL, "wss://restore.example/socket")
    XCTAssertEqual(storageViewModel.diskCacheLimitGB, 25)

    let writeCallCount = await persistence.writeCallCount
    XCTAssertEqual(writeCallCount, 0)
    XCTAssertEqual(notification.requestCallCount, 0)
    XCTAssertEqual(opener.openCallCount, 0)
    XCTAssertEqual(storage.refreshCallCount, 0)
    XCTAssertEqual(storage.clearCallCount, 0)
    XCTAssertEqual(discord.state, .error("restore-sentinel"))
    XCTAssertTrue(clipboard.writtenTexts.isEmpty)
    let logRequests = await logReader.requests
    XCTAssertTrue(logRequests.isEmpty)
    XCTAssertNil(scope.messageCenter.currentMessage)
    XCTAssertNil(appearance.alert)
    XCTAssertNil(library.alert)
    XCTAssertNil(privacy.alert)
    XCTAssertNil(network.alert)
    XCTAssertNil(storageViewModel.alert)
}

@MainActor
private enum SharedSettingsTestRuntime {
    static let database: TestDatabase = {
        do {
            return try TestDatabase()
        } catch {
            fatalError("Failed to create Settings test database: \(error)")
        }
    }()
    static let libraryManager = LibraryManager(dbPool: database.dbPool)
    static let discordRPCManager = DiscordRPCManager(libraryManager: libraryManager)
}

nonisolated enum DebugLogReaderError: Error {
    case failed
}

nonisolated struct DebugLogRequest: Equatable, Sendable {
    let lookback: TimeInterval
    let allowedSubsystems: Set<String>
}

actor ImmediateDebugLogReader: DebugLogReading {
    nonisolated enum Response: Sendable {
        case success([DebugLogEntry])
        case failure
    }

    private var responses: [Response]
    private(set) var requests: [DebugLogRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func readEntries(
        lookback: TimeInterval,
        allowedSubsystems: Set<String>
    ) async throws -> [DebugLogEntry] {
        requests.append(DebugLogRequest(
            lookback: lookback,
            allowedSubsystems: allowedSubsystems
        ))
        guard !responses.isEmpty else { throw DebugLogReaderError.failed }
        switch responses.removeFirst() {
        case .success(let entries):
            return entries
        case .failure:
            throw DebugLogReaderError.failed
        }
    }
}

actor ControlledDebugLogReader: DebugLogReading {
    private(set) var requests: [DebugLogRequest] = []
    private var requestContinuations: [Int: CheckedContinuation<[DebugLogEntry], any Error>] = [:]

    func readEntries(
        lookback: TimeInterval,
        allowedSubsystems: Set<String>
    ) async throws -> [DebugLogEntry] {
        let index = requests.count
        requests.append(DebugLogRequest(
            lookback: lookback,
            allowedSubsystems: allowedSubsystems
        ))
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            requestContinuations[index] = continuation
        }
    }

    func succeedRequest(at index: Int, entries: [DebugLogEntry]) {
        guard let continuation = requestContinuations.removeValue(forKey: index) else {
            return
        }
        continuation.resume(returning: entries)
    }

    func failRequest(at index: Int) {
        guard let continuation = requestContinuations.removeValue(forKey: index) else {
            return
        }
        continuation.resume(throwing: DebugLogReaderError.failed)
    }

    func failAllPendingRequests() {
        let continuations = requestContinuations.values
        requestContinuations.removeAll()
        continuations.forEach { $0.resume(throwing: DebugLogReaderError.failed) }
    }
}
