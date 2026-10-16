import Foundation
import XCTest
@testable import Ito

final class MigrationReportDependencyBoundaryTests: XCTestCase {
    func testViewRendersOnlyThroughViewModelAndExposesReadOnlyBuilder() throws {
        let source = try read("Ito/Views/Settings/MigrationReportView.swift")

        XCTAssertTrue(source.contains("@StateObject private var viewModel: MigrationReportViewModel"))
        XCTAssertTrue(source.contains("static func readOnly(report: MigrationReport)"))
        for forbidden in [
            "@EnvironmentObject",
            "AppLogger",
            "Task {",
            "RepoManager",
            "PluginManager",
            "PluginResolver",
            "LibrarySourceRemapper",
            "import GRDB",
            "import OSLog"
        ] {
            XCTAssertFalse(source.contains(forbidden), "View must not contain \(forbidden)")
        }
    }

    func testViewModelHasNoPlatformOrLoggingAuthority() throws {
        let source = try read("Ito/ViewModels/MigrationReportViewModel.swift")

        for forbidden in ["AppLogger", "print(", "import SwiftUI", ".shared", "AppDatabase"] {
            XCTAssertFalse(source.contains(forbidden), "ViewModel must not contain \(forbidden)")
        }
    }

    func testDependencyAdapterDoesNotConstructNewAuthorities() throws {
        let source = try read("Ito/Services/MigrationReport/MigrationReportDependencies.swift")

        for forbidden in ["RepoManager(", "PluginManager(", "PluginResolver(", "LibrarySourceRemapper(dbPool", "AppDatabase"] {
            XCTAssertFalse(source.contains(forbidden), "Adapter must not construct \(forbidden)")
        }
    }

    func testReadOnlyBackupReportUsesDependencyFreeBuilder() throws {
        let source = try read("Ito/Views/Settings/BackupRestoreReportView.swift")

        XCTAssertTrue(source.contains("MigrationReportView.readOnly(report: migrationReport)"))
        XCTAssertFalse(source.contains("remediationAllowed"))
        XCTAssertFalse(source.contains("showsDismissButton"))
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
}
