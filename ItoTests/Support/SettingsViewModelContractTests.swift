import XCTest
@testable import Ito

@MainActor
extension SettingsViewModelTests {
    func testMigratedSettingsSourcesUseNoGlobalsEnvironmentOrConfigure() throws {
        let migratedPaths = [
            "Ito/AppScope.swift",
            "Ito/Views/MainTabView.swift",
            "Ito/Views/Settings/SettingsView.swift",
            "Ito/Services/BackupSettings/BackupSettingsDependencies.swift",
            "Ito/ViewModels/BackupSettingsViewModel.swift",
            "Ito/ViewModels/Settings/AppearanceSettingsViewModel.swift",
            "Ito/ViewModels/Settings/LibrarySettingsViewModel.swift",
            "Ito/ViewModels/Settings/PrivacySettingsViewModel.swift",
            "Ito/ViewModels/Settings/StorageSettingsViewModel.swift",
            "Ito/ViewModels/Settings/NetworkSettingsViewModel.swift",
            "Ito/ViewModels/Settings/DebugLogViewModel.swift",
            "Ito/Views/Settings/BackupSettingsView.swift",
            "Ito/Views/Settings/AppearanceSettingsView.swift",
            "Ito/Views/Settings/LibrarySettingsView.swift",
            "Ito/Views/Settings/PrivacySettingsView.swift",
            "Ito/Views/Settings/StorageSettingsView.swift",
            "Ito/Views/Settings/NetworkSettingsView.swift",
            "Ito/Views/Settings/DebugLogView.swift"
        ]
        var migratedSources = try migratedPaths.map { try source(at: $0) }
        let routeFactorySource = try source(
            at: "Ito/Views/Search/SearchRouteFactory.swift"
        )
        migratedSources.append(try XCTUnwrap(
            routeFactorySource.components(separatedBy: "struct SearchRouteFactory").first
        ))

        for forbidden in [
            "UserDefaults.standard",
            "UIApplication.shared",
            "UNUserNotificationCenter.current()",
            "FileManager.default",
            "SnackBarManager.shared",
            "AppLogger",
            "URLSession.shared",
            "UIPasteboard.general",
            "@EnvironmentObject",
            "configure("
        ] {
            for (path, source) in zip(migratedPaths + ["AppViewFactory"], migratedSources) {
                XCTAssertFalse(source.contains(forbidden), "Forbidden \(forbidden) in \(path)")
            }
        }

        let settingsAdapter = try source(
            at: "Ito/Services/Settings/SettingsDependencies.swift"
        )
        XCTAssertTrue(settingsAdapter.contains("UIApplication.shared"))
        XCTAssertTrue(settingsAdapter.contains("UIPasteboard.general"))
        XCTAssertTrue(settingsAdapter.contains(
            "extension NotificationManager: NotificationAuthorizationRequesting {}"
        ))
    }

    func testAppearancePresentationContracts() throws {
        let appearanceSource = try source(at: "Ito/Views/Settings/AppearanceSettingsView.swift")

        XCTAssertTrue(appearanceSource.contains(
            "Section(header: Text(\"Theme\"), footer: Text(\"Choose your preferred appearance.\"))"
        ))
        XCTAssertTrue(appearanceSource.contains("Picker(\"Appearance\", selection:"))
        XCTAssertTrue(appearanceSource.contains(".pickerStyle(SegmentedPickerStyle())"))
        XCTAssertTrue(appearanceSource.contains(".navigationTitle(\"Appearance\")"))
    }

    func testBootstrapReusesRuntimeSettingsDependencyIdentities() throws {
        let source = try source(at: "Ito/Managers/DurableStateBootstrap.swift")
        let installStart = try XCTUnwrap(source.range(of: "private func install(_ runtime: Runtime)"))
        let installEnd = try XCTUnwrap(source.range(
            of: "    private func clearRuntime()",
            range: installStart.upperBound..<source.endIndex
        ))
        let install = String(source[installStart.lowerBound..<installEnd.lowerBound])

        for argument in [
            "settingsStore: runtime.settingsStore",
            "notificationManager: runtime.notificationManager",
            "storageManager: runtime.storageManager",
            "discordRPCManager: runtime.discordRPCManager"
        ] {
            XCTAssertTrue(install.contains(argument), "Missing runtime identity: \(argument)")
        }
        XCTAssertTrue(install.contains("appScope = AppScope.prepared("))
        XCTAssertFalse(install.contains("AppSettingsStore("))
        XCTAssertFalse(install.contains("NotificationManager("))
        XCTAssertFalse(install.contains("StorageManager("))
        XCTAssertFalse(install.contains("DiscordRPCManager("))
    }

    func testSystemDebugLogAdapterPreservesScopeFilterAndDomainConversion() throws {
        let source = try source(at: "Ito/Services/Settings/DebugLogDependencies.swift")

        XCTAssertTrue(source.contains("OSLogStore(scope: .currentProcessIdentifier)"))
        XCTAssertTrue(source.contains("allowedSubsystems.contains(log.subsystem)"))
        XCTAssertTrue(source.contains("return DebugLogEntry("))
        XCTAssertTrue(source.contains("subsystem: log.subsystem"))
        XCTAssertTrue(source.contains("category: log.category"))
        XCTAssertTrue(source.contains("message: log.composedMessage"))
        for mapping in [
            "case .fault:\n            return .fault",
            "case .error:\n            return .error",
            "case .info:\n            return .info",
            "case .notice:\n            return .notice",
            "case .debug:\n            return .debug",
            "default:\n            return .other"
        ] {
            XCTAssertTrue(source.contains(mapping), "Missing log conversion: \(mapping)")
        }
    }

    func testSettingsRouteContractPreservesLegacyAndExcludedBoundaries() throws {
        let settingsSource = try source(at: "Ito/Views/Settings/SettingsView.swift")
        let routeFactorySource = try source(
            at: "Ito/Views/Search/SearchRouteFactory.swift"
        )
        let appFactorySource = try XCTUnwrap(
            routeFactorySource.components(separatedBy: "struct SearchRouteFactory").first
        )
        let enumSource = try XCTUnwrap(
            settingsSource.components(separatedBy: "struct SettingsView").first
        )

        XCTAssertTrue(settingsSource.contains(
            "destination: viewFactory.makeSettingsDestination(for: .trackers)"
        ))
        XCTAssertTrue(settingsSource.contains(
            "destination: viewFactory.makeSettingsDestination(for: .backup)"
        ))
        XCTAssertTrue(settingsSource.contains("NavigationView"))
        XCTAssertTrue(settingsSource.contains("NavigationLink"))
        XCTAssertFalse(settingsSource.contains("NavigationStack"))
        XCTAssertFalse(appFactorySource.contains("AnyView"))
        XCTAssertFalse(appFactorySource.contains("ReaderSettingsView("))
        XCTAssertFalse(appFactorySource.contains("ManageExtensionsView("))

        for excludedCase in [
            "repository",
            "source",
            "plugin",
            "listing",
            "migrationReport",
            "discoverDetail",
            "mediaDetail",
            "libraryRoot",
            "libraryCategory",
            "libraryHistory"
        ] {
            XCTAssertFalse(enumSource.localizedCaseInsensitiveContains("case \(excludedCase)"))
        }
    }

    private func source(at path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
