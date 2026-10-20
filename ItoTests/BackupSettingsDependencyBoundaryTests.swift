import Foundation
import XCTest
@testable import Ito

final class BackupSettingsDependencyBoundaryTests: XCTestCase {
    func testViewOwnsViewModelAndKeepsPlatformFilePresentation() throws {
        let source = try read("Ito/Views/Settings/BackupSettingsView.swift")

        XCTAssertTrue(source.contains("@StateObject private var viewModel"))
        XCTAssertTrue(source.contains(".fileImporter("))
        XCTAssertTrue(source.contains(".fileExporter("))
        XCTAssertTrue(source.contains("BackupDocument"))
        XCTAssertTrue(source.contains("UniformTypeIdentifiers"))
        XCTAssertFalse(source.contains("@EnvironmentObject"))
        XCTAssertFalse(source.contains("BackupManager"))
        XCTAssertFalse(source.contains("AppLogger"))
    }

    func testViewModelUsesNarrowInjectedBoundaryWithoutBusinessGlobals() throws {
        let source = try read("Ito/ViewModels/BackupSettingsViewModel.swift")

        XCTAssertTrue(source.contains("final class BackupSettingsViewModel: ObservableObject"))
        XCTAssertTrue(source.contains("private let service: any BackupSettingsServing"))
        XCTAssertTrue(source.contains("private let presentationLogger"))
        XCTAssertFalse(source.contains("import SwiftUI"))
        for forbidden in [
            "BackupManager",
            "AppLogger",
            "AppDatabase.shared",
            "UserDefaults.standard",
            "URLSession.shared",
            "FileManager.default"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Forbidden \(forbidden)")
        }
    }

    func testPreparedAdapterReusesCanonicalBackupManager() throws {
        let dependencySource = try read(
            "Ito/Services/BackupSettings/BackupSettingsDependencies.swift"
        )
        let scopeSource = try read("Ito/AppScope.swift")

        XCTAssertTrue(dependencySource.contains("extension BackupManager: BackupSettingsServing"))
        XCTAssertTrue(dependencySource.contains("Self(service: backupManager)"))
        XCTAssertTrue(scopeSource.contains(
            "backupSettings: .production(backupManager: backupManager)"
        ))
        XCTAssertFalse(dependencySource.contains("BackupManager("))
        XCTAssertFalse(dependencySource.contains("AppDatabase"))
    }

    func testFactoryCreatesFreshScreenModelAndSettingsUsesTypedRoute() throws {
        let factorySource = try appViewFactorySource()
        let settingsSource = try read("Ito/Views/Settings/SettingsView.swift")

        XCTAssertTrue(factorySource.contains("func makeBackupSettingsViewModel()"))
        XCTAssertTrue(factorySource.contains("BackupSettingsViewModel("))
        XCTAssertTrue(factorySource.contains("case .backup:"))
        XCTAssertTrue(settingsSource.contains(
            "makeSettingsDestination(for: .backup)"
        ))
        XCTAssertFalse(settingsSource.contains("destination: BackupSettingsView()"))
    }

    func testRootModelStoreExcludesScreenModelsAndReportStaysReadOnly() throws {
        let scopeSource = try read("Ito/AppScope.swift")
        let rootStore = try XCTUnwrap(
            scopeSource.components(separatedBy: "@MainActor\nfinal class AppScope").first
        )
        let reportSource = try read("Ito/Views/Settings/BackupRestoreReportView.swift")

        XCTAssertFalse(rootStore.contains("BackupSettingsViewModel"))
        XCTAssertFalse(rootStore.contains("MigrationReportViewModel"))
        XCTAssertTrue(reportSource.contains("MigrationReportView.readOnly(report: migrationReport)"))
    }

    func testMigratedSourcesContainNoRawURLPathOrErrorLogging() throws {
        let sources = try [
            "Ito/Views/Settings/BackupSettingsView.swift",
            "Ito/ViewModels/BackupSettingsViewModel.swift"
        ].map(read)

        for source in sources {
            XCTAssertFalse(source.contains("AppLogger"))
            XCTAssertFalse(source.contains("print("))
            XCTAssertFalse(source.contains("logger."))
            XCTAssertFalse(source.contains("absoluteString"))
            XCTAssertFalse(source.contains(".path)"))
        }
        XCTAssertTrue(sources[1].contains("PresentationEventLogging"))
        XCTAssertTrue(sources[1].contains(".failed(.persistence)"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func appViewFactorySource() throws -> String {
        let source = try read("Ito/Views/Search/SearchRouteFactory.swift")
        return try XCTUnwrap(
            source.components(separatedBy: "struct SearchRouteFactory").first
        )
    }
}
