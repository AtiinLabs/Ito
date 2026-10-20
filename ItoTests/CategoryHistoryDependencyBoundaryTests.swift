import XCTest
@testable import Ito

final class CategoryHistoryDependencyBoundaryTests: XCTestCase {
    func testMigratedViewsAndViewModelsHaveNoDirectGlobalsOrManagerOwnership() throws {
        let paths = [
            "Ito/Views/Library/CategoryAssignmentSheet.swift",
            "Ito/Views/Library/CategorySettingsView.swift",
            "Ito/Views/Library/HistoryView.swift",
            "Ito/ViewModels/CategoryAssignmentViewModel.swift",
            "Ito/ViewModels/CategorySettingsViewModel.swift",
            "Ito/ViewModels/HistoryViewModel.swift"
        ]
        let forbidden = [
            "@EnvironmentObject",
            "LibraryManager.shared",
            "HistoryManager.shared",
            "AppDatabase.shared",
            "SnackBarManager.shared",
            "AppLogger",
            "UserDefaults.standard",
            "URLSession.shared",
            "FileManager.default",
            "UIApplication.shared",
            "AnyView",
            ".configure("
        ]

        for path in paths {
            let source = try sourceFile(path)
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "\(path) contains forbidden \(token)")
            }
        }
    }

    func testScreensOwnInjectedViewModelsWithStateObject() throws {
        let assignment = try sourceFile("Ito/Views/Library/CategoryAssignmentSheet.swift")
        let settings = try sourceFile("Ito/Views/Library/CategorySettingsView.swift")
        let history = try sourceFile("Ito/Views/Library/HistoryView.swift")

        XCTAssertTrue(assignment.contains("@StateObject private var viewModel: CategoryAssignmentViewModel"))
        XCTAssertTrue(assignment.contains("init(viewModel: @autoclosure @escaping () -> CategoryAssignmentViewModel)"))
        XCTAssertTrue(settings.contains("@StateObject private var viewModel: CategorySettingsViewModel"))
        XCTAssertTrue(settings.contains("init(viewModel: @autoclosure @escaping () -> CategorySettingsViewModel)"))
        XCTAssertTrue(history.contains("@StateObject private var viewModel: HistoryViewModel"))
        XCTAssertTrue(history.contains("init(viewModel: @autoclosure @escaping () -> HistoryViewModel)"))
    }

    func testEveryCategoryAndHistoryConstructionSiteUsesFactoryComposition() throws {
        let library = try sourceFile("Ito/Views/Library/LibraryView.swift")
        let mediaDetail = try sourceFile("Ito/Views/Browse/MediaDetailView.swift")
        let snackBar = try sourceFile("Ito/Views/Shared/SnackBarOverlay.swift")
        let appFactory = try sourceFile("Ito/Views/Search/SearchRouteFactory.swift")
        let focusedFactory = try sourceFile("Ito/Views/Library/CategoryHistoryViewFactory.swift")

        XCTAssertTrue(library.contains("viewFactory.makeCategoryAssignmentSheet(itemID: intent.id)"))
        XCTAssertTrue(library.contains("viewFactory.makeCategorySettingsView()"))
        XCTAssertTrue(library.contains("viewFactory.makeHistoryView()"))
        XCTAssertTrue(mediaDetail.contains("categoryHistoryViewFactory.makeCategoryAssignmentSheet(itemID: intent.itemID)"))
        XCTAssertTrue(snackBar.contains("categoryHistoryViewFactory.makeCategoryAssignmentSheet(itemID: wrapper.id)"))
        XCTAssertFalse(snackBar.contains("SnackBarManager"))
        XCTAssertTrue(snackBar.contains("messageCenter.dismiss(messageID: toast.id)"))
        XCTAssertTrue(appFactory.contains("let categoryHistoryViewFactory: CategoryHistoryViewFactory"))
        XCTAssertTrue(focusedFactory.contains("CategoryAssignmentSheet(viewModel:"))
        XCTAssertTrue(focusedFactory.contains("CategorySettingsView(viewModel:"))
        XCTAssertTrue(focusedFactory.contains("HistoryView(viewModel:"))

        let allSwift = try allProductionSwiftSource()
        XCTAssertEqual(occurrences(of: "CategoryAssignmentSheet(viewModel:", in: allSwift), 1)
        XCTAssertEqual(occurrences(of: "CategorySettingsView(viewModel:", in: allSwift), 1)
        XCTAssertEqual(occurrences(of: "HistoryView(viewModel:", in: allSwift), 1)
    }

    func testDurableAPIsAreNarrowAndViewsDoNotIssuePersistenceCalls() throws {
        let libraryManager = try sourceFile("Ito/Managers/LibraryManager.swift")
        let historyManager = try sourceFile("Ito/Managers/HistoryManager.swift")
        let views = try [
            "Ito/Views/Library/CategoryAssignmentSheet.swift",
            "Ito/Views/Library/CategorySettingsView.swift",
            "Ito/Views/Library/HistoryView.swift"
        ].map(sourceFile).joined(separator: "\n")

        for signature in [
            "deleteCategoryDurably(id: String) async throws",
            "toggleCategoryDurably(forItemID itemID: String, categoryID: String) async throws",
            "reorderCategoriesDurably(userCategoryIDs: [String]) async throws",
            "createCategoryAndAssignDurably(name: String, itemID: String) async throws -> String"
        ] {
            XCTAssertTrue(libraryManager.contains(signature), "Missing \(signature)")
        }
        XCTAssertTrue(libraryManager.contains("public func renameCategory(id: String, to name: String) async throws"))
        XCTAssertTrue(historyManager.contains("removeEntryDurably(id: String) async throws"))
        XCTAssertTrue(historyManager.contains("clearHistoryDurably() async throws"))
        XCTAssertFalse(views.contains("dbPool"))
        XCTAssertFalse(views.contains("createCategory(name:"))
        XCTAssertFalse(views.contains("renameCategory(id:"))
        XCTAssertFalse(views.contains("deleteCategoryDurably"))
        XCTAssertFalse(views.contains("toggleCategoryDurably"))
        XCTAssertFalse(views.contains("removeEntryDurably"))
        XCTAssertFalse(views.contains("clearHistoryDurably"))
    }

    func testHistoryRowRemainsPurePresentation() throws {
        let source = try sourceFile("Ito/Views/Library/HistoryView.swift")
        let rowStart = try XCTUnwrap(source.range(of: "struct HistoryItemRow"))
        let row = String(source[rowStart.lowerBound...])

        XCTAssertTrue(row.contains("let entry: HistoryEntry"))
        XCTAssertTrue(row.contains("LazyImage"))
        XCTAssertTrue(row.contains("RelativeDateTimeFormatter"))
        XCTAssertFalse(row.contains("ViewModel"))
        XCTAssertFalse(row.contains("HistoryManager"))
    }

    private func sourceFile(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func allProductionSwiftSource() throws -> String {
        let root = repositoryRoot.appendingPathComponent("Ito")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var sources: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            sources.append(try String(contentsOf: url, encoding: .utf8))
        }
        return sources.joined(separator: "\n")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
