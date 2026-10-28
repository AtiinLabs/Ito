import Foundation
import XCTest

@MainActor
final class SourceControlsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testGroupedCatalogSelectionAndContentChoiceSurviveReopeningSettings() throws {
        let app = try openSource()
        app.buttons["Source settings"].tap()
        let adult = app.switches["Include adult content"]
        XCTAssertTrue(adult.waitForExistence(timeout: 10))
        XCTAssertEqual(adult.value as? String, "0")
        adult.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        openTagPicker(app)

        let search = app.searchFields["Search options"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Tag 0001")
        let option = app.buttons.matching(NSPredicate(format: "label == %@", "Tag 0001")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        option.tap()
        let selected = app.buttons["Remove Tag 0001"]
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        attach(app, name: "Grouped catalog with persisted selection")

        let closeSearch = app.buttons["close"]
        if closeSearch.exists { closeSearch.tap() }
        app.navigationBars["Blocked tags"].buttons.element(boundBy: 0).tap()
        app.navigationBars["Tags"].buttons.element(boundBy: 0).tap()
        app.navigationBars["Rich Controls Example Settings"].buttons["Done"].tap()
        let settings = app.buttons["Source settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(adult.waitForExistence(timeout: 10))
        XCTAssertEqual(adult.value as? String, "1")
        openTagPicker(app)
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        selected.tap()
        XCTAssertFalse(selected.exists)
        attach(app, name: "Selected catalog value can be removed after reload")
    }

    func testStructuredFiltersAndSortDriveSourceResults() throws {
        let app = try openSource()
        let sort = app.buttons["Sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 10))
        sort.tap()
        app.buttons["Title"].tap()
        let filters = app.buttons["Filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 10))
        filters.tap()
        let adult = app.switches["Include adult content"]
        XCTAssertTrue(adult.waitForExistence(timeout: 10))
        adult.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(adult.value as? String, "1")
        attach(app, name: "Draft filter before applying")
        app.buttons["Apply"].tap()
        let first = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Example 000")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        attach(app, name: "Structured browse filter and title ordering")

        let search = app.searchFields["Search source..."]
        search.tap()
        search.typeText("Example 01")
        let suggestion = app.buttons.containing(.staticText, identifier: "Example 010").firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        suggestion.tap()
        let match = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Example 010")).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 10))
        attach(app, name: "A declared suggestion executes its catalog search")
    }

    func testAccessibilityTextSizeKeepsCatalogSelectionUsable() throws {
        let app = try openSource(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        app.buttons["Source settings"].tap()
        openTagPicker(app)
        let search = app.searchFields["Search options"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Tag 5999")
        let option = app.buttons.matching(NSPredicate(format: "label == %@", "Tag 5999")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        option.tap()
        XCTAssertTrue(app.buttons["Remove Tag 5999"].waitForExistence(timeout: 10))
        attach(app, name: "Searchable selection at accessibility text size")
    }

    private func openSource(extraArguments: [String] = []) throws -> XCUIApplication {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "rich-settings", withExtension: "ito", subdirectory: "Fixtures")
                ?? bundle.url(forResource: "rich-settings", withExtension: "ito")
        )
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-reset-storage"] + extraArguments
        app.launchEnvironment["ITO_UI_TEST_PLUGIN_BASE64"] = try Data(contentsOf: url).base64EncodedString()
        app.launch()
        let browse = app.tabBars.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 20))
        browse.tap()
        let source = app.staticTexts["Rich Controls Example"]
        XCTAssertTrue(source.waitForExistence(timeout: 20))
        source.tap()
        XCTAssertTrue(app.buttons["Source settings"].waitForExistence(timeout: 20))
        return app
    }

    private func openTagPicker(_ app: XCUIApplication) {
        let tags = app.staticTexts["Tags"]
        for _ in 0..<6 {
            if tags.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(tags.isHittable)
        tags.tap()
        let blocked = app.staticTexts["Blocked tags"]
        XCTAssertTrue(blocked.waitForExistence(timeout: 10))
        blocked.tap()
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
